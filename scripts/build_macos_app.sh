#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT/macos"
APP="$ROOT/dist/Setlist.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
PLIST="$CONTENTS/Info.plist"

swift build --package-path "$PACKAGE_DIR" --configuration release
BIN_DIR="$(swift build --package-path "$PACKAGE_DIR" --configuration release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$BIN_DIR/SetlistMac" "$MACOS/Setlist"
chmod +x "$MACOS/Setlist"

plutil -create xml1 "$PLIST"
plutil -insert CFBundleDevelopmentRegion -string "en" "$PLIST"
plutil -insert CFBundleDisplayName -string "Setlist" "$PLIST"
plutil -insert CFBundleExecutable -string "Setlist" "$PLIST"
plutil -insert CFBundleIdentifier -string "com.jan.setlist" "$PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "$PLIST"
plutil -insert CFBundleName -string "Setlist" "$PLIST"
plutil -insert CFBundlePackageType -string "APPL" "$PLIST"
plutil -insert CFBundleShortVersionString -string "0.1.0" "$PLIST"
plutil -insert CFBundleVersion -string "1" "$PLIST"
plutil -insert LSMinimumSystemVersion -string "13.0" "$PLIST"
plutil -insert LSUIElement -bool true "$PLIST"
plutil -insert NSHighResolutionCapable -bool true "$PLIST"
plutil -insert NSPrincipalClass -string "NSApplication" "$PLIST"
plutil -insert NSAppTransportSecurity -xml \
  '<dict><key>NSAllowsLocalNetworking</key><true/></dict>' "$PLIST"
plutil -insert SetlistProjectRoot -string "$ROOT" "$PLIST"

codesign --force --deep --sign - "$APP"

printf 'Built %s\n' "$APP"
printf 'Open it with: open "%s"\n' "$APP"
