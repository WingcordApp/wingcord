#!/bin/bash
# The public tracker's labels (docs/BUG-REPORTING.md D35, D38): priority, which
# CodeRabbit sets on bugs; `needs triage`, which the triage workflow adds to
# issues people open; and an area each, which the reports Worker and the
# triage workflow add. `bug`, `idea`, `crash` and `planned` exist already.
# Safe to run again: an existing label is updated, not doubled.
set -euo pipefail
REPO="WingcordApp/wingcord"

label() { gh label create "$1" --repo "$REPO" --color "$2" --description "$3" --force; }

label "priority: critical" B60205 "Crashes, loses something or stops everyone — first in line"
label "priority: high"     D93F0B "A core feature broken, or many people hit it"
label "priority: medium"   FBCA04 "Wrong, but there's a way around it"
label "priority: low"      0E8A16 "Cosmetic or rare"
label "needs triage"       EDEDED "Opened here and not looked at yet"

while IFS='|' read -r name title; do
    label "area: $name" C5DEF5 "In Wingcord's $title"
done <<'AREAS'
messages|messages
voice|voice calls
video|video
screen share|screen sharing
notifications|notifications
profiles|profiles
servers & channels|servers and channels
appearance|appearance
settings|settings
speed & freezes|speed, or where it freezes
signing in|signing in
AREAS
