#!/bin/bash
# Builds Tendedero.saver into ./build. With --install, puts it in
# ~/Library/Screen Savers, where System Settings lists it.
# Usage: scripts/build-saver.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product TendederoSaver >&2
LIB="$(swift build -c release --show-bin-path)/libTendederoSaver.dylib"

SAVER="build/Tendedero.saver"
rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS"
cp "$LIB" "$SAVER/Contents/MacOS/TendederoSaver"
cat > "$SAVER/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>app.tendedero.Saver</string>
  <key>CFBundleName</key><string>Tendedero</string>
  <key>CFBundleExecutable</key><string>TendederoSaver</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSPrincipalClass</key><string>TendederoSaverView</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$SAVER" >/dev/null

if [ "${1:-}" = "--install" ]; then
  # The same saver as last time: nothing to install, and the engine keeps
  # running.
  STAMP="build/.saver-installed"
  SUM="$(cat "$LIB" "$SAVER/Contents/Info.plist" | shasum | cut -c1-40)"
  if [ -d "$HOME/Library/Screen Savers/Tendedero.saver" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$SUM" ]; then
    echo "Screen saver unchanged"
    exit 0
  fi
  mkdir -p "$HOME/Library/Screen Savers"
  rm -rf "$HOME/Library/Screen Savers/Tendedero.saver"
  cp -R "$SAVER" "$HOME/Library/Screen Savers/"
  # The engine keeps an old copy loaded until it restarts.
  killall legacyScreenSaver 2>/dev/null || true
  echo "$SUM" > "$STAMP"
  echo "Installed in ~/Library/Screen Savers"
fi
