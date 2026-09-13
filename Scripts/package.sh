#!/usr/bin/env bash
# 把 Sift.app 打成带安装脚本的 DMG。
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

APP_NAME="Sift"
DIST="$PROJECT_ROOT/dist"

"$PROJECT_ROOT/Scripts/build.sh"

VERSION="$(cat "$DIST/version.txt")"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
TMP_DIR="$(mktemp -d)"

echo "📦 打包 ${DMG_NAME}..."

cp -R "$DIST/${APP_NAME}.app" "$TMP_DIR/"
ln -s /Applications "$TMP_DIR/Applications"

cat > "$TMP_DIR/Install Sift.command" << 'INSTALL_EOF'
#!/bin/bash
set -e
APP_NAME="Sift"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="/Applications/$APP_NAME.app"

echo "Installing $APP_NAME..."
rm -rf "$TARGET"
cp -R "$SCRIPT_DIR/$APP_NAME.app" "$TARGET"
xattr -cr "$TARGET"
echo "Done! Launching $APP_NAME..."
open "$TARGET"
INSTALL_EOF
chmod +x "$TMP_DIR/Install Sift.command"

rm -f "$DIST/$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder "$TMP_DIR" -ov -format UDZO "$DIST/$DMG_NAME"
rm -rf "$TMP_DIR"

echo "✅ $DIST/$DMG_NAME"
