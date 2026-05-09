#!/usr/bin/env bash
# Quit MeterBar, rebuild it (signed Debug by default), restart the macOS widget
# daemons so the new widget bundle is picked up immediately, then relaunch.
#
# Usage:
#   scripts/rebuild-and-reload.sh                # Debug
#   CONFIG=Release scripts/rebuild-and-reload.sh # Release
#
# Assumes:
# - You're signed into Xcode with an Apple ID that has a valid Apple Development
#   certificate for the team configured in MeterBar.xcodeproj.
# - You're running it from anywhere; the script resolves paths relative to its
#   own location.

set -euo pipefail

CONFIG="${CONFIG:-Debug}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$REPO_ROOT/MeterBar.xcodeproj"
DERIVED="$REPO_ROOT/build-signed"
APP="$DERIVED/Build/Products/$CONFIG/MeterBar.app"

echo "▸ Quitting any running MeterBar instance"
osascript -e 'tell application "MeterBar" to quit' 2>/dev/null || true
sleep 1
pkill -f "MeterBar.app/Contents/MacOS/MeterBar" 2>/dev/null || true

echo "▸ Building $CONFIG configuration with auto-provisioning"
xcodebuild -project "$PROJECT" \
  -scheme MeterBar -configuration "$CONFIG" -destination 'platform=macOS' \
  -allowProvisioningUpdates \
  -derivedDataPath "$DERIVED" \
  build >/dev/null

echo "▸ Restarting widget daemons (chronod, NotificationCenter)"
killall chronod 2>/dev/null || true
killall NotificationCenter 2>/dev/null || true

echo "▸ Launching $APP"
open "$APP"

echo "✓ Done. Open Notification Center to see the refreshed widget."
