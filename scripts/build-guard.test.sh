#!/bin/sh
# Tests for scripts/build-guard.sh. No network: the "bridge" URL points at a local fixture via
# file://. Run: scripts/build-guard.test.sh   (exit 0 = all pass).
set -eu
cd "$(dirname "$0")/.."
GUARD="scripts/build-guard.sh"

pass=0; fail=0
check() { # description expected_rc actual_rc
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "ok   - $1"
  else fail=$((fail + 1)); echo "FAIL - $1 (expected rc $2, got $3)"; fi
}
run() { # build  -> sets rc; APPCAST/BRIDGE_FILE come from the caller's env
  rc=0; "$GUARD" "$1" >/dev/null 2>&1 || rc=$?; echo "$rc"
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Local appcast: highest build 40. Bridge appcast: highest build 47.
printf '<rss><channel><title>Spex Glance</title>\n<item><sparkle:version>40</sparkle:version></item>\n<item><sparkle:version>31</sparkle:version></item>\n</channel></rss>\n' > "$TMP/appcast.xml"
printf '<rss><channel><title>Spex Glance</title>\n<item><sparkle:version>47</sparkle:version></item>\n</channel></rss>\n' > "$TMP/bridge-appcast.xml"
MISSING="$TMP/no-such-bridge-file"                 # absent on purpose
printf 'file://%s/bridge-appcast.xml\n' "$TMP" > "$TMP/bridgeurl"

echo "# bridge ABSENT -> old-feed check skipped, only local appcast (max 40) considered"
check "absent bridge: build 41 > local 40 passes"            0 "$(APPCAST="$TMP/appcast.xml" BRIDGE_FILE="$MISSING" run 41)"
check "absent bridge: build 40 == local 40 fails"            1 "$(APPCAST="$TMP/appcast.xml" BRIDGE_FILE="$MISSING" run 40)"

echo "# bridge PRESENT (max 47 via file://) -> old feed IS consulted"
# Same build 41 that passed above must now FAIL — proves absence/presence toggles the old-feed check.
check "present bridge: build 41 <= bridge 47 fails"          1 "$(APPCAST="$TMP/appcast.xml" BRIDGE_FILE="$TMP/bridgeurl" run 41)"
check "present bridge: build 48 > bridge 47 passes"          0 "$(APPCAST="$TMP/appcast.xml" BRIDGE_FILE="$TMP/bridgeurl" run 48)"

echo "# absent bridge is clean even when a would-be-higher bridge exists but file is gone"
check "absent bridge: build 41 passes though bridge feed=47" 0 "$(APPCAST="$TMP/appcast.xml" BRIDGE_FILE="$MISSING" run 41)"

echo "----"; echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
