#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-0.1.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
BUILD_DIR="$ROOT/.build/arm64-apple-macosx/release"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/DockerSweep.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICON_SOURCE="$ROOT/Sources/DockerSweep/Resources/DockerSweepIcon.png"
ICONSET="$DIST_DIR/DockerSweepIcon.iconset"
ZIP_NAME="DockerSweep-${VERSION}-arm64.zip"

rm -rf "$DIST_DIR"
mkdir -p "$MACOS" "$RESOURCES" "$ICONSET"

swift test
swift build -c release --arch arm64
cp "$BUILD_DIR/DockerSweep" "$MACOS/DockerSweep"

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

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$APP_DIR"
else
  codesign --force --deep --sign - "$APP_DIR"
fi

codesign --verify --deep --strict "$APP_DIR"
file "$MACOS/DockerSweep" | grep -q "arm64"

(
  cd "$DIST_DIR"
  /usr/bin/ditto -c -k --norsrc --keepParent "DockerSweep.app" "$ZIP_NAME"
  shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256"
)

echo "$DIST_DIR/$ZIP_NAME"
echo "$DIST_DIR/$ZIP_NAME.sha256"
