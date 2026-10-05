#!/bin/sh
# Generates SpexGlance.xcodeproj. Reads your Apple Team ID from ./.team (untracked).
set -e
cd "$(dirname "$0")/.."
if [ ! -f .team ]; then
  printf 'Apple Team ID (10 chars, Xcode > Settings > Accounts): '
  read -r TEAM
  printf '%s\n' "$TEAM" > .team
fi
export DEVELOPMENT_TEAM="$(tr -d '[:space:]' < .team)"
# Sparkle EdDSA public key (safe to commit); created by scripts/release.sh setup. Empty = updater idle.
SPARKLE_PUBLIC_KEY=""
[ -f sparkle-public-key.txt ] && SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < sparkle-public-key.txt)"
export SPARKLE_PUBLIC_KEY
if [ ! -d App/Assets.xcassets/AppIcon.appiconset ] || [ -z "$(ls App/Assets.xcassets/AppIcon.appiconset/*.png 2>/dev/null)" ]; then
  echo "Rendering app icon..."
  swift scripts/render-icon.swift >/dev/null
fi
xcodegen generate
