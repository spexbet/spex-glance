#!/bin/sh
# Release build → /Applications/Spex Glance.app → relaunch. Run after scripts/gen.sh.
set -e
cd "$(dirname "$0")/.."
xcodebuild -project SpexGlance.xcodeproj -scheme SpexGlance -destination 'platform=macOS' \
  -configuration Release -allowProvisioningUpdates build | grep -E "error:|BUILD" || true
PRODUCTS="$(xcodebuild -project SpexGlance.xcodeproj -scheme SpexGlance -destination 'platform=macOS' \
  -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')"
pkill -x "Spex Glance" 2>/dev/null || true
sleep 1
rm -rf "/Applications/Spex Glance.app"
ditto "$PRODUCTS/Spex Glance.app" "/Applications/Spex Glance.app"
open "/Applications/Spex Glance.app"
echo "Installed /Applications/Spex Glance.app"
