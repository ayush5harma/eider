#!/usr/bin/env bash
# Builds IDeviceFFI.xcframework: Native/IDeviceFFI (Eider's small C API over idevice,
# jkcoxson/idevice, MIT) as static libraries for aarch64-apple-ios, aarch64-apple-ios-sim
# and aarch64-apple-darwin (the Mac runs the EiderPairing tests), then a zip of it and the
# zip's SwiftPM checksum for Package.swift's binaryTarget.
#
#   Scripts/build-idevice.sh
#
#   OUT           Output directory (default build/idevice, ignored by git).
#   CARGO_TARGET_DIR  Cargo's build directory (default ~/.cache/eider-dev/idevice-target,
#                 outside the repository; about 1 GB for the three targets, measured
#                 2026-11-28). KEEP_TARGET=1 keeps it; otherwise it is deleted at the end.
#   RUST_TOOLCHAIN    rustup toolchain (default stable; 1.100.1 on 2026-11-28).
#
# Needs rustup with the three targets. The nix rustc has no iOS standard library, so without
# rustup on PATH the script re-runs itself under `nix shell nixpkgs#rustup`.
#
# Publishing is separate and by hand (the zip is a release asset, not committed):
#   gh release create idevice-<short commit> --prerelease \
#     build/idevice/IDeviceFFI.xcframework.zip build/idevice/LICENSE-idevice.txt
# then set the url and checksum in Package.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE="$ROOT/Native/IDeviceFFI"
OUT="${OUT:-$ROOT/build/idevice}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/eider-dev/idevice-target}"
TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"
# Must match the rev in Native/IDeviceFFI/Cargo.toml.
IDEVICE_COMMIT="c8fff6d7fb2690eaeb591ce510754effa7b1e19b"
TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)

if ! command -v rustup >/dev/null 2>&1; then
  command -v nix >/dev/null 2>&1 || { echo "error: needs rustup (or nix to provide it)" >&2; exit 1; }
  exec nix shell nixpkgs#rustup -c bash "$0" "$@"
fi

grep -q "rev = \"$IDEVICE_COMMIT\"" "$CRATE/Cargo.toml" || {
  echo "error: Native/IDeviceFFI/Cargo.toml does not pin idevice $IDEVICE_COMMIT" >&2
  exit 1
}

rustup toolchain install "$TOOLCHAIN" --profile minimal $(printf -- '--target %s ' "${TARGETS[@]}") >/dev/null
echo "rustc: $(rustup run "$TOOLCHAIN" rustc --version)"

# The same minimums as Package.swift, so the linker does not warn about newer objects.
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0

for target in "${TARGETS[@]}"; do
  echo "building $target"
  (cd "$CRATE" && rustup run "$TOOLCHAIN" cargo build --locked --release --target "$target")
done

rm -rf "$OUT"
mkdir -p "$OUT/headers"
cp "$CRATE/include/eider_idevice.h" "$CRATE/include/module.modulemap" "$OUT/headers/"

xcframework_args=()
for target in "${TARGETS[@]}"; do
  mkdir -p "$OUT/$target"
  lib="$OUT/$target/libeider_idevice.a"
  cp "$CARGO_TARGET_DIR/$target/release/libeider_idevice.a" "$lib"
  # -S drops debug symbols, -x local symbols; the exported C API stays.
  xcrun strip -S -x "$lib" 2>/dev/null
  xcframework_args+=(-library "$lib" -headers "$OUT/headers")
done

xcodebuild -create-xcframework "${xcframework_args[@]}" -output "$OUT/IDeviceFFI.xcframework" >/dev/null

# idevice's licence travels with the binary, inside the xcframework and beside the zip.
idevice_manifest="$(cd "$CRATE" && rustup run "$TOOLCHAIN" cargo metadata --format-version 1 --locked \
  | python3 -I -c 'import json,sys; print(next(p["manifest_path"] for p in json.load(sys.stdin)["packages"] if p["name"] == "idevice"))')"
idevice_license="$(dirname "$(dirname "$idevice_manifest")")/LICENSE.txt"
[ -f "$idevice_license" ] || { echo "error: idevice LICENSE.txt not found at $idevice_license" >&2; exit 1; }
cp "$idevice_license" "$OUT/LICENSE-idevice.txt"
cp "$idevice_license" "$OUT/IDeviceFFI.xcframework/LICENSE-idevice.txt"

(cd "$OUT" && rm -f IDeviceFFI.xcframework.zip && ditto -c -k --keepParent IDeviceFFI.xcframework IDeviceFFI.xcframework.zip)
checksum="$(swift package compute-checksum "$OUT/IDeviceFFI.xcframework.zip")"

echo
echo "idevice $IDEVICE_COMMIT"
for target in "${TARGETS[@]}"; do
  printf '%-24s %s bytes (stripped)\n' "$target" "$(stat -f %z "$OUT/$target/libeider_idevice.a")"
done
printf '%-24s %s bytes\n' "IDeviceFFI.xcframework.zip" "$(stat -f %z "$OUT/IDeviceFFI.xcframework.zip")"
echo "checksum $checksum"

if [ "${KEEP_TARGET:-0}" != 1 ]; then
  rm -rf "$CARGO_TARGET_DIR"
fi
