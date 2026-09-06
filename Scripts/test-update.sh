#!/bin/zsh
# Proves the updater actually delivers an update, end to end.
#
#   Scripts/test-update.sh
#
# The one thing about a release that cannot be checked by reading it: whether an
# installed copy notices a newer version, verifies it, and becomes that version.
# Everything else about the update path can look right and still not work, and
# the failure only shows up on someone else's machine, months later, when a
# security fix silently fails to reach them.
#
# What is real here and what is not:
#
#   real   the code signature, on both builds
#   real   the EdDSA signature on the update, and its verification
#   real   Sparkle's download, extraction and install
#   real   the install lives in /Applications, like a user's
#   fake   the feed is on localhost, NOT current.alantom.dev
#
# That last one is not a shortcut, it is the point: publishing a pretend 1.1.1
# to the live appcast would hand it to every real install. The feed URL is the
# only thing changed, and it is patched into the bundle *before* signing, so the
# signature stays valid.
#
# Leaves /Applications/Current.app as whatever the test produced. Anything that
# was there is moved aside and put back.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/update-test"
PORT=8123
FEED="http://localhost:$PORT/appcast.xml"
APPS="/Applications/Current.app"
BACKUP="/Applications/Current.app.before-update-test"

SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
step() { print -P "\n%F{cyan}==>%f $1" }
ok()   { print -P "  %F{green}✓%f $1" }
bad()  { print -P "  %F{red}✗%f $1" }
die()  { print -P "%F{red}error:%f $1" >&2; cleanup; exit 1 }

cleanup() {
    [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
    pkill -f "$APPS/Contents/MacOS/Current" 2>/dev/null || true
}
trap cleanup EXIT

# Quits the app the way a person does.
#
# `pkill` sends SIGTERM, which a GUI app does not treat as a quit — Sparkle
# installs a downloaded update from the app's termination handler, and that
# handler does not run reliably on a signal. This made the test flaky in the
# most misleading way possible: the update path was fine and the *test* was
# killing the app before it could finish.
quit_app() {
    osascript -e 'tell application "Current" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do
        pgrep -f "$APPS/Contents/MacOS/Current" >/dev/null || return 0
        sleep 1
    done
    pkill -f "$APPS/Contents/MacOS/Current" 2>/dev/null || true
}

SIGNER=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
[[ -n "$SIGNER" ]] || die "no Developer ID identity in the keychain"

# ---------------------------------------------------------------------------
step "Building the pair"
# ---------------------------------------------------------------------------
rm -rf "$WORK"; mkdir -p "$WORK/serve"
"$ROOT/Scripts/make-app.sh" --release >/dev/null

# Builds a copy at a given version, pointed at the local feed, properly signed.
build_at() {
    local version="$1" build="$2" dest="$3"
    ditto "$ROOT/.build/Current.app" "$dest"
    plutil -replace CFBundleShortVersionString -string "$version" "$dest/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$build" "$dest/Contents/Info.plist"
    plutil -replace SUFeedURL -string "$FEED" "$dest/Contents/Info.plist"
    plutil -replace SUEnableAutomaticChecks -bool true "$dest/Contents/Info.plist"

    # Inside out, exactly as release.sh does it — an update installed onto a
    # badly-signed app fails in ways that look like Sparkle's fault.
    local fw="$dest/Contents/Frameworks/Sparkle.framework"
    for nested in "$fw/Versions/B/XPCServices/Downloader.xpc" \
                  "$fw/Versions/B/XPCServices/Installer.xpc" \
                  "$fw/Versions/B/Updater.app" "$fw/Versions/B/Autoupdate"; do
        [[ -e "$nested" ]] && codesign --force --options runtime --timestamp \
            --sign "$SIGNER" "$nested" 2>/dev/null
    done
    codesign --force --options runtime --timestamp --sign "$SIGNER" "$fw/Versions/B" 2>/dev/null
    codesign --force --options runtime --timestamp --sign "$SIGNER" "$fw" 2>/dev/null
    for lib in "$dest"/Contents/Frameworks/*.dylib(N); do
        codesign --force --options runtime --timestamp --sign "$SIGNER" "$lib" 2>/dev/null
    done
    codesign --force --options runtime --timestamp --sign "$SIGNER" "$dest" 2>/dev/null
}

build_at "1.1.0" "58" "$WORK/old/Current.app"
build_at "1.1.1" "59" "$WORK/new/Current.app"
ok "built 1.1.0 (58) and 1.1.1 (59), both pointed at $FEED"

codesign --verify --deep --strict "$WORK/old/Current.app" || die "the 1.1.0 build is not properly signed"
codesign --verify --deep --strict "$WORK/new/Current.app" || die "the 1.1.1 build is not properly signed"
ok "both signatures verify"

# ---------------------------------------------------------------------------
step "Publishing 1.1.1 to a local feed"
# ---------------------------------------------------------------------------
hdiutil create -volname "Current" -srcfolder "$WORK/new" -ov -format UDZO \
    "$WORK/serve/Current-1.1.1.dmg" >/dev/null
codesign --force --timestamp --sign "$SIGNER" "$WORK/serve/Current-1.1.1.dmg"

"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "http://localhost:$PORT/" \
    -o "$WORK/serve/appcast.xml" "$WORK/serve" >/dev/null

grep -q "sparkle:edSignature" "$WORK/serve/appcast.xml" \
    || die "the test appcast is unsigned — this would prove nothing"
ok "1.1.1 signed into a local appcast"

(cd "$WORK/serve" && python3 -m http.server "$PORT" >/dev/null 2>&1) &
SERVER_PID=$!
sleep 2
curl -sf "$FEED" >/dev/null || die "the local feed is not serving"
ok "feed live on port $PORT"

# ---------------------------------------------------------------------------
step "Installing 1.1.0 like a user would"
# ---------------------------------------------------------------------------
[[ -d "$APPS" ]] && mv "$APPS" "$BACKUP"
ditto "$WORK/old/Current.app" "$APPS"
installed_version() { plutil -extract CFBundleShortVersionString raw "$APPS/Contents/Info.plist" 2>/dev/null }
installed_build()   { plutil -extract CFBundleVersion raw "$APPS/Contents/Info.plist" 2>/dev/null }
ok "installed $(installed_version) ($(installed_build)) to /Applications"

# Pre-answer the first-launch question so the run is unattended. This is the
# setting the card writes; setting it directly is the same as clicking yes.
DB="$HOME/Library/Application Support/Current/library.sqlite"
if [[ -f "$DB" ]]; then
    sqlite3 "$DB" "insert or replace into settings(key,value) values('updates.asked','1'),('updates.automatic','1');" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
step "Letting it update itself"
# ---------------------------------------------------------------------------
# CURRENT_UPDATE_CHECK_ON_LAUNCH asks for one check straight away. Without it
# this waits on Sparkle's own scheduler, which spaces checks out by a day —
# correct for a real install, useless for proving the path works.
CURRENT_UPDATE_CHECK_ON_LAUNCH=1 "$APPS/Contents/MacOS/Current" > "$WORK/run.log" 2>&1 &

# Long enough to check, download ten megabytes over loopback and extract.
print "  waiting for the check and download"
sleep 45

# Sparkle installs on quit when the update came down in the background — which
# is the path a real user takes by ignoring the toast rather than pressing it.
quit_app
print "  quit cleanly; the installer runs now"

for i in {1..40}; do
    sleep 3
    [[ "$(installed_version)" == "1.1.1" ]] && break
done

FINAL_VERSION="$(installed_version)"
FINAL_BUILD="$(installed_build)"

# ---------------------------------------------------------------------------
step "Result"
# ---------------------------------------------------------------------------
if [[ "$FINAL_VERSION" == "1.1.1" && "$FINAL_BUILD" == "59" ]]; then
    ok "the installed app is now $FINAL_VERSION ($FINAL_BUILD) — it updated itself"
    RESULT=0
else
    bad "still $FINAL_VERSION ($FINAL_BUILD) — the update did not install"
    RESULT=1
fi

codesign --verify --deep --strict "$APPS" 2>/dev/null \
    && ok "the updated app is still properly signed" \
    || bad "the updated app's signature is broken"

# ---------------------------------------------------------------------------
step "The half that matters: a tampered update must be refused"
#
# The first half only proves updates install. If a *modified* one installs too,
# the EdDSA signature is decoration and anyone who can answer for the feed's
# host — a hostile network, a compromised CDN, a stolen domain — can hand every
# install whatever they like.
#
# The appcast keeps the signature of the real 1.1.1. The file served under that
# name is swapped for a different, perfectly valid disk image. So the download
# succeeds, mounts, and contains a real app: the *only* thing wrong is that its
# bytes are not the ones that were signed.
# ---------------------------------------------------------------------------
rm -rf "$APPS"
ditto "$WORK/old/Current.app" "$APPS"
ok "back to $(installed_version) ($(installed_build))"

# A valid image, different bytes. Rebuilding is enough — the timestamps inside
# differ, so the hash does.
hdiutil create -volname "Current" -srcfolder "$WORK/new" -ov -format UDZO \
    "$WORK/tampered.dmg" >/dev/null
codesign --force --timestamp --sign "$SIGNER" "$WORK/tampered.dmg"
cp "$WORK/tampered.dmg" "$WORK/serve/Current-1.1.1.dmg"

ok "served file swapped; the appcast still advertises the original's signature"

CURRENT_UPDATE_CHECK_ON_LAUNCH=1 "$APPS/Contents/MacOS/Current" > "$WORK/run2.log" 2>&1 &
sleep 45
quit_app
sleep 30

TAMPER_VERSION="$(installed_version)"
if [[ "$TAMPER_VERSION" == "1.1.0" ]]; then
    ok "refused it — still $TAMPER_VERSION, exactly as it should be"
else
    bad "INSTALLED A FILE THAT DID NOT MATCH ITS SIGNATURE (now $TAMPER_VERSION)"
    RESULT=1
fi

# Put back whatever was there before.
rm -rf "$APPS"
[[ -d "$BACKUP" ]] && mv "$BACKUP" "$APPS"
print "\n  /Applications restored to how it was."
exit $RESULT
