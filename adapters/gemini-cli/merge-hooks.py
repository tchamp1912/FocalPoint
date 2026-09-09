#!/usr/bin/env python3
"""Render a Gemini JSON-with-comments settings merge without changing inputs."""
import copy
import json
from pathlib import Path
import shlex
import sys

EVENTS = {"SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent", "BeforeTool", "AfterTool", "BeforeModel", "AfterModel", "BeforeToolSelection", "PreCompress", "Notification"}


def strip_comments(text):
    result = []
    index = 0
    in_string = False
    while index < len(text):
        char = text[index]
        if in_string:
            result.append(char)
            index += 1
            if char == "\\" and index < len(text):
                result.append(text[index])
                index += 1
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        if text[index:index + 2] == "//":
            result.extend("  ")
            index += 2
            while index < len(text) and text[index] not in "\r\n":
                result.append(" ")
                index += 1
            continue
        if text[index:index + 2] == "/*":
            result.extend("  ")
            index += 2
            while index < len(text) and text[index:index + 2] != "*/":
                result.append(text[index] if text[index] in "\r\n" else " ")
                index += 1
            if index == len(text):
                raise ValueError("Unterminated settings comment")
            result.extend("  ")
            index += 2
            continue
        result.append(char)
        index += 1
    return "".join(result)


def reject_constant(value):
    raise ValueError("Invalid JSON constant: " + value)


def load(path):
    return json.loads(strip_comments(Path(path).read_text(encoding="utf-8-sig")), parse_constant=reject_constant)


def merge(original, fragment, executable):
    if not isinstance(original, dict) or not isinstance(original.get("hooks", {}), dict):
        raise ValueError("Gemini settings and hooks must be objects")
    output = copy.deepcopy(original)
    hooks = output.setdefault("hooks", {})
    # Remove owned hooks across every event, including obsolete model and
    # compression hooks that cannot distinguish local child agents.
    for event, groups in list(hooks.items()):
        if not isinstance(groups, list):
            if event in EVENTS:
                raise ValueError("Gemini hook event must be an array: " + event)
            continue
        cleaned = []
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                if event in EVENTS:
                    raise ValueError("Invalid Gemini hook group: " + event)
                cleaned.append(group)
                continue
            remaining = []
            for hook in group["hooks"]:
                if not isinstance(hook, dict):
                    raise ValueError("Invalid Gemini hook configuration: " + event)
                name = hook.get("name", "")
                if not (isinstance(name, str) and name.startswith("focalpoint-gemini-")):
                    remaining.append(hook)
            if remaining or not group["hooks"]:
                group["hooks"] = remaining
                cleaned.append(group)
        hooks[event] = cleaned
    for event, groups in fragment["hooks"].items():
        incoming = copy.deepcopy(groups)
        for group in incoming:
            for hook in group["hooks"]:
                hook["command"] = shlex.quote(executable)
        hooks.setdefault(event, []).extend(incoming)
    return output


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--normalize":
        output = load(sys.argv[2])
    elif len(sys.argv) == 4:
        output = merge(load(sys.argv[1]), load(sys.argv[2]), sys.argv[3])
    else:
        raise ValueError("usage: merge-hooks.sh SETTINGS FRAGMENT EXECUTABLE | --normalize SETTINGS")
    print(json.dumps(output, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("Gemini hook settings: " + str(error), file=sys.stderr)
        sys.exit(1)
