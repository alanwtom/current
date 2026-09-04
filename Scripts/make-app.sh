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
FRAMEWORKS="$APP/Contents/Frameworks"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$FRAMEWORKS"
cp "$BIN" "$APP/Contents/MacOS/Current"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"

# App icon. Regenerate with `swift Scripts/make-icon.swift` after editing it.
if [[ -f "$ROOT/Scripts/AppIcon.icns" ]]; then
    cp "$ROOT/Scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "warning: Scripts/AppIcon.icns missing — run: swift Scripts/make-icon.swift" >&2
fi

# ---------------------------------------------------------------------------
# Bundling the libraries
#
# Everything the app loads that macOS does not ship has to travel inside the
# bundle, with every reference to it rewritten to a path relative to the
# bundle. Miss one and the app launches fine here and dies instantly on any Mac
# without Homebrew — not with a message, just a dyld abort, because the
# reference is an absolute path into /opt/homebrew that only exists on the
# machine that built it.
#
# This walks the whole graph rather than naming libraries. The first version
# copied libtorrent and stopped, which looked right and wasn't: libtorrent
# pulls OpenSSL, and libssl in turn pulls libcrypto, so the bundle shipped one
# library and still needed two more from Homebrew.
# ---------------------------------------------------------------------------

# Paths under these prefixes are part of macOS and are found on every Mac.
is_system_lib() {
    [[ "$1" == /usr/lib/* || "$1" == /System/* ]]
}

# Already relative to something in the bundle, so nothing to do.
is_relative_lib() {
    [[ "$1" == @* ]]
}

# Direct dependencies of a Mach-O file, minus its own id line.
dependencies_of() {
    otool -L "$1" | tail -n +2 | awk '{print $1}'
}

# Copies a library in, then does the same for whatever *it* needs.
vendor_library() {
    local source="$1"
    local base="${source:t}"
    [[ -f "$FRAMEWORKS/$base" ]] && return 0

    # `cp` follows symlinks, which matters: Homebrew's lib paths are links into
    # the Cellar, and copying the link would leave the bundle pointing at a
    # directory that isn't there.
    cp "$source" "$FRAMEWORKS/$base"
    chmod u+w "$FRAMEWORKS/$base"

    local dep
    for dep in $(dependencies_of "$FRAMEWORKS/$base"); do
        is_system_lib "$dep" && continue
        is_relative_lib "$dep" && continue
        [[ "${dep:t}" == "$base" ]] && continue   # its own id
        vendor_library "$dep"
    done
}

for dep in $(dependencies_of "$APP/Contents/MacOS/Current"); do
    is_system_lib "$dep" && continue
    is_relative_lib "$dep" && continue
    vendor_library "$dep"
done

# Point every reference at the bundle. The executable reaches its libraries
# through @executable_path; the libraries sit beside each other, so they reach
# each other through @loader_path.
for lib in "$FRAMEWORKS"/*.dylib(N); do
    base="${lib:t}"
    # stderr is dropped: install_name_tool warns that it invalidates the
    # code signature on every call, which is true and is why we re-sign below.
    install_name_tool -id "@loader_path/$base" "$lib" 2>/dev/null
    for dep in $(dependencies_of "$lib"); do
        is_system_lib "$dep" && continue
        is_relative_lib "$dep" && continue
        install_name_tool -change "$dep" "@loader_path/${dep:t}" "$lib" 2>/dev/null
    done
done

for dep in $(dependencies_of "$APP/Contents/MacOS/Current"); do
    is_system_lib "$dep" && continue
    is_relative_lib "$dep" && continue
    install_name_tool -change "$dep" "@executable_path/../Frameworks/${dep:t}" \
        "$APP/Contents/MacOS/Current" 2>/dev/null
done

# The certificate bundle. Homebrew's OpenSSL has the location of the trust
# store compiled in, pointing at a Homebrew directory no user has, so the
# library ships with the file it needs instead. `LibtorrentEngine` points
# OpenSSL at this copy on launch. Without it most trackers are HTTPS, every
# announce fails verification, and it reads as a flaky network.
CERT_SOURCE="/opt/homebrew/etc/openssl@3/cert.pem"
if [[ -f "$CERT_SOURCE" ]]; then
    cp "$CERT_SOURCE" "$APP/Contents/Resources/cacert.pem"
else
    echo "error: no CA bundle at $CERT_SOURCE" >&2
    echo "  install it with: brew install ca-certificates" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Proof, not hope
#
# The failure this guards against is invisible on the machine that builds it,
# so the check has to be structural: if nothing in the bundle names an absolute
# path outside macOS's own directories, there is nothing left to be missing.
# This fails the build rather than warning, because a warning in a build log is
# how the OpenSSL dependency survived the first attempt.
# ---------------------------------------------------------------------------
leaks=()
for macho in "$APP/Contents/MacOS/Current" "$FRAMEWORKS"/*.dylib(N); do
    for dep in $(dependencies_of "$macho"); do
        is_system_lib "$dep" && continue
        is_relative_lib "$dep" && continue
        leaks+=("${macho:t} -> $dep")
    done
done
if (( ${#leaks} )); then
    echo "error: bundle still depends on libraries outside it:" >&2
    printf '  %s\n' "${leaks[@]}" >&2
    echo "  (the app would fail to launch on a Mac without these installed)" >&2
    exit 1
fi

# Signing comes last: every install_name_tool edit above invalidates whatever
# signature the file had, so signing earlier would ship a broken one. Ad-hoc
# for now — a released build needs a Developer ID identity and notarisation.
for lib in "$FRAMEWORKS"/*.dylib(N); do
    codesign --force -s - "$lib" >/dev/null 2>&1 || true
done
codesign --force -s - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Bundled: $(print -l "$FRAMEWORKS"/*.dylib(N) | wc -l | tr -d ' ') libraries, no external dependencies"
