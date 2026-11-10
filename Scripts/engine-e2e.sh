#!/usr/bin/env bash
# End-to-end check of the Swift install engine, judged by effect: builds the
# shims and the probe IPA (legacy/test/probe.m) with Xcode's tools, then runs
# `eider install` the way a stock Mac would: DEVELOPER_DIR=/var/empty and a
# bare PATH make every developer-tool stub (xcrun, clang, lipo, vtool, ...)
# fail, so an install that succeeds called none of them. The probe is then
# launched and reports what UIKit and the C library gave it, and only lines
# logged after each launch's own marker count.
#
# Covers what legacy/test/e2e.sh asserts for its non-PlayTools installs:
#   default     shipped idiom, the binary's own SDK kept, sandboxed with no
#               extra sandbox exceptions, embedded framework loads, GL lookups
#               answer OpenGL ES, an app-group folder is writable in the
#               container, a keychain item survives a relaunch
#   mac idiom   --mac-idiom runs the app in the Mac idiom, and a prebuilt
#               --dylib is linked and loads
# plus: the registry holds the app, and uninstall removes it.
#
# Everything installs into a temporary --dest and a temporary EIDER_HOME,
# never /Applications. Left behind: nothing this script can remove; the
# probe's container is emptied (its root belongs to containermanagerd) and
# the copies the installer trashed are deleted from ~/.Trash again.
#
# Usage: Scripts/engine-e2e.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BID=local.ipa-install-on-mac.probe
CONTAINER="$HOME/Library/Containers/$BID/Data"
LOG="$CONTAINER/Documents/probe.log"
# Physical path: pkill/pgrep match the /private/var form of a $TMPDIR path.
W=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/eider-e2e.XXXXXX")" && pwd -P)
APP="$W/apps/IPA Probe.app"
PASS=0; FAIL=0; SKIP=0; MARK=""

ok()   { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP  $*"; SKIP=$((SKIP + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

# ~/.Trash entries that exist before the run, so only the installer's are removed.
TRASH_BEFORE="$W/trash.before"
ls -1 "$HOME/.Trash" > "$TRASH_BEFORE" 2>/dev/null || { : > "$TRASH_BEFORE"; echo "note: ~/.Trash is not listable from here; trashed probe copies will stay"; }

quit_probe() {
  pkill -f "$APP/Probe" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$APP/Probe" >/dev/null || return 0
    sleep 0.3
  done
}
empty_container() {
  [ -d "$CONTAINER" ] || return 0
  find "$CONTAINER" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
  rmdir "$CONTAINER" "$(dirname "$CONTAINER")" 2>/dev/null
  return 0
}
clean_trash() {
  [ -s "$TRASH_BEFORE" ] || [ -d "$HOME/.Trash" ] || return 0
  ls -1 "$HOME/.Trash" 2>/dev/null | while IFS= read -r name; do
    case "$name" in "IPA Probe"*|"$BID"*) grep -Fx -- "$name" "$TRASH_BEFORE" >/dev/null || rm -rf "$HOME/.Trash/$name" ;; esac
  done
  return 0
}
cleanup() { quit_probe; empty_container; clean_trash; rm -rf "$W"; }
trap cleanup EXIT

# ── Build (with developer tools: this part is the test rig, not the product) ──
echo "Building eider, the shims and the probe ..."
(cd "$ROOT" && swift build >"$W/build.log" 2>&1) || { cat "$W/build.log"; echo "swift build failed"; exit 2; }
BIN="$(cd "$ROOT" && swift build --show-bin-path)/eider"
"$ROOT/Scripts/build-shims.sh" >"$W/shims.log" 2>&1 || { cat "$W/shims.log"; echo "build-shims failed"; exit 2; }
"$ROOT/legacy/test/make-probe-ipa.sh" "$W/probe.ipa" >/dev/null || { echo "could not build the probe (needs Xcode's iOS SDK)"; exit 2; }
xcrun clang -target arm64-apple-ios14.0-macabi -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -dynamiclib \
  -install_name @rpath/extra.dylib -o "$W/extra.dylib" "$ROOT/legacy/test/extra.c" || { echo "could not build the extra dylib"; exit 2; }
unzip -q -o "$W/probe.ipa" 'Payload/Probe.app/Probe' -d "$W/x"
SDK=$(otool -l "$W/x/Payload/Probe.app/Probe" | awk '/LC_BUILD_VERSION/ { c = 1 } c && $1 == "sdk" && !d { print $2; d = 1 }')

# ── The product, run as on a Mac with no developer tools ────────────────────
eider() {
  env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    DEVELOPER_DIR=/var/empty EIDER_HOME="$W/home" EIDER_SHIMS_DIR="$ROOT/build/shims" "$BIN" "$@"
}
install_probe() {
  eider install "$W/probe.ipa" --dest "$W/apps" --json "$@" >"$W/out" 2>"$W/err" \
    || { bad "install $*: $(tail -n 3 "$W/out") $(cat "$W/err")"; exit 1; }
}

entitlements() { codesign -d --entitlements - "$APP" 2>/dev/null; }
has_entitlement() { entitlements | grep -F "$1" >/dev/null; }
lacks_entitlement() {   # some entitlements must exist, or the check passes for the wrong reason
  local ents
  ents=$(entitlements)
  [ -n "$ents" ] && ! printf '%s\n' "$ents" | grep -F "$1" >/dev/null
}
links() { otool -L "$APP/Probe" 2>/dev/null | grep -F "$1" >/dev/null; }
stamped_sdk() { otool -l "$APP/Probe" | grep -A4 LC_BUILD_VERSION | grep -F "sdk $1" >/dev/null; }
catalyst() { vtool -show-build "$APP/Probe" 2>/dev/null | grep -F MACCATALYST >/dev/null; }
no_quarantine() { ! xattr -r "$APP" 2>/dev/null | grep -F com.apple.quarantine >/dev/null; }
registry_has() { grep -F "\"bundleID\" : \"$BID\"" "$W/home/library.json" >/dev/null 2>&1; }
registry_count() { grep -c '"bundleID"' "$W/home/library.json" 2>/dev/null; }

since() { awk -v m="$MARK" 'f; $0 == m { f = 1 }' "$LOG" 2>/dev/null; }
logged() { since | grep -E "$1" >/dev/null; }
launch() {
  quit_probe
  MARK="--- e2e $(date +%s).$RANDOM"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  echo "$MARK" >> "$LOG" || { echo "cannot write the probe's log ($LOG)"; exit 2; }
  # LaunchServices can refuse an open moments after the previous instance was
  # killed (-600), so a refused open is retried.
  local tries=0
  until open "$APP" 2>"$W/open.err"; do
    tries=$((tries + 1))
    [ "$tries" -lt 10 ] || { cat "$W/open.err"; return 1; }
    sleep 0.5
  done
  for _ in $(seq 1 40); do logged ' launch ' && return 0; sleep 0.25; done
  return 1
}

# ── default install ─────────────────────────────────────────────────────────
echo "default install (no developer tools: DEVELOPER_DIR=/var/empty, PATH=/usr/bin:/bin:/usr/sbin:/sbin)"
empty_container   # a first keychain write must look like a first write
install_probe
check "the install result is reported as JSON" grep -qF '"type":"result"' "$W/out"
check "the binary is Mac Catalyst" catalyst
check "the binary keeps its own SDK ($SDK)" stamped_sdk "$SDK"
check "sandboxed" has_entitlement app-sandbox
check "no sandbox exceptions beyond the base set" lacks_entitlement temporary-exception
check "OpenGL ES redirect linked (the probe links OpenGL ES)" links libipagles.dylib
check "keychain shim linked" links libipakeychain.dylib
check "app-group shim linked" links libipagroups.dylib
check "embedded.mobileprovision removed" test ! -e "$APP/embedded.mobileprovision"
check "bundle signature verifies" codesign --verify --strict "$APP"
check "no quarantine attribute left" no_quarantine
check "the registry holds the app" registry_has
if launch; then
  check "shipped idiom (iPad, 1)" logged ' launch idiom=1 '
  check "embedded framework loaded" logged 'probekit ok'
  check "GL lookup answers OpenGL ES, not desktop libGL" logged 'gl lookup=OpenGLES '
  check "keychain item stored (shim)" logged 'keychain miss=.* add=0 '
  check "app-group folder is in the container and writable" \
    logged 'group write=1 path=.*/Library/Containers/[^/]+/Data/Library/Group Containers/group\.ipa\.probe\.shared '
else
  bad "the probe did not launch"
fi
if launch; then
  check "keychain item read back after relaunch (shim)" logged 'keychain read=v-'
else
  bad "the probe did not relaunch"
fi

# ── mac idiom + extra dylib (replaces the first copy) ───────────────────────
echo "--mac-idiom and --dylib install"
quit_probe
install_probe --mac-idiom --dylib "$W/extra.dylib"
check "extra library linked" links libextra.dylib
check "the registry still holds exactly one entry for the app" test "$(registry_count)" = 1
if launch; then
  check "Mac idiom (5)" logged ' launch idiom=5 '
  check "the extra dylib was linked and loaded" logged 'extra dylib loaded'
else
  bad "the probe did not launch"
fi

# ── uninstall ───────────────────────────────────────────────────────────────
echo "uninstall"
quit_probe
if eider uninstall "$BID" >"$W/out" 2>"$W/err"; then ok "uninstall succeeded"; else bad "uninstall: $(cat "$W/err")"; fi
check "the app is gone from the destination" test ! -e "$APP"
check "the registry no longer holds the app" test "$(registry_count)" = 0
if eider uninstall "$BID" >/dev/null 2>&1; then bad "a second uninstall should fail"; else ok "a second uninstall fails: nothing to remove"; fi

echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
