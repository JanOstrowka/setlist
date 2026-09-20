#!/usr/bin/env bash
# Package dist/Setlist.app into a release disk image:
#
#   dist/Setlist-<version>-arm64.dmg      (drag Setlist → Applications)
#   dist/Setlist-<version>-arm64.dmg.sha256
#
# Builds the app first unless SKIP_BUILD=1. Honors CODESIGN_IDENTITY like
# build_macos_app.sh; with a real identity the image itself is signed too.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Setlist.app"
STAGE="$ROOT/build/dmg"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

log() { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  CODESIGN_IDENTITY="$CODESIGN_IDENTITY" "$ROOT/scripts/build_macos_app.sh"
fi
[ -d "$APP" ] || die "Missing $APP — run scripts/build_macos_app.sh first"

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")"
ARCH="$(lipo -archs "$APP/Contents/MacOS/Setlist" | tr ' ' '-')"
DMG="$ROOT/dist/Setlist-$VERSION-$ARCH.dmg"
VOLUME_NAME="Setlist $VERSION"

if plutil -extract SetlistProjectRoot raw -o - "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  die "This app is linked to the source checkout (BUNDLE_ENGINE=0); build a bundled app for distribution"
fi

log "Staging $VOLUME_NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"
# ditto preserves symlinks, permissions, and the code signature seal.
ditto "$APP" "$STAGE/Setlist.app"
ln -s /Applications "$STAGE/Applications"

log "Creating $DMG"
rm -f "$DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 \
  -ov -quiet \
  "$DMG"

if [ "$CODESIGN_IDENTITY" != "-" ]; then
  log "Signing disk image"
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
fi

log "Verifying image"
hdiutil verify -quiet "$DMG"
shasum -a 256 "$DMG" | sed "s|$ROOT/dist/||" > "$DMG.sha256"

rm -rf "$STAGE"
printf '\n'
log "Ready: $DMG ($(du -h "$DMG" | cut -f1))"
printf '  sha256: %s\n' "$(cut -d' ' -f1 "$DMG.sha256")"
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  printf '  note:   ad-hoc signed. First launch: right-click → Open, or System Settings → Privacy & Security → Open Anyway.\n'
else
  printf '  next:   xcrun notarytool submit "%s" --keychain-profile <profile> --wait && xcrun stapler staple "%s"\n' "$DMG" "$APP"
fi
