#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_localizations.py — generate <code>.lproj/Localizable.strings for TajArchive
from the upstream 7-Zip Windows GUI translations.

Source of the translations
--------------------------
The 7-Zip source tarball does NOT ship the GUI language files; they live in the
Windows distribution.  Fetch and unpack them like this (already done once, the
result is kept in Vendor/7z2501-lang/):

    curl -O https://www.7-zip.org/a/7z2501.exe          # main Windows installer
    ./7-Zip/7-Zip/Resources/7zz x 7z2501.exe -o7z2501-lang 'Lang/*'

(Note: 7z2501-extra.7z contains only the console tools — no Lang folder.)

Upstream file format ("Lang2")
------------------------------
Each Lang/<code>.txt is UTF-8, usually with a BOM, and is *positional* rather
than key/value.  A line consisting solely of digits opens a block and sets the
current Windows resource ID; every following non-comment line is the string for
the current ID, which then increments.  Blank lines are untranslated slots and
still consume an ID, which is what keeps every language aligned with English.

    ;!@Lang2@!UTF-8!
    ; 24.04 : Igor Pavlov      <- ';' starts a comment
    0
    7-Zip                      <- ID 0
    German                     <- ID 1  (language name in English)
    Deutsch                    <- ID 2  (language name, native)
    401
    OK                         <- ID 401
    Abbrechen                  <- ID 402
                               <- ID 403 (blank = untranslated)

English itself ships as Lang/en.ttt (the '.ttt' extension keeps 7-Zip from
offering it as a selectable language); it is the reference for the ID space.

What this script does
---------------------
* parses every Lang/*.txt into {resourceID: string},
* maps upstream resource IDs onto this app's string keys via KEY_TO_RESOURCE_ID,
  and — for every other key — by matching the key's English text against
  Lang/en.ttt (ignoring accelerators, trailing colons/ellipses and case),
* normalises Windows-isms (accelerators, trailing colons/ellipses),
* writes <code>.lproj/Localizable.strings for every language: every dotted key
  (translated, or English so no raw key can reach the UI) plus whichever
  English-text keys have an upstream translation — a missing English-text key
  already falls back to its own English text at run time,
* leaves the hand-written locales (en, ru, tg) alone entirely,
* preserves hand-written translations already present on disk (existing wins).

Idempotent: re-running produces byte-identical output.  English-fallback lines
are tagged with a trailing `/* en */` comment so that a later run can tell a
real translation apart from a placeholder and refresh the placeholders only.

Usage:
    python3 Scripts/build_localizations.py [--dry-run] [--force] [--quiet]
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

# --------------------------------------------------------------------------
# Paths (all derived from this script's location: Scripts/ -> repo root)
# --------------------------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LANG_DIR = REPO_ROOT / "Vendor" / "7z2501-lang" / "Lang"
DEFAULT_RESOURCES_DIR = REPO_ROOT / "7-Zip" / "7-Zip" / "Resources"
BASE_LOCALE = "en"  # en.lproj is the hand-written source of truth; never rewritten

# Hand-written localisations that --force must never clobber.
PROTECTED_LOCALES = {"en", "ru", "tg"}

# Marker appended to values that fall back to English.  Lets a later run
# distinguish a placeholder from a genuine translation when merging.
FALLBACK_MARKER = "/* en */"


# --------------------------------------------------------------------------
# Mapping: this app's Localizable.strings key -> upstream 7-Zip resource ID
# --------------------------------------------------------------------------
#
# Derived by reading en.lproj/Localizable.strings and locating the matching
# English text in Lang/en.ttt.  The comment on each line is the *upstream*
# English string for that ID, so every mapping can be audited at a glance.
#
# Deliberately NOT mapped (see UNMAPPED_NOTES at the bottom for the reasons):
# anything with a %-format specifier whose shape differs upstream, anything
# carrying the "7-Zip"/"TajArchive" brand name, and app-specific UI that simply
# has no counterpart in the Windows GUI (themes, file associations, About box).

KEY_TO_RESOURCE_ID: dict[str, int] = {
    # --- Toolbar ------------------------------------------------------------
    "toolbar.add":            7200,  # "Add"
    "toolbar.extract":        7201,  # "Extract"
    "toolbar.test":           7202,  # "Test"
    "toolbar.delete":         7205,  # "Delete"
    "toolbar.info":           7206,  # "Info"

    # --- Navigation ---------------------------------------------------------
    "nav.up":                  735,  # "Up One Level" (7-Zip's parent-folder command)

    # --- Status -------------------------------------------------------------
    "status.extracting":      3300,  # "Extracting"
    "status.compressing":     3301,  # "Compressing"
    "status.testing":         3302,  # "Testing"

    # --- Menu ---------------------------------------------------------------
    "menu.preferences":        900,  # "&Options..."  (Tools > Options == Preferences on macOS)
    "menu.file":               500,  # "&File"
    "menu.edit":               501,  # "&Edit"
    "menu.view":               502,  # "&View"
    "menu.archive":           4001,  # "&Archive:"    (colon stripped, our key has none)
    "menu.help":               505,  # "&Help"

    # --- File list columns --------------------------------------------------
    "column.name":            1004,  # "Name"
    "column.size":            1007,  # "Size"
    "column.packed":          1008,  # "Packed Size"
    "column.modified":        1012,  # "Modified"

    # --- Compress sheet -----------------------------------------------------
    "compress.title":         4000,  # "Add to archive"     (the compress dialog's title)
    "compress.archive_name":  4001,  # "&Archive:"
    "compress.format":        4003,  # "Archive &format:"
    "compress.level":         4004,  # "Compression &level:"
    "compress.method":        4005,  # "Compression &method:"
    "compress.password":      3807,  # "Password"           (colon added, our key has one)
    "compress.encrypt_names": 4016,  # "Encrypt file &names"
    "compress.browse":        4070,  # "Browse"             (ellipsis added to match ours)
    "compress.cancel":         402,  # "Cancel"

    # --- Compression levels -------------------------------------------------
    "level.store":            4050,  # "Store"
    "level.fastest":          4051,  # "Fastest"
    "level.fast":             4052,  # "Fast"
    "level.normal":           4053,  # "Normal"
    "level.maximum":          4054,  # "Maximum"
    "level.ultra":            4055,  # "Ultra"

    # --- Extract ------------------------------------------------------------
    "extract.title":          3400,  # "Extract"            (the extract dialog's title)
    "extract.to":             3401,  # "E&xtract to:"
    "extract.here":           2326,  # "Extract Here"
    "extract.password_title": 3800,  # "Enter password"     (password prompt title)
    "extract.password_msg":   3801,  # "Enter password:"

    # --- Preferences --------------------------------------------------------
    "prefs.select_all":        600,  # "Select &All"
    "prefs.deselect_all":      601,  # "Deselect All"
    "prefs.language":         2102,  # "Language:"

    # --- Common dialogs -----------------------------------------------------
    "dialog.ok":               401,  # "OK"
    "dialog.cancel":           402,  # "Cancel"
    "dialog.error":           1055,  # "Error"
    "dialog.warning":         1073,  # "Warning"
    "dialog.confirm_delete":  6100,  # "Confirm File Delete"
    "dialog.delete":          7205,  # "Delete"
    "dialog.open":             540,  # "&Open"

    # --- Archive info -------------------------------------------------------
    "info.title":             6600,  # "Properties"
    "info.path":              1003,  # "Path"
    "info.type":              1020,  # "Type"
    "info.size":              1007,  # "Size"
    "info.packed_size":       1008,  # "Packed Size"
    "info.files":             1032,  # "Files"
    "info.folders":           1031,  # "Folders"
}

# Why the remaining app keys have no upstream counterpart.  Kept next to the
# table so the two stay in sync when either side grows.
UNMAPPED_NOTES: dict[str, str] = {
    "toolbar.search":           "7-Zip's Windows GUI has no Search command",
    "nav.back":                 "no history Back/Forward in the Windows GUI",
    "nav.forward":              "no history Back/Forward in the Windows GUI",
    "status.ready":             "no equivalent",
    "status.items":             "'%d items' has no upstream counterpart",
    "status.items_selected":    "upstream 3002 is '{0} object(s) selected' — one placeholder, ours needs two",
    "status.loading":           "upstream 3303/3304 are 'Opening...'/'Scanning...', different meaning",
    "menu.about":               "upstream 961/2900 hard-code the '7-Zip' product name",
    "column.crc":               "'CRC' is an untranslated acronym everywhere",
    "compress.destination":     "no equivalent field in the Add dialog",
    "compress.compress":        "upstream has only the gerund 'Compressing', no imperative verb",
    "compress.volume_size":     "upstream 7302 is 'Split to volumes, bytes:', too different",
    "compress.no_split":        "no equivalent",
    "compress.total_size":      "'Total: %@' — upstream 3902 'Total size:' carries no placeholder",
    "extract.success":          "no equivalent",
    "extract.success_msg":      "'%d' placeholder with no upstream counterpart",
    "extract.error":            "no equivalent",
    "prefs.title":              "carries the TajArchive brand name",
    "prefs.file_assoc":         "upstream 2201 hard-codes '7-Zip'",
    "prefs.general":            "no equivalent",
    "prefs.choose_formats":     "app-specific sentence",
    "prefs.apply":              "no equivalent",
    "prefs.default":            "no equivalent",
    "prefs.appearance":         "macOS-only concept",
    "prefs.theme_system":       "macOS-only concept",
    "prefs.theme_dark":         "macOS-only concept",
    "prefs.theme_light":        "macOS-only concept",
    "prefs.auto_claim":         "app-specific sentence",
    "prefs.assoc_updated":      "app-specific",
    "prefs.assoc_claimed":      "app-specific, two placeholders",
    "about.title":              "carries the TajArchive brand name",
    "about.version":            "'%@' placeholders",
    "about.copyright":          "app-specific",
    "about.opensource":         "app-specific licence text",
    "about.licenses":           "no equivalent",
    "about.website":            "app-specific",
    "dialog.confirm_delete_msg": "no equivalent",
    "dialog.save":              "no Save command in the Windows GUI",
}


# --------------------------------------------------------------------------
# Upstream language code -> macOS locale code (the .lproj folder name)
# --------------------------------------------------------------------------
# Only codes that differ from the upstream spelling are listed; everything else
# passes through unchanged (de -> de, ja -> ja, ...).

LOCALE_OVERRIDES: dict[str, str] = {
    "zh-cn":   "zh-Hans",   # Chinese Simplified
    "zh-tw":   "zh-Hant",   # Chinese Traditional
    "pt-br":   "pt-BR",     # Portuguese (Brazil)
    "pt":      "pt-PT",     # upstream "pt" is explicitly "Portuguese Portugal"
    "sr-spc":  "sr",        # Serbian Cyrillic is the default script for "sr"
    "sr-spl":  "sr",        # Serbian Latin — collides with the above, skipped as a duplicate
    "uz-cyrl": "uz-Cyrl",   # Uzbek in Cyrillic script
    "ku-ckb":  "ckb",       # Sorani (Central Kurdish) has its own ISO 639-3 code
    "mng":     "mn-Mong",   # Mongolian in the traditional Mongolian script
    "pa-in":   "pa",        # Punjabi (Gurmukhi); macOS uses plain "pa"
}

# Upstream files we deliberately do not ship, with the reason shown in the report.
SKIP_LANGS: dict[str, str] = {
    "mng2": "Mongolian in the private 'MenkCode' font encoding, not Unicode "
            "(its own native-name field is empty) — unusable on macOS",
    "va":   "Valencian has no ISO 639 / BCP-47 identifier of its own; "
            "Catalan (ca) is already shipped",
}


# --------------------------------------------------------------------------
# Upstream .txt parsing
# --------------------------------------------------------------------------

_NUMERIC_LINE = re.compile(r"\A\d+\Z")


def parse_upstream(path: Path) -> dict[int, str]:
    """Parse a 7-Zip Lang2 file into {resourceID: string}.

    Blank lines consume an ID without producing an entry — that is what keeps
    every translation aligned with the English reference.
    """
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):  # UTF-8 BOM
        raw = raw[3:]
    text = raw.decode("utf-8", errors="replace")

    strings: dict[int, str] = {}
    current: int | None = None
    for line in text.split("\n"):
        line = line.rstrip("\r")
        if line.startswith(";"):  # comment
            continue
        stripped = line.strip()
        if _NUMERIC_LINE.match(stripped):
            current = int(stripped)
            continue
        if current is None:  # text before the first block marker
            continue
        if stripped:
            strings[current] = stripped
        current += 1
    return strings


# --------------------------------------------------------------------------
# .strings parsing / writing
# --------------------------------------------------------------------------

_STRINGS_LINE = re.compile(r'\A\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')

_UNESCAPE = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'"}


def unescape(s: str) -> str:
    out: list[str] = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            nxt = s[i + 1]
            if nxt == "U" or nxt == "u":
                out.append(chr(int(s[i + 2:i + 6], 16)))
                i += 6
                continue
            out.append(_UNESCAPE.get(nxt, nxt))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def escape(s: str) -> str:
    return (
        s.replace("\\", "\\\\")
         .replace('"', '\\"')
         .replace("\n", "\\n")
         .replace("\t", "\\t")
         .replace("\r", "\\r")
    )


def parse_strings_file(path: Path) -> dict[str, tuple[str, bool]]:
    """Read a .strings file -> {key: (value, is_english_fallback)}."""
    result: dict[str, tuple[str, bool]] = {}
    if not path.is_file():
        return result
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    for line in raw.decode("utf-8", errors="replace").splitlines():
        m = _STRINGS_LINE.match(line)
        if not m:
            continue
        result[unescape(m.group(1))] = (
            unescape(m.group(2)),
            FALLBACK_MARKER in line[m.end():],
        )
    return result


def read_base_layout(path: Path) -> list[tuple[str, str]]:
    """Read en.lproj/Localizable.strings preserving order, comments and blanks.

    Returns a list of ('entry', key) / ('comment', text) / ('blank', '') items
    so the generated files mirror the English file's grouping.
    """
    layout: list[tuple[str, str]] = []
    raw = path.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        raw = raw[3:]
    for line in raw.decode("utf-8").splitlines():
        m = _STRINGS_LINE.match(line)
        if m:
            layout.append(("entry", unescape(m.group(1))))
        elif not line.strip():
            layout.append(("blank", ""))
        elif line.lstrip().startswith("/*"):
            layout.append(("comment", line.rstrip()))

    # Drop the base file's own header (leading comments plus the blank line
    # that follows them); each generated file gets its own header instead.
    i = 0
    while i < len(layout) and layout[i][0] == "comment":
        i += 1
    if i:
        while i < len(layout) and layout[i][0] == "blank":
            i += 1
        layout = layout[i:]
    return layout


# --------------------------------------------------------------------------
# Normalisation of Windows-isms
# --------------------------------------------------------------------------

# CJK translations spell accelerators as a trailing "(&F)" — drop the whole group.
_CJK_ACCEL = re.compile(r"\s*\(&[A-Za-z0-9]\)")
_FORMAT_SPEC = re.compile(r"%(?:\d+\$)?[@a-zA-Z%]|\{\d+\}")

_TRAILING_ELLIPSIS = re.compile(r"(?:\.\.\.|…|。。。)\s*\Z")
_TRAILING_COLON = re.compile(r"[:：]\s*\Z")


def strip_accelerators(s: str) -> str:
    s = _CJK_ACCEL.sub("", s)
    # "&&" is a literal ampersand; a lone "&" before a character is the marker.
    out: list[str] = []
    i = 0
    while i < len(s):
        if s[i] == "&":
            if i + 1 < len(s) and s[i + 1] == "&":
                out.append("&")
                i += 2
                continue
            i += 1  # drop the accelerator marker
            continue
        out.append(s[i])
        i += 1
    return "".join(out)


def normalise(translated: str, english: str) -> str | None:
    """Shape an upstream string to match our key's English text.

    Returns None when the result cannot be trusted (format-specifier mismatch),
    in which case the caller falls back to English.
    """
    s = strip_accelerators(translated).strip()
    if not s:
        return None

    # Trailing ellipsis: match whatever our English text does.
    s = _TRAILING_ELLIPSIS.sub("", s).rstrip()
    if _TRAILING_ELLIPSIS.search(english):
        s += "…"

    # Trailing colon: likewise.
    s = _TRAILING_COLON.sub("", s).rstrip()
    if _TRAILING_COLON.search(english):
        s += ":"

    s = s.strip()
    if not s:
        return None

    # Safety net: a translation must carry exactly the format specifiers our
    # English text carries, or String(format:) will read garbage off the stack.
    if sorted(_FORMAT_SPEC.findall(s)) != sorted(_FORMAT_SPEC.findall(english)):
        return None
    # Belt and braces: no stray '%' or '{' unless our English has them too.
    if ("%" in s or "{" in s) and not ("%" in english or "{" in english):
        return None

    return s


_DOTTED_KEY = re.compile(r"\A[a-z_]+\.[a-z_0-9]+\Z")


def is_dotted(key: str) -> bool:
    """Dotted keys ("compress.title") must always resolve; English-text keys need not."""
    return bool(_DOTTED_KEY.match(key))


def text_signature(s: str) -> str:
    """Comparable form of a UI string: no accelerators, trailing ':'/'…', case or spacing."""
    s = strip_accelerators(s).strip()
    s = _TRAILING_ELLIPSIS.sub("", s).rstrip()
    s = _TRAILING_COLON.sub("", s).rstrip()
    return " ".join(s.lower().split())


def build_text_index(english_upstream: dict[int, str]) -> dict[str, int]:
    """English text signature -> upstream resource ID (the first ID wins on ties)."""
    index: dict[str, int] = {}
    for rid in sorted(english_upstream):
        sig = text_signature(english_upstream[rid])
        if sig and not _FORMAT_SPEC.search(sig):
            index.setdefault(sig, rid)
    return index


# --------------------------------------------------------------------------
# Generation
# --------------------------------------------------------------------------

def build_file(locale: str,
               native_name: str,
               english_name: str,
               upstream: dict[int, str],
               base_layout: list[tuple[str, str]],
               base_values: dict[str, str],
               existing: dict[str, tuple[str, bool]],
               source_code: str,
               text_index: dict[str, int]) -> tuple[str, int, int]:
    """Render one Localizable.strings. Returns (text, n_translated, n_fallback)."""
    lines: list[str] = [
        f"/* {native_name} ({english_name}) — {locale} */",
        f"/* Generated by Scripts/build_localizations.py from 7-Zip Lang/{source_code}.txt. */",
        # NB: must not embed FALLBACK_MARKER here — old-style plists do not
        # nest comments, and a literal "/* en */" inside this one would end it
        # early and make the file unparseable.
        '/* Lines carrying a trailing "en" comment have no upstream */',
        "/* translation and fall back to the English text.            */",
        "",
    ]

    translated = fallback = 0
    for kind, payload in base_layout:
        if kind == "blank":
            lines.append("")
            continue
        if kind == "comment":
            lines.append(payload)
            continue

        key = payload
        english = base_values[key]

        value: str | None = None

        # 1. A hand-written translation already on disk always wins.
        prior = existing.get(key)
        if prior is not None and not prior[1] and prior[0] != english:
            value = prior[0]

        # 2. Otherwise take the upstream translation, if we have a mapping —
        #    explicit first, then by matching the English text.
        if value is None:
            rid = KEY_TO_RESOURCE_ID.get(key)
            if rid is None:
                rid = text_index.get(text_signature(english))
            if rid is not None and rid in upstream:
                value = normalise(upstream[rid], english)

        if value is None and not is_dotted(key):
            continue  # an English-text key falls back to itself at run time
        if value is None:
            translated_line = (
                f'"{escape(key)}" = "{escape(english)}"; {FALLBACK_MARKER}'
            )
            fallback += 1
        else:
            translated_line = f'"{escape(key)}" = "{escape(value)}";'
            translated += 1
        lines.append(translated_line)

    return "\n".join(lines).rstrip() + "\n", translated, fallback


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--lang-dir", type=Path, default=DEFAULT_LANG_DIR,
                    help="upstream 7-Zip Lang folder (default: %(default)s)")
    ap.add_argument("--resources-dir", type=Path, default=DEFAULT_RESOURCES_DIR,
                    help="folder holding the *.lproj directories (default: %(default)s)")
    ap.add_argument("--dry-run", action="store_true",
                    help="report only, write nothing")
    ap.add_argument("--force", action="store_true",
                    help="ignore translations already on disk and regenerate from "
                         f"upstream (never applies to {sorted(PROTECTED_LOCALES)})")
    ap.add_argument("--quiet", action="store_true", help="suppress the per-language table")
    args = ap.parse_args(argv)

    lang_dir: Path = args.lang_dir
    res_dir: Path = args.resources_dir

    if not lang_dir.is_dir():
        print(f"error: upstream Lang folder not found: {lang_dir}\n"
              f"       see the module docstring for how to fetch it.", file=sys.stderr)
        return 2

    base_path = res_dir / f"{BASE_LOCALE}.lproj" / "Localizable.strings"
    if not base_path.is_file():
        print(f"error: base strings file not found: {base_path}", file=sys.stderr)
        return 2

    base_layout = read_base_layout(base_path)
    base_values = {k: v for k, (v, _) in parse_strings_file(base_path).items()}
    app_keys = [k for kind, k in base_layout if kind == "entry"]

    # Sanity: every mapped key must exist in the app.
    stray = sorted(set(KEY_TO_RESOURCE_ID) - set(app_keys))
    if stray:
        print(f"note: mapping table references keys the app no longer uses: {stray}", file=sys.stderr)

    english_upstream = parse_upstream(lang_dir / "en.ttt")
    text_index = build_text_index(english_upstream)
    mapped_total = len([k for k in app_keys
                        if k in KEY_TO_RESOURCE_ID or text_signature(base_values[k]) in text_index])
    print(f"App keys: {len(app_keys)}   mapped to upstream IDs: {mapped_total}   "
          f"app-specific (English only): {len(app_keys) - mapped_total}")
    print(f"Upstream: {lang_dir}")
    print(f"Output:   {res_dir}")
    print()

    sources = sorted(lang_dir.glob("*.txt"), key=lambda p: p.stem)
    seen_locales: dict[str, str] = {}
    rows: list[tuple[str, str, str, int, int]] = []
    skipped: list[tuple[str, str]] = []
    written = 0

    for src in sources:
        code = src.stem
        if code in SKIP_LANGS:
            skipped.append((code, SKIP_LANGS[code]))
            continue

        locale = LOCALE_OVERRIDES.get(code, code)
        if locale in seen_locales:
            skipped.append((code, f"duplicate of '{seen_locales[locale]}' "
                                  f"(both map to {locale}.lproj)"))
            continue
        if locale == BASE_LOCALE:
            skipped.append((code, "en.lproj is the hand-written base localisation"))
            continue
        if locale in PROTECTED_LOCALES:
            skipped.append((code, f"{locale}.lproj is translated by hand"))
            continue
        seen_locales[locale] = code

        upstream = parse_upstream(src)
        english_name = upstream.get(1, code)
        native_name = upstream.get(2, english_name)

        out_dir = res_dir / f"{locale}.lproj"
        out_path = out_dir / "Localizable.strings"
        drop_existing = args.force and locale not in PROTECTED_LOCALES
        existing = {} if drop_existing else parse_strings_file(out_path)

        text, n_tr, n_fb = build_file(locale, native_name, english_name, upstream,
                                      base_layout, base_values, existing, code, text_index)
        rows.append((locale, code, native_name, n_tr, n_fb))

        if not args.dry_run:
            out_dir.mkdir(parents=True, exist_ok=True)
            new = text.encode("utf-8")
            if not out_path.is_file() or out_path.read_bytes() != new:
                out_path.write_bytes(new)
                written += 1

    # ---------------- coverage report ----------------
    total = len(app_keys)
    rows.sort(key=lambda r: (-r[3], r[0]))

    if not args.quiet:
        print(f"{'lproj':12} {'src':8} {'language':26} {'translated':>10} "
              f"{'english':>8} {'coverage':>9}")
        print("-" * 78)
        for locale, code, name, n_tr, n_fb in rows:
            pct = 100.0 * n_tr / total if total else 0.0
            print(f"{locale:12} {code:8} {name[:25]:26} {n_tr:10} {n_fb:8} {pct:8.1f}%")
        print("-" * 78)

    if rows:
        cov = sorted(r[3] for r in rows)
        median = cov[len(cov) // 2] if len(cov) % 2 else (cov[len(cov) // 2 - 1] + cov[len(cov) // 2]) / 2
        best = rows[0]
        worst = rows[-1]
        print(f"Languages generated: {len(rows)}   files written this run: {written}"
              f"{' (dry run)' if args.dry_run else ''}")
        print(f"Best:   {best[0]} ({best[2]}) {best[3]}/{total} = {100.0*best[3]/total:.1f}%")
        print(f"Worst:  {worst[0]} ({worst[2]}) {worst[3]}/{total} = {100.0*worst[3]/total:.1f}%")
        print(f"Median: {median}/{total} = {100.0*median/total:.1f}%")
        print(f"Ceiling (keys with an upstream mapping): {mapped_total}/{total} = "
              f"{100.0*mapped_total/total:.1f}%")

    if skipped:
        print("\nSkipped:")
        for code, why in skipped:
            print(f"  {code:8} {why}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
