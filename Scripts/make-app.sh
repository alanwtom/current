#!/bin/zsh
# Builds Current.app from the Swift package.
#
# Usage:
#   Scripts/make-app.sh            # debug build
#   Scripts/make-app.sh --release  # release build
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="debug"
[[ "${1:-}" == "--release" ]] && CONFIG="release"

cd "$ROOT"
swift build -c "$CONFIG"

BIN=".build/arm64-apple-macosx/$CONFIG/Current"
APP="$ROOT/.build/Current.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Current"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"

# Embed Homebrew libtorrent so the bundle runs without a bare /opt/homebrew dependency.
if [[ -f /opt/homebrew/lib/libtorrent-rasterbar.2.1.dylib ]]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp /opt/homebrew/lib/libtorrent-rasterbar.*.dylib "$APP/Contents/Frameworks/" 2>/dev/null || true
    for dylib in "$APP"/Contents/Frameworks/libtorrent-rasterbar*.dylib; do
        install_name_tool -change \
            /opt/homebrew/opt/libtorrent-rasterbar/lib/libtorrent-rasterbar.2.1.dylib \
            @executable_path/../Frameworks/$(basename "$dylib") \
            "$APP/Contents/MacOS/Current" 2>/dev/null || true
    done
fi

# Ad-hoc sign so macOS will actually run the bundle.
codesign --force -s - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
