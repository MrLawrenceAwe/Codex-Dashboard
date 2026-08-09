#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="${0:A:h}"
BUILD_ROOT="$PROJECT_ROOT/.build"
APP_BUNDLE="$PROJECT_ROOT/release/Codex Dashboard.app"
INSTALL_ROOT="${INSTALL_ROOT:-$HOME/Applications}"
INSTALLED_APP="$INSTALL_ROOT/Codex Dashboard.app"
RUN_TESTS=1
RELAUNCH=0

for argument in "$@"; do
  case "$argument" in
    --skip-tests) RUN_TESTS=0 ;;
    --relaunch) RELAUNCH=1 ;;
    --no-launch) RELAUNCH=0 ;;
    *) echo "Unknown option: $argument" >&2; exit 2 ;;
  esac
done

source "$PROJECT_ROOT/Packaging/version.env"

cd "$PROJECT_ROOT"
if (( RUN_TESTS )); then
  swift test
fi
swift build -c release

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/Dashboard"
cp "$BUILD_ROOT/release/CodexDashboard" "$APP_BUNDLE/Contents/MacOS/CodexDashboard"
cp "$PROJECT_ROOT/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_ROOT/Packaging/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $APP_BUILD" "$APP_BUNDLE/Contents/Info.plist"
ditto "$BUILD_ROOT/release/CodexDashboard_CodexDashboard.bundle/Dashboard" "$APP_BUNDLE/Contents/Resources/Dashboard"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

mkdir -p "$INSTALL_ROOT"
if (( RELAUNCH )) && [[ -d "$INSTALLED_APP" ]]; then
  osascript -e 'tell application id "local.lawrenceawe.codex-dashboard" to quit' 2>/dev/null || true
  for _ in {1..40}; do
    pgrep -f '/Codex Dashboard.app/Contents/MacOS/CodexDashboard' >/dev/null || break
    sleep 0.1
  done
fi
rm -rf "$INSTALLED_APP"
ditto "$APP_BUNDLE" "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"

echo "Installed: $INSTALLED_APP"
if (( RELAUNCH )); then
  open "$INSTALLED_APP"
fi
