#!/usr/bin/env bash
# End-to-end check of the whole product flow, judged by effect: a local source
# on loopback offers a probe app (legacy/test/probe.m), and the real `eider`
# adds the source, finds the app, installs version 1, launches it, learns that
# the source now offers version 2, updates with the app's data intact, diagnoses
# a deliberately broken install, and uninstalls.
#
# Every `eider` call runs as on a Mac with no developer tools: DEVELOPER_DIR is
# /var/empty and PATH is the system directories only, so any step that reached
# for xcrun, clang, lipo or python3 would fail. Building the rig (swift, the
# shims, the probe IPAs, python3 -m http.server for the loopback source) is
# outside that and is not the product.
#
# Everything installs into a temporary --dest and a temporary EIDER_HOME, never
# /Applications. Left behind: nothing this script can remove. The probe's
# container is emptied (its root belongs to containermanagerd) and only the
# Trash entries the run itself created are deleted again.
#
# Usage: Scripts/e2e.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BID=local.ipa-install-on-mac.probe
CONTAINER="$HOME/Library/Containers/$BID/Data"
LOG="$CONTAINER/Documents/probe.log"
# Physical path: pkill/pgrep match the /private/var form of a $TMPDIR path.
W=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/eider-e2e-product.XXXXXX")" && pwd -P)
APP="$W/apps/IPA Probe.app"
SITE="$W/site"
PASS=0; FAIL=0; MARK=""; SERVER_PID=""

ok()    { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad()   { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
fatal() { bad "$*"; echo "$PASS passed, $FAIL failed"; exit 1; }

# ~/.Trash entries that exist before the run, so only the run's own are removed.
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
  ls -1 "$HOME/.Trash" 2>/dev/null | while IFS= read -r name; do
    case "$name" in "IPA Probe"*|"$BID"*) grep -Fx -- "$name" "$TRASH_BEFORE" >/dev/null || rm -rf "$HOME/.Trash/$name" ;; esac
  done
  return 0
}
cleanup() {
  quit_probe
  [ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null
  empty_container; clean_trash; rm -rf "$W"
}
trap cleanup EXIT

# ── Rig: build the product, the shims, two versions of the probe, the source ──
echo "Building eider, the shims and the probe ..."
(cd "$ROOT" && swift build >"$W/build.log" 2>&1) || { cat "$W/build.log"; echo "swift build failed"; exit 2; }
BIN="$(cd "$ROOT" && swift build --show-bin-path)/eider"
"$ROOT/Scripts/build-shims.sh" >"$W/shims.log" 2>&1 || { cat "$W/shims.log"; echo "build-shims failed"; exit 2; }
mkdir -p "$SITE" "$W/v2"
"$ROOT/legacy/test/make-probe-ipa.sh" "$SITE/probe-1.ipa" >/dev/null || { echo "could not build the probe (needs Xcode's iOS SDK)"; exit 2; }
# Version 2 is version 1 with a new version and build, so the update is visible
# and nothing else differs. The installer signs afresh, so the old seal does not matter.
(cd "$W/v2" && unzip -q "$SITE/probe-1.ipa") || { echo "could not unpack the probe"; exit 2; }
plutil -replace CFBundleShortVersionString -string 2.0 "$W/v2/Payload/Probe.app/Info.plist"
plutil -replace CFBundleVersion -string 2 "$W/v2/Payload/Probe.app/Info.plist"
(cd "$W/v2" && zip -qry "$SITE/probe-2.ipa" Payload iTunesMetadata.plist) || { echo "could not pack version 2"; exit 2; }
SHA1=$(shasum -a 256 "$SITE/probe-1.ipa" | awk '{ print $1 }')
SHA2=$(shasum -a 256 "$SITE/probe-2.ipa" | awk '{ print $1 }')

PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
(cd "$SITE" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >"$W/server.log" 2>&1) &
SERVER_PID=$!
BASE="http://127.0.0.1:$PORT"
for _ in $(seq 1 40); do curl -fs "$BASE/probe-1.ipa" -o /dev/null && break; sleep 0.25; done
curl -fs "$BASE/probe-1.ipa" -o /dev/null || { echo "the loopback source server did not start"; exit 2; }

# An AltStore-format source; the first version listed is the newest.
write_source() {
  local versions="$1"
  printf '{"name":"E2E Source","apps":[{"name":"IPA Probe","bundleIdentifier":"%s","developerName":"Eider tests","versions":[%s]}]}\n' \
    "$BID" "$versions" > "$SITE/source.json"
}
version_entry() { printf '{"version":"%s","buildVersion":"%s","downloadURL":"%s/probe-%s.ipa","sha256":"%s"}' "$1" "$2" "$BASE" "$2" "$3"; }
write_source "$(version_entry 1.0 1 "$SHA1")"

# ── The product, run as on a Mac with no developer tools ────────────────────
eider() {
  env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    DEVELOPER_DIR=/var/empty EIDER_HOME="$W/home" EIDER_SHIMS_DIR="$ROOT/build/shims" "$BIN" "$@"
}
# Run eider --json, keep stdout and the last line (the result object) apart.
run_json() {
  eider "$@" --json >"$W/out" 2>"$W/err"; RC=$?
  tail -n 1 "$W/out" > "$W/last.json"
}
jget() { plutil -extract "$1" raw -o - -- "$W/last.json" 2>/dev/null; }
is() { [ "$(jget "$1")" = "$2" ]; }
registry_get() { plutil -extract "$1" raw -o - -- "$W/home/library.json" 2>/dev/null; }
installed_version() { plutil -extract CFBundleShortVersionString raw -o - -- "$APP/Info.plist" 2>/dev/null; }

since() { awk -v m="$MARK" 'f; $0 == m { f = 1 }' "$LOG" 2>/dev/null; }
logged() { since | grep -E "$1" >/dev/null; }
launch() {
  quit_probe
  MARK="--- e2e $(date +%s).$RANDOM"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  echo "$MARK" >> "$LOG" || fatal "cannot write the probe's log ($LOG)"
  run_json open "$BID"
  [ "$RC" = 0 ] || return 1
  for _ in $(seq 1 40); do logged ' launch ' && return 0; sleep 0.25; done
  return 1
}

echo "e2e against $BASE (no developer tools: DEVELOPER_DIR=/var/empty, PATH=/usr/bin:/bin:/usr/sbin:/sbin)"
empty_container   # a first keychain write must look like a first write

# ── source add, search ──────────────────────────────────────────────────────
echo "source add and search"
run_json source add "$BASE/source.json"
check "source add succeeds" test "$RC" = 0
check "the source reports one app" is data.apps 1
run_json source list
check "source list shows the source" is data.sources.0.name "E2E Source"
run_json search probe
check "search finds the probe by name" is data.apps.0.bundleID "$BID"
run_json search nothing-matches-this
check "a search with no match is an empty list, not an error" is data.apps.0.bundleID ""
eider search probe >"$W/out" 2>&1
check "human search output is a plain aligned table" grep -E "^IPA Probe +$BID +1.0 +E2E Source$" "$W/out"
run_json info "$BID"
check "info shows the app and that it is not installed yet" test "$(jget data.app.name)" = "IPA Probe" -a -z "$(jget data.installed.version)"

# ── install version 1 from the catalog ──────────────────────────────────────
echo "install $BID (version 1)"
run_json install "$BID" --dest "$W/apps"
check "install succeeds" test "$RC" = 0
check "the result names the installed version" is data.app.version 1.0
check "download events were reported" grep -q '"phase":"download"' "$W/out"
check "install events were reported" grep -q '"phase":"install"' "$W/out"
check "the app is in the destination" test -d "$APP"
check "the registry records the source address" test "$(registry_get 0.sourceURL)" = "$BASE/source.json"
check "the registry records the IPA's SHA-256" test "$(registry_get 0.ipaSHA256)" = "$SHA1"
check "bundle signature verifies" codesign --verify --strict "$APP"
check "the shims are linked (keychain, app groups)" sh -c "otool -L '$APP/Probe' | grep -q libipakeychain && otool -L '$APP/Probe' | grep -q libipagroups"
if launch; then
  check "eider open reports the pid" test "$(jget data.running)" = true -a -n "$(jget data.pid)"
  check "shipped idiom (iPad, 1)" logged ' launch idiom=1 '
  check "embedded framework loaded" logged 'probekit ok'
  check "GL lookup answers OpenGL ES" logged 'gl lookup=OpenGLES '
  check "keychain item stored on the first launch" logged 'keychain miss=.* add=0 '
  check "app-group folder is writable in the container" logged 'group write=1 '
else
  bad "the probe did not launch: $(cat "$W/err") $(tail -n 1 "$W/out")"
fi
FIRST_MARK="$MARK"
quit_probe

# ── the source offers version 2 ─────────────────────────────────────────────
echo "update"
run_json list
check "list shows no update while the source offers version 1" is data.apps.0.update.version ""
write_source "$(version_entry 2.0 2 "$SHA2"),$(version_entry 1.0 1 "$SHA1")"
run_json source refresh
check "source refresh succeeds" test "$RC" = 0
run_json list
check "list marks the update (JSON)" is data.apps.0.update.version 2.0
eider list >"$W/out" 2>&1
check "list marks the update (text)" grep -E "IPA Probe .*1\.0 +-> 2\.0" "$W/out"
run_json update "$BID"
check "update succeeds" test "$RC" = 0
[ "$RC" = 0 ] || echo "    $(cut -c1-400 "$W/err") $(cut -c1-400 "$W/last.json")"
check "update reports the app as updated" is data.updated.0.version 2.0
check "version 2 is installed" test "$(installed_version)" = 2.0
check "the registry holds exactly one entry at version 2.0" test "$(registry_get 0.version)" = 2.0 -a -z "$(registry_get 1.version)"
check "the registry records version 2's SHA-256" test "$(registry_get 0.ipaSHA256)" = "$SHA2"
run_json update "$BID"
check "a second update finds nothing to do" is data.current.0 "$BID"
run_json list
check "list shows no update after updating" is data.apps.0.update.version ""
if launch; then
  check "version 2 launches" logged 'probekit ok'
  check "the keychain item version 1 stored is still there" logged 'keychain read=v-'
  check "the log version 1 wrote is still in the container" grep -qF -- "$FIRST_MARK" "$LOG"
else
  bad "version 2 did not launch: $(cat "$W/err") $(tail -n 1 "$W/out")"
fi
quit_probe

# ── doctor on a deliberately broken install ─────────────────────────────────
echo "doctor"
run_json doctor "$BID"
check "doctor on a healthy install exits 0 and reports it running" test "$RC" = 0 -a "$(jget data.running)" = true
quit_probe
rm -rf "$APP/Frameworks/ProbeKit.framework"
run_json doctor "$BID" --timeout 15
check "doctor on the broken install exits 2" test "$RC" = 2
check "the diagnosis is a missing library" is data.diagnosis.code library_not_loaded
check "the error carries the same code with a launch. prefix" is error.code launch.library_not_loaded
check "the evidence names the framework" grep -q 'ProbeKit' "$W/last.json"
eider doctor "$BID" --timeout 15 >"$W/out" 2>"$W/err"
check "the text report prints the sentence and the code on stderr" grep -q '(launch.library_not_loaded)' "$W/err"
quit_probe

# ── failures and usage ──────────────────────────────────────────────────────
echo "exit codes"
run_json install com.example.not-in-any-source
check "an unknown bundle id fails with exit 2" test "$RC" = 2 -a "$(jget error.code)" = operations.not_in_catalog
eider bogus-command >/dev/null 2>&1
check "a usage error exits 1" test "$?" = 1
eider install >/dev/null 2>&1
check "a missing argument exits 1" test "$?" = 1

# ── uninstall ───────────────────────────────────────────────────────────────
echo "uninstall"
run_json uninstall "$BID"
check "uninstall succeeds" test "$RC" = 0
check "the app is gone from the destination" test ! -e "$APP"
check "the registry no longer holds the app" test -z "$(registry_get 0.bundleID)"
run_json uninstall "$BID"
check "a second uninstall fails: nothing to remove" test "$RC" = 2
run_json source remove "$BASE/source.json"
check "source remove succeeds" test "$RC" = 0

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
