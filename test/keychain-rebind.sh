#!/usr/bin/env bash
# The keychain shim next to a tweak that hooks SecItem* by rewriting symbol
# pointers (test/rebind-hook.c, standing in for Watusi's libWatusiToolsSL):
# every call must come back, for the classes the shim passes through to the
# real keychain as much as for the ones it answers itself. Before the shim
# called the real keychain through its own pointers, a passthrough looped
# between the two hooks until the stack ran out (WhatsApp 26.42.77,
# 2026-11-11).
#
# Builds the shim, the hook library and a probe (test/keychain-rebind.c) for
# Mac Catalyst, as the installer builds the shim, and runs the probe with HOME
# in a scratch directory so the shim's store lands there. No app, no GUI.
#
# Usage: test/keychain-rebind.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W=$(mktemp -d "${TMPDIR:-/tmp}/ipa-rebind.XXXXXX")
PID=""
# The probe runs in the background: a Ctrl-C mid-wait must not leave it spinning.
trap '[ -z "$PID" ] || kill -9 "$PID" 2>/dev/null; rm -rf "$W"' EXIT
PASS=0; FAIL=0

ok()  { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

SDK=$(xcrun --sdk macosx --show-sdk-path) || { echo "no macOS SDK (xcode-select --install)"; exit 2; }
build() {
  xcrun clang -target arm64-apple-ios14.0-macabi -isysroot "$SDK" -O2 -Wall \
    -framework CoreFoundation -framework Security "$@" 2>"$W/clang.err" \
    || { echo "build failed:"; cat "$W/clang.err"; exit 2; }
}
build -dynamiclib -install_name @rpath/libipakeychain.dylib -o "$W/libipakeychain.dylib" "$HERE/../lib/ipa-keychain.c"
build -dynamiclib -install_name @rpath/librebindhook.dylib -o "$W/librebindhook.dylib" "$HERE/rebind-hook.c"
build -L"$W" -lipakeychain -lrebindhook -Wl,-rpath,"$W" -o "$W/probe" "$HERE/keychain-rebind.c"

mkdir -p "$W/home"
HOME="$W/home" CFFIXED_USER_HOME="$W/home" "$W/probe" >"$W/out" 2>&1 &
PID=$!
# A passthrough that tail-calls itself spins rather than overflowing (seen
# 2026-11-11 with a dlsym-based fix), so a hang is a loop too. The probe
# finishes in well under a second.
for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$PID" 2>/dev/null; then
  kill -9 "$PID" 2>/dev/null; echo "rebind-hook: probe still running after 10 s: a call never returned" >>"$W/out"
fi
wait "$PID"; STATUS=$?
sed 's/^/        /' "$W/out"

line() { grep -E "^$1 " "$W/out"; }
# "copy=-25300 add=0" -> the number after KEY=
field() { line "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
# A status the real keychain can answer, as opposed to one this test invented.
real_status() { local v; v=$(field passthrough "$1"); [ -n "$v" ] && [ "$v" != -4 ]; }   # -4 errSecUnimplemented: hook had no original

check "every call returned (no hook loop: exit $STATUS)" test "$STATUS" -eq 0
# The probe's four symbol pointers at least; the shim keeps none for these.
check "the hooks rewrote the probe's symbol pointers" \
  test "$(line hooks | sed -n 's/.*slots=\([0-9]*\).*/\1/p')" -ge 4 2>/dev/null
check "every call went through a hook" \
  test "$(line hooks | sed -n 's/.*calls=\([0-9]*\).*/\1/p')" -ge 8 2>/dev/null
for op in copy add update delete; do
  check "key class: SecItem $op reached the real keychain" real_status "$op"
done
# The real keychain refuses an add with no key in it; the shim would take it.
check "key class: the add was refused (not kept by the shim)" test "$(field passthrough add)" != 0
check "password class: the shim answered (miss, add, update, delete)" \
  test "$(line shim)" = "shim copy=-25300 add=0 update=0 delete=0"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
