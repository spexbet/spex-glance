#!/bin/sh
# Fails unless the given Spex Glance.app is signed to use CloudKit's PRODUCTION database.
# Every Mac (home, work, release, beta) must share one Live Line history; a build on the
# Development database would start its own. Run by install-mac.sh and release.sh.
APP="${1:-/Applications/Spex Glance.app}"
TMP="$(mktemp -t spexglance-ent)"
codesign -d --entitlements - --xml "$APP" > "$TMP" 2>/dev/null
ENV="$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-container-environment" "$TMP" 2>/dev/null)"
rm -f "$TMP"
if [ "$ENV" != "Production" ]; then
  echo "iCLOUD CHECK FAILED: $APP uses CloudKit '${ENV:-default (Development for dev-signed builds)}', not Production."
  exit 1
fi
echo "iCloud check: Production database"
