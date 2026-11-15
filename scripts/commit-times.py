#!/usr/bin/env python3
"""Gives every tracked file the time of the last commit that changed it.

    scripts/commit-times.py

For CI's build cache (.github/workflows/build.yml). A fresh checkout stamps
every file with the moment it was written, so a restored build would see all
of them as changed and compile everything again. With each file at its last
commit's time, a file nobody touched since the cached build has the time it had
then, and only what changed is compiled. It needs the whole history
(`fetch-depth: 0`); a file it can't date keeps the time it has.
"""
import os
import subprocess


def git(*args):
    return subprocess.run(["git", "-c", "core.quotepath=off", *args], capture_output=True, text=True, check=True).stdout


def main():
    times, current = {}, None
    # Newest first, so the first time a path appears is its last change.
    for line in git("log", "--format=\x01%ct", "--name-only", "--no-renames", "HEAD").splitlines():
        if line.startswith("\x01"):
            current = int(line[1:])
        elif line and current is not None:
            times.setdefault(line, current)
    tracked = git("ls-files").splitlines()
    dated = 0
    for path in tracked:
        stamp = times.get(path)
        if stamp is not None and os.path.lexists(path):
            os.utime(path, (stamp, stamp), follow_symlinks=False)
            dated += 1
    print(f"commit-times: {dated} of {len(tracked)} files dated")


if __name__ == "__main__":
    main()
