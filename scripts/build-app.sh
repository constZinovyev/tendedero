#!/bin/bash
# Builds Tendedero.app into ./build without needing Xcode.
# Usage: scripts/build-app.sh [debug|release|dev]
#
# dev is for trying changes on this Mac: optimized like release, but only for
# this Mac's architecture and file by file instead of the whole module at
# once, so a change rebuilds in seconds. It keeps its own build folder, so
# switching between dev and release never throws either cache away.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
SWIFT_FLAGS=()
ARCHS=(arm64 x86_64)
if [ "$CONFIG" = dev ]; then
  CONFIG=release
  SWIFT_FLAGS=(--scratch-path .build-dev -Xswiftc -no-whole-module-optimization)
  ARCHS=("$(uname -m)")
fi
APP="build/Tendedero.app"
VERSION="1.0.0"

# Builds one architecture and prints the binary's path.
# The Command Line Tools for macOS 27 ship an SDK whose SwiftUI needs a macro
# plugin they do not include. If the default SDK fails, fall back to the
# newest macOS 26 SDK installed alongside it.
build_arch() {
  local triple="$1-apple-macosx14.0"
  local build=(swift build -c "$CONFIG" --triple "$triple" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"})
  if [ -z "${SDKROOT:-}" ] && ! "${build[@]}" >&2; then
    FALLBACK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)"
    if [ -z "$FALLBACK" ]; then exit 1; fi
    echo "Retrying with $FALLBACK" >&2
    export SDKROOT="$FALLBACK"
  fi
  if [ -n "${SDKROOT:-}" ]; then "${build[@]}" >&2; fi
  cp "$("${build[@]}" --show-bin-path)/Tendedero" "$OUT/Tendedero-$1"
}

# A universal binary, so it runs on Apple silicon and on Intel Macs, from
# macOS 14 Sonoma onwards.
OUT="$(mktemp -d)"
for arch in "${ARCHS[@]}"; do build_arch "$arch"; done
lipo -create "${ARCHS[@]/#/$OUT/Tendedero-}" -output "$OUT/Tendedero"
BIN="$OUT/Tendedero"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tendedero"

# Icon, drawn again only when the script that draws it changes.
ICON_CACHE="build/.icon-$(shasum scripts/make-icon.swift | cut -c1-12).icns"
if [ ! -f "$ICON_CACHE" ]; then
  WORK="$(mktemp -d)"
  swift scripts/make-icon.swift "$WORK/icon.png"
  ICONSET="$WORK/Tendedero.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  rm -f build/.icon-*.icns
  iconutil -c icns "$ICONSET" -o "$ICON_CACHE"
  rm -rf "$WORK"
fi
cp "$ICON_CACHE" "$APP/Contents/Resources/Tendedero.icns"

# The seagull's voice: short clips of real gull calls (see Resources/Gull/SOURCES.md).
if [ -d Resources/Gull ]; then cp -R Resources/Gull "$APP/Contents/Resources/Gull"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Tendedero</string>
  <key>CFBundleDisplayName</key><string>Tendedero</string>
  <key>CFBundleIdentifier</key><string>app.tendedero.Tendedero</string>
  <key>CFBundleExecutable</key><string>Tendedero</string>
  <key>CFBundleIconFile</key><string>Tendedero</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key>
  <string>Tendedero watches the folder where macOS saves your screenshots so it can hang them on the line.</string>
</dict>
</plist>
PLIST

# Sign with a Developer ID when one is in the keychain (or SIGN_IDENTITY is
# set), with the hardened runtime and a secure timestamp that notarization
# requires. Without one, a local self-signed identity named "Tendedero Local
# Signing" keeps the app the same app from build to build, so macOS keeps
# its permissions, like access to the Desktop. Without either, sign ad hoc
# so the app still runs locally; macOS then asks again after each build.
# (grep reads all of the list: with -q it would stop at the match, and
# under pipefail the cut-off security command would fail the test.)
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
LOCAL_IDENTITY="Tendedero Local Signing"
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  echo "Signed with $IDENTITY"
elif security find-identity -p codesigning 2>/dev/null | grep -F "\"$LOCAL_IDENTITY\"" >/dev/null; then
  codesign --force --deep --sign "$LOCAL_IDENTITY" "$APP" >/dev/null
  echo "Signed with $LOCAL_IDENTITY"
else
  codesign --force --deep --sign - "$APP" >/dev/null
  echo "Signed ad hoc (no Developer ID found)"
fi
echo "Built $APP"
