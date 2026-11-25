BEGIN {
    quote = sprintf("%c", 39)
    word_pattern = "^([[:alnum:]_./,:=%+@-]+|" quote "[^" quote "]*" quote "|\"[^\"]*\")([ \t]|$)"
}

function literal_head(source,    program, word, first, options, needs_value) {
    sub(/^[ \t]+/, "", source)
    if (!match(source, /^(rg|grep|cat|printf)([ \t]|$)/)) return ""
    program = substr(source, 1, RLENGTH)
    sub(/[ \t]$/, "", program)
    source = substr(source, RLENGTH + 1)
    options = 1

    while (1) {
        sub(/^[ \t]+/, "", source)
        if (source == "") return needs_value ? "" : program
        if (!match(source, word_pattern)) return ""
        word = substr(source, 1, RLENGTH)
        source = substr(source, RLENGTH + 1)
        sub(/[ \t]$/, "", word)
        first = substr(word, 1, 1)
        if (first == "=") return ""
        if (first == "\"" && word ~ /[$`\\]/) return ""
        if (first == quote || first == "\"") word = substr(word, 2, length(word) - 2)

        if (needs_value) {
            if (word ~ /^-/) return ""
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
}

NR == 1 { head = literal_head($0) }
NR > 1 { exit 1 }
END {
    if (NR != 1 || head == "") exit 1
    print head
}
