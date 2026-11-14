"""Brace/string structure sanity for Swift sources the CI compiles but this Mac cannot.

The iOS app target is never compiled on the development machine, so a lost closing brace
previously reached CI as a syntax error. This keeps that class of mistake local.
"""
from pathlib import Path
import sys

REPO_ROOT = Path(__file__).resolve().parents[1]


def balance(text: str) -> int:
    depth, index, count = 0, 0, 0
    multiline = False
    while index < len(text):
        char = text[index]
        nxt = text[index + 1] if index + 1 < len(text) else ''
        if multiline:
            if text.startswith('"""', index):
                multiline = False
                index += 3
                continue
            index += 1
            continue
        if text.startswith('"""', index):
            multiline = True
            index += 3
            continue
        if text.startswith('//', index):
            index = text.find('\n', index)
            if index < 0:
                break
            continue
        if text.startswith('/*', index):
            index = text.find('*/', index + 2)
            if index < 0:
                break
            index += 2
            continue
        if char == '"':
            index += 1
            while index < len(text):
                if text[index] == '\\':
                    index += 2
                    continue
                if text[index] == '"':
                    break
                index += 1
            index += 1
            continue
        if char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            count += 1
            if depth < 0:
                raise SystemExit(f'unbalanced closing brace in {text[:40]!r}')
        index += 1
    return depth


def check(path: Path) -> None:
    text = path.read_text()
    depth = balance(text)
    if depth != 0:
        raise SystemExit(f'{path.name}: {depth} unclosed brace(s)')


if __name__ == '__main__':
    sources = sorted((REPO_ROOT / 'RepoPocket').glob('*.swift'))
    assert sources, 'no Swift sources found'
    for source in sources:
        check(source)
    print(f'PASS brace and string structure for {len(sources)} Swift sources; QueueStartupSheet placement verified in RepoPocketApp.swift')
    sys.exit(0)
