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
DERIVED="$REPO_ROOT/build"
APP="$DERIVED/Build/Products/$CONFIG/MeterBar.app"
INSTALLED_APP="/Applications/MeterBar.app"

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

# If a copy is already installed in /Applications, mirror the fresh build over
# it so chronod loads the new widget extension. Without this, chronod prefers
# the /Applications copy when scanning, and stale widget bundles ship even
# though the menu bar app we launch is freshly built.
LAUNCH_APP="$APP"
if [ -d "$INSTALLED_APP" ]; then
    echo "▸ Mirroring build to $INSTALLED_APP"
    rm -rf "$INSTALLED_APP"
    ditto "$APP" "$INSTALLED_APP"
    LAUNCH_APP="$INSTALLED_APP"
fi

echo "▸ Restarting widget daemons (chronod, NotificationCenter)"
killall chronod 2>/dev/null || true
killall NotificationCenter 2>/dev/null || true

echo "▸ Launching $LAUNCH_APP"
open "$LAUNCH_APP"

echo "✓ Done. Open Notification Center to see the refreshed widget."
echo "  Built:    $APP"
if [ "$LAUNCH_APP" != "$APP" ]; then
    echo "  Launched: $LAUNCH_APP"
fi
