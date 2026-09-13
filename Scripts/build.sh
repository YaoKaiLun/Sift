#!/usr/bin/env bash
# 用 Xcode 工程打出 ad-hoc 签名的 Sift.app，放到 dist/。
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

APP_NAME="Sift"
DERIVED="$PROJECT_ROOT/.build/DerivedData"
DIST="$PROJECT_ROOT/dist"
ENTITLEMENTS="$PROJECT_ROOT/App/Sift/Sift.entitlements"
ICON="$PROJECT_ROOT/App/Sift/Assets.xcassets/AppIcon.appiconset/icon_512@2x.png"

VERSION="$(python3 - <<'PY'
import os
import subprocess
import sys

sys.path.insert(0, "Scripts")
from version import parse_version

ref = os.environ.get("GITHUB_REF") or None
describe = None
try:
    describe = subprocess.check_output(
        ["git", "describe", "--tags", "--abbrev=0"],
        text=True,
        stderr=subprocess.DEVNULL,
    ).strip()
except subprocess.CalledProcessError:
    pass
print(parse_version(ref, describe))
PY
)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || date +%s)"

echo "📦 构建 $APP_NAME $VERSION ($BUILD_NUMBER)"

if [[ ! -f "$ICON" ]]; then
    echo "🎨 生成 App Icon…"
    python3 Scripts/create_icons.py
fi

mkdir -p "$DIST"
rm -rf "$DIST/${APP_NAME}.app"

xcodebuild \
    -project App/Sift.xcodeproj \
    -scheme Sift \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    build

SRC="$DERIVED/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "$SRC" ]]; then
    echo "找不到 $SRC" >&2
    exit 1
fi

cp -R "$SRC" "$DIST/${APP_NAME}.app"

echo "🎨 编译 AppIcon.icns…"
ICONSET="$PROJECT_ROOT/.build/AppIcon.iconset"
ICON_SRC="$PROJECT_ROOT/App/Sift/Assets.xcassets/AppIcon.appiconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
cp "$ICON_SRC/icon_16.png" "$ICONSET/icon_16x16.png"
cp "$ICON_SRC/icon_16@2x.png" "$ICONSET/icon_16x16@2x.png"
cp "$ICON_SRC/icon_32.png" "$ICONSET/icon_32x32.png"
cp "$ICON_SRC/icon_32@2x.png" "$ICONSET/icon_32x32@2x.png"
cp "$ICON_SRC/icon_128.png" "$ICONSET/icon_128x128.png"
cp "$ICON_SRC/icon_128@2x.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICON_SRC/icon_256.png" "$ICONSET/icon_256x256.png"
cp "$ICON_SRC/icon_256@2x.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICON_SRC/icon_512.png" "$ICONSET/icon_512x512.png"
cp "$ICON_SRC/icon_512@2x.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$DIST/${APP_NAME}.app/Contents/Resources/AppIcon.icns"

echo "🔏 签名…"
codesign --force --sign - \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$DIST/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
codesign --force --sign - \
    --entitlements "$ENTITLEMENTS" \
    --options runtime \
    "$DIST/${APP_NAME}.app"
codesign --verify --deep --strict "$DIST/${APP_NAME}.app"

printf '%s\n' "$VERSION" > "$DIST/version.txt"

echo "✅ $DIST/${APP_NAME}.app"
