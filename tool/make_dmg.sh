#!/bin/sh
# Builds the macOS installer, build/SpaceMan.dmg: a window with SpaceMan and
# a link to Applications to drag it onto. Run from anywhere on a Mac:
#
#   tool/make_dmg.sh
#
# Without settings the app keeps Flutter's ad-hoc signature, so Gatekeeper
# blocks the first start. To ship it, sign and notarize:
#
#   SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)", from
#                   `security find-identity -v -p codesigning`
#   NOTARY_PROFILE  a profile saved with `xcrun notarytool store-credentials`,
#   or APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD (an app-specific
#                   password from account.apple.com)
#
# SKIP_BUILD=1 packages the existing release build instead of building again.
set -eu
cd "$(dirname "$0")/.."

APP=build/macos/Build/Products/Release/SpaceMan.app
DMG=build/SpaceMan.dmg
SIGN_IDENTITY=${SIGN_IDENTITY:-}

[ -n "${SKIP_BUILD:-}" ] || flutter build macos --release

if [ -n "$SIGN_IDENTITY" ]; then
  # Inside out: the embedded frameworks first, then the app itself, all with
  # the hardened runtime and a secure timestamp, as notarization requires.
  find "$APP/Contents/Frameworks" -depth \( -name '*.framework' -o -name '*.dylib' \) -print0 |
    xargs -0 -n1 codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY"
  codesign --force --timestamp --options runtime \
    --entitlements macos/Runner/Release.entitlements --sign "$SIGN_IDENTITY" "$APP"
  codesign --verify --strict --deep "$APP"
fi

# dmgbuild writes the window layout itself instead of scripting Finder, so
# it also works on a headless CI runner.
if ! command -v dmgbuild >/dev/null; then
  [ -x build/dmg-venv/bin/dmgbuild ] || {
    python3 -m venv build/dmg-venv
    build/dmg-venv/bin/pip install --quiet dmgbuild
  }
  PATH="$PWD/build/dmg-venv/bin:$PATH"
fi

# One TIFF with both resolutions, so the window is sharp on Retina screens.
tiffutil -cathidpicheck macos/dmg/background.png macos/dmg/background@2x.png \
  -out build/dmg-background.tiff
rm -f "$DMG"
dmgbuild -s macos/dmg/settings.py -D app="$APP" -D background=build/dmg-background.tiff \
  SpaceMan "$DMG"

if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  elif [ -n "${APPLE_ID:-}" ]; then
    xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_PASSWORD" --wait
  fi
  # Attach the notarization ticket, so the app also opens offline.
  if [ -n "${NOTARY_PROFILE:-}${APPLE_ID:-}" ]; then
    xcrun stapler staple "$DMG"
  fi
fi

echo "$DMG"
