#!/bin/bash
# Builds OTPeek.app into ./dist. Pass --install to also copy it to
# /Applications and launch it.
#
# The bundle is assembled and signed in a staging directory outside the project:
# iCloud stamps files under ~/Desktop with com.apple.FinderInfo, which codesign
# rejects.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="OTPeek"
BUNDLE_ID="com.otpeek.OTPeek"
VERSION="1.0.0"
DIST="dist"

echo "==> Compiling (release)"
swift build -c release

echo "==> Running tests and security audit"
"./.build/release/$APP_NAME" --self-test > /dev/null || {
  echo "Tests failed — refusing to build. Run ./run-tests.sh to see why." >&2
  exit 1
}
./audit.sh > /dev/null || {
  echo "Security audit failed — refusing to build. Run ./audit.sh to see why." >&2
  exit 1
}

STAGE="$(mktemp -d)"
APP="$STAGE/$APP_NAME.app"

echo "==> Assembling bundle"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "./.build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

echo "==> Rendering icon"
ICONSET="$STAGE/$APP_NAME.iconset"
swift Tools/make-icon.swift "$ICONSET" > /dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$APP_NAME.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>            <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>              <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSHumanReadableCopyright</key>      <string>MIT licensed</string>
</dict>
</plist>
PLIST

echo "==> Signing"
codesign --force --deep --sign - "$APP"

echo "==> Installing to $DIST"
rm -rf "${DIST:?}/$APP_NAME.app"
mkdir -p "$DIST"
ditto "$APP" "$DIST/$APP_NAME.app"
rm -rf "$STAGE"

if [ "${1:-}" = "--install" ]; then
  echo "==> Copying to /Applications"
  osascript -e 'quit app "OTPeek"' 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$DIST/$APP_NAME.app" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "==> Launched from /Applications"
else
  echo "==> Built $DIST/$APP_NAME.app"
fi
