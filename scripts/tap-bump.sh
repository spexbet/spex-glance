#!/bin/sh
# Bump the spex-glance cask in spexbet/homebrew-tap to <version>, with <dmg>'s sha256.
#
#   scripts/tap-bump.sh 0.4.0 dist/SpexGlance-0.4.0.dmg
#   TAP_DRY_RUN=1 scripts/tap-bump.sh 0.4.0 some.dmg     everything except the push
#
# Called by release.sh --publish. Kept as its own script so it can be dry-run on its own.
# Identity, belt and suspenders: the temp clone lives under ~/Developer/spex (override with
# SPEX_TAP_PARENT) so it picks up the Spex git identity and commit hook there; the commit also
# sets that identity explicitly; and nothing is pushed unless the new commit's author AND
# committer are the Spex noreply address. Any failure exits non-zero with a "tap-bump:" reason.
set -eu

VERSION="${1:?usage: tap-bump.sh <version> <dmg>}"
DMG="${2:?usage: tap-bump.sh <version> <dmg>}"
SPEX_NAME="Spex"
SPEX_EMAIL="336294245+spex-bet@users.noreply.github.com"
TAP_REPO="https://github.com/spexbet/homebrew-tap.git"
TAP_PARENT="${SPEX_TAP_PARENT:-$HOME/Developer/spex}"

die() { echo "tap-bump: $*" >&2; exit 1; }

[ -f "$DMG" ] || die "no dmg at $DMG"
[ -d "$TAP_PARENT" ] || die "$TAP_PARENT does not exist (set SPEX_TAP_PARENT)"
TAP_DIR="$(mktemp -d "$TAP_PARENT/.tap-XXXXXX")" || die "could not create a temp clone under $TAP_PARENT"
trap 'rm -rf "$TAP_DIR"' EXIT
trap 'exit 130' INT TERM

git clone -q --depth 1 "$TAP_REPO" "$TAP_DIR" || die "could not clone $TAP_REPO"
CASK="$TAP_DIR/Casks/spex-glance.rb"
[ -f "$CASK" ] || die "Casks/spex-glance.rb not found in the tap"

SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
grep -q "^  version \"$VERSION\"\$" "$CASK" && grep -q "^  sha256 \"$SHA\"\$" "$CASK" \
  || die "cask edit did not apply (version/sha256 lines not found)"
if git -C "$TAP_DIR" diff --quiet; then
  echo "Homebrew tap already at spex-glance $VERSION ($SHA); nothing to push."
  exit 0
fi

git -C "$TAP_DIR" -c user.name="$SPEX_NAME" -c user.email="$SPEX_EMAIL" commit -qam "spex-glance $VERSION" \
  || die "commit failed"
AUTHOR="$(git -C "$TAP_DIR" log -1 --format=%ae)"
COMMITTER="$(git -C "$TAP_DIR" log -1 --format=%ce)"
[ "$AUTHOR" = "$SPEX_EMAIL" ] && [ "$COMMITTER" = "$SPEX_EMAIL" ] \
  || die "commit author <$AUTHOR> / committer <$COMMITTER> is not <$SPEX_EMAIL>; tap push aborted"
echo "Tap commit: $(git -C "$TAP_DIR" log -1 --format='%h "%s" author %an <%ae>, committer %cn <%ce>')"

if [ "${TAP_DRY_RUN:-}" = "1" ]; then
  echo "TAP_DRY_RUN=1: push skipped."
  exit 0
fi
git -C "$TAP_DIR" push -q || die "push to $TAP_REPO failed"
echo "Homebrew tap updated: spex-glance $VERSION."
