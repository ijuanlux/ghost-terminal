#!/bin/zsh
# Construye el DMG de distribución: build + bundle + imagen comprimida en dist/
set -e
cd "$(dirname "$0")/.."

VERSION=${1:-1.2.0}

./scripts/make-app.sh

echo "→ dmg"
rm -rf dist && mkdir -p dist/stage
cp -R /Applications/Ghost.app dist/stage/Ghost.app
ln -s /Applications dist/stage/Applications
hdiutil create -volname "Ghost" -srcfolder dist/stage -ov -format UDZO \
  "dist/Ghost-${VERSION}.dmg" | tail -1
rm -rf dist/stage
echo "✓ dist/Ghost-${VERSION}.dmg"
