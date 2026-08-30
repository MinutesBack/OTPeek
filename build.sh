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
# macOS ties Full Disk Access to the app's code signature. An ad-hoc signature
# has no certificate, so the grant is pinned to the exact binary hash and is
# silently lost on every rebuild — the permission still looks granted in
# System Settings but no longer applies. Signing with a stable certificate,
# even a self-signed local one, keeps the identity constant across rebuilds.
IDENTITY="${OTPEEK_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -i "local signing" | head -1 | sed 's/.*"\(.*\)"/\1/')"
fi

if [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
  echo "    signed as \"$IDENTITY\" — Full Disk Access survives rebuilds"
else
  codesign --force --deep --sign - "$APP"
  cat <<'WARN'
    signed ad-hoc. Full Disk Access will have to be granted again after
    every rebuild, because macOS pins it to the exact binary.

    To avoid that, create a local signing certificate once:
      Keychain Access > Certificate Assistant > Create a Certificate…
      Name: OTPeek Local Signing
      Identity Type: Self Signed Root
      Certificate Type: Code Signing
    Then rebuild — build.sh picks it up automatically.
WARN
fi

echo "==> Installing to $DIST"
rm -rf "${DIST:?}/$APP_NAME.app"
mkdir -p "$DIST"
# The Desktop is backed by File Provider on this machine. It stamps the bundle
# root with Finder metadata that strict codesign verification rejects even
# though the sealed files are untouched. Do not copy extended attributes, and
# defensively remove FinderInfo if File Provider adds it after the copy.
ditto --noextattr "$APP" "$DIST/$APP_NAME.app"
xattr -d com.apple.FinderInfo "$DIST/$APP_NAME.app" 2>/dev/null || true
rm -rf "$STAGE"

if [ "${1:-}" = "--install" ]; then
  echo "==> Copying to /Applications"
  osascript -e 'quit app "OTPeek"' 2>/dev/null || true
  sleep 1
  rm -rf "/Applications/$APP_NAME.app"
  ditto --noextattr "$DIST/$APP_NAME.app" "/Applications/$APP_NAME.app"
  xattr -d com.apple.FinderInfo "/Applications/$APP_NAME.app" 2>/dev/null || true
  open "/Applications/$APP_NAME.app"
  echo "==> Launched from /Applications"
else
  echo "==> Built $DIST/$APP_NAME.app"
fi
