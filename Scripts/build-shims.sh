#!/usr/bin/env bash
# Compile the shims the engine links into installed apps, once, on a machine
# with Xcode's command line tools (a developer machine or CI). The install
# path itself never compiles anything: it finds these through ShimLocator.
#
# Every shim is built for Mac Catalyst (arm64-apple-ios14.0-macabi) against the
# macOS SDK with the flags legacy/bin/ipa-install-on-mac used, so a Catalyst
# process can load them. Output: build/shims/*.dylib, install names
# @executable_path/Frameworks/<file>.
#
# Usage: Scripts/build-shims.sh [OUT_DIR]     (default: <repo>/build/shims)

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/Shims"
OUT="${1:-$ROOT/build/shims}"
SDK=$(xcrun --sdk macosx --show-sdk-path) || { echo "build-shims: no macOS SDK (install Xcode or the Command Line Tools)" >&2; exit 2; }

mkdir -p "$OUT"

# build FILE.dylib SOURCE [extra clang flags]
build() {
  local name="$1" source="$2"
  shift 2
  xcrun clang -target arm64-apple-ios14.0-macabi -isysroot "$SDK" ${1+"$@"} -dynamiclib \
    -install_name "@executable_path/Frameworks/$name" -o "$OUT/$name" "$SRC/$source"
  echo "built $OUT/$name"
}

build libipakeychain.dylib ipa-keychain.c -O2 -framework CoreFoundation -framework Security
build libipagles.dylib ipa-gles.c -O2
build libipagroups.dylib ipa-groups.m -O2 -fobjc-arc -framework Foundation
# The neutraliser's install name is rewritten per tweak to the tweak's own,
# which may be longer than this one: ask the linker for header room (the
# legacy script built it per tweak with the name already in place).
build libipaneutralised.dylib ipa-neutralised.c -Wl,-headerpad_max_install_names
