#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h}"
BUILD_ROOT="$PROJECT_ROOT/.build"
APP_BUNDLE="$PROJECT_ROOT/release/Codex Dashboard.app"
INSTALL_ROOT="${INSTALL_ROOT:-/Users/lawrenceawe/Applications}"
INSTALLED_APP="$INSTALL_ROOT/Codex Dashboard.app"

cd "$PROJECT_ROOT"
swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/Adapter"
cp "$BUILD_ROOT/release/CodexCanvas" "$APP_BUNDLE/Contents/MacOS/CodexCanvas"
cp "$PROJECT_ROOT/App/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_ROOT/Resources/Adapter/canvas.js" "$APP_BUNDLE/Contents/Resources/Adapter/canvas.js"
cp "$PROJECT_ROOT/Resources/Adapter/canvas.css" "$APP_BUNDLE/Contents/Resources/Adapter/canvas.css"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

mkdir -p "$INSTALL_ROOT"
rm -rf "$INSTALLED_APP"
ditto "$APP_BUNDLE" "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"

echo "Installed: $INSTALLED_APP"
