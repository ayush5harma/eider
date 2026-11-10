#!/bin/bash
# Build the release artifacts for a version and update the Homebrew cask.
#
# Usage: Scripts/release.sh <version>
#
# Writes build/release/Eider-<version>.zip and
# build/release/eider-<version>-macos-arm64.tar.gz, prints their SHA-256
# values, rewrites the version and sha256 lines in Casks/eider.rb and prints
# (never runs) the gh command. It does not tag, push or publish.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[ $# -eq 1 ] || { echo "usage: $0 <version>" >&2; exit 2; }
VERSION="$1"

if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is not clean; commit or stash first" >&2
  exit 1
fi

SOURCE_VERSION="$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' Sources/EiderKit/Support/EiderVersion.swift)"
if [ "$VERSION" != "$SOURCE_VERSION" ]; then
  echo "error: $VERSION does not match EiderVersion.swift ($SOURCE_VERSION)" >&2
  exit 1
fi

"$ROOT/Scripts/make-app.sh" --configuration release --output "$ROOT/build"
APP="$ROOT/build/Eider.app"

RELEASE_DIR="$ROOT/build/release"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

ZIP="$RELEASE_DIR/Eider-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# The CLI archive holds bin/eider and share/eider/shims/ as a real directory
# (the app bundle's symlink is resolved here), so the CLI finds its shims
# beside its own path after extraction. COPYFILE_DISABLE keeps AppleDouble
# "._" files out of the tarball.
STAGE="$RELEASE_DIR/stage"
mkdir -p "$STAGE/bin" "$STAGE/share/eider/shims"
cp "$APP/Contents/Resources/cli/bin/eider" "$STAGE/bin/eider"
for f in "$APP"/Contents/Resources/shims/*.dylib; do
  [ -e "$f" ] || continue
  cp "$f" "$STAGE/share/eider/shims/"
done
TARBALL="$RELEASE_DIR/eider-$VERSION-macos-arm64.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$TARBALL" -C "$STAGE" bin share
rm -rf "$STAGE"

ZIP_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
TAR_SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"

CASK="$ROOT/Casks/eider.rb"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" \
  -e "s/^  sha256 \".*\"/  sha256 \"$ZIP_SHA\"/" "$CASK"

echo
echo "zip     $ZIP_SHA  $ZIP"
echo "tarball $TAR_SHA  $TARBALL"
echo "updated $CASK"
echo
echo "To publish (not run by this script):"
echo "  git tag v$VERSION && git push origin v$VERSION"
echo "  gh release create v$VERSION \"$ZIP\" \"$TARBALL\" --title \"Eider $VERSION\" --generate-notes"
