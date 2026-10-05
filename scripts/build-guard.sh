#!/bin/sh
# Build-number guard for Spex Glance releases.
#
# Exits non-zero unless <build-number> is strictly greater than every already-published build —
# the highest <sparkle:version> in this repo's appcast AND, *while the update bridge exists*, in
# the old repo's appcast. Sparkle compares the build number (CFBundleVersion), so a release whose
# build isn't the new maximum would never be offered to installed users.
#
# The old-feed URL lives in the untracked, gitignored .bridge-appcast-url (keeps the old personal
# handle out of this public repo). When that file is ABSENT (i.e. after the bridge is retired),
# the old-feed check is skipped cleanly and only this repo's appcast is consulted.
#
# Usage: scripts/build-guard.sh <build-number>
# Overridable for tests: APPCAST (default appcast.xml), BRIDGE_FILE (default .bridge-appcast-url).
set -eu

BUILD="${1:?usage: build-guard.sh <build-number>}"
APPCAST="${APPCAST:-appcast.xml}"
BRIDGE_FILE="${BRIDGE_FILE:-.bridge-appcast-url}"

max_ver() { grep -oE '<sparkle:version>[0-9]+' 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1; }

GMAX="$([ -f "$APPCAST" ] && max_ver < "$APPCAST")"; GMAX="${GMAX:-0}"
if [ -f "$BRIDGE_FILE" ]; then
  BURL="$(tr -d '[:space:]' < "$BRIDGE_FILE")"
  OMAX="$(curl -fsSL "$BURL" 2>/dev/null | max_ver)"; OMAX="${OMAX:-0}"
  [ "$OMAX" -gt "$GMAX" ] && GMAX="$OMAX"
  SRC="appcast + bridge feed"
else
  SRC="appcast only (no bridge feed)"
fi

if [ "$BUILD" -le "$GMAX" ]; then
  echo "Refusing to build: BUILD_NUMBER ($BUILD) must be greater than the highest published build ($GMAX) [$SRC]." >&2
  echo "Bump BUILD_NUMBER and retry." >&2
  exit 1
fi
echo "Build number: $BUILD (highest already published: $GMAX) [$SRC]"
