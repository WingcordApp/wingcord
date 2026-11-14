#!/usr/bin/env python3
"""Refuses a release that carries anything personal (docs/UPDATES.md D11).

    private-scan.py <file or folder>...

Exits 1, naming each file that holds one of the strings below — and never the
string itself, so the scan's own output can be pasted anywhere. Exits 0 when
everything is clean.

**The strings are found at run time and written nowhere**: this file goes to
GitHub with the rest of the repository, so it can't hold what it looks for.

- this Mac's account name, which is in every folder path built here;
- the account's full name, and each longer word of it;
- the name and address in the "Apple Development" certificate, which signs
  the builds that never leave this Mac;
- every line of ~/.config/wingcord/private-strings, for anything else (other
  addresses, account ids). Lines starting with # are notes.

Case is ignored. Strings shorter than five characters are skipped, as they
would match by chance.
"""
import os
import pathlib
import re
import subprocess
import sys

MINIMUM = 5


def run(*command):
    try:
        return subprocess.run(command, capture_output=True, text=True, check=False).stdout
    except OSError:
        return ""


def certificate_strings():
    pem = run("security", "find-certificate", "-c", "Apple Development", "-p")
    if not pem.strip():
        return []
    try:
        subject = subprocess.run(
            ["openssl", "x509", "-noout", "-subject", "-nameopt", "multiline,utf8"],
            input=pem, capture_output=True, text=True, check=False,
        ).stdout
    except OSError:
        return []
    found = []
    for line in subject.splitlines():
        key, _, value = line.strip().partition("=")
        key = key.strip()
        value = value.strip()
        if key == "commonName":
            # "Apple Development: someone@example.com (ABCDE12345)"
            value = value.split(":", 1)[-1]
            value = re.sub(r"\([A-Z0-9]+\)\s*$", "", value).strip()
            found.append(value)
        elif key in ("organizationName", "emailAddress"):
            found.append(value)
    return found


def patterns():
    strings = [run("id", "-un").strip()]
    full_name = run("id", "-F").strip()
    strings.append(full_name)
    strings.extend(full_name.split())
    for value in certificate_strings():
        strings.append(value)
        strings.extend(value.split())
    extra = pathlib.Path.home() / ".config" / "wingcord" / "private-strings"
    if extra.is_file():
        for line in extra.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                strings.append(line)
    unique = sorted({value for value in strings if len(value) >= MINIMUM}, key=len, reverse=True)
    return [re.compile(re.escape(value.encode("utf-8")), re.IGNORECASE) for value in unique]


def files(paths):
    for path in paths:
        if os.path.isdir(path) and not os.path.islink(path):
            for folder, _, names in os.walk(path):
                for name in names:
                    full = os.path.join(folder, name)
                    if not os.path.islink(full):
                        yield full
        elif os.path.isfile(path):
            yield path


def main(paths):
    if not paths:
        sys.exit(__doc__)
    compiled = patterns()
    if not compiled:
        sys.exit("private-scan.py: found nothing to look for, which can't be right")
    dirty = []
    for path in files(paths):
        data = pathlib.Path(path).read_bytes()
        hits = [index for index, pattern in enumerate(compiled) if pattern.search(data)]
        if hits:
            dirty.append((path, hits))
    for path, hits in dirty:
        print("personal string #%s in %s" % (",".join(str(i) for i in hits), path))
    if dirty:
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
