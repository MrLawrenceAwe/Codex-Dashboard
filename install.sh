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

if [[ -z "$INSTALL_ROOT" || "$INSTALL_ROOT" == "/" ]]; then
  echo "Refusing unsafe INSTALL_ROOT: $INSTALL_ROOT" >&2
  exit 2
fi

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
STAGING_ROOT="$(mktemp -d "$INSTALL_ROOT/.codex-dashboard-install.XXXXXX")"
STAGED_APP="$STAGING_ROOT/Codex Dashboard.app"
PREVIOUS_APP="$STAGING_ROOT/Previous Codex Dashboard.app"
cleanup() { rm -rf "$STAGING_ROOT"; }
trap cleanup EXIT

if (( RELAUNCH )) && [[ -d "$INSTALLED_APP" ]]; then
  osascript -e 'tell application id "local.lawrenceawe.codex-dashboard" to quit' 2>/dev/null || true
  for _ in {1..40}; do
    pgrep -f '/Codex Dashboard.app/Contents/MacOS/CodexDashboard' >/dev/null || break
    sleep 0.1
  done
fi
ditto "$APP_BUNDLE" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
if [[ -d "$INSTALLED_APP" ]]; then
  mv "$INSTALLED_APP" "$PREVIOUS_APP"
fi
if ! mv "$STAGED_APP" "$INSTALLED_APP"; then
  if [[ -d "$PREVIOUS_APP" ]]; then mv "$PREVIOUS_APP" "$INSTALLED_APP"; fi
  echo "Installation failed; the previous application was restored." >&2
  exit 1
fi
if ! codesign --verify --deep --strict "$INSTALLED_APP"; then
  rm -rf "$INSTALLED_APP"
  if [[ -d "$PREVIOUS_APP" ]]; then mv "$PREVIOUS_APP" "$INSTALLED_APP"; fi
  echo "Installed bundle verification failed; the previous application was restored." >&2
  exit 1
fi

echo "Installed: $INSTALLED_APP"
if (( RELAUNCH )); then
  open "$INSTALLED_APP"
fi
