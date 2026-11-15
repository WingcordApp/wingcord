#!/usr/bin/env python3
"""Refuses a push that would publish something it shouldn't. This repository is
public, so whatever a push adds is published the moment it lands.

    scripts/check-push.py <remote> [<url>]     git's pre-push hook (scripts/git-hooks/pre-push)
    scripts/check-push.py --range <from>..<to>  the same check, by hand

It reads every commit the push would add: its author and committer, its
message, and every file it adds or changes, with its path. It looks for:

- strings shaped like the tokens and keys GitHub's push protection refuses;
- a Claude session link in a commit message;
- a file under a path that stays on the maintainer's Mac (DROPPED below);
- what scripts/release/private-scan.py looks for: this Mac's account name, the
  account's full name, the signing certificate's name and address, and the
  lines of ~/.config/wingcord/private-strings;
- the original side of every line of ~/.config/wingcord/mirror-replacements.txt
  (`old==>new`, or `regex:old==>new`): strings that must never appear here;
- a committer other than the one ~/.config/wingcord/identity names.

The files under ~/.config/wingcord exist only on the maintainer's Mac, so on
anyone else's the last three checks have nothing to look for. Like
private-scan.py it prints what it found by number and path, never the string
itself, and it exits 1 if it found anything. It ignores case, except for a
string shorter than five characters, matched only as a whole word with its
case, and the strings ~/.config/wingcord/block-exact.txt lists by the first 16
hex digits of their SHA-256, matched with their case.
"""
import hashlib
import importlib.util
import pathlib
import re
import subprocess
import sys

# private-scan.py is loaded as a module; leave no __pycache__ beside it.
sys.dont_write_bytecode = True

ROOT = pathlib.Path(__file__).resolve().parent.parent
CONFIG = pathlib.Path.home() / ".config/wingcord"
MINIMUM = 5
ZERO = "0" * 40

# Paths that stay on the maintainer's Mac: his notes, and MetalForge's code,
# whose license forbids publishing it (THIRD-PARTY-NOTICES.md), with the paths
# it had before it got a folder of its own.
DROPPED = [
    "docs/",
    "Website/",
    ".claude/",
    "scripts/public-mirror/",
    "Sources/Wingcord/Welcome/MetalForge/",
    "Sources/Wingcord/Welcome/EmberRenderer.swift",
    "Sources/Wingcord/Welcome/ParticleLockup.swift",
    "Sources/Wingcord/Welcome/Shaders/",
]

# Shapes GitHub's push protection refuses. Its Discord pattern refused a push
# over a made-up test token once (2026-11-15).
SECRET_SHAPES = {
    "a Discord token": re.compile(rb"[MNO][A-Za-z0-9_-]{23,27}\.[A-Za-z0-9_-]{6}\.[A-Za-z0-9_-]{27,40}"),
    "a GitHub token": re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{60,}"),
    "a private key": re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "an AWS key": re.compile(rb"\bAKIA[0-9A-Z]{16}\b"),
    "a Slack token": re.compile(rb"\bxox[abprs]-[0-9A-Za-z-]{10,}"),
}
SESSION_LINK = re.compile(rb"^Claude-Session:", re.IGNORECASE | re.MULTILINE)


def git(*args, data=None):
    return subprocess.run(["git", "-C", str(ROOT), *args], input=data, capture_output=True, check=True).stdout


def private_patterns():
    spec = importlib.util.spec_from_file_location("private_scan", ROOT / "scripts/release/private-scan.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.patterns()


def blocked_patterns():
    """The original side of each line of the block list, as git filter-repo read it when it was a rule file."""
    path = CONFIG / "mirror-replacements.txt"
    if not path.is_file():
        return []
    exact_path = CONFIG / "block-exact.txt"
    exact = set()
    if exact_path.is_file():
        exact = {line.split("#", 1)[0].strip() for line in exact_path.read_text(encoding="utf-8").splitlines()} - {""}
    found = []
    for line in path.read_bytes().splitlines():
        if not line.strip():
            continue
        old = line.split(b"==>", 1)[0]
        if old.startswith(b"regex:"):
            found.append(re.compile(old[len(b"regex:"):]))
            continue
        if old.startswith(b"literal:"):
            old = old[len(b"literal:"):]
        if hashlib.sha256(old).hexdigest()[:16] in exact:
            found.append(re.compile(re.escape(old)))
        elif len(old) >= MINIMUM:
            found.append(re.compile(re.escape(old), re.IGNORECASE))
        else:
            found.append(re.compile(rb"(?<![A-Za-z0-9_])" + re.escape(old) + rb"(?![A-Za-z0-9_])"))
    return found


class Finder:
    """
    All the patterns over one piece of data. A literal that ignores case is
    looked for with `in` on the lowercased data, which runs in C; the few
    other patterns run as regexes, after a quick `in` for the text a
    whole-word pattern must contain.
    """

    def __init__(self, patterns):
        self.patterns = patterns
        self.literals = {}
        self.others = []
        for index, pattern in enumerate(patterns):
            text = pattern.pattern
            plain = re.sub(rb"\\(.)", rb"\1", text)
            if pattern.flags & re.IGNORECASE and re.escape(plain) == text:
                self.literals.setdefault(plain.lower(), []).append(index)
            elif re.escape(plain) == text:
                self.others.append((index, plain))
            else:
                word = re.fullmatch(rb"\(\?<!\[A-Za-z0-9_\]\)(.*)\(\?!\[A-Za-z0-9_\]\)", text, re.DOTALL)
                needle = re.sub(rb"\\(.)", rb"\1", word.group(1)) if word else None
                self.others.append((index, needle))

    def hits(self, data):
        found = set()
        lowered = data.lower()
        for key, indexes in self.literals.items():
            if key in lowered:
                found.update(indexes)
        for index, needle in self.others:
            if (needle is None or needle in data) and self.patterns[index].search(data):
                found.add(index)
        return found


def outgoing(lines):
    """The commits and annotated tags a push would add, from the hook's ref lines."""
    commits, tags = [], []
    for line in lines:
        parts = line.split()
        if len(parts) != 4 or parts[1] == ZERO:
            continue  # malformed, or a deletion: nothing is added
        local_ref, local, _, remote = parts
        if git("cat-file", "-t", local).strip() == b"tag":
            tags.append((local_ref, local))
        known = [remote] if remote != ZERO and subprocess.run(
            ["git", "-C", str(ROOT), "cat-file", "-e", remote], capture_output=True).returncode == 0 else []
        listed = git("rev-list", f"{local}^{{commit}}", "--not", *known, "--remotes").decode().split()
        commits.extend(commit for commit in listed if commit not in commits)
    return commits, tags


def changed_files(commit):
    """(blob, path) for every file the commit adds or changes, against each parent."""
    parents = git("rev-list", "--parents", "-n", "1", commit).decode().split()[1:]
    out = []
    for parent in parents or [None]:
        args = ["diff-tree", "-r", "-z", "--no-renames", "--no-commit-id"]
        args += [parent, commit] if parent else ["--root", commit]
        fields = git(*args).split(b"\0")
        for meta, path in zip(fields[0::2], fields[1::2]):
            _, _, _, blob, change = meta.decode().split()
            if change != "D" and (blob, path) not in out:
                out.append((blob, path))
    return out


def read_blobs(names):
    data = git("cat-file", "--batch", data="".join(name + "\n" for name in names).encode())
    blobs, position = {}, 0
    for name in names:
        end = data.index(b"\n", position)
        size = int(data[position:end].split()[2])
        blobs[name] = data[end + 1:end + 1 + size]
        position = end + 1 + size + 1
    return blobs


def main(arguments):
    if arguments[:1] == ["--range"] and len(arguments) == 2:
        start, end = arguments[1].split("..", 1)
        commits = git("rev-list", f"{start}..{end}").decode().split()
        tags = []
    elif len(arguments) in (1, 2) and not arguments[0].startswith("-"):
        commits, tags = outgoing(sys.stdin.read().splitlines())
    else:
        sys.exit(__doc__)
    if not commits and not tags:
        return

    private = private_patterns()
    blocked = blocked_patterns()
    finder = Finder(private + blocked)
    identity_file = CONFIG / "identity"
    identity = identity_file.read_text(encoding="utf-8").strip().encode() if identity_file.is_file() else None

    def label(index):
        return f"personal string #{index + 1}" if index < len(private) else f"blocked string #{index - len(private) + 1}"

    problems = []
    for commit in commits:
        short = commit[:12]
        author, committer, message = git("log", "-1", "--format=%an <%ae>%x00%cn <%ce>%x00%B", commit).split(b"\0", 2)
        if identity and committer != identity:
            problems.append(f"commit {short} is committed by someone other than ~/.config/wingcord/identity")
        for index in sorted(finder.hits(b"\n".join([author, committer, message]))):
            problems.append(f"{label(index)} in commit {short}'s message or names")
        if SESSION_LINK.search(message):
            problems.append(f"a Claude session link in commit {short}'s message")
        for shape, pattern in SECRET_SHAPES.items():
            if pattern.search(message):
                problems.append(f"{shape} in commit {short}'s message")
        files = changed_files(commit)
        blobs = read_blobs([blob for blob, _ in files])
        for blob, raw_path in files:
            path = raw_path.decode("utf-8", "surrogateescape")
            for prefix in DROPPED:
                if path == prefix.rstrip("/") or path.startswith(prefix if prefix.endswith("/") else prefix + "/"):
                    problems.append(f"{path} in commit {short} is under a path that stays off GitHub ({prefix})")
            for index in sorted(finder.hits(raw_path) | finder.hits(blobs[blob])):
                problems.append(f"{label(index)} in {path} (commit {short})")
            for shape, pattern in SECRET_SHAPES.items():
                if pattern.search(blobs[blob]):
                    problems.append(f"{shape} in {path} (commit {short})")
    for ref, tag in tags:
        text = git("cat-file", "tag", tag)
        for index in sorted(finder.hits(text)):
            problems.append(f"{label(index)} in tag {ref}")
        if SESSION_LINK.search(text):
            problems.append(f"a Claude session link in tag {ref}")

    checks = f"{len(private)} personal strings, {len(blocked)} blocked strings"
    print(f"check-push: {len(commits)} commits, {len(tags)} tags; {checks}", file=sys.stderr)
    for problem in problems:
        print(f"check-push: {problem}", file=sys.stderr)
    if problems:
        print("check-push: nothing was pushed", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
