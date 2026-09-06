#!/bin/zsh
# Builds a signed, notarised, stapled Current.dmg ready to put on a website.
#
#   Scripts/release.sh
#
# What Gatekeeper needs, and why each step is here:
#
#   signed          an ad-hoc signature runs locally and is rejected on any
#                   other Mac. Only a Developer ID identity is accepted.
#   hardened        notarisation refuses anything without the hardened runtime.
#   timestamped     a signature without a secure timestamp stops being valid
#                   the day the certificate expires, rather than staying valid
#                   for what it signed at the time.
#   notarised       required since macOS 10.15 for downloaded software. Signing
#                   alone is not enough and never has been.
#   stapled         attaches the notarisation ticket to the file. Without it a
#                   Mac has to ask Apple at first launch — so an offline user,
#                   or one behind a captive portal, gets the warning anyway.
#
# Credentials live in the keychain, never in this repo. Set them up once:
#
#   xcrun notarytool store-credentials "current-notary" \
#       --key ~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 \
#       --key-id XXXX --issuer <issuer-uuid>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Current.app"
DMG="$ROOT/.build/Current.dmg"
STAGE="$ROOT/.build/dmg-stage"
IDENTITY="${CURRENT_SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${CURRENT_NOTARY_PROFILE:-current-notary}"

step() { print -P "\n%F{cyan}==>%f $1" }
fail() { print -P "%F{red}error:%f $1" >&2; exit 1 }

# ---------------------------------------------------------------------------
# Preflight — every one of these has a specific fix, so say which.
# ---------------------------------------------------------------------------
step "Checking prerequisites"

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    fail "no Developer ID Application certificate in the keychain.
  Create one: Xcode > Settings > Accounts > your team > Manage Certificates > +
  or https://developer.apple.com/account/resources/certificates/add (pick G2 Sub-CA)"
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    fail "no usable notarisation credentials under the profile '$PROFILE'.
  Store them once with:
    xcrun notarytool store-credentials \"$PROFILE\" \\
        --key <path to AuthKey_XXXX.p8> --key-id <key id> --issuer <issuer uuid>"
fi

SIGNER=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
print "  signing as: $SIGNER"
print "  notarising with keychain profile: $PROFILE"

# Sparkle's tools come from the resolved package rather than being installed
# separately, so the signing tool always matches the framework being shipped.
GENERATE_APPCAST="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "$GENERATE_APPCAST" ]] || fail "Sparkle's generate_appcast is missing.
  Resolve the package first:  swift build"

if ! "$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys" -p >/dev/null 2>&1; then
    fail "no Sparkle signing key in the keychain.
  Every released update is signed with it, and a release without one cannot be
  installed by anybody. Generate it once with:
    .build/artifacts/sparkle/Sparkle/bin/generate_keys
  then put the public half in Scripts/Info.plist as SUPublicEDKey and back the
  private half up somewhere durable — losing it means no existing install can
  ever be updated again."
fi

# ---------------------------------------------------------------------------
# A release is a tag, and nothing else
#
# The version in the bundle now comes from `git describe`, so releasing from an
# untagged or dirty tree would publish a build whose version is a guess — and,
# worse, one nobody can check out again. Both of these are cheap to get wrong at
# midnight and expensive to discover afterwards.
# ---------------------------------------------------------------------------
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] \
    || fail "the working tree is dirty. Commit or stash before releasing."

TAG="$(git -C "$ROOT" describe --exact-match --tags HEAD 2>/dev/null || true)"
[[ -n "$TAG" ]] || fail "HEAD is not tagged.
  Tag the commit you intend to release first:  git tag -a v1.1.0 -m 'Current 1.1.0'"
VERSION="${TAG#v}"
print "  releasing: $TAG"

# ---------------------------------------------------------------------------
step "Building the release bundle"
# ---------------------------------------------------------------------------
"$ROOT/Scripts/make-app.sh" --release

# ---------------------------------------------------------------------------
step "Signing"
#
# Inside out, and that order is not a style choice: signing the bundle first
# and a nested library afterwards invalidates the outer signature, and the
# failure surfaces much later as a confusing notarisation rejection.
# ---------------------------------------------------------------------------
for lib in "$APP"/Contents/Frameworks/*.dylib(N); do
    codesign --force --options runtime --timestamp --sign "$SIGNER" "$lib"
    print "  signed ${lib:t}"
done

# Sparkle is a framework, and a framework signs from the inside out.
#
# It contains two XPC services, a helper app, and a standalone `Autoupdate`
# binary that does the installing after Current has quit. Each is its own
# signable unit, and signing the framework as a whole does NOT sign them —
# `codesign --deep` claims to and is explicitly unsupported for submission.
# Get the order wrong and everything looks fine locally, then notarisation
# rejects the build with a message about a nested component, which is a long
# way from the cause.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
    for nested in \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE/Versions/B/Updater.app" \
        "$SPARKLE/Versions/B/Autoupdate"
    do
        [[ -e "$nested" ]] || continue
        codesign --force --options runtime --timestamp --sign "$SIGNER" "$nested"
        print "  signed ${nested:t}"
    done
    # The framework itself last, so its seal covers everything above.
    codesign --force --options runtime --timestamp --sign "$SIGNER" "$SPARKLE/Versions/B"
    codesign --force --options runtime --timestamp --sign "$SIGNER" "$SPARKLE"
    print "  signed Sparkle.framework"
fi

codesign --force --options runtime --timestamp --sign "$SIGNER" "$APP"
print "  signed ${APP:t}"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

# ---------------------------------------------------------------------------
step "Notarising — this usually takes a few minutes"
#
# Apple only accepts an archive, not a bundle. The zip is a transport detail;
# the ticket it comes back with is stapled to the .app itself.
# ---------------------------------------------------------------------------
NOTARY_ZIP="$ROOT/.build/Current-notarize.zip"
rm -f "$NOTARY_ZIP"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"

if ! xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$PROFILE" --wait; then
    print -P "\n%F{red}Notarisation failed.%f Ask Apple exactly why:" >&2
    print "  xcrun notarytool history --keychain-profile $PROFILE" >&2
    print "  xcrun notarytool log <submission-id> --keychain-profile $PROFILE" >&2
    exit 1
fi
rm -f "$NOTARY_ZIP"

step "Stapling the ticket to the app"
xcrun stapler staple "$APP"

# ---------------------------------------------------------------------------
step "Checking what Gatekeeper will actually say"
#
# The real test. `codesign --verify` only says the signature is intact; this
# asks the thing that decides whether a user can open it.
# ---------------------------------------------------------------------------
if spctl --assess --type execute -vvv "$APP" 2>&1 | tee /dev/stderr | grep -q "accepted"; then
    print -P "  %F{green}Gatekeeper accepts it.%f"
else
    fail "Gatekeeper still rejects the app — do not ship this build."
fi

# ---------------------------------------------------------------------------
step "Building the disk image"
# ---------------------------------------------------------------------------
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # so the install is a drag

hdiutil create -volname "Current" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# The disk image gets signed and notarised too. A stapled app inside an
# unnotarised .dmg still warns on the *download*, which is the first thing
# anyone sees.
step "Signing and notarising the disk image"
codesign --force --timestamp --sign "$SIGNER" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# ---------------------------------------------------------------------------
step "Signing the update feed"
#
# The appcast is what every installed copy reads to learn a new version exists,
# and its EdDSA signature is the only thing standing between a user and an
# attacker-supplied "update". The private key lives in the login keychain and
# must never enter this repository — `generate_appcast` reads it from there.
#
# Note this signs the *disk image*: Sparkle downloads and verifies the same file
# a human would, so there is one artifact to trust rather than two.
# ---------------------------------------------------------------------------
APPCAST_DIR="$ROOT/.build/appcast"
rm -rf "$APPCAST_DIR"; mkdir -p "$APPCAST_DIR"
cp "$DMG" "$APPCAST_DIR/"

# Release notes for this version, lifted from the changelog so the two can
# never disagree.
NOTES="$ROOT/.build/release-notes.md"
python3 "$ROOT/Scripts/changelog-section.py" "$VERSION" > "$NOTES" || {
    fail "no CHANGELOG.md section for $VERSION — add one before releasing"
}

"$GENERATE_APPCAST" \
    --download-url-prefix "https://current.alantom.dev/" \
    --link "https://current.alantom.dev" \
    -o "$APPCAST_DIR/appcast.xml" \
    "$APPCAST_DIR"

grep -q "sparkle:edSignature" "$APPCAST_DIR/appcast.xml" \
    || fail "the appcast carries no signature — updates would be refused by every client"
print "  appcast signed"

# ---------------------------------------------------------------------------
step "Staging the site"
#
# `site/` deploys from this folder rather than from git, because Current.dmg is
# deliberately not in the repository — see site/README.md. Both the image and
# the feed have to be here before the deploy.
# ---------------------------------------------------------------------------
cp "$DMG" "$ROOT/site/Current.dmg"
cp "$APPCAST_DIR/appcast.xml" "$ROOT/site/appcast.xml"
print "  site/Current.dmg and site/appcast.xml updated"

# ---------------------------------------------------------------------------
step "Done"
# ---------------------------------------------------------------------------
SIZE=$(du -h "$DMG" | cut -f1)
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
print "  version: $VERSION"
print "  $DMG ($SIZE)"
print "  sha256: $SHA"
print ""
print "  Two commands left, deliberately not automated — each one publishes:"
print ""
print "    cd site && vercel deploy --prod        # download page + update feed"
print "    gh release create $TAG \\"
print "        --title \"Current $VERSION\" --notes-file $NOTES \\"
print "        $DMG"
print ""
print "  Update the SHA-256 on the download page to the one above."
print "  Then check it the way a user will: download it in a browser and open it"
print "  on a Mac that has never had Xcode or Homebrew."
