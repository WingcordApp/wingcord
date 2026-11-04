#!/usr/bin/env python3
"""settings-index.py [--json] — the settings search's index, read off the panes.

Writes Sources/Wingcord/Settings/SettingsSearchIndex.swift: every toggle,
slider, picker heading, flyout, value, action, meter and shortcut row, by the
title and the description it carries, under the pane it is drawn on. With
--json it prints the rows instead and writes nothing.

Run it after adding, renaming or rewording a row; `SettingsSearchTests` fails
until it has been.
"""
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.path.join(REPO, "Sources/Wingcord")
OUT = os.path.join(BASE, "Settings/SettingsSearchIndex.swift")

# Files whose every row is on one pane; None reads the enclosing struct.
FILES = {
    "Settings/SettingsPanes.swift": None,
    "Settings/SettingsPanes+Games.swift": None,
    "Settings/VoiceVideoPane.swift": "voiceVideo",
    "Settings/StreamerModePane.swift": "streamerMode",
    "Settings/ConnectedAppsPane.swift": "connections",
    "Settings/ExperimentsPane.swift": "experiments",
    "Settings/MessagingPermissionsPane.swift": "privacySafety",
    "Settings/NowPlayingSettingsGroup.swift": "activity",
    "Settings/GameEventsSettingsGroup.swift": "activity",
    "Settings/RegisteredGamesGroup.swift": "activity",
    "Settings/BroadcastPreviewGroup.swift": "activity",
    "Settings/ConnectedRPCAppsGroup.swift": "activity",
    "Settings/FocusSettingsGroup.swift": "notifications",
    "Settings/FocusCustomStatusRow.swift": "notifications",
    "Settings/AccountInfoCard.swift": "account",
    "Settings/AccountStandingCard.swift": "account",
    "Settings/Plumage.swift": "appearance",
    "Settings/ThemeGallery.swift": "appearance",
    "Wallpaper/WallpaperPicker.swift": "appearance",
}
STRUCTS = {
    "GeneralPane": "general", "ExtrasPane": "extras",
    "AppearancePane": "appearance", "ThemeSyncCard": "appearance", "ServerThemePreferenceCard": "appearance",
    "ChatPane": "chat", "ExpressionsPane": "chat", "MediaPane": "chat",
    "NotificationsPane": "notifications",
    "AccountPane": "account",
    "PrivacySafetyPane": "privacySafety", "PrivacyPane": "privacySafety",
    "PerformancePane": "performance", "StoragePane": "performance",
    "AccessibilityPane": "accessibility", "ShortcutsPane": "shortcuts",
    "DiagnosticsPane": "diagnostics", "AboutPane": "about",
    "ActivityPane": "activity", "AddGameRow": "activity",
    "OverlayPane": "overlay", "WidgetRow": "overlay", "OverlayLayoutCard": "overlay",
    "ClipsPane": "clips", "ClipRow": "clips",
}
ROWS = (
    "SettingsToggle", "SettingsSliderRow", "CardHeaderRow", "SettingsValueRow", "SettingsControlRow",
    "SettingsActionRow", "SettingsFlyoutRow", "SettingsMeterRow", "HotkeyRecorderRow",
)
# What an empty card says, not a setting anybody searches for.
PLACEHOLDERS = {
    "Nothing detected", "Nothing yet", "None yet", "No games added", "Nothing is shared", "None right now",
    "None this build names", "In none this build names", "Stored accounts", "Other devices", "Account",
}


def string_end(text, i):
    """The index just past the string literal opening at text[i] (a quote)."""
    if text.startswith('"""', i):
        end = text.find('"""', i + 3)
        return end + 3
    i += 1
    while i < len(text):
        c = text[i]
        if c == "\\":
            if text.startswith("\\(", i):
                i = group_end(text, i + 1)
                continue
            i += 2
            continue
        if c == '"':
            return i + 1
        i += 1
    return i


def group_end(text, i):
    """The index just past the bracket group opening at text[i]."""
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = [pairs[text[i]]]
    i += 1
    while i < len(text) and stack:
        c = text[i]
        if c == '"':
            i = string_end(text, i)
            continue
        if text.startswith("//", i):
            i = text.find("\n", i)
            continue
        if c in pairs:
            stack.append(pairs[c])
        elif c == stack[-1]:
            stack.pop()
        i += 1
    return i


def arguments(text, open_paren):
    """The call's top-level arguments, as (label or None, source)."""
    end = group_end(text, open_paren)
    inner = text[open_paren + 1:end - 1]
    parts, start, i = [], 0, 0
    pairs = "([{"
    while i < len(inner):
        c = inner[i]
        if c == '"':
            i = string_end(inner, i)
            continue
        if c in pairs:
            i = group_end(inner, i)
            continue
        if c == ",":
            parts.append(inner[start:i])
            start = i + 1
        i += 1
    parts.append(inner[start:])
    result = []
    for part in parts:
        part = part.strip()
        if not part:
            continue
        m = re.match(r"^([A-Za-z_]\w*)\s*:(?!:)\s*", part)
        result.append((m.group(1), part[m.end():]) if m else (None, part))
    return result


def literal(source):
    """The text of the string literals an expression starts with, joined by +,
    or None when it starts with something else. A computed tail — a key
    summary added on — is left off."""
    pieces, i = [], 0
    source = source.strip()
    while i < len(source):
        if source[i] != '"':
            if pieces:
                break
            return None
        end = string_end(source, i)
        pieces.append(source[i + 1:end - 1])
        rest = source[end:].lstrip()
        if not rest:
            break
        if not rest.startswith("+"):
            return None
        source = rest[1:].lstrip()
        i = 0
    text = "".join(pieces)
    if "\\(" in text:
        return None  # it says something different every time it is drawn
    text = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), text)
    return text.replace('\\"', '"').replace("\\n", " ").replace("\\\\", "\\")


def rows():
    found = []
    opener = re.compile(r"\b(" + "|".join(ROWS) + r")\(")
    for rel, default in FILES.items():
        text = open(os.path.join(BASE, rel), encoding="utf-8").read()
        structs = [(m.start(), m.group(1)) for m in re.finditer(r"\n(?:private |fileprivate )?struct (\w+)", text)]
        for m in opener.finditer(text):
            args = arguments(text, m.end() - 1)
            # A first unlabelled literal, or `title:` — a flyout's `title:` is
            # the key path that names its options, which is not a literal.
            if args and args[0][0] is None:
                title_source = args[0][1]
            else:
                title_source = next((src for label, src in args if label == "title"), None)
            title = literal(title_source) if title_source else None
            if not title or title in PLACEHOLDERS:
                continue
            help_source = next((src for label, src in args if label == "help"), None)
            help_text = (literal(help_source) or "") if help_source else ""
            enclosing = None
            for start, name in structs:
                if start < m.start():
                    enclosing = name
            section = default or STRUCTS.get(enclosing)
            if not section:
                print(f"unmapped: {rel} {enclosing} {title}", file=sys.stderr)
                continue
            found.append({"section": section, "title": title, "help": help_text.strip()})
    # The first drawing of a row is the one that describes it — a row drawn
    # again for another state says something about that state.
    seen, unique = set(), []
    for row in found:
        key = (row["section"], row["title"])
        if key not in seen:
            seen.add(key)
            unique.append(row)
    return unique


def swift(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


HEADER = """import Foundation

// MARK: - Every setting, for the search
//
// Generated by `scripts/settings-index.py` from the panes' own rows — each
// toggle, slider, picker heading, flyout, value, action, meter and shortcut
// row, by the title and the description it carries. Do not edit by hand:
// change the row, then run the script. `SettingsSearchTests` fails when a row
// appears that this list does not have or this list names a row that is gone.

extension SettingsSearch {
    static let entries: [SettingsSearchEntry] = [
"""


def main():
    found = rows()
    if "--json" in sys.argv:
        print(json.dumps(found, ensure_ascii=False, indent=1))
        return
    lines = []
    for row in found:
        args = [f".{row['section']}", swift(row["title"])]
        if row["help"]:
            args.append(swift(row["help"]))
        lines.append(f"        .init({', '.join(args)}),")
    with open(OUT, "w", encoding="utf-8") as out:
        out.write(HEADER + "\n".join(lines) + "\n    ]\n}\n")
    print(f"{len(found)} settings → {os.path.relpath(OUT, REPO)}")


if __name__ == "__main__":
    main()
