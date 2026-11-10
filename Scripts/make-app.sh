#!/bin/bash
# Assemble build/Eider.app from the SwiftPM products, by hand (no Xcode project).
#
# Usage: Scripts/make-app.sh [--configuration release|debug] [--output DIR]
#
# Layout (the CLI lives under Resources/cli because Contents/MacOS cannot hold
# both "Eider" and "eider" on a case-insensitive volume; the CLI finds shims at
# ../share/eider/shims beside its real path):
#   Contents/MacOS/Eider
#   Contents/Resources/AppIcon.icns
#   Contents/Resources/shims/*.dylib
#   Contents/Resources/cli/bin/eider
#   Contents/Resources/cli/share/eider/shims -> ../../../shims
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION=release
OUTPUT="$ROOT/build"

usage() {
  echo "usage: $0 [--configuration release|debug] [--output DIR]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --configuration) [ $# -ge 2 ] || usage; CONFIGURATION="$2"; shift 2 ;;
    --output) [ $# -ge 2 ] || usage; OUTPUT="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case "$CONFIGURATION" in release | debug) ;; *) usage ;; esac

cd "$ROOT"

VERSION="$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' Sources/EiderKit/Support/EiderVersion.swift)"
[ -n "$VERSION" ] || { echo "error: cannot read version from EiderVersion.swift" >&2; exit 1; }

# Shims are produced by another script (developer machine or CI); the build
# directory they land in is fixed by that script, not by --output.
SHIMS_SRC="$ROOT/build/shims"
if [ -x "$ROOT/Scripts/build-shims.sh" ]; then
  "$ROOT/Scripts/build-shims.sh"
fi

swift build -c "$CONFIGURATION"
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

APP="$OUTPUT/Eider.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/shims" \
  "$APP/Contents/Resources/cli/bin" "$APP/Contents/Resources/cli/share/eider"

cp "$BIN_DIR/EiderApp" "$APP/Contents/MacOS/Eider"
cp "$BIN_DIR/eider" "$APP/Contents/Resources/cli/bin/eider"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
sed "s/@VERSION@/$VERSION/g" "$ROOT/Resources/Info.plist.template" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The shims directory always exists so the CLI's relative symlink resolves
# (a dangling symlink would also break the bundle's signature seal).
SHIM_COUNT=0
if [ -d "$SHIMS_SRC" ]; then
  for f in "$SHIMS_SRC"/*.dylib; do
    [ -e "$f" ] || continue
    cp "$f" "$APP/Contents/Resources/shims/"
    SHIM_COUNT=$((SHIM_COUNT + 1))
  done
fi
if [ "$SHIM_COUNT" -eq 0 ]; then
  echo "warning: no shims found in $SHIMS_SRC; this bundle cannot install apps until Scripts/build-shims.sh has run" >&2
fi
ln -s ../../../shims "$APP/Contents/Resources/cli/share/eider/shims"

# Ad hoc signing, inner code first, then the bundle.
for f in "$APP"/Contents/Resources/shims/*.dylib; do
  [ -e "$f" ] || continue
  codesign --force --sign - --timestamp=none "$f"
done
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/cli/bin/eider"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "built $APP (version $VERSION, $CONFIGURATION, $SHIM_COUNT shim(s))"
