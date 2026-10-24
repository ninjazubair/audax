#!/bin/bash
# Build AUDAX.app, sign it with the self-signed "AUDAX Local Signing" identity, pack a DMG.
#   ./build.sh            -> dist/<timestamp>/AUDAX-<version>-<timestamp>.dmg
#   ./build.sh --install  -> the same, then replaces /Applications/AUDAX.app and opens it
# Each build's DMG gets its own folder and is never overwritten, so any earlier version can be
# reinstalled from it. The app itself is assembled in a temporary folder and only the DMG is
# kept: stray AUDAX.app copies would each show up in Launchpad and Spotlight.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION="0.2.1"
# Explicit: swiftc's default deployment target follows the build Mac and came out as 28.0 on
# macOS 27.0.1, which LaunchServices refuses to open. 14.0: the code uses macOS 14 APIs.
MIN_MACOS="14.0"
IDENTITY="AUDAX Local Signing"
BUNDLE_ID="local.audax"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$DIR/dist/$STAMP"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT  # this build's own temp folder only, also when a step fails
APP="$WORK/AUDAX.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

make_identity() {
  # Self-signed code-signing certificate in the login keychain. A stable identity keeps
  # macOS Microphone/Accessibility grants across rebuilds (ad-hoc signing loses them).
  local d="$HOME/.audax-signing" o=/opt/homebrew/opt/openssl@3/bin/openssl pass
  [ -x "$o" ] || brew install openssl@3
  mkdir -p "$d" && chmod 700 "$d"
  "$o" req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$d/audax.key" -out "$d/audax.crt" \
    -subj "/CN=$IDENTITY" -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
  pass="$("$o" rand -hex 16)" && echo "$pass" > "$d/p12-password"
  chmod 600 "$d/audax.key" "$d/p12-password"
  "$o" pkcs12 -export -legacy -inkey "$d/audax.key" -in "$d/audax.crt" -name "$IDENTITY" \
    -out "$d/audax.p12" -passout "pass:$pass"
  security import "$d/audax.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$pass" -T /usr/bin/codesign
}
security find-identity -p codesigning | grep -q "\"$IDENTITY\"" || make_identity

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target "arm64-apple-macos$MIN_MACOS" -o "$APP/Contents/MacOS/AUDAX" \
  "$DIR/main.swift" "$DIR/AUDAX.swift" "$DIR/AUDAXWindow.swift" "$DIR/Shortcut.swift" \
  "$DIR/Settings.swift" "$DIR/KeyTap.swift"
cp "$DIR/dictate.py" "$DIR/providers.py" "$DIR/word_subs.json" "$DIR/setup.sh" \
  "$DIR/assets/AppIcon.icns" "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/setup.sh"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>AUDAX</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>AUDAX</string>
  <key>CFBundleDisplayName</key><string>AUDAX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$STAMP</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>AUDAX records your voice for local dictation.</string>
</dict></plist>
EOF
# No --options runtime: hardened runtime would need a mic entitlement and only matters for
# Apple notarization, which a self-signed build cannot get anyway.
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

mkdir -p "$OUT"
DMG="$OUT/AUDAX-$VERSION-$STAMP.dmg"
STAGE="$WORK/dmg-stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "AUDAX" -srcfolder "$STAGE" -format UDZO "$DMG"
codesign --sign "$IDENTITY" "$DMG"
echo "Built: $DMG"

if [ "${1:-}" = "--install" ]; then
  pkill -x AUDAX || true
  rm -rf /Applications/AUDAX.app  # the previous version stays reinstallable from its DMG
  cp -R "$APP" /Applications/
  "$LSREGISTER" -f /Applications/AUDAX.app  # refresh name and icon in Launchpad/Finder
  open /Applications/AUDAX.app
  echo "Installed and opened /Applications/AUDAX.app"
fi

# Temporary build copies: unregister so they never appear as extra apps; the EXIT trap
# removes them.
"$LSREGISTER" -u "$APP" 2>/dev/null || true
"$LSREGISTER" -u "$STAGE/AUDAX.app" 2>/dev/null || true
