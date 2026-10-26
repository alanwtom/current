#!/bin/zsh
# Isolated, signed Sparkle integration test. App/library files stay in .build/.
# Sparkle uses the separate org.current.torrent.update-test defaults domain.
#
#   Scripts/test-update.sh prepare
#   Scripts/test-update.sh launch valid
#   Quit the named test app through its UI after "update-ready" in run-valid.log.
#   Scripts/test-update.sh verify valid
#   Scripts/test-update.sh launch tampered-feed
#   Quit the test app through its UI after "updater-error" in its run log.
#   Scripts/test-update.sh verify tampered-feed
#   Scripts/test-update.sh launch tampered-archive
#   Quit the test app through its UI after "updater-error" in its run log.
#   Scripts/test-update.sh verify tampered-archive
#   Scripts/test-update.sh cleanup
#
# The app, library, defaults, DHT state, and URL registration are separate from
# the real Current installation. No /Applications install is replaced. UI quit
# is deliberate: Sparkle installs a background update from the quit handler.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/update-test"
APPS="$WORK/install/Current Update Test.app"
SUPPORT="$WORK/support"
PORT="${CURRENT_UPDATE_TEST_PORT:-8123}"
FEED="http://localhost:$PORT/appcast.xml"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
TEST_ID="org.current.torrent.update-test"
step() { print -P "\n%F{cyan}==>%f $1" }
die() { print -u2 -- "error: $1"; exit 1 }
installed_version() { plutil -extract CFBundleShortVersionString raw "$APPS/Contents/Info.plist"; }

stop_server() {
    [[ -f "$WORK/server.pid" ]] || return 0
    local server_pid="$(cat "$WORK/server.pid")"
    [[ "$(ps -p "$server_pid" -o args= 2>/dev/null || true)" == *"http.server $PORT --bind 127.0.0.1 --directory $WORK/serve"* ]] \
        && kill "$server_pid" 2>/dev/null || true
    rm -f "$WORK/server.pid"
}

sign_app() {
    local dest="$1" fw="$1/Contents/Frameworks/Sparkle.framework"
    for nested in "$fw/Versions/B/XPCServices/Downloader.xpc" \
                  "$fw/Versions/B/XPCServices/Installer.xpc" \
                  "$fw/Versions/B/Updater.app" "$fw/Versions/B/Autoupdate"; do
        [[ ! -e "$nested" ]] || codesign --force --options runtime --timestamp --sign "$SIGNER" "$nested"
    done
    codesign --force --options runtime --timestamp --sign "$SIGNER" "$fw/Versions/B"
    codesign --force --options runtime --timestamp --sign "$SIGNER" "$fw"
    for lib in "$dest"/Contents/Frameworks/*.dylib(N); do
        codesign --force --options runtime --timestamp --sign "$SIGNER" "$lib"
    done
    codesign --force --options runtime --timestamp --sign "$SIGNER" "$dest"
    codesign --verify --deep --strict "$dest"
}

build_at() {
    local version="$1" build="$2" dest="$3"
    ditto "$ROOT/.build/Current.app" "$dest"
    local plist="$dest/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string "$TEST_ID" "$plist"
    plutil -replace CFBundleName -string "Current Update Test" "$plist"
    plutil -replace CFBundleDisplayName -string "Current Update Test" "$plist"
    plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    plutil -replace CFBundleVersion -string "$build" "$plist"
    plutil -replace SUFeedURL -string "$FEED" "$plist"
    plutil -replace SUEnableAutomaticChecks -bool true "$plist"
    plutil -insert CurrentUpdateTestSupportPath -string "$SUPPORT" "$plist"
    plutil -insert NSAppTransportSecurity -json '{"NSAllowsLocalNetworking":true}' "$plist"
    plutil -remove CFBundleURLTypes "$plist" 2>/dev/null || true
    plutil -remove CFBundleDocumentTypes "$plist" 2>/dev/null || true
    sign_app "$dest"
}

prepare() {
    step "Preparing an isolated signed update"
    stop_server
    [[ ! -e "$WORK/install" ]] || die "clean up the previous isolated test before preparing"
    rm -rf "$WORK/old" "$WORK/new" "$WORK/serve" "$SUPPORT"
    mkdir -p "$WORK/old" "$WORK/new" "$WORK/serve" "$SUPPORT" "$WORK/install"
    if [[ "${CURRENT_UPDATE_TEST_SKIP_BUILD:-0}" != 1 ]]; then
        "$ROOT/Scripts/make-app.sh" --release
    fi
    [[ -d "$ROOT/.build/Current.app" ]] || die "build Current.app first"
    SIGNER="${CURRENT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)}"
    [[ -n "$SIGNER" ]] || die "no Developer ID identity"
    build_at "1.1.0" "100001" "$WORK/old/Current Update Test.app"
    build_at "1.1.1" "100002" "$WORK/new/Current Update Test.app"
    hdiutil create -volname "Current Update Test" -srcfolder "$WORK/new" -ov -format UDZO "$WORK/serve/Current-1.1.1.dmg" >/dev/null
    codesign --force --timestamp --sign "$SIGNER" "$WORK/serve/Current-1.1.1.dmg"
    "$SPARKLE_BIN/generate_appcast" --download-url-prefix "http://localhost:$PORT/" \
        -o "$WORK/serve/appcast.xml" "$WORK/serve"
    "$SPARKLE_BIN/sign_update" --verify "$WORK/serve/appcast.xml"
    cp "$WORK/serve/appcast.xml" "$WORK/valid-appcast.xml"
    cp "$WORK/serve/Current-1.1.1.dmg" "$WORK/valid-update.dmg"
    sqlite3 "$SUPPORT/library.sqlite" "CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT NOT NULL); INSERT INTO settings VALUES('updates.asked','1'),('updates.automatic','1'),('network.binding','review');"
    python3 - "$WORK" "$PORT" <<'PY'
from pathlib import Path
import subprocess,sys
work,port=Path(sys.argv[1]),sys.argv[2]
with (work/'server.log').open('ab') as output:
    server=subprocess.Popen([sys.executable,'-m','http.server',port,'--bind','127.0.0.1','--directory',str(work/'serve')],stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
(work/'server.pid').write_text(str(server.pid))
PY
    for _ in {1..10}; do
        curl --max-time 2 -fsS "$FEED" >/dev/null 2>&1 && break
        sleep 1
    done
    curl --max-time 2 -fsS "$FEED" >/dev/null || die "test feed did not start"
    print "Prepared. Run: Scripts/test-update.sh launch valid"
}

launch_case() {
    local test_case="$1"
    [[ -f "$WORK/valid-appcast.xml" ]] || die "run prepare first"
    [[ "$test_case" == valid || "$test_case" == tampered-feed || "$test_case" == tampered-archive ]] || die "unknown test case"
    if pgrep -f "$APPS/Contents/MacOS/Current" >/dev/null; then
        die "quit Current Update Test through its UI before launching another case"
    fi
    rm -rf "$APPS"
    ditto "$WORK/old/Current Update Test.app" "$APPS"
    cp "$WORK/valid-appcast.xml" "$WORK/serve/appcast.xml"
    cp "$WORK/valid-update.dmg" "$WORK/serve/Current-1.1.1.dmg"
    if [[ "$test_case" == tampered-feed ]]; then
        python3 - "$WORK/serve/appcast.xml" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); text=p.read_text(); assert '<title>1.1.1</title>' in text
p.write_text(text.replace('<title>1.1.1</title>','<title>Modified update title</title>',1))
PY
        if "$SPARKLE_BIN/sign_update" --verify "$WORK/serve/appcast.xml" >/dev/null 2>&1; then
            die "modified feed unexpectedly verifies"
        fi
    elif [[ "$test_case" == tampered-archive ]]; then
        python3 - "$WORK/serve/Current-1.1.1.dmg" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); data=bytearray(p.read_bytes()); data[len(data)//2]^=1; p.write_bytes(data)
PY
    fi
    # Sparkle may cache its last check. Each case gets separate test defaults.
    defaults delete "$TEST_ID" 2>/dev/null || true
    python3 - "$APPS/Contents/MacOS/Current" "$WORK/run-$test_case.log" "$WORK/app.pid" <<'PY'
from pathlib import Path
import os,subprocess,sys
exe,log,pidfile=sys.argv[1:]
env=os.environ.copy(); env['CURRENT_UPDATE_CHECK_ON_LAUNCH']='1'; env['CURRENT_NO_NOTIFICATIONS']='1'
with open(log,'w') as output:
    app=subprocess.Popen([exe],stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,env=env,start_new_session=True)
Path(pidfile).write_text(str(app.pid))
PY
    print "Launched $test_case at $APPS"
    print "Read $WORK/run-$test_case.log, then quit this test app through its UI."
}

verify_case() {
    local test_case="$1" version="$(installed_version)" log="$WORK/run-$1.log"
    [[ -f "$log" ]] || die "launch this case first"
    if [[ "$test_case" == valid ]]; then
        for _ in {1..20}; do
            version="$(installed_version)"
            [[ "$version" == 1.1.1 ]] && break
            sleep 2
        done
        [[ "$version" == 1.1.1 ]] || die "valid update not installed (still $version)"
        codesign --verify --deep --strict "$APPS"
    else
        ! pgrep -f "$APPS/Contents/MacOS/Current" >/dev/null \
            || die "quit the isolated test app before verifying rejection"
        grep -q 'Current updater test: updater-error' "$log" || die "no verified updater rejection in $log"
        [[ "$version" == 1.1.0 ]] || die "a modified update installed ($version)"
    fi
    print "PASS: $test_case ($version)"
}

case "${1:-}" in
    prepare) prepare ;;
    launch) launch_case "${2:?choose valid, tampered-feed, or tampered-archive}" ;;
    verify) verify_case "${2:?choose a test case}" ;;
    cleanup)
        ! pgrep -f "$APPS/Contents/MacOS/Current" >/dev/null \
            || die "quit the isolated test app through its UI first"
        stop_server
        rm -rf "$WORK/install"
        print "Local test server stopped. Test evidence kept at $WORK"
        ;;
    *) die "usage: $0 prepare | launch CASE | verify CASE | cleanup" ;;
esac
