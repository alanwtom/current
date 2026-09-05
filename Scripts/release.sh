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
step "Done"
# ---------------------------------------------------------------------------
SIZE=$(du -h "$DMG" | cut -f1)
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
print "  $DMG ($SIZE)"
print "  sha256: $SHA"
print ""
print "  Publish the checksum alongside the download so people can verify it."
print "  Test it the way a user will: upload it, download it in a browser,"
print "  and open it on a Mac that has never had Xcode or Homebrew."
