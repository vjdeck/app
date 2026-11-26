#!/bin/bash
set -euo pipefail

usage() {
  echo 'Usage: scripts/build-dmg.sh [--derived-data PATH] [--app PATH] [--output PATH]'
  echo 'Builds and signs Release, or signs and packages the supplied app without rebuilding.'
}

SCHEME="VJDeck"
DMG_OUT="$(pwd)/VJDeck.dmg"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="$repo_root/build/DerivedData"
APP_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --derived-data|--app|--output)
      [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 64; }
      case "$1" in
        --derived-data) derived_data="$2" ;;
        --app) APP_PATH="$2" ;;
        --output) DMG_OUT="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

if [[ -z "$APP_PATH" ]]; then
  echo "Building $SCHEME (Release)..."
  xcodebuild -project "$repo_root/VJDeck.xcodeproj" -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived_data" build -quiet
  APP_PATH="$derived_data/Build/Products/Release/$SCHEME.app"
fi

if [ ! -d "$APP_PATH" ]; then
  echo "Error: $APP_PATH not found"
  exit 1
fi

echo "Re-signing bundle (ad-hoc)..."
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

echo "Packaging DMG..."
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$(dirname "$DMG_OUT")"
ditto "$APP_PATH" "$TEMP_DIR/$SCHEME.app"
ln -s /Applications "$TEMP_DIR/Applications"
hdiutil create -volname "$SCHEME" -srcfolder "$TEMP_DIR" -ov -format UDZO "$DMG_OUT" -quiet

SIZE=$(du -h "$DMG_OUT" | cut -f1 | xargs)
echo "Done: $DMG_OUT ($SIZE)"
