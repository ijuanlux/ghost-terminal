#!/bin/zsh
# Construye Ciclope.app en ~/Apps a partir del build release.
set -e
cd "$(dirname "$0")/.."

echo "→ build release"
swift build -c release

APP=/Applications/Ghost.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ icono"
TMPICON=$(mktemp -d)
swift scripts/icon.swift "$TMPICON/icon.png"
mkdir -p "$TMPICON/ciclope.iconset"
for s in 16 32 64 128 256 512; do
  sips -z $s $s "$TMPICON/icon.png" --out "$TMPICON/ciclope.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s*2))
  sips -z $d $d "$TMPICON/icon.png" --out "$TMPICON/ciclope.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMPICON/ciclope.iconset" -o "$APP/Contents/Resources/Ghost.icns"
rm -rf "$TMPICON"

echo "→ bundle"
cp .build/release/Ciclope "$APP/Contents/MacOS/Ghost"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Ghost</string>
    <key>CFBundleDisplayName</key><string>Ghost</string>
    <key>CFBundleIdentifier</key><string>com.juan.ghost</string>
    <key>CFBundleVersion</key><string>1.1</string>
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleExecutable</key><string>Ghost</string>
    <key>CFBundleIconFile</key><string>Ghost</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

codesign --force -s - "$APP" 2>/dev/null || true
echo "✓ $APP listo"
