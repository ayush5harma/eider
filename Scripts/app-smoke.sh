#!/usr/bin/env bash
# Smoke test of the real app bundle, judged by effect: build Eider.app with
# make-app.sh, give it a temporary EIDER_HOME that holds a local source and one
# installed probe app (made by the real `eider` CLI, as Scripts/e2e.sh does),
# launch it in the background with --snapshot, and check that every section
# produced a PNG with real content, that the app never became the frontmost
# application, and that it quit by itself with status "ok".
#
# Everything installs into a temporary --dest and EIDER_HOME, never
# /Applications. The probe is never launched, so it leaves no container, and
# nothing is uninstalled, so the Trash is untouched. Left behind on purpose:
# build/snapshots/*.png (and build/shims, which build-shims.sh owns).
#
# Usage: Scripts/app-smoke.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID=io.github.ayush5harma.Eider
OUT="$ROOT/build/snapshots"
# Physical path: pgrep matches the /private/var form of a $TMPDIR path.
W=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/eider-app-smoke.XXXXXX")" && pwd -P)
SNAP="$W/snapshots"
APP="$W/bundle/Eider.app"
EXE="$APP/Contents/MacOS/Eider"
# A blank 1100x720 window encodes to a few KB; the measured real pages are far
# above this (see the sizes printed below).
MIN_PNG_BYTES=20000
MIN_PNG_WIDTH=800
LAUNCH_TIMEOUT=120
PASS=0; FAIL=0

ok()    { echo "  PASS  $*"; PASS=$((PASS + 1)); }
bad()   { echo "  FAIL  $*"; FAIL=$((FAIL + 1)); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
fatal() { bad "$*"; echo "$PASS passed, $FAIL failed"; exit 1; }

cleanup() {
  pkill -f "$EXE" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT

echo "Building Eider.app ..."
"$ROOT/Scripts/make-app.sh" --configuration debug --output "$W/bundle" >"$W/make-app.log" 2>&1 \
  || { cat "$W/make-app.log"; echo "make-app.sh failed"; exit 2; }
[ -x "$EXE" ] || { echo "no executable at $EXE"; exit 2; }

echo "Preparing a library and a source in a temporary EIDER_HOME ..."
mkdir -p "$W/home" "$W/apps" "$W/site"
"$ROOT/legacy/test/make-probe-ipa.sh" "$W/site/probe-1.ipa" >/dev/null \
  || { echo "could not build the probe (needs Xcode's iOS SDK)"; exit 2; }
# The source offers version 2.0 of the probe, so the installed 1.0 gets an
# update badge, plus a second app so Browse has more than one row. Its download
# address points at nothing: this run never downloads.
cat >"$W/site/source.json" <<'JSON'
{"name":"Smoke Source","apps":[
 {"name":"IPA Probe","bundleIdentifier":"local.ipa-install-on-mac.probe","developerName":"Eider tests",
  "localizedDescription":"A tiny app used to test the installer.",
  "versions":[{"version":"2.0","buildVersion":"2","downloadURL":"https://example.invalid/probe-2.ipa","date":"2026-11-01"},
              {"version":"1.0","buildVersion":"1","downloadURL":"https://example.invalid/probe-1.ipa"}]},
 {"name":"Another App","bundleIdentifier":"com.example.another","developerName":"Someone",
  "versions":[{"version":"1.0","downloadURL":"https://example.invalid/another.ipa"}]}]}
JSON
CLI="$APP/Contents/Resources/cli/bin/eider"
eider() { env EIDER_HOME="$W/home" "$CLI" "$@"; }
eider install "$W/site/probe-1.ipa" --dest "$W/apps" >"$W/install.log" 2>&1 \
  || { cat "$W/install.log"; fatal "the CLI could not install the probe"; }
eider source add "$W/site/source.json" >"$W/source.log" 2>&1 \
  || { cat "$W/source.log"; fatal "the CLI could not add the local source"; }

echo "Launching the app with --snapshot (background, no activation) ..."
rm -rf "$SNAP"; mkdir -p "$SNAP"
# -W returns when the app quits; -g keeps it in the background; -n a fresh instance.
open -g -n -W "$APP" --env "EIDER_HOME=$W/home" --args --snapshot "$SNAP" >"$W/open.log" 2>&1 &
OPEN_PID=$!

front_is_eider() {
  local front
  front=$(lsappinfo front 2>/dev/null) || return 1
  [ "$(lsappinfo info -only bundleid "$front" 2>/dev/null | sed -n 's/.*"CFBundleIdentifier"="\(.*\)"/\1/p')" = "$BUNDLE_ID" ]
}
STOLE_FOCUS=0
for _ in $(seq 1 $((LAUNCH_TIMEOUT * 4))); do
  kill -0 "$OPEN_PID" 2>/dev/null || break
  front_is_eider && STOLE_FOCUS=1
  sleep 0.25
done
if kill -0 "$OPEN_PID" 2>/dev/null; then
  kill "$OPEN_PID" 2>/dev/null
  bad "the app did not quit within ${LAUNCH_TIMEOUT}s"
fi
wait "$OPEN_PID" 2>/dev/null

echo "Checking the result"
check "the app quit and no process is left" test -z "$(pgrep -f "$EXE")"
check "the snapshot status says ok" test "$(cat "$SNAP/snapshot.status" 2>/dev/null)" = ok
check "the app never became the frontmost application" test "$STOLE_FOCUS" = 0
for name in library browse activity sources browse-detail; do
  file="$SNAP/$name.png"
  if [ ! -f "$file" ]; then bad "$name.png exists"; continue; fi
  size=$(stat -f %z "$file")
  width=$(sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth/ { print $2 }')
  echo "        $name.png: $size bytes, ${width:-?} px wide"
  check "$name.png is larger than a blank window ($size > $MIN_PNG_BYTES) and wide enough" \
    test "$size" -gt "$MIN_PNG_BYTES" -a "${width:-0}" -ge "$MIN_PNG_WIDTH"
done

mkdir -p "$OUT"
rm -f "$OUT"/*.png
cp "$SNAP"/*.png "$OUT"/ 2>/dev/null
echo "PNGs: $OUT"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
