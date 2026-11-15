#!/bin/bash
# The release command (docs/UPDATES.md D11): make a release, try it, publish it.
#
#   scripts/release.sh make <version> ["Beta 2"] [--critical] [--test]
#   scripts/release.sh publish [--test | --local]
#   scripts/release.sh discard [--test]
#   scripts/release.sh serve-test
#
# **make** builds the committed tree with the release identity and the feed,
# checks what it built, packs it, and stages it in build/releases/<build>/ beside
# the appcast that would go live. Nothing leaves this Mac: try the app first.
#
# **publish** is the deploy, the commit and the push, together, so it runs on
# Alex's say only. The archive and its deltas go up first and the appcast last,
# so no item ever names a file that isn't there yet; the dSYM goes to the private
# bucket; what's live is compared with what was staged; then the version bump is
# committed, tagged and pushed, once every commit's author has been checked, and
# the release gets its page on GitHub, from the same notes.
#
# **discard** drops a made release and puts the version back as it was.
#
# --critical  testers can't skip it, and it's offered at once (`sparkle:criticalUpdate`).
# --test      a copy for testing the updater: its own identifier, name and Keychain
#             service, the throwaway certificate and EdDSA key in
#             $WINGCORD_TEST_CREDENTIALS, a feed on 127.0.0.1 (`serve-test`), its own
#             folder, build/releases-test/. It touches no tracked file, and its
#             publish only marks it live.
# --local     publish into Wrangler's local R2 rather than Cloudflare's: the uploads,
#             their order and the read-back, with nothing deployed. Implies --test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
HELPERS="$ROOT/scripts/release"
WRANGLER_PROJECT="$ROOT/ReportsWorker"

FEED_HOST="https://download.wingcord.app"
DOWNLOADS_BUCKET="wingcord-downloads"
SYMBOLS_BUCKET="wingcord-symbols"
RELEASE_IDENTITY="Wingcord"
TEST_PORT=8765

die() { echo "release: $*" >&2; exit 1; }
say() { echo "── $*"; }

COMMAND="${1:-}"
[ $# -gt 0 ] && shift
MODE=real
LOCAL=0
CRITICAL=0
ARG1=""
ARG2=""
while [ $# -gt 0 ]; do
    case "$1" in
        --test) MODE=test ;;
        --local) MODE=test; LOCAL=1 ;;
        --critical) CRITICAL=1 ;;
        -*) die "unknown option $1" ;;
        *) if [ -z "$ARG1" ]; then ARG1="$1"; elif [ -z "$ARG2" ]; then ARG2="$1"; else die "too many arguments"; fi ;;
    esac
    shift
done

if [ "$MODE" = test ]; then
    DIR="$ROOT/build/releases-test"
    FEED_BASE="http://127.0.0.1:$TEST_PORT"
    APP_NAME="Wingcord Update Test"
    ARCHIVE_PREFIX="WingcordUpdateTest"
    IDENTITY_NAME="Wingcord Update Test"
    CREDENTIALS="${WINGCORD_TEST_CREDENTIALS:-}"
    if [ -n "$CREDENTIALS" ]; then
        KEYCHAIN="$CREDENTIALS/test.keychain-db"
        ED_KEY_FILE="$CREDENTIALS/ed.key"
        ED_PUBLIC="$(cat "$CREDENTIALS/ed.pub")"
    elif [ "$COMMAND" = make ] || [ "$LOCAL" = 1 ]; then
        die "--test needs WINGCORD_TEST_CREDENTIALS: a folder with test.keychain-db, kc.pw, ed.key and ed.pub"
    fi
else
    DIR="$ROOT/build/releases"
    FEED_BASE="$FEED_HOST"
    APP_NAME="Wingcord"
    ARCHIVE_PREFIX="Wingcord"
    IDENTITY_NAME="$RELEASE_IDENTITY"
    KEYCHAIN=""
    ED_KEY_FILE=""
    ED_PUBLIC="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT/Packaging/Info.plist" 2>/dev/null || true)"
fi
FEED_URL="$FEED_BASE/appcast.xml"
FEED_DIR="$DIR/feed"
PENDING="$DIR/pending.env"

# Sparkle's tools take the EdDSA key from the login Keychain unless given a file.
key_args() { [ -n "${ED_KEY_FILE:-}" ] && printf '%s\n' --ed-key-file "$ED_KEY_FILE"; true; }

# The SHA-1 of the one identity named exactly so.
identity_sha1() {
    local found
    found="$(security find-identity -p codesigning ${KEYCHAIN:+"$KEYCHAIN"} 2>/dev/null \
        | sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) "([^"]*)".*$/\1	\2/p' | sort -u \
        | awk -F'\t' -v n="$1" '$2 == n { print $1 }')"
    [ "$(printf '%s' "$found" | grep -c .)" = 1 ] || die "need exactly one code-signing identity named \"$1\" (found $(printf '%s' "$found" | grep -c .))"
    printf '%s' "$found"
}

private_scan() {
    if python3 -I "$HELPERS/private-scan.py" "$@"; then
        say "private strings: none"
    elif [ "$MODE" = test ]; then
        echo "warning: the scan found personal strings (above) — fatal for a real release" >&2
    else
        die "the scan found personal strings (above); nothing was published"
    fi
}

highest_build() { python3 -I "$HELPERS/appcast.py" highest "$1"; }

# ── make ───────────────────────────────────────────────────────────────────
make_release() {
    local VERSION="$ARG1" PRERELEASE="$ARG2"
    [[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || die "usage: release.sh make <version> [\"Beta 2\"] — e.g. make 1.0 \"Beta 2\""
    if [ -n "$PRERELEASE" ]; then
        [[ "$PRERELEASE" =~ ^(Alpha|Beta|RC)\ [0-9]+$ ]] || die "a pre-release is Alpha, Beta or RC and a number: \"Beta 2\""
    fi
    [ -f "$PENDING" ] && die "a release is already made ($(. "$PENDING"; echo "$NAME")): publish or discard it first"
    [ -x "$SPARKLE_BIN/generate_appcast" ] || die "Sparkle's tools are missing: run swift package resolve --disable-keychain"
    mkdir -p "$FEED_DIR"

    local NAME="$VERSION${PRERELEASE:+ $PRERELEASE}"
    local SLUG="$VERSION"
    [ -n "$PRERELEASE" ] && SLUG="$VERSION-$(printf '%s' "$PRERELEASE" | tr '[:upper:] ' '[:lower:].')"
    local TAG="v$SLUG"
    local NOTES="$ROOT/Packaging/ReleaseNotes/$SLUG.md"

    # A release is built from a commit, and from main (D12).
    if [ "$MODE" = real ]; then
        git -C "$ROOT" diff --quiet HEAD -- || die "tracked files have changes: commit or stash them; a release is built from a commit"
        [ "$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)" = main ] || die "releases come from main (docs/UPDATES.md D12)"
        git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG exists already"
        [ -f "$NOTES" ] || die "write the release notes first: Packaging/ReleaseNotes/$SLUG.md"
        [ -n "$ED_PUBLIC" ] || die "Packaging/Info.plist has no SUPublicEDKey — the update key isn't set up (docs/UPDATES.md phase 5)"
        [ "$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)" = "$ED_PUBLIC" ] \
            || die "the EdDSA key in the Keychain isn't the one in Packaging/Info.plist"
    else
        NOTES="$DIR/notes-test.md"
        printf '### Test build\n- A copy for testing the updater, made %s.\n' "$(date '+%Y-%m-%d %H:%M')" > "$NOTES"
    fi

    # ── The number (D3): one higher than anything ever published ──
    local LIVE LOCAL_HIGHEST
    if [ "$MODE" = real ]; then
        local LIVE_FEED="$DIR/live-appcast.xml"
        local STATUS
        STATUS="$(curl -sS -o "$LIVE_FEED" -w '%{http_code}' "$FEED_URL" 2>/dev/null || true)"
        if [ "$STATUS" = 200 ]; then
            LIVE="$(highest_build "$LIVE_FEED")"
        elif [ "$(highest_build "$FEED_DIR/appcast.xml")" = 0 ]; then
            say "no live appcast yet ($FEED_URL answered ${STATUS:-nothing}): this is the first release"
            LIVE=0
        else
            die "can't read the live appcast ($FEED_URL answered ${STATUS:-nothing}), so the next number can't be checked"
        fi
        rm -f "$LIVE_FEED"
    else
        LIVE=0
    fi
    LOCAL_HIGHEST="$(highest_build "$FEED_DIR/appcast.xml")"
    local BUILD=$(( (LIVE > LOCAL_HIGHEST ? LIVE : LOCAL_HIGHEST) + 1 ))
    local STAGE="$DIR/$BUILD"
    say "making $NAME ($BUILD)"
    rm -rf "$STAGE"
    mkdir -p "$STAGE"

    # Where things were, so discard can put them back.
    local PLIST="$ROOT/Packaging/Info.plist"
    local OLD_SHORT OLD_BUILD OLD_PRE
    OLD_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
    OLD_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
    OLD_PRE="$(/usr/libexec/PlistBuddy -c 'Print :WingcordPrerelease' "$PLIST" 2>/dev/null || true)"
    [ -f "$FEED_DIR/appcast.xml" ] && cp "$FEED_DIR/appcast.xml" "$STAGE/appcast.before.xml"
    ls -1 "$FEED_DIR" > "$STAGE/feed.before"

    # ── The version, into the bundle ──
    local -a BUILD_ENV=(
        WINGCORD_FEED_URL="$FEED_URL"
        WINGCORD_RELEASE_NOTES="$NOTES"
        WINGCORD_SIGN_IDENTITY="$(identity_sha1 "$IDENTITY_NAME")"
    )
    if [ "$MODE" = real ]; then
        # The bump is part of the release commit that publish makes.
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
        if [ -n "$PRERELEASE" ]; then
            /usr/libexec/PlistBuddy -c "Set :WingcordPrerelease $PRERELEASE" "$PLIST" 2>/dev/null \
                || /usr/libexec/PlistBuddy -c "Add :WingcordPrerelease string $PRERELEASE" "$PLIST"
        else
            /usr/libexec/PlistBuddy -c "Delete :WingcordPrerelease" "$PLIST" 2>/dev/null || true
        fi
    else
        security unlock-keychain -p "$(cat "$CREDENTIALS/kc.pw")" "$KEYCHAIN"
        BUILD_ENV+=(
            WINGCORD_SIGN_KEYCHAIN="$KEYCHAIN"
            WINGCORD_ED_PUBLIC_KEY="$ED_PUBLIC"
            WINGCORD_SHORT_VERSION="$VERSION"
            WINGCORD_BUILD_NUMBER="$BUILD"
            WINGCORD_PRERELEASE="$PRERELEASE"
            WINGCORD_BUNDLE_ID="dev.wingcord.Wingcord.updatetest"
            WINGCORD_BUNDLE_NAME="$APP_NAME"
            WINGCORD_KEYCHAIN_SERVICE="dev.wingcord.Wingcord.updatetest.token"
            WINGCORD_ALLOW_LOCAL_HTTP=1
        )
    fi

    # ── Build ──
    local APP="$STAGE/$APP_NAME.app"
    env "${BUILD_ENV[@]}" WINGCORD_APP="$APP" "$ROOT/scripts/build-app.sh" release > "$STAGE/build.log" 2>&1 \
        || { tail -20 "$STAGE/build.log" >&2; die "the build failed (log: $STAGE/build.log)"; }

    # ── What was built ──
    local BIN="$APP/Contents/MacOS/Wingcord"
    codesign --verify --strict --deep "$APP" || die "the signature doesn't verify"
    local SIGNATURE
    SIGNATURE="$(codesign -dvv "$APP" 2>&1)"
    [ "$(printf '%s\n' "$SIGNATURE" | sed -n 's/^Authority=//p' | head -1)" = "$IDENTITY_NAME" ] \
        || die "signed by someone other than \"$IDENTITY_NAME\""
    printf '%s\n' "$SIGNATURE" | grep -q 'flags=0x10000(runtime)' || die "the hardened runtime is off (docs/UPDATES.md D2)"
    if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q get-task-allow; then
        die "the app is debuggable (get-task-allow)"
    fi
    [ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")" = "$FEED_URL" ] || die "the feed URL didn't make it in"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)" = "$ED_PUBLIC" ] \
        || die "the bundle's SUPublicEDKey isn't the release key"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = "$BUILD" ] || die "the build number didn't make it in"
    local RPATHS
    RPATHS="$(otool -l "$BIN" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }' | tr '\n' ' ')"
    [ "$RPATHS" = "@executable_path/../Frameworks " ] || die "the binary searches for frameworks outside its bundle: $RPATHS"
    local UUID
    UUID="$(dwarfdump --uuid "$BIN" | awk '{ print $2; exit }')"
    local DSYM="$ROOT/build/dSYMs/Wingcord-$UUID.dSYM"
    [ -s "$DSYM/Contents/Resources/DWARF/Wingcord" ] || die "no dSYM for this binary ($UUID): its crashes could never be read"
    [ "$(dwarfdump --uuid "$DSYM" | awk '{ print $2; exit }')" = "$UUID" ] || die "the dSYM is for another binary"
    private_scan "$APP" "$NOTES"

    # ── Pack: one disk image, the app beside an Applications link on the hand-drawn arrow (D9) ──
    local ARCHIVE="$ARCHIVE_PREFIX-$SLUG-$BUILD"
    local IMAGE_ROOT="$STAGE/image"
    mkdir -p "$IMAGE_ROOT/.background"
    ditto "$APP" "$IMAGE_ROOT/$APP_NAME.app"
    ln -s /Applications "$IMAGE_ROOT/Applications"
    cp "$ROOT/Packaging/DMG/WingcordBackground.tiff" "$IMAGE_ROOT/.background/"
    "$HELPERS/pack-dmg.sh" "$IMAGE_ROOT" "$APP_NAME" "$STAGE/$ARCHIVE.dmg" || die "the disk image wasn't made"
    rm -rf "$IMAGE_ROOT"
    ditto -c -k --keepParent "$DSYM" "$STAGE/Wingcord-$UUID.dSYM.zip"

    # ── The appcast: Sparkle signs the archive, the deltas, the notes and the feed ──
    cp "$STAGE/$ARCHIVE.dmg" "$FEED_DIR/"
    cp "$NOTES" "$FEED_DIR/$ARCHIVE.md"
    local -a APPCAST_ARGS=(--download-url-prefix "$FEED_BASE/" --embed-release-notes --maximum-deltas 3)
    # Until 1.0 is out every build is on the default channel; a later beta is "beta" (D7).
    if [ -n "$PRERELEASE" ] && [ "$(printf '%s\n%s\n' "$VERSION" 1.0 | sort -V | tail -1)" != 1.0 ]; then
        APPCAST_ARGS+=(--channel beta)
    fi
    [ "$CRITICAL" = 1 ] && APPCAST_ARGS+=(--critical-update-version "")
    # shellcheck disable=SC2046
    "$SPARKLE_BIN/generate_appcast" $(key_args) "${APPCAST_ARGS[@]}" -o "$FEED_DIR/appcast.xml" "$FEED_DIR" \
        > "$STAGE/appcast.log" 2>&1 || { cat "$STAGE/appcast.log" >&2; die "generate_appcast failed"; }
    python3 -I "$HELPERS/appcast.py" title "$FEED_DIR/appcast.xml" "$BUILD" "Wingcord $NAME"
    # shellcheck disable=SC2046
    "$SPARKLE_BIN/sign_update" $(key_args) "$FEED_DIR/appcast.xml" > /dev/null
    # shellcheck disable=SC2046
    "$SPARKLE_BIN/sign_update" $(key_args) --verify "$FEED_DIR/appcast.xml" > /dev/null 2>&1 \
        || die "the appcast's signature doesn't verify"
    grep -q "<title>Wingcord $NAME</title>" "$FEED_DIR/appcast.xml" || die "the appcast has no item for $NAME"
    private_scan "$FEED_DIR/appcast.xml"

    ls -1 "$FEED_DIR" > "$STAGE/feed.after"
    comm -13 "$STAGE/feed.before" "$STAGE/feed.after" > "$STAGE/feed.new"

    local COMMIT
    COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
    # Quoted for the shell (%q): a name like "1.0 Beta 2" has spaces in it.
    {
        printf 'NAME=%q\n' "$NAME"
        printf 'VERSION=%q\n' "$VERSION"
        printf 'PRERELEASE=%q\n' "$PRERELEASE"
        printf 'BUILD=%q\n' "$BUILD"
        printf 'SLUG=%q\n' "$SLUG"
        printf 'TAG=%q\n' "$TAG"
        printf 'ARCHIVE=%q\n' "$ARCHIVE"
        printf 'UUID=%q\n' "$UUID"
        printf 'COMMIT=%q\n' "$COMMIT"
        printf 'OLD_SHORT=%q\n' "$OLD_SHORT"
        printf 'OLD_BUILD=%q\n' "$OLD_BUILD"
        printf 'OLD_PRE=%q\n' "$OLD_PRE"
    } > "$PENDING"
    say "made $NAME ($BUILD): $APP"
    echo "   disk image  $STAGE/$ARCHIVE.dmg ($(du -h "$STAGE/$ARCHIVE.dmg" | cut -f1 | tr -d ' '))"
    echo "   new in the feed: $(tr '\n' ' ' < "$STAGE/feed.new")"
    echo "   symbols     $DSYM"
    local SUFFIX=""
    [ "$MODE" = test ] && SUFFIX=" --test"
    echo "   try it, then: scripts/release.sh publish$SUFFIX (or discard$SUFFIX)"
}

# ── publish ────────────────────────────────────────────────────────────────
wrangler() { (cd "$WRANGLER_PROJECT" && npx --no-install wrangler "$@"); }

put() { # bucket, key, file, content type, cache control
    local where=(--remote)
    [ "$LOCAL" = 1 ] && where=(--local --persist-to "$DIR/r2-local")
    wrangler r2 object put "$1/$2" --file "$3" --content-type "$4" --cache-control "$5" "${where[@]}" > /dev/null \
        || die "upload failed: $1/$2"
    echo "   ↑ $1/$2"
}

publish_release() {
    [ -f "$PENDING" ] || die "nothing is made: release.sh make first"
    # shellcheck disable=SC1090
    . "$PENDING"
    local STAGE="$DIR/$BUILD"

    if [ "$MODE" = test ] && [ "$LOCAL" = 0 ]; then
        rm -f "$PENDING"
        say "published $NAME ($BUILD) to the test feed — serve it with: scripts/release.sh serve-test"
        return
    fi

    if [ "$MODE" = real ]; then
        # The commits that will go up are checked before anything does
        # (feedback: his name and personal addresses never reach GitHub).
        git -C "$ROOT" diff --quiet HEAD -- . ':(exclude)Packaging/Info.plist' \
            || die "tracked files besides the version bump have changed since make"
        local AUTHORS
        AUTHORS="$(git -C "$ROOT" log --format='%an <%ae>%n%cn <%ce>' '@{upstream}..HEAD' 2>/dev/null | sort -u)"
        if [ -n "$AUTHORS" ] && [ "$AUTHORS" != "arkanalex <alex@wingcord.app>" ]; then
            die "commits to push carry another author or committer: $AUTHORS"
        fi
        # The push goes to the public repository through scripts/check-push.py,
        # which refuses a Claude session link. Refused after the uploads, it would
        # leave a live release without its commit, so both are checked first.
        [ "$(git -C "$ROOT" config core.hooksPath || true)" = scripts/git-hooks ] \
            || die "the push check is off: git config core.hooksPath scripts/git-hooks"
        case "${WINGCORD_COMMIT_TRAILERS:-}" in
            *[Cc]laude-[Ss]ession:*) die "WINGCORD_COMMIT_TRAILERS carries a Claude session link, which the push check refuses" ;;
        esac
    fi

    # Archive and deltas first, the appcast last: no item ever names a missing file.
    say "uploading $NAME ($BUILD)"
    put "$SYMBOLS_BUCKET" "Wingcord-$UUID.dSYM.zip" "$STAGE/Wingcord-$UUID.dSYM.zip" application/zip "private, no-store"
    local FILE
    while IFS= read -r FILE; do
        case "$FILE" in
            *.dmg) put "$DOWNLOADS_BUCKET" "$FILE" "$FEED_DIR/$FILE" application/x-apple-diskimage "public, max-age=31536000, immutable" ;;
            *.delta) put "$DOWNLOADS_BUCKET" "$FILE" "$FEED_DIR/$FILE" application/octet-stream "public, max-age=31536000, immutable" ;;
            *.md) put "$DOWNLOADS_BUCKET" "notes/$FILE" "$FEED_DIR/$FILE" "text/markdown; charset=utf-8" "public, max-age=300" ;;
        esac
    done < "$STAGE/feed.new"
    put "$DOWNLOADS_BUCKET" "$APP_NAME.dmg" "$FEED_DIR/$ARCHIVE.dmg" application/x-apple-diskimage "public, max-age=300"
    put "$DOWNLOADS_BUCKET" appcast.xml "$FEED_DIR/appcast.xml" "application/xml; charset=utf-8" "public, max-age=60"

    # What's live is what was staged.
    say "checking what's live"
    if [ "$LOCAL" = 1 ]; then
        wrangler r2 object get "$DOWNLOADS_BUCKET/appcast.xml" --file "$STAGE/appcast.live.xml" --local --persist-to "$DIR/r2-local" > /dev/null
        wrangler r2 object get "$SYMBOLS_BUCKET/Wingcord-$UUID.dSYM.zip" --file "$STAGE/dsym.live.zip" --local --persist-to "$DIR/r2-local" > /dev/null
        cmp -s "$STAGE/dsym.live.zip" "$STAGE/Wingcord-$UUID.dSYM.zip" || die "the dSYM read back differs"
    else
        curl -fsS "$FEED_URL" -o "$STAGE/appcast.live.xml" || die "the live appcast can't be read"
        local SIZE
        SIZE="$(curl -fsSI "$FEED_HOST/$ARCHIVE.dmg" | awk 'tolower($1) == "content-length:" { print $2 }' | tr -d '\r')"
        [ "$SIZE" = "$(stat -f%z "$FEED_DIR/$ARCHIVE.dmg")" ] || die "the live disk image isn't the staged one"
    fi
    cmp -s "$STAGE/appcast.live.xml" "$FEED_DIR/appcast.xml" || die "the live appcast isn't the staged one"
    # shellcheck disable=SC2046
    "$SPARKLE_BIN/sign_update" $(key_args) --verify "$STAGE/appcast.live.xml" > /dev/null 2>&1 \
        || die "the live appcast's signature doesn't verify"
    rm -f "$PENDING"
    say "published $NAME ($BUILD)"

    [ "$MODE" = real ] || return 0

    # ── The release commit, its tag, and the push ──
    printf '%s\t%s\t%s\t%s\t%s\n' "$BUILD" "$NAME" "$UUID" "$(date -u +%Y-%m-%d)" "$ARCHIVE.dmg" \
        >> "$ROOT/Packaging/Releases.tsv"
    git -C "$ROOT" add Packaging/Info.plist Packaging/Releases.tsv "Packaging/ReleaseNotes/$SLUG.md"
    git -C "$ROOT" commit -q -m "Wingcord $NAME ($BUILD)${WINGCORD_COMMIT_TRAILERS:+

$WINGCORD_COMMIT_TRAILERS}"
    git -C "$ROOT" tag -a "$TAG" -m "Wingcord $NAME ($BUILD)"
    git -C "$ROOT" push -q origin HEAD "$TAG"
    say "committed, tagged $TAG and pushed"

    # ── The release page on GitHub, from the same notes ──
    # A beta is a pre-release there. A page that can't be made doesn't undo
    # anything: the release is live and pushed, so the command is printed instead.
    local PAGE="$STAGE/github-release.md"
    {
        cat "$ROOT/Packaging/ReleaseNotes/$SLUG.md"
        printf '\nDownload: %s/%s.dmg\nSHA-256: %s\n' "$FEED_HOST" "$ARCHIVE" \
            "$(shasum -a 256 "$FEED_DIR/$ARCHIVE.dmg" | cut -d' ' -f1)"
    } > "$PAGE"
    # shellcheck disable=SC2086
    if command -v gh > /dev/null && (cd "$ROOT" && gh release create "$TAG" --verify-tag \
        --title "Wingcord $NAME" --notes-file "$PAGE" ${PRERELEASE:+--prerelease} > /dev/null); then
        say "release page: $(cd "$ROOT" && gh release view "$TAG" --json url --jq .url)"
    else
        echo "release: the page on GitHub wasn't made; from $ROOT run:" >&2
        echo "   gh release create $TAG --verify-tag --title \"Wingcord $NAME\" --notes-file $PAGE ${PRERELEASE:+--prerelease}" >&2
    fi
}

# ── discard ────────────────────────────────────────────────────────────────
discard_release() {
    [ -f "$PENDING" ] || die "nothing is made"
    # shellcheck disable=SC1090
    . "$PENDING"
    local STAGE="$DIR/$BUILD"
    local FILE
    if [ -f "$STAGE/feed.new" ]; then
        while IFS= read -r FILE; do rm -f "$FEED_DIR/$FILE"; done < "$STAGE/feed.new"
    fi
    if [ -f "$STAGE/appcast.before.xml" ]; then
        cp "$STAGE/appcast.before.xml" "$FEED_DIR/appcast.xml"
    else
        rm -f "$FEED_DIR/appcast.xml"
    fi
    if [ "$MODE" = real ]; then
        local PLIST="$ROOT/Packaging/Info.plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $OLD_SHORT" "$PLIST"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $OLD_BUILD" "$PLIST"
        if [ -n "$OLD_PRE" ]; then
            /usr/libexec/PlistBuddy -c "Set :WingcordPrerelease $OLD_PRE" "$PLIST" 2>/dev/null \
                || /usr/libexec/PlistBuddy -c "Add :WingcordPrerelease string $OLD_PRE" "$PLIST"
        else
            /usr/libexec/PlistBuddy -c "Delete :WingcordPrerelease" "$PLIST" 2>/dev/null || true
        fi
    fi
    rm -rf "$STAGE" "$PENDING"
    say "discarded $NAME ($BUILD)"
}

# ── serve-test ─────────────────────────────────────────────────────────────
serve_test() {
    [ -d "$ROOT/build/releases-test/feed" ] || die "no test feed: release.sh make 1.0 \"Beta 1\" --test first"
    say "serving build/releases-test/feed on http://127.0.0.1:$TEST_PORT (Control-C stops it)"
    exec python3 -I -m http.server "$TEST_PORT" --bind 127.0.0.1 --directory "$ROOT/build/releases-test/feed"
}

case "$COMMAND" in
    make) make_release ;;
    publish) publish_release ;;
    discard) discard_release ;;
    serve-test) serve_test ;;
    *) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
