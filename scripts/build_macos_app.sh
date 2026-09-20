#!/usr/bin/env bash
# Build dist/Setlist.app.
#
# Default: a portable, self-contained app for Apple Silicon Macs. The media
# engine (relocatable CPython + the Python backend + static ffmpeg/ffprobe)
# ships inside the bundle, so the .app runs on a Mac that has nothing else
# installed. Pair with scripts/build_dmg.sh for a release disk image.
#
#   ./scripts/build_macos_app.sh
#
# Developer flavour: link the app to this checkout instead (the engine runs
# from ./run.sh and reads ./.env), which is faster to iterate on:
#
#   BUNDLE_ENGINE=0 ./scripts/build_macos_app.sh
#
# Environment knobs:
#   CODESIGN_IDENTITY  "-" for ad-hoc (default) or a "Developer ID Application: …"
#                      identity. A real identity also enables the hardened
#                      runtime and secure timestamps so the app can be notarized.
#   PYTHON_VERSION     CPython series to bundle (default 3.12; uv downloads it).
#   FFMPEG_BUILD       Static-build id from https://ffmpeg.martin-riedl.de
#                      (default pinned below, with checksums).
#   FFMPEG_DIR         Use prebuilt static ffmpeg + ffprobe from this folder
#                      instead of downloading.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$ROOT/macos"
BUILD_DIR="$ROOT/build"
CACHE_DIR="$BUILD_DIR/cache"
APP="$ROOT/dist/Setlist.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ENGINE="$RESOURCES/engine"
PLIST="$CONTENTS/Info.plist"

BUNDLE_ENGINE="${BUNDLE_ENGINE:-1}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
FFMPEG_BUILD="${FFMPEG_BUILD:-1787073674_9.0.1}"
FFMPEG_BASE_URL="https://ffmpeg.martin-riedl.de/download/macos/arm64/$FFMPEG_BUILD"
# SHA-256 of the pinned zips. Update both when bumping FFMPEG_BUILD; leave
# empty to accept whatever the server sends (the script prints the digest).
FFMPEG_SHA256="${FFMPEG_SHA256-8287a1b2229e05eb41859f073e18e6c52c60a778f2f5e6881070fe51b79407fe}"
FFPROBE_SHA256="${FFPROBE_SHA256-102a26b8940a053298d9929bfaae71e4b6ef65ba5f19a99a88c433108560741a}"

APP_VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/pyproject.toml" | head -n1)"
APP_VERSION="${APP_VERSION:-0.0.0}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || date +%Y%m%d)"

log() { printf '\033[1;35m▸\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing tool: $1${2:+ — $2}"
}

sha256_of() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

# --- 1. Swift app -------------------------------------------------------------
need swift "install Xcode or the Command Line Tools"
log "Building SetlistMac (release)"
swift build --package-path "$PACKAGE_DIR" --configuration release
BIN_DIR="$(swift build --package-path "$PACKAGE_DIR" --configuration release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BIN_DIR/SetlistMac" "$MACOS/Setlist"
chmod +x "$MACOS/Setlist"

if [ -f "$PACKAGE_DIR/Resources/AppIcon.icns" ]; then
  cp "$PACKAGE_DIR/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

# --- 2. Media engine ------------------------------------------------------------
bundle_python() {
  need uv "brew install uv"
  log "Installing CPython $PYTHON_VERSION via uv"
  uv python install "$PYTHON_VERSION" >/dev/null
  local python_bin python_root
  python_bin="$(uv python find --managed-python "$PYTHON_VERSION")"
  python_root="$(cd "$(dirname "$python_bin")/.." && pwd -P)"
  [ -x "$python_root/bin/python3" ] || die "Unexpected Python layout at $python_root"

  log "Copying Python from $python_root"
  mkdir -p "$ENGINE/python"
  # Trim what a headless media engine never needs: Tk, IDLE, tests, static
  # libs, headers. The interpreter finds its stdlib relative to itself and
  # libpython via @executable_path, so the copy is relocatable as-is.
  rsync -a \
    --exclude 'include/' \
    --exclude 'share/' \
    --exclude 'lib/pkgconfig/' \
    --exclude 'lib/tcl*' --exclude 'lib/tk*' --exclude 'lib/Tk*' \
    --exclude 'lib/itcl*' --exclude 'lib/thread*' \
    --exclude 'lib/libtcl*' --exclude 'lib/libtk*' \
    --exclude 'lib/*Config.sh' \
    --exclude 'lib/python*/config-*' \
    --exclude 'lib/python*/test/' \
    --exclude 'lib/python*/idlelib/' \
    --exclude 'lib/python*/tkinter/' \
    --exclude 'lib/python*/turtledemo/' \
    --exclude 'lib/python*/turtle.py' \
    --exclude 'lib/python*/ensurepip/' \
    --exclude 'lib/python*/lib2to3/' \
    --exclude 'lib/python*/lib-dynload/_tkinter*' \
    --exclude 'lib/python*/lib-dynload/_test*' \
    --exclude 'lib/python*/lib-dynload/_ctypes_test*' \
    --exclude 'lib/python*/lib-dynload/_xxtestfuzz*' \
    --exclude 'lib/python*/lib-dynload/xxlimited*' \
    --exclude '__pycache__/' \
    --exclude 'bin/2to3*' --exclude 'bin/idle*' --exclude 'bin/pydoc*' \
    --exclude 'bin/*-config' --exclude 'bin/pip*' \
    "$python_root/" "$ENGINE/python/"
  # uv marks its interpreters "externally managed" (PEP 668) so nothing
  # installs into them by accident. This copy is the app's own environment.
  find "$ENGINE/python/lib" -maxdepth 2 -name 'EXTERNALLY-MANAGED' -delete

  local py="$ENGINE/python/bin/python3"
  log "Installing backend dependencies into the bundled Python"
  # -r pyproject.toml installs the project's dependency list (not the
  # project). yt-dlp's default extras carry its optional network helpers;
  # certifi gives httpx/yt-dlp a CA bundle that does not depend on the host.
  uv pip install --python "$py" --quiet \
    -r "$ROOT/pyproject.toml" \
    "yt-dlp[default]" certifi
}

bundle_backend() {
  log "Copying backend (app/ + web/)"
  mkdir -p "$ENGINE/backend"
  rsync -a --exclude '__pycache__/' --exclude '.DS_Store' \
    "$ROOT/app/" "$ENGINE/backend/app/"
  rsync -a --exclude '.DS_Store' \
    "$ROOT/web/" "$ENGINE/backend/web/"
}

fetch_ffmpeg_tool() {
  local tool="$1" expected="$2"
  local zip="$CACHE_DIR/ffmpeg-$FFMPEG_BUILD/$tool.zip"
  mkdir -p "$(dirname "$zip")"
  if [ ! -f "$zip" ]; then
    log "Downloading static $tool ($FFMPEG_BUILD)"
    curl -fsSL --retry 3 -o "$zip.part" "$FFMPEG_BASE_URL/$tool.zip"
    mv "$zip.part" "$zip"
  fi
  local actual
  actual="$(sha256_of "$zip")"
  if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
    rm -f "$zip"
    die "$tool.zip checksum mismatch: expected $expected, got $actual"
  fi
  [ -n "$expected" ] || log "$tool.zip sha256 = $actual (unpinned)"
  unzip -o -q "$zip" "$tool" -d "$ENGINE/bin"
}

bundle_ffmpeg() {
  mkdir -p "$ENGINE/bin"
  if [ -n "${FFMPEG_DIR:-}" ]; then
    log "Using ffmpeg/ffprobe from $FFMPEG_DIR"
    cp "$FFMPEG_DIR/ffmpeg" "$FFMPEG_DIR/ffprobe" "$ENGINE/bin/"
  else
    need curl; need unzip
    fetch_ffmpeg_tool ffmpeg "$FFMPEG_SHA256"
    fetch_ffmpeg_tool ffprobe "$FFPROBE_SHA256"
  fi
  chmod +x "$ENGINE/bin/ffmpeg" "$ENGINE/bin/ffprobe"
  for tool in ffmpeg ffprobe; do
    if otool -L "$ENGINE/bin/$tool" | grep -qE '/(opt/homebrew|usr/local)/'; then
      die "$tool is not a static build (links into Homebrew); use a static binary"
    fi
  done
}

precompile_engine() {
  local py="$ENGINE/python/bin/python3"
  log "Precompiling bytecode (the signed bundle is read-only at run time)"
  # unchecked-hash pycs are used without consulting source mtimes, which
  # survive the copy to /Applications regardless of how Finder handles them.
  "$py" -m compileall -q -j 0 --invalidation-mode unchecked-hash \
    "$ENGINE/python/lib" "$ENGINE/backend/app" >/dev/null
}

smoke_test_engine() {
  local py="$ENGINE/python/bin/python3"
  log "Smoke-testing the bundled engine"
  (
    cd "$ENGINE/backend"
    PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1 PYTHONPATH="$ENGINE/backend" \
    PATH="$ENGINE/bin:/usr/bin:/bin" \
      "$py" - <<'PY'
import importlib, shutil, sys
for name in ("uvicorn", "fastapi", "yt_dlp", "mutagen", "PIL", "httpx", "dotenv", "certifi"):
    importlib.import_module(name)
import app.main  # noqa: F401  (mounts web/, builds the job manager)
for tool in ("ffmpeg", "ffprobe"):
    assert shutil.which(tool), f"{tool} missing from PATH"
print(f"  python {sys.version.split()[0]} · yt-dlp {importlib.import_module('yt_dlp.version').__version__}")
PY
    "$ENGINE/bin/ffmpeg" -version | head -n1 | sed 's/^/  /'
  )
}

if [ "$BUNDLE_ENGINE" = "1" ]; then
  bundle_python
  bundle_backend
  bundle_ffmpeg
  precompile_engine
  smoke_test_engine
fi

# --- 3. Info.plist ---------------------------------------------------------------
log "Writing Info.plist (version $APP_VERSION, build $BUILD_NUMBER)"
plutil -create xml1 "$PLIST"
plutil -insert CFBundleDevelopmentRegion -string "en" "$PLIST"
plutil -insert CFBundleDisplayName -string "Setlist" "$PLIST"
plutil -insert CFBundleExecutable -string "Setlist" "$PLIST"
plutil -insert CFBundleIconFile -string "AppIcon" "$PLIST"
plutil -insert CFBundleIdentifier -string "com.jan.setlist" "$PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "$PLIST"
plutil -insert CFBundleName -string "Setlist" "$PLIST"
plutil -insert CFBundlePackageType -string "APPL" "$PLIST"
plutil -insert CFBundleShortVersionString -string "$APP_VERSION" "$PLIST"
plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$PLIST"
plutil -insert CFBundleSupportedPlatforms -xml '<array><string>MacOSX</string></array>' "$PLIST"
plutil -insert LSApplicationCategoryType -string "public.app-category.music" "$PLIST"
plutil -insert LSMinimumSystemVersion -string "26.0" "$PLIST"
plutil -insert LSUIElement -bool true "$PLIST"
plutil -insert NSHighResolutionCapable -bool true "$PLIST"
plutil -insert NSHumanReadableCopyright -string "© $(date +%Y) Jan Ostrowka. Free software." "$PLIST"
plutil -insert NSPrincipalClass -string "NSApplication" "$PLIST"
plutil -insert NSAppTransportSecurity -xml \
  '<dict><key>NSAllowsLocalNetworking</key><true/></dict>' "$PLIST"
plutil -insert NSAppleEventsUsageDescription -string \
  "Setlist adds finished tracks to your Apple Music library." "$PLIST"
if [ "$BUNDLE_ENGINE" != "1" ]; then
  plutil -insert SetlistProjectRoot -string "$ROOT" "$PLIST"
fi

# --- 4. Code signing -------------------------------------------------------------
# Entitlements (macos/Resources/Setlist.entitlements):
#   automation.apple-events            — the Add to Apple Music step drives Music.app
#   cs.allow-unsigned-executable-memory — CPython's ctypes/libffi under hardened runtime
#   cs.disable-library-validation       — Python extension modules carry our signature,
#                                         not a platform one
# The two cs.* keys only take effect with `--options runtime` (real identity).
need codesign
ENTITLEMENTS="$PACKAGE_DIR/Resources/Setlist.entitlements"
SIGN_FLAGS=(--force --sign "$CODESIGN_IDENTITY")
if [ "$CODESIGN_IDENTITY" != "-" ]; then
  # Real identity: hardened runtime + timestamp, as notarization requires.
  SIGN_FLAGS+=(--options runtime --timestamp)
fi

# Finder metadata and quarantine flags on downloaded tools would be rejected
# by codesign as "detritus"; strip them first.
xattr -cr "$APP"
find "$APP" -name '.DS_Store' -delete

if [ "$BUNDLE_ENGINE" = "1" ]; then
  log "Signing engine binaries"
  # Every Mach-O inside the engine gets its own signature (inside-out), so
  # the final bundle seal covers already-valid nested code.
  SIGNED=0
  while IFS= read -r -d '' file; do
    if file -b "$file" | grep -q 'Mach-O'; then
      # Executables get the entitlements; libraries carry a plain signature.
      if [ -x "$file" ] && [[ "$file" != *.so && "$file" != *.dylib ]]; then
        codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$file" 2>&1 \
          | grep -v 'replacing existing signature' || true
      else
        codesign "${SIGN_FLAGS[@]}" "$file" 2>&1 \
          | grep -v 'replacing existing signature' || true
      fi
      codesign --verify "$file" || die "Signing failed for $file"
      SIGNED=$((SIGNED + 1))
    fi
  done < <(find "$ENGINE" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0)
  log "Signed $SIGNED engine binaries"
fi

log "Signing Setlist.app ($CODESIGN_IDENTITY)"
codesign "${SIGN_FLAGS[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --deep "$APP"

# --- 5. Report -------------------------------------------------------------------
SIZE="$(du -sh "$APP" | cut -f1)"
printf '\n'
log "Built $APP ($SIZE)"
if [ "$BUNDLE_ENGINE" = "1" ]; then
  printf '  engine: bundled (python %s, ffmpeg %s)\n' "$PYTHON_VERSION" "$FFMPEG_BUILD"
else
  printf '  engine: source checkout at %s\n' "$ROOT"
fi
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  printf '  signed: ad-hoc — downloaders must allow it once in System Settings → Privacy & Security\n'
else
  printf '  signed: %s — notarize with: xcrun notarytool submit <dmg> --keychain-profile <name> --wait\n' "$CODESIGN_IDENTITY"
fi
printf '  next:   ./scripts/build_dmg.sh   or   open "%s"\n' "$APP"
