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

# Resolve Homebrew the same way Package.swift does, so a build that compiles
# on a non-default prefix also bundles from it. These used to disagree: the
# manifest was made portable while this script still read /opt/homebrew, which
# would have failed at the CA bundle with a confusing message.
BREW_PREFIX="${CURRENT_BREW_PREFIX:-}"
if [[ -z "$BREW_PREFIX" ]]; then
    for candidate in /opt/homebrew /usr/local; do
        [[ -d "$candidate/include/libtorrent" ]] && BREW_PREFIX="$candidate" && break
    done
fi
BREW_PREFIX="${BREW_PREFIX:-/opt/homebrew}"

BIN=".build/arm64-apple-macosx/$CONFIG/Current"
BUILT_PRODUCTS=".build/arm64-apple-macosx/$CONFIG"
APP="$ROOT/.build/Current.app"
FRAMEWORKS="$APP/Contents/Frameworks"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$FRAMEWORKS"
cp "$BIN" "$APP/Contents/MacOS/Current"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"

# ---------------------------------------------------------------------------
# Version, stamped from git rather than typed into the template
#
# The template used to carry `1.0.0` and build `1` literally, which meant every
# build the project has ever produced claimed to be the same one. That is fine
# right up until an updater exists, at which point two releases are
# indistinguishable — Sparkle compares CFBundleVersion and would see no reason
# to offer anything. It is also the first thing a bug report gets asked for.
#
# Marketing version comes from the newest tag; build number from the commit
# count, which only ever goes up and needs no state kept anywhere.
# ---------------------------------------------------------------------------
SHORT_VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
SHORT_VERSION="${SHORT_VERSION#v}"
if [[ -z "$SHORT_VERSION" ]]; then
    # An untagged checkout is a normal thing for a contributor to have, so this
    # is a real fallback rather than an error — but it is deliberately obvious,
    # so a fallback version can never be mistaken for a release.
    SHORT_VERSION="0.0.0-dev"
fi
BUILD_VERSION="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

plutil -replace CFBundleShortVersionString -string "$SHORT_VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_VERSION" "$APP/Contents/Info.plist"
echo "  version: $SHORT_VERSION ($BUILD_VERSION)"

# Licences for everything bundled inside. libtorrent (BSD-3), OpenSSL
# (Apache-2.0) and Boost (BSL-1.0) all require their notice to travel with a
# binary distribution, and this is the binary distribution. Regenerate with
# Scripts/make-notices.sh after upgrading a dependency.
if [[ -f "$ROOT/THIRD-PARTY-NOTICES.md" ]]; then
    cp "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/THIRD-PARTY-NOTICES.md"
else
    echo "error: THIRD-PARTY-NOTICES.md missing — run: Scripts/make-notices.sh" >&2
    exit 1
fi

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

# ---------------------------------------------------------------------------
# Sparkle
#
# A framework, not a dylib, so the walker above cannot handle it: it is a
# directory with versioned symlinks, its own code signature, an XPC service,
# and two nested executables (Autoupdate and Updater.app) that do the actual
# installing after Current has quit. Flattening any of that breaks updates in
# ways that only show up when an update is attempted.
#
# `ditto` rather than `cp -R` because it preserves the symlink structure and
# the existing signature exactly; `cp -R` on a versioned framework is a classic
# way to end up with a bundle that passes a casual look and fails notarisation.
# ---------------------------------------------------------------------------
SPARKLE_SOURCE="$ROOT/$BUILT_PRODUCTS/Sparkle.framework"
if [[ -d "$SPARKLE_SOURCE" ]]; then
    ditto "$SPARKLE_SOURCE" "$FRAMEWORKS/Sparkle.framework"

    # The executable looks for @rpath/Sparkle.framework/..., and SPM only gives
    # it an @loader_path rpath — which for something in Contents/MacOS points at
    # Contents/MacOS, not Contents/Frameworks. Without this the app dies at
    # launch with a dyld "Library not loaded" the moment Sparkle is linked.
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP/Contents/MacOS/Current" 2>/dev/null || true
else
    echo "error: Sparkle.framework not found at $SPARKLE_SOURCE" >&2
    echo "  the app links Sparkle; run: swift build -c $CONFIG" >&2
    exit 1
fi

# The certificate bundle. Homebrew's OpenSSL has the location of the trust
# store compiled in, pointing at a Homebrew directory no user has, so the
# library ships with the file it needs instead. `LibtorrentEngine` points
# OpenSSL at this copy on launch. Without it most trackers are HTTPS, every
# announce fails verification, and it reads as a flaky network.
CERT_SOURCE="$BREW_PREFIX/etc/openssl@3/cert.pem"
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
