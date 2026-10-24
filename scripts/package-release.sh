#!/usr/bin/env bash
set -euo pipefail

: "${1:?Usage: package-release.sh <version>}"
VERSION="$1"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ARM_BUILD_DIR="$ROOT/.build/arm64-apple-macosx/release"
INTEL_BUILD_DIR="$ROOT/.build/x86_64-apple-macosx/release"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/DockerSweep.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICON_SOURCE="$ROOT/Sources/DockerSweep/Resources/DockerSweepIcon.png"
ICONSET="$DIST_DIR/DockerSweepIcon.iconset"
ZIP_NAME="DockerSweep-${VERSION}-universal.zip"

rm -rf "$DIST_DIR"
mkdir -p "$MACOS" "$RESOURCES" "$ICONSET"

swift test
swift build -c release --arch arm64
swift build -c release --arch x86_64
lipo -create "$ARM_BUILD_DIR/DockerSweep" "$INTEL_BUILD_DIR/DockerSweep" -output "$MACOS/DockerSweep"

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Missing app icon source: $ICON_SOURCE" >&2
  exit 1
fi

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RESOURCES/DockerSweepIcon.icns"
rm -rf "$ICONSET"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>DockerSweep</string>
  <key>CFBundleIdentifier</key><string>dev.marcelbreuer.dockersweep</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleIconFile</key><string>DockerSweepIcon.icns</string>
  <key>CFBundleName</key><string>DockerSweep</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Marcel Breuer. MIT License.</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

if [[ "${REQUIRE_NOTARIZATION:-false}" == "true" ]]; then
  : "${DEVELOPER_ID_APPLICATION:?Developer ID identity is required for release signing}"
  : "${APPLE_ID:?Apple ID is required for notarization}"
  : "${APPLE_APP_SPECIFIC_PASSWORD:?Apple app-specific password is required for notarization}"
  : "${APPLE_TEAM_ID:?Apple Team ID is required for notarization}"
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP_DIR"
elif [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP_DIR"
else
  codesign --force --deep --sign - "$APP_DIR"
fi

codesign --verify --deep --strict "$APP_DIR"
ARCHS="$(lipo -archs "$MACOS/DockerSweep")"
[[ " $ARCHS " == *" arm64 "* && " $ARCHS " == *" x86_64 "* ]]

(
  cd "$DIST_DIR"
  /usr/bin/ditto -c -k --norsrc --keepParent "DockerSweep.app" "$ZIP_NAME"
  if [[ "${REQUIRE_NOTARIZATION:-false}" == "true" ]]; then
    xcrun notarytool submit "$ZIP_NAME" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
    xcrun stapler staple "DockerSweep.app"
    xcrun stapler validate "DockerSweep.app"
    rm -f "$ZIP_NAME"
    /usr/bin/ditto -c -k --norsrc --keepParent "DockerSweep.app" "$ZIP_NAME"
    spctl --assess --type execute --verbose "DockerSweep.app"
  fi
  shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256"
)

echo "$DIST_DIR/$ZIP_NAME"
echo "$DIST_DIR/$ZIP_NAME.sha256"
