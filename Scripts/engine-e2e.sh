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
#               extra sandbox exceptions, the IPA's application-groups entitlement
#               carried into the signature, embedded framework loads, GL lookups
#               answer OpenGL ES, an app-group folder is writable in the
#               container, a keychain item survives a relaunch, and after a
#               kill -9 a keychain item with a shared access group and the
#               app group's preferences (NSUserDefaults and the CFPreferences
#               C API, written on the group's first launch) are read back,
#               as are the group's preferences seen as a persistent domain, an
#               unsigned group's suite, a SQLite database and a coordinated
#               file in the group's folder, and a synchronizable keychain item
#               found with query flags that describe no item, then updated
#               and deleted by access group
#   mac idiom   --mac-idiom runs the app in the Mac idiom, and a prebuilt
#               --dylib is linked and loads
# plus: the registry holds the app, and uninstall removes it.
#
# Everything installs into a temporary --dest and a temporary EIDER_HOME,
# never /Applications. Left behind: nothing this script can remove; the
# probe's container is emptied (its root belongs to containermanagerd) and
# the copies the installer trashed are deleted from ~/.Trash again. The probe
# is signed with a fresh app group per run, because the group's first launch
# is the case under test and macOS keeps a group container after its app is
# gone; the run removes it again where macOS lets it.
#
# Usage: Scripts/engine-e2e.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BID=local.ipa-install-on-mac.probe
CONTAINER="$HOME/Library/Containers/$BID/Data"
LOG="$CONTAINER/Documents/probe.log"
GROUP="group.local.eider-e2e.$(date +%s)$RANDOM"
GROUP_CONTAINER="$HOME/Library/Group Containers/$GROUP"
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
kill_probe() {   # as a crash or Force Quit would: no chance to save anything
  pkill -KILL -f "$APP/Probe" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$APP/Probe" >/dev/null || return 0
    sleep 0.3
  done
}
remove_group_container() {
  [ -d "$GROUP_CONTAINER" ] || return 0
  rm -rf "$GROUP_CONTAINER" 2>/dev/null || echo "note: could not remove $GROUP_CONTAINER"
}
cleanup() { quit_probe; empty_container; remove_group_container; clean_trash; rm -rf "$W"; }
trap cleanup EXIT

# ── Build (with developer tools: this part is the test rig, not the product) ──
echo "Building eider, the shims and the probe ..."
(cd "$ROOT" && swift build >"$W/build.log" 2>&1) || { cat "$W/build.log"; echo "swift build failed"; exit 2; }
BIN="$(cd "$ROOT" && swift build --show-bin-path)/eider"
"$ROOT/Scripts/build-shims.sh" >"$W/shims.log" 2>&1 || { cat "$W/shims.log"; echo "build-shims failed"; exit 2; }
PROBE_APP_GROUP="$GROUP" "$ROOT/legacy/test/make-probe-ipa.sh" "$W/probe.ipa" >/dev/null || { echo "could not build the probe (needs Xcode's iOS SDK)"; exit 2; }
for mode in blank detached; do
  PROBE_APP_GROUP="$GROUP" PROBE_WINDOW=$mode "$ROOT/legacy/test/make-probe-ipa.sh" "$W/probe-$mode.ipa" >/dev/null \
    || { echo "could not build the $mode-window probe"; exit 2; }
done
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
check "the IPA's own app group is carried into the new signature" has_entitlement "$GROUP"
check "nothing else of the IPA's entitlements is carried (no application-identifier)" lacks_entitlement application-identifier
check "OpenGL ES redirect linked (the probe links OpenGL ES)" links libipagles.dylib
check "keychain shim linked" links libipakeychain.dylib
check "CallKit shim linked (the probe links CallKit)" links libipacallkit.dylib
check "camera shim linked (the probe links AVFoundation)" links libipacamera.dylib
check "app-group shim linked" links libipagroups.dylib
check "quirks shim linked (the probe has rows in the quirk table)" links libipaquirks.dylib
check "the probe's quirk rows are written into the bundle" grep -qF probeQuirkSwitch "$APP/EiderQuirks.plist"
check "embedded.mobileprovision removed" test ! -e "$APP/embedded.mobileprovision"
check "bundle signature verifies" codesign --verify --strict "$APP"
check "no quarantine attribute left" no_quarantine
check "the registry holds the app" registry_has
if launch; then
  check "shipped idiom (iPad, 1)" logged ' launch idiom=1 '
  check "embedded framework loaded" logged 'probekit ok'
  check "GL lookup answers OpenGL ES, not desktop libGL" logged 'gl lookup=OpenGLES '
  check "a quirk row forced the BOOL getter and left the NSInteger getter alone" logged 'quirk switch=1 count=7$'
  check "the signature's team id answers the keychain shim's seed, not nothing" logged 'teamid=[A-Z0-9]{10} seed=[A-Z0-9]{10} same=1$'
  check "keychain item stored (shim)" logged 'keychain miss=.* add=0 '
  check "app-group folder is in the container and writable" \
    logged 'group write=1 path=.*/Library/Containers/[^/]+/Data/Library/Group Containers/group\.ipa\.probe\.shared '
  check "shared-access-group keychain item stored (shim)" logged 'keychain-shared miss=.* add=0 '
  check "app-group preferences written on the group's first launch (NSUserDefaults)" logged 'groupdefaults miss add=g-'
  check "app-group preferences written on the group's first launch (CFPreferences)" logged 'groupcf miss add=g-'
  check "flagged keychain item stored (synchronizable, access group, AfterFirstUnlockThisDeviceOnly)" logged 'keychain-flags miss=.* add=0 '
  check "an unsigned group's preferences written" logged 'unsigned miss add=q-'
  check "SQLite database written in the app group's folder" logged 'groupsql miss add=q-[0-9]+ rc=0'
  check "coordinated file written in the app group's folder" logged 'groupcoord miss add=q-[0-9]+ wrote=1'
else
  bad "the probe did not launch"
fi
sleep 2   # past the probe's writes; a kill -9 then stands for a crash or Force Quit
kill_probe
if launch; then
  check "keychain item read back after kill -9 and relaunch (shim)" logged 'keychain read=v-'
  check "shared-access-group keychain item read back after kill -9 and relaunch" logged 'keychain-shared read=s-'
  check "app-group preferences read back after kill -9 and relaunch (NSUserDefaults)" logged 'groupdefaults read=g-'
  check "app-group preferences read back after kill -9 and relaunch (CFPreferences)" logged 'groupcf read=g-'
  check "keychain item found with flags that describe no item, then updated and deleted by access group" \
    logged 'keychain-flags read=f-[0-9]+ pdmn=cku sync=1 update=0 reread=updated delete=0 gone=-25300'
  check "app-group preferences read back as a persistent domain" logged 'groupdomain probe=g-'
  check "an unsigned group's preferences read back after kill -9 and relaunch" logged 'unsigned read=q-'
  check "SQLite database in the app group's folder read back after kill -9 and relaunch" logged 'groupsql read=q-'
  check "coordinated file in the app group's folder read back after kill -9 and relaunch" logged 'groupcoord read=q-'
  if logged 'kvs read=q-'; then ok "NSUbiquitousKeyValueStore value read back after kill -9 and relaunch"
  else skip "NSUbiquitousKeyValueStore did not keep its value (no iCloud entitlement): $(since | grep -E ' kvs ' | tail -n 1)"; fi
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

# ── an empty window (replaces the copy again) ───────────────────────────────
# The probe built to leave its window empty the way YouTube did, and one with
# content that logs the same UIKit warning. The doctor reads the window
# through the Accessibility API, which needs the Accessibility permission for
# the terminal this runs in; without it the empty case is skipped.
echo "empty window: doctor reports window_not_attached, and only for an empty window"
doctor_probe() {   # $1 = blank | detached; the doctor's JSON lands in $W/doctor
  quit_probe
  eider install "$W/probe-$1.ipa" --dest "$W/apps" --json >"$W/out" 2>"$W/err" || bad "install the $1-window probe: $(cat "$W/err")"
  eider doctor "$BID" --json >"$W/doctor" 2>&1
}
doctor_probe blank
if grep -qF '"window_not_attached"' "$W/doctor"; then
  ok "doctor reports window_not_attached for an app whose window stayed empty"
elif grep -qF '"running":true' "$W/doctor"; then
  skip "doctor saw the app running but could not read its window (Accessibility permission for this terminal?)"
else
  bad "doctor on the blank-window probe: $(tail -n 2 "$W/doctor")"
fi
doctor_probe detached
check "doctor calls an app with content running even when it logs the same warning" grep -qF '"running":true' "$W/doctor"

# ── uninstall ───────────────────────────────────────────────────────────────
echo "uninstall"
quit_probe
if eider uninstall "$BID" >"$W/out" 2>"$W/err"; then ok "uninstall succeeded"; else bad "uninstall: $(cat "$W/err")"; fi
check "the app is gone from the destination" test ! -e "$APP"
check "the registry no longer holds the app" test "$(registry_count)" = 0
if eider uninstall "$BID" >/dev/null 2>&1; then bad "a second uninstall should fail"; else ok "a second uninstall fails: nothing to remove"; fi

echo "$PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
