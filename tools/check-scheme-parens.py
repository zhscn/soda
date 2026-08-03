#!/usr/bin/env python3
"""Check delimiter balance in Chez Scheme source files.

The scanner is deliberately small, but understands the lexical constructs
that commonly make a textual parenthesis counter report false positives:
line comments, nested block comments, strings, escaped identifiers, character
literals, and Chez's ``#!...`` directives.  It checks all three delimiter
pairs so a malformed form is reported at the first mismatching token.

Examples:

    tools/check-scheme-parens.py scheme
    tools/check-scheme-parens.py scheme/soda/kernel/state.sls
"""

from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass
from pathlib import Path


OPENERS = "([{"
CLOSERS = ")] }".replace(" ", "")
PAIR = dict(zip(CLOSERS, OPENERS))
SUFFIXES = {".sls", ".ss", ".scm"}


@dataclass(frozen=True)
class Token:
    char: str
    line: int
    column: int


def source_files(paths: list[Path]) -> list[Path]:
    files: list[Path] = []
    for path in paths:
        if path.is_dir():
            files.extend(
                candidate
                for candidate in path.rglob("*")
                if candidate.is_file() and candidate.suffix in SUFFIXES
            )
        elif path.is_file():
            files.append(path)
        else:
            raise FileNotFoundError(path)
    return sorted(set(files))


def scan(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    stack: list[Token] = []
    errors: list[str] = []
    i = 0
    line = 1
    column = 1
    length = len(text)
    block_comment_depth = 0
    in_string = False
    in_escaped_identifier = False

    def advance(char: str) -> None:
        nonlocal line, column
        if char == "\n":
            line += 1
            column = 1
        else:
            column += 1

    def consume() -> str:
        nonlocal i
        char = text[i]
        i += 1
        advance(char)
        return char

    while i < length:
        char = text[i]
        next_char = text[i + 1] if i + 1 < length else ""

        if block_comment_depth:
            if char == "#" and next_char == "|":
                consume()
                consume()
                block_comment_depth += 1
            elif char == "|" and next_char == "#":
                consume()
                consume()
                block_comment_depth -= 1
            else:
                consume()
            continue

        if in_string:
            if char == "\\":
                consume()
                if i < length:
                    consume()
            elif char == '"':
                consume()
                in_string = False
            else:
                consume()
            continue

        if in_escaped_identifier:
            consume()
            if char == "|":
                in_escaped_identifier = False
            elif char == "\\" and i < length:
                consume()
            continue

        # A Scheme line comment, including the first line of a #! directive.
        if char == ";" or (char == "#" and next_char == "!"):
            while i < length and consume() != "\n":
                pass
            continue

        if char == "#" and next_char == "|":
            consume()
            consume()
            block_comment_depth = 1
            continue

        if char == '"':
            consume()
            in_string = True
            continue

        # R6RS escaped identifiers can contain any delimiter.
        if char == "|":
            consume()
            in_escaped_identifier = True
            continue

        # A character literal such as #\( contains a delimiter as data.
        if char == "#" and next_char == "\\":
            consume()
            consume()
            if i < length:
                consume()
            while i < length and not text[i].isspace() and text[i] not in "()[]{};\"|":
                consume()
            continue

        if char in OPENERS:
            stack.append(Token(char, line, column))
            consume()
            continue

        if char in CLOSERS:
            token = Token(char, line, column)
            if not stack:
                errors.append(f"{path}:{line}:{column}: unexpected '{char}'")
            elif stack[-1].char != PAIR[char]:
                opening = stack[-1]
                errors.append(
                    f"{path}:{line}:{column}: '{char}' closes '{opening.char}' "
                    f"opened at {path}:{opening.line}:{opening.column}"
                )
                stack.pop()
            else:
                stack.pop()
            consume()
            continue

        consume()

    if in_string:
        errors.append(f"{path}:{line}:{column}: unterminated string literal")
    if in_escaped_identifier:
        errors.append(f"{path}:{line}:{column}: unterminated escaped identifier")
    if block_comment_depth:
        errors.append(f"{path}:{line}:{column}: unterminated block comment")
    for opening in reversed(stack):
        errors.append(
            f"{path}:{opening.line}:{opening.column}: unclosed '{opening.char}'"
        )
    return errors


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="*",
        type=Path,
        default=[Path("scheme")],
        help="Scheme files or directories (default: scheme)",
    )
    args = parser.parse_args(argv)
    try:
        files = source_files(args.paths)
    except FileNotFoundError as error:
        print(f"check-scheme-parens: path does not exist: {error.args[0]}", file=sys.stderr)
        return 2

    errors = [error for path in files for error in scan(path)]
    if errors:
        print("\n".join(errors), file=sys.stderr)
        print(f"check-scheme-parens: {len(errors)} error(s) in {len(files)} file(s)", file=sys.stderr)
        return 1
    print(f"check-scheme-parens: {len(files)} file(s) balanced")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
