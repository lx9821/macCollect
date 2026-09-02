#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/macCollect.app"
LEGACY_APP_DIR="$ROOT_DIR/dist/macCollect Basic.app"
LEGACY_COPY_APP_DIR="$ROOT_DIR/dist/macCollect Kopie.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build -c debug --product macCollectBasicApp
BUILD_BIN_DIR="$(swift build -c debug --product macCollectBasicApp --show-bin-path)"
APP_BINARY="$BUILD_BIN_DIR/macCollectBasicApp"

rm -rf "$APP_DIR" "$LEGACY_APP_DIR" "$LEGACY_COPY_APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/en.lproj"

cp "$APP_BINARY" "$MACOS_DIR/macCollectApp"
chmod +x "$MACOS_DIR/macCollectApp"

cat > "$MACOS_DIR/macCollect" <<'LAUNCHER'
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BIN="$SCRIPT_DIR/macCollectApp"

if [ ! -x "$APP_BIN" ]; then
  echo "macCollect executable not found: $APP_BIN" >&2
  exit 127
fi

export MACCOLLECT_FULLBUILD="${MACCOLLECT_FULLBUILD:-1}"

if [ "$(/usr/bin/id -u)" = "0" ]; then
  exec "$APP_BIN" "$@"
fi

is_recovery() {
  [ -d "/Applications/Utilities/Recovery Assistant.app" ] ||
  [ -e "/System/Volumes/Data/private/tmp/Recovery" ] ||
  [ -e "/private/tmp/Recovery" ]
}

if ! is_recovery; then
  exec "$APP_BIN" "$@"
fi

shell_quote() {
  /usr/bin/printf "'%s'" "$(/usr/bin/printf "%s" "$1" | /usr/bin/sed "s/'/'\\\\''/g")"
}

if [ -t 0 ] && [ -x /usr/bin/sudo ]; then
  exec /usr/bin/sudo "$APP_BIN" "$@"
fi

if [ -x /usr/bin/osascript ]; then
  COMMAND="$(shell_quote "$APP_BIN")"
  COMMAND="${COMMAND//\\/\\\\}"
  COMMAND="${COMMAND//\"/\\\"}"
  exec /usr/bin/osascript -e "do shell script \"$COMMAND\" with administrator privileges"
fi

echo "macCollect needs root privileges for Recovery APFS imaging. Start it from Terminal with: sudo $(shell_quote "$APP_BIN")" >&2
exit 77
LAUNCHER
chmod +x "$MACOS_DIR/macCollect"

cat > "$RESOURCES_DIR/en.lproj/InfoPlist.strings" <<'STRINGS'
"CFBundleDisplayName" = "macCollect";
STRINGS

if [[ -f "$ROOT_DIR/logo.png" ]]; then
  cp "$ROOT_DIR/logo.png" "$RESOURCES_DIR/AppLogo.png"
  ICONSET_DIR="$ROOT_DIR/dist/macCollectBasic.iconset"
  rm -rf "$ICONSET_DIR"
  mkdir -p "$ICONSET_DIR"
  sips -z 16 16 "$ROOT_DIR/logo.png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ROOT_DIR/logo.png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ROOT_DIR/logo.png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ROOT_DIR/logo.png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ROOT_DIR/logo.png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ROOT_DIR/logo.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ROOT_DIR/logo.png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ROOT_DIR/logo.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ROOT_DIR/logo.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ROOT_DIR/logo.png" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/macCollect.icns"
  rm -rf "$ICONSET_DIR"
fi

if [[ -f "$ROOT_DIR/HS-Wismar_Logo-FIW_2010-01.jpg" ]]; then
  cp "$ROOT_DIR/HS-Wismar_Logo-FIW_2010-01.jpg" "$RESOURCES_DIR/HS-Wismar_Logo-FIW_2010-01.jpg"
fi

if [[ -d "$ROOT_DIR/Resources/Tools" ]]; then
  mkdir -p "$RESOURCES_DIR/Tools"
  cp -R "$ROOT_DIR/Resources/Tools/." "$RESOURCES_DIR/Tools/"
  find "$RESOURCES_DIR/Tools" -type f -perm -111 -exec chmod 755 {} \;
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>macCollect</string>
    <key>CFBundleExecutable</key>
    <string>macCollect</string>
    <key>CFBundleIdentifier</key>
    <string>maccollect</string>
    <key>CFBundleIconFile</key>
    <string>macCollect</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>macCollect</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "Created $APP_DIR"
echo "Open with: open '$APP_DIR'"
