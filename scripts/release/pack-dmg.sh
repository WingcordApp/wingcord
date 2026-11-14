#!/bin/bash
# The disk image a tester opens (docs/UPDATES.md D9): the app on the left, Applications on the
# right and the background's hand-drawn arrow between them. Finder lays the window out in a
# writable copy (dmg-layout.applescript, beside this), which is then compressed.
#
#   scripts/release/pack-dmg.sh <folder> <volume name> <out.dmg>
#
# <folder> holds "<volume name>.app", the Applications link and .background/WingcordBackground.tiff.
# The first run asks for permission to control Finder (Privacy & Security ▸ Automation).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$1"
VOLUME="$2"
OUT="$3"
MOUNT="/Volumes/$VOLUME"
WRITABLE="${OUT%.dmg}-writable.dmg"
die() { echo "pack-dmg: $*" >&2; exit 1; }

# Finder finds the disk by its name, so another one with this name would get the layout.
[ -e "$MOUNT" ] && die "a disk named \"$VOLUME\" is mounted: eject it first"
[ -s "$SOURCE/.background/WingcordBackground.tiff" ] || die "no background in $SOURCE/.background"

hdiutil create -quiet -volname "$VOLUME" -srcfolder "$SOURCE" -fs APFS -format UDRW -ov "$WRITABLE"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$WRITABLE" 2>/dev/null
[ -d "$MOUNT" ] || die "the writable image didn't mount at $MOUNT"
if ! osascript "$HERE/dmg-layout.applescript" "$VOLUME" "$VOLUME.app" > /dev/null; then
    hdiutil detach -quiet "$MOUNT" || true
    die "Finder couldn't lay out the window (allowed to control Finder? Privacy & Security ▸ Automation)"
fi
# The layout lives in the image's .DS_Store, written as the window closed.
[ -s "$MOUNT/.DS_Store" ] || { hdiutil detach -quiet "$MOUNT" || true; die "Finder wrote no layout"; }
rm -rf "$MOUNT/.fseventsd"
sync
for attempt in 1 2 3 4 5; do
    hdiutil detach -quiet "$MOUNT" && break
    sleep 2
done
[ -e "$MOUNT" ] && die "the writable image wouldn't eject"
hdiutil convert -quiet "$WRITABLE" -format ULMO -ov -o "$OUT"
rm -f "$WRITABLE"
