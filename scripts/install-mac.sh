#!/bin/sh
# Release build → /Applications/Spex Glance.app → relaunch. Run after scripts/gen.sh.
# The installed copy is only replaced after a successful build.
set -e
cd "$(dirname "$0")/.."
# xcodebuild needs full Xcode; use it even when xcode-select points at the Command Line Tools.
if [ -z "$DEVELOPER_DIR" ] && [ -d /Applications/Xcode.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
LOG="$(mktemp -t spexglance-build)"
if ! xcodebuild -project SpexGlance.xcodeproj -scheme SpexGlance -destination 'platform=macOS' \
     -configuration Release -allowProvisioningUpdates build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -20
  echo "BUILD FAILED — installed app left untouched. Full log: $LOG"
  exit 1
fi
PRODUCTS="$(xcodebuild -project SpexGlance.xcodeproj -scheme SpexGlance -destination 'platform=macOS' \
  -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR =/{print $3}')"
if [ -z "$PRODUCTS" ] || [ ! -d "$PRODUCTS/Spex Glance.app" ]; then
  echo "Built app not found — installed app left untouched."
  exit 1
fi
./scripts/check-icloud-env.sh "$PRODUCTS/Spex Glance.app" || { echo "Installed app left untouched."; exit 1; }
pkill -x "Spex Glance" 2>/dev/null || true
sleep 1
rm -rf "/Applications/Spex Glance.app"
ditto "$PRODUCTS/Spex Glance.app" "/Applications/Spex Glance.app"
open "/Applications/Spex Glance.app"
echo "BUILD SUCCEEDED — installed /Applications/Spex Glance.app"
