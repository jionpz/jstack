BEGIN {
    quote = sprintf("%c", 39)
    word_pattern = "^([[:alnum:]_./,:=%+@~-]+|" quote "[^" quote "]*" quote "|\"[^\"]*\")([ \t]|$)"
}

function read_words(source, words,    count, word, first) {
    words["static"] = 1
    while (1) {
        sub(/^[ \t]+/, "", source)
        if (source == "") return count
        if (!match(source, word_pattern)) return 0
        word = substr(source, 1, RLENGTH)
        source = substr(source, RLENGTH + 1)
        sub(/[ \t]$/, "", word)
        first = substr(word, 1, 1)
        if (first == "\"" && word ~ /[$`\\]/) return 0
        if (first == quote || first == "\"") {
            word = substr(word, 2, length(word) - 2)
        } else if (first == "=") {
            return 0
        } else if (word ~ /~/) {
            words["static"] = 0
        }
        words[++count] = word
    }
}

function literal_head(source, words, count,    program, position, word, options, needs_value) {
    if (!words["static"]) return ""
    if (!match(source, /^[ \t]*(rg|grep|cat|printf|git|head|tail)([ \t]|$)/)) return ""
    program = words[1]
    position = 2
    if (program == "git") {
        if (count < 2 || words[2] != "grep") return ""
        program = "git grep"
        position = 3
    }
    options = 1
    for (; position <= count; position++) {
        word = words[position]
        if (needs_value) {
            if (program == "head" || program == "tail") {
                if (word !~ /^[0-9]+$/) return ""
            } else if (word ~ /^-/) {
                return ""
            }
            needs_value = 0
        } else if (options) {
            if (program == "printf") {
                if (word ~ /^-/ || (word ~ /%/ && word != "%s" && word != "%s\\n")) return ""
                options = 0
            } else if (word == "--") {
                options = 0
            } else if (word !~ /^-/ || word == "-") {
                continue
            } else if (program == "cat") {
                if (word !~ /^-[AbEntTuv]+$/) return ""
            } else if (program == "head" || program == "tail") {
                if (word ~ /^-[nc]$/) needs_value = 1
                else if (word !~ /^-[0-9]+$/) return ""
            } else if (program == "git grep") {
                if (word == "-e") needs_value = 1
                else if (word !~ /^-[nFiwsvxqHhclo]+$/ &&
                         word !~ /^--(fixed-strings|ignore-case|line-number|only-matching)$/) return ""
            } else if (word ~ /^-[nFiwsvxqHhclLoUV]+$/ ||
                       word ~ /^--(fixed-strings|ignore-case|line-number|no-heading|no-config|hidden|files|files-with-matches|only-matching)$/) {
                continue
            } else if (word ~ /^(-[efmABC]|--(regexp|file|max-count|after-context|before-context|context|include|exclude))$/ ||
                       (program == "rg" && word ~ /^(-[gtT]|--(glob|type|type-not))$/)) {
                needs_value = 1
            } else if (word !~ /^--(regexp|file|max-count|after-context|before-context|context|include|exclude)=/ &&
                       !(program == "rg" && word ~ /^--(glob|type|type-not)=/)) {
                return ""
            }
        }
    }
    return needs_value ? "" : program
}

function operator_position(source,    position, char, quoted) {
    for (position = 1; position <= length(source); position++) {
        char = substr(source, position, 1)
        if (quoted != "") {
            if (char == quoted) quoted = ""
            else if (quoted == "\"" && char == "\\") return -1
        } else if (char == quote || char == "\"") {
            quoted = char
        } else if (char ~ /[;&|]/) {
            return position
        } else if (char == "\\") {
            return -1
        }
    }
    return quoted == "" ? 0 : -1
}

function project_compound(source,    result, original, projected, safe, piped, segment, op, position, words, count, head, separators, changed) {
    safe = 1
    while (1) {
        op = ""
        segment = source
        position = operator_position(source)
        if (position < 0) return ""
        if (position) {
            segment = substr(source, 1, position - 1)
            op = substr(source, position, 2)
            if (op != "&&" && op != "||") op = substr(op, 1, 1)
            if (op == "&") return ""
            source = substr(source, position + length(op))
        }
        count = read_words(segment, words)
        if (!count) return ""
        head = literal_head(segment, words, count)
        if (head == "" || (piped && head !~ /^(cat|grep|rg|head|tail)$/)) safe = 0
        separators = segment
        gsub(/[^;&|]+/, " ", separators)
        original = original segment
        projected = projected head separators
        if (op == "|") {
            original = original op
            projected = projected op
            piped = 1
        } else {
            if (safe) changed = 1
            result = result (safe ? projected : original) op
            if (op == "" || (op == ";" && source ~ /^[ \t]*$/)) return changed ? result : ""
            original = projected = ""
            safe = 1
            piped = 0
        }
    }
}

NR == 1 {
    count = read_words($0, words)
    if (count) projection = literal_head($0, words, count)
    if (projection == "") projection = project_compound($0)
}
NR > 1 { exit 1 }
END {
    if (NR != 1 || projection == "") exit 1
    print projection
}
