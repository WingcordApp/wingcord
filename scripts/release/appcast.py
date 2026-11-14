#!/usr/bin/env python3
"""The two things release.sh asks of an appcast that Sparkle's tools don't do.

    appcast.py highest <appcast.xml>               the highest sparkle:version in it, 0 if none
    appcast.py title <appcast.xml> <build> <title>  names the item for that build

**The title is how a beta's name travels** (docs/UPDATES.md D3). The version
stays numeric — "1.0" — as Apple and Sparkle want it, so "Wingcord 1.0 Beta 2"
goes in the item's <title>, which `generate_appcast` writes once and never
overwrites; the app reads it back (`UpdateNaming`).

Edits are made to the text, not through an XML library, so nothing else in the
file moves: release.sh signs the feed again straight after (`sign_update`).
"""
import re
import sys

VERSION = re.compile(r"<sparkle:version>\s*(\d+)\s*</sparkle:version>")


def highest(path):
    try:
        text = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        return 0
    return max((int(match) for match in VERSION.findall(text)), default=0)


def set_title(path, build, title):
    text = open(path, encoding="utf-8").read()
    items = list(re.finditer(r"<item>.*?</item>", text, re.DOTALL))
    for item in items:
        block = item.group(0)
        if not re.search(r"<sparkle:version>\s*%s\s*</sparkle:version>" % re.escape(build), block):
            continue
        escaped = title.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        if re.search(r"<title>.*?</title>", block, re.DOTALL):
            new_block = re.sub(r"<title>.*?</title>", "<title>%s</title>" % escaped, block, count=1, flags=re.DOTALL)
        else:
            new_block = block.replace("<item>", "<item>\n            <title>%s</title>" % escaped, 1)
        text = text[: item.start()] + new_block + text[item.end():]
        open(path, "w", encoding="utf-8").write(text)
        return
    sys.exit("appcast.py: no item for build %s in %s" % (build, path))


def main(argv):
    if len(argv) == 3 and argv[1] == "highest":
        print(highest(argv[2]))
    elif len(argv) == 5 and argv[1] == "title":
        set_title(argv[2], argv[3], argv[4])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
