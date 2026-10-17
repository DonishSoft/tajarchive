#!/usr/bin/env python3
"""Wrap user-visible string literals in L("…") so they can be translated.

The app uses English text as the localization key for strings added after the
original dotted keys (toolbar.add, compress.title, …). L() returns the key itself
when a language has no entry, so English needs no table at all and every other
language falls back to English instead of showing a raw key.

Only literals in positions that are certainly user-visible are touched: label and
button titles, menu items, alert texts, placeholders, tooltips and status lines.
Command-line switches, file extensions, identifiers and `return` statements are
left alone on purpose — those are handled by hand where they are UI.

Interpolated literals ("Extract \\(name)") are reported, not rewritten: they need
a format string with the right specifier, which a regex cannot infer safely.

Usage:  localize_literals.py [--apply] FILE...
"""
import re
import sys

# Call sites whose next argument is a user-visible string
PREFIXES = [
    r"NSTextField\(labelWithString:\s*",
    r"NSTextField\(wrappingLabelWithString:\s*",
    r"NSButton\(title:\s*",
    r"NSButton\(checkboxWithTitle:\s*",
    r"NSButton\(radioButtonWithTitle:\s*",
    r"NSMenuItem\(title:\s*",
    r"NSMenu\(title:\s*",
    r"addItem\(withTitle:\s*",
    r"insertItem\(withTitle:\s*",
    r"addButton\(withTitle:\s*",
    r"\.title\s*=\s*",
    r"\.messageText\s*=\s*",
    r"messageText\s*=\s*",
    r"\.informativeText\s*=\s*",
    r"informativeText\s*=\s*",
    r"placeholderString\s*=\s*",
    r"toolTip\s*=\s*",
    r"updateStatus\(\s*",
    r"\.stringValue\s*=\s*",
    r"\.label\s*=\s*",
    r"paletteLabel\s*=\s*",
    r"showSimpleAlert\(title:\s*",
    r"showAlert\(message:\s*",
    r"showFailureAlert\(title:\s*",
    r"operationName:\s*",
    r"prompt\s*=\s*",
    r"\.message\s*=\s*",
    r"setTitle\(\s*",
    r"suppressionButton\?\.title\s*=\s*",
    r"\btext:\s*",
    r"detail:\s*",
    r"\btitle:\s*",
]

LITERAL = r'"((?:[^"\\\n]|\\.)*)"'
PATTERN = re.compile(r"(?P<prefix>" + "|".join(PREFIXES) + r")" + LITERAL)

# Things that look like text but are not prose
NOT_PROSE = re.compile(r"^(?:[\W\d_]*|[a-z]+\.[a-z.]+|-\w.*|%[@d].*)$")


def is_prose(literal: str) -> bool:
    if not re.search(r"[A-Za-zА-Яа-я]{2,}", literal):
        return False
    if NOT_PROSE.match(literal):
        return False
    return True


def already_wrapped(text: str, start: int) -> bool:
    return text[max(0, start - 2):start] == "L("


def process(path: str, apply: bool) -> tuple[int, list[str]]:
    source = open(path, encoding="utf-8").read()
    replacements = 0
    interpolated = []
    out = []
    last = 0
    for match in PATTERN.finditer(source):
        literal = match.group(2)
        literal_start = match.start(2) - 1  # opening quote
        if already_wrapped(source, literal_start) or not is_prose(literal):
            continue
        # Skip multi-line string literals (""")
        if source[literal_start:literal_start + 3] == '"""':
            continue
        if "\\(" in literal:
            line = source.count("\n", 0, literal_start) + 1
            interpolated.append(f"{path}:{line}: \"{literal}\"")
            continue
        out.append(source[last:literal_start])
        out.append(f'L("{literal}")')
        last = match.end(2) + 1  # closing quote
        replacements += 1
    out.append(source[last:])
    if apply and replacements:
        open(path, "w", encoding="utf-8").write("".join(out))
    return replacements, interpolated


def main() -> None:
    args = sys.argv[1:]
    apply = "--apply" in args
    files = [a for a in args if a != "--apply"]
    total = 0
    all_interpolated = []
    for path in files:
        count, interpolated = process(path, apply)
        total += count
        all_interpolated += interpolated
        if count:
            print(f"{count:4d}  {path}")
    print(f"\n{'Wrapped' if apply else 'Would wrap'} {total} literals.")
    if all_interpolated:
        print(f"\n{len(all_interpolated)} interpolated literals need manual format strings:")
        for item in all_interpolated:
            print("  " + item)


if __name__ == "__main__":
    main()
