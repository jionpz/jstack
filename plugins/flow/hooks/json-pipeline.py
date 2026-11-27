"""Recognize literal Python consumers that only read and display JSON."""

import ast
import re
import sys


CONSUMER = re.compile(
    r"(?<![\\|])\|[ \t]*(?P<python>python(?:[0-9]+(?:\.[0-9]+)?)?)"
    r"[ \t]+-c[ \t]+(?:'(?P<single>[^']+)'|\"(?P<double>[^\"$`\\]+)\")"
    r"[ \t]*(?=\n|$|;|&&|\|\|)"
)
RESERVED = {"json", "sys", "print"}
DATA_SYNTAX = (
    ast.Module, ast.Expr, ast.Assign, ast.For, ast.DictComp, ast.ListComp,
    ast.comprehension, ast.Constant, ast.Name, ast.Load, ast.Store,
    ast.List, ast.Tuple, ast.Dict, ast.Subscript, ast.Slice,
    ast.alias, ast.Import, ast.Call, ast.Attribute, ast.keyword,
)


def attribute(node, name, member):
    return (
        isinstance(node, ast.Attribute) and node.attr == member
        and isinstance(node.value, ast.Name) and node.value.id == name
    )


def reads_json_only(code):
    try:
        tree = ast.parse(code)
    except (SyntaxError, RecursionError):
        return False
    variables = {
        node.id for node in ast.walk(tree) if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store)
    }
    if RESERVED & variables:
        return False
    json_read = False
    for node in ast.walk(tree):
        if not isinstance(node, DATA_SYNTAX):
            return False
        if isinstance(node, ast.Name) and node.id not in variables | RESERVED:
            return False
        if isinstance(node, (ast.Attribute, ast.Subscript)) and isinstance(node.ctx, ast.Store):
            return False
        if isinstance(node, ast.Import):
            if any(alias.name not in {"json", "sys"} or alias.asname for alias in node.names):
                return False
        elif isinstance(node, ast.Attribute):
            if not (node.attr == "get" or attribute(node, "json", "load") or attribute(node, "sys", "stdin")):
                return False
        elif isinstance(node, ast.Call):
            func = node.func
            if attribute(func, "json", "load"):
                if len(node.args) != 1 or node.keywords or not attribute(node.args[0], "sys", "stdin"):
                    return False
                json_read = True
            elif isinstance(func, ast.Name) and func.id == "print":
                if any(keyword.arg not in {"sep", "end"} for keyword in node.keywords):
                    return False
            elif not (isinstance(func, ast.Attribute) and func.attr == "get" and not node.keywords):
                return False
    return json_read


def mask_consumer(match):
    # Remove the interpreter token from the remote-pipe match only.
    if not reads_json_only(match["single"] or match["double"]):
        return match[0]
    start = match.start("python") - match.start()
    end = match.end("python") - match.start()
    return match[0][:start] + "_" * (end - start) + match[0][end:]


if __name__ == "__main__":
    sys.stdout.write(CONSUMER.sub(mask_consumer, sys.stdin.read()))
