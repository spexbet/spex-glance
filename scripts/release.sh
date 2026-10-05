#!/bin/sh
# Spex Glance macOS release: archive → Developer ID export → notarize → staple → .dmg → Sparkle sign → appcast.
#
#   scripts/release.sh setup            one-time: Sparkle EdDSA keys + notary credentials
#   scripts/release.sh 0.4.0            build, notarize, package, sign; leaves dist/ ready
#   scripts/release.sh 0.4.0 --publish  also: git tag, GitHub Release, push appcast.xml
#
# Release notes: write docs/releases/<version>.md in plain English before running. They go into
# the Sparkle update dialog (appcast <description>) and the GitHub Release body. Missing file = abort.
#
# Needs: Xcode, xcodegen, gh (brew install gh), a "Developer ID Application" certificate in the
# login keychain (Xcode → Settings → Accounts → Manage Certificates), and `setup` run once.
set -eu
cd "$(dirname "$0")/.."

APP="Spex Glance"
SCHEME="SpexGlance"
REPO_URL="https://github.com/spexbet/spex-glance"
NOTARY_PROFILE="spex-notary"
SPARKLE_BIN="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/SpexGlance-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1 || true)"

if [ "${1:-}" = "setup" ]; then
  [ -n "$SPARKLE_BIN" ] || { echo "Build once in Xcode first so the Sparkle tools get downloaded."; exit 1; }
  if [ ! -f sparkle-public-key.txt ]; then
    # generate_keys stores the private key in the login Keychain and prints the public key.
    "$SPARKLE_BIN/generate_keys" | grep -Eo '[A-Za-z0-9+/=]{40,}' | head -1 > sparkle-public-key.txt
    echo "Public key written to sparkle-public-key.txt (commit it). Private key is in your Keychain."
    echo "Back the private key up NOW (losing it orphans every installed copy):"
    echo "  $SPARKLE_BIN/generate_keys -x ~/Desktop/spex-sparkle-private.key   → store in your password manager, then delete the file"
  fi
  printf 'Apple ID email: '; read -r APPLE_ID
  TEAM="$(tr -d '[:space:]' < .team)"
  echo "Create an app-specific password at https://account.apple.com → Sign-In and Security → App-Specific Passwords."
  xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id "$APPLE_ID" --team-id "$TEAM"
  echo "Done. Run scripts/gen.sh so the public key lands in Info.plist."
  exit 0
fi

VERSION="${1:?usage: release.sh <version> [--publish]}"
PUBLISH="${2:-}"
# Build number (CFBundleVersion / sparkle:version) comes from the committed BUILD_NUMBER file,
# NOT the git commit count (which reset at the clean-copy migration). It must increase every release.
[ -f BUILD_NUMBER ] || { echo "BUILD_NUMBER file missing."; exit 1; }
BUILD="$(tr -d '[:space:]' < BUILD_NUMBER)"
case "$BUILD" in ''|*[!0-9]*) echo "BUILD_NUMBER must be a positive integer (got '$BUILD')."; exit 1;; esac

# Guard: BUILD must exceed every already-published build, or Sparkle won't offer the update.
# Check this repo's appcast and — while the update bridge exists — the old repo's appcast
# (URL in the untracked .bridge-appcast-url, which keeps the old handle out of this public repo).
max_ver() { grep -oE '<sparkle:version>[0-9]+' 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1; }
GMAX="$([ -f appcast.xml ] && max_ver < appcast.xml)"; GMAX="${GMAX:-0}"
if [ -f .bridge-appcast-url ]; then
  BURL="$(tr -d '[:space:]' < .bridge-appcast-url)"
  OMAX="$(curl -fsSL "$BURL" 2>/dev/null | max_ver)"; OMAX="${OMAX:-0}"
  [ "$OMAX" -gt "$GMAX" ] && GMAX="$OMAX"
fi
if [ "$BUILD" -le "$GMAX" ]; then
  echo "Refusing to build: BUILD_NUMBER ($BUILD) must be greater than the highest published build ($GMAX)."
  echo "Bump BUILD_NUMBER and retry."
  exit 1
fi
echo "Build number: $BUILD (highest already published: $GMAX)"

DIST="dist"; rm -rf "$DIST"; mkdir -p "$DIST"

NOTES_MD="docs/releases/$VERSION.md"
[ -f "$NOTES_MD" ] || { echo "No release notes at $NOTES_MD — write them first (plain English, what changed for the user)."; exit 1; }
# Markdown subset → HTML for the Sparkle dialog: '# ' / '## ' headings, '- ' bullets, blank-line paragraphs.
md_to_html() {
  awk '
    function flush() { if (inp) { print "</p>"; inp = 0 } if (inl) { print "</ul>"; inl = 0 } }
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
    /^## /  { flush(); print "<h3>" esc(substr($0, 4)) "</h3>"; next }
    /^# /   { flush(); print "<h2>" esc(substr($0, 3)) "</h2>"; next }
    /^- /   { if (inp) { print "</p>"; inp = 0 } if (!inl) { print "<ul>"; inl = 1 } print "<li>" esc(substr($0, 3)) "</li>"; next }
    /^[[:space:]]*$/ { flush(); next }
    { if (inl) { print "</ul>"; inl = 0 } if (!inp) { print "<p>"; inp = 1 } print esc($0) }
    END { flush() }
  ' "$1"
}
NOTES_HTML="$(md_to_html "$NOTES_MD")"

sed -i '' "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" project.yml
scripts/gen.sh

echo "== archive"
xcodebuild -project SpexGlance.xcodeproj -scheme "$SCHEME" -destination 'generic/platform=macOS' \
  -configuration Release -archivePath "$DIST/$APP.xcarchive" archive | grep -E "error:|ARCHIVE" || true

echo "== export (Developer ID)"
TEAM="$(tr -d '[:space:]' < .team)"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict>' \
  '  <key>method</key><string>developer-id</string>' \
  "  <key>teamID</key><string>$TEAM</string>" \
  '  <key>signingStyle</key><string>automatic</string>' \
  '</dict></plist>' > "$DIST/export.plist"
xcodebuild -exportArchive -archivePath "$DIST/$APP.xcarchive" -exportOptionsPlist "$DIST/export.plist" \
  -exportPath "$DIST/export" -allowProvisioningUpdates | grep -E "error:|EXPORT" || true

echo "== notarize app"
ditto -c -k --keepParent "$DIST/export/$APP.app" "$DIST/notarize.zip"
xcrun notarytool submit "$DIST/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DIST/export/$APP.app"

echo "== dmg"
DMG="$DIST/SpexGlance-$VERSION.dmg"
STAGE="$DIST/dmg"; mkdir -p "$STAGE"
cp -R "$DIST/export/$APP.app" "$STAGE/"
cp LICENSE "$STAGE/LICENSE.txt"          # MIT text travels with the binary
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --sign "Developer ID Application" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait >/dev/null
xcrun stapler staple "$DMG"

echo "== sparkle signature + appcast"
SIG="$("$SPARKLE_BIN/sign_update" "$DMG")"     # → sparkle:edSignature="..." length="..."
DL="$REPO_URL/releases/download/v$VERSION/SpexGlance-$VERSION.dmg"
NOTES="$REPO_URL/releases/tag/v$VERSION"
DATE="$(date -R)"
[ -f appcast.xml ] || printf '%s\n' \
  '<?xml version="1.0" encoding="utf-8"?>' \
  '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">' \
  '  <channel>' \
  '    <title>Spex Glance</title>' \
  '  </channel>' \
  '</rss>' > appcast.xml
ITEM="    <item>
      <title>Spex Glance $VERSION</title>
      <link>$NOTES</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <pubDate>$DATE</pubDate>
      <description><![CDATA[
$NOTES_HTML
      ]]></description>
      <enclosure url=\"$DL\" $SIG type=\"application/octet-stream\" />
    </item>"
# newest first, right after the channel title
ITEM="$ITEM" perl -0pi -e 's|(<title>Spex Glance</title>\n)|$1$ENV{ITEM}\n|' appcast.xml

echo "Built $DMG"
if [ "$PUBLISH" = "--publish" ]; then
  echo "$((BUILD + 1))" > BUILD_NUMBER   # reserve the next build; committed with this release
  git add project.yml appcast.xml "$NOTES_MD" BUILD_NUMBER
  git commit -m "Release $VERSION (build $BUILD)" || true
  git tag -a "v$VERSION" -m "Spex Glance $VERSION"
  git push && git push --tags
  gh release create "v$VERSION" "$DMG" --title "Spex Glance $VERSION" --notes-file "$NOTES_MD"
  # Tell spex.bet to redeploy so the site shows the new version (its workflow reads the latest release).
  gh api repos/spexbet/spex.bet/dispatches -f event_type=release \
    && echo "spex.bet redeploy requested." \
    || echo "WARN: could not ping spex.bet (site updates on its daily run instead)."
  # Homebrew: bump the cask in spexbet/homebrew-tap so `brew install --cask spex-glance` gets this version.
  TAP_DIR="$(mktemp -d)"
  if git clone -q --depth 1 https://github.com/spexbet/homebrew-tap.git "$TAP_DIR"; then
    SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
    sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP_DIR/Casks/spex-glance.rb"
    git -C "$TAP_DIR" commit -qam "spex-glance $VERSION" \
      && git -C "$TAP_DIR" push -q \
      && echo "Homebrew tap updated: spex-glance $VERSION." \
      || echo "WARN: Homebrew tap not updated; bump Casks/spex-glance.rb in spexbet/homebrew-tap by hand."
  else
    echo "WARN: could not clone spexbet/homebrew-tap; bump the cask by hand."
  fi
  rm -rf "$TAP_DIR"
  echo "Published. Sparkle clients see $VERSION on their next check (daily, or Check for Updates…)."
fi
