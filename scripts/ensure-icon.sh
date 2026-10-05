#!/bin/sh
# Renders the app icon set when it's missing or older than its sources (render-icon.swift, docs/logo/spex-mark.svg).
# Called by gen.sh and install-mac.sh, so a build never ships without an icon or with a stale one.
set -e
cd "$(dirname "$0")/.."
OUT=App/Assets.xcassets/AppIcon.appiconset/mac-512@2x.png
if [ ! -f "$OUT" ] || [ scripts/render-icon.swift -nt "$OUT" ] || [ docs/logo/spex-mark.svg -nt "$OUT" ]; then
  echo "Rendering app icon..."
  swift scripts/render-icon.swift >/dev/null
fi
[ -f "$OUT" ] || { echo "Icon render failed — no $OUT"; exit 1; }
