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
# The source is a local file, so its icons and screenshots can be local files
# too (URLPolicy lets a file source point at files, never a remote one): the
# pictures show real icons without any network or loopback server. One app's
# icon is an https address that cannot resolve, to show the silent fallback.
# Every page is drawn twice, light (<name>.png) and dark (<name>-dark.png).
#
# --bench adds a 17,430-app source (the size of the catalog that made Browse
# slow) with a distinct icon address per app, scrolls Browse through it
# (EIDER_SCROLL_BENCH) and prints the main-thread cost per frame;
# --bench-no-icons does the same with no icon addresses, for comparison.
#
# Usage: Scripts/app-smoke.sh [--bench | --bench-no-icons]

set -uo pipefail

BENCH=""
case "${1:-}" in
  --bench) BENCH=icons ;;
  --bench-no-icons) BENCH=plain ;;
  "") ;;
  *) echo "usage: $0 [--bench | --bench-no-icons]"; exit 2 ;;
esac
BENCH_APPS=17430
BENCH_FRAMES=600

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
# The bench measures what the owner runs, so it builds release; the smoke
# pictures keep the faster debug build.
CONFIGURATION=debug
[ -n "$BENCH" ] && CONFIGURATION=release
"$ROOT/Scripts/make-app.sh" --configuration "$CONFIGURATION" --output "$W/bundle" >"$W/make-app.log" 2>&1 \
  || { cat "$W/make-app.log"; echo "make-app.sh failed"; exit 2; }
[ -x "$EXE" ] || { echo "no executable at $EXE"; exit 2; }

echo "Preparing a library and a source in a temporary EIDER_HOME ..."
mkdir -p "$W/home" "$W/apps" "$W/site"
"$ROOT/legacy/test/make-probe-ipa.sh" "$W/site/probe-1.ipa" >/dev/null \
  || { echo "could not build the probe (needs Xcode's iOS SDK)"; exit 2; }
echo "Drawing fixture icons and screenshots ..."
# Original artwork (a gradient tile and an SF Symbol), drawn here so the
# pictures carry no third-party icons.
cat >"$W/make-art.swift" <<'SWIFT'
import AppKit
let out = CommandLine.arguments[1]
let icons: [(String, NSColor, NSColor)] = [
    ("note.text", .systemBlue, .systemIndigo), ("camera.fill", .systemOrange, .systemPink),
    ("gamecontroller.fill", .systemPurple, .systemBlue), ("music.note", .systemRed, .systemPink),
    ("map.fill", .systemGreen, .systemTeal), ("hammer.fill", .systemGray, .darkGray),
    ("cloud.fill", .systemCyan, .systemBlue), ("bolt.fill", .systemYellow, .systemOrange),
]
func png(_ size: NSSize, _ draw: (NSRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
func symbol(_ name: String, _ side: CGFloat, in rect: NSRect) {
    let config = NSImage.SymbolConfiguration(pointSize: side, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
    let s = image.size
    image.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
}
for (i, (name, top, bottom)) in icons.enumerated() {
    let data = png(NSSize(width: 512, height: 512)) { rect in
        NSGradient(starting: top, ending: bottom)!.draw(in: rect, angle: -90)
        symbol(name, 220, in: rect)
    }
    try! data.write(to: URL(fileURLWithPath: "\(out)/icon\(i).png"))
}
for i in 0..<3 {
    let (_, top, bottom) = icons[i]
    let data = png(NSSize(width: 600, height: 1200)) { rect in
        NSColor(white: 0.97, alpha: 1).setFill(); rect.fill()
        NSGradient(starting: top, ending: bottom)!.draw(in: NSRect(x: 0, y: 900, width: 600, height: 300), angle: -90)
        for row in 0..<5 {
            let card = NSRect(x: 40, y: 760 - row * 150, width: 520, height: 120)
            NSColor(white: 1, alpha: 1).setFill(); NSBezierPath(roundedRect: card, xRadius: 24, yRadius: 24).fill()
            top.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: NSRect(x: 64, y: card.minY + 24, width: 72, height: 72), xRadius: 18, yRadius: 18).fill()
            NSColor(white: 0.85, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 160, y: card.minY + 70, width: 300, height: 18), xRadius: 9, yRadius: 9).fill()
            NSBezierPath(roundedRect: NSRect(x: 160, y: card.minY + 36, width: 200, height: 14), xRadius: 7, yRadius: 7).fill()
        }
        symbol(icons[i].0, 120, in: NSRect(x: 0, y: 900, width: 600, height: 300))
    }
    try! data.write(to: URL(fileURLWithPath: "\(out)/shot\(i).png"))
}
SWIFT
mkdir -p "$W/site/art"
swift "$W/make-art.swift" "$W/site/art" >"$W/art.log" 2>&1 || { cat "$W/art.log"; echo "could not draw the fixture art"; exit 2; }

# The source offers version 2.0 of the probe, so the installed 1.0 gets an
# update badge, plus more apps so Browse has a real list. Download addresses
# point at nothing: this run never downloads.
cat >"$W/site/source.json" <<'JSON'
{"name":"Smoke Source","iconURL":"art/icon7.png","apps":[
 {"name":"Aurora Notes","bundleIdentifier":"com.example.aurora","developerName":"Northwind Labs",
  "subtitle":"Notes that sync across your devices","iconURL":"art/icon0.png",
  "localizedDescription":"Write, sketch and organise notes in a calm, focused space. Aurora Notes keeps everything in sync and works offline.\n\nThis entry is a fixture for the app's smoke test.",
  "screenshotURLs":["art/shot0.png","art/shot1.png","art/shot2.png"],
  "versions":[{"version":"3.2","buildVersion":"32","downloadURL":"https://example.invalid/aurora-3.2.ipa","date":"2026-11-12","size":48234496,
               "localizedDescription":"Faster search and a new sidebar."},
              {"version":"3.1","buildVersion":"31","downloadURL":"https://example.invalid/aurora-3.1.ipa","date":"2026-09-30","size":47185920},
              {"version":"3.0","buildVersion":"30","downloadURL":"https://example.invalid/aurora-3.0.ipa","date":"2026-08-01","size":46137344}]},
 {"name":"Beacon Camera","bundleIdentifier":"com.example.beacon","developerName":"Lumen","iconURL":"art/icon1.png",
  "versions":[{"version":"1.4","downloadURL":"https://example.invalid/beacon.ipa"}]},
 {"name":"Cascade Arcade","bundleIdentifier":"com.example.cascade","developerName":"Pixel Forge","iconURL":"art/icon2.png",
  "versions":[{"version":"2.0","downloadURL":"https://example.invalid/cascade.ipa"}]},
 {"name":"Echo Music","bundleIdentifier":"com.example.echo","developerName":"Soundry","iconURL":"art/icon3.png",
  "versions":[{"version":"5.1","downloadURL":"https://example.invalid/echo.ipa"}]},
 {"name":"Field Maps","bundleIdentifier":"com.example.field","developerName":"Cartograph","iconURL":"art/icon4.png",
  "versions":[{"version":"1.0","downloadURL":"https://example.invalid/field.ipa"}]},
 {"name":"IPA Probe","bundleIdentifier":"local.ipa-install-on-mac.probe","developerName":"Eider tests","iconURL":"art/icon5.png",
  "localizedDescription":"A tiny app used to test the installer.",
  "versions":[{"version":"2.0","buildVersion":"2","downloadURL":"https://example.invalid/probe-2.ipa","date":"2026-11-01"},
              {"version":"1.0","buildVersion":"1","downloadURL":"https://example.invalid/probe-1.ipa"}]},
 {"name":"Nimbus Weather","bundleIdentifier":"com.example.nimbus","developerName":"Skyline","iconURL":"art/icon6.png",
  "versions":[{"version":"4.0","downloadURL":"https://example.invalid/nimbus.ipa"}]},
 {"name":"Quiet Hours","bundleIdentifier":"com.example.quiet","developerName":"Someone",
  "iconURL":"https://icons.example.invalid/quiet.png",
  "versions":[{"version":"1.0","downloadURL":"https://example.invalid/quiet.ipa"}]},
 {"name":"Volt","bundleIdentifier":"com.example.volt","developerName":"Current Co","iconURL":"art/icon7.png",
  "versions":[{"version":"0.9","downloadURL":"https://example.invalid/volt.ipa"}]},
 {"name":"Zen Garden","bundleIdentifier":"com.example.zen","developerName":"Stillwater",
  "versions":[{"version":"1.0","downloadURL":"https://example.invalid/zen.ipa"}]}]}
JSON
if [ -n "$BENCH" ]; then
  echo "Writing a $BENCH_APPS-app source for the scroll bench ($BENCH) ..."
  python3 -I - "$W/site/bench.json" "$BENCH_APPS" "$BENCH" <<'PY'
import json, sys
path, count, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
words = ["Photo", "Tele", "Cloud", "Game", "Notes", "Music", "Radio", "Map", "Cam", "Pay", "Chat", "Fit", "Draw", "Mail", "Clock"]
adjectives = ["Super", "Mini", "Pro", "Lite", "Ultra", "Smart", "Cafe", "Zen", "Neo", "Retro"]
apps = []
for i in range(count):
    app = {"name": f"{adjectives[i % 10]} {words[(i // 7) % 15]} {i % 997}", "bundleIdentifier": f"com.example.bench{i}",
           "developerName": f"Developer {i % 211}", "versions": [{"version": "1.0", "downloadURL": f"https://example.invalid/{i}.ipa"}]}
    if mode == "icons":
        # A distinct address per app, so every row is a real fetch and decode.
        app["iconURL"] = f"art/icon{i % 8}.png?app={i}"
    apps.append(app)
json.dump({"name": "Bench Source", "apps": apps}, open(path, "w"))
PY
fi
CLI="$APP/Contents/Resources/cli/bin/eider"
eider() { env EIDER_HOME="$W/home" "$CLI" "$@"; }
eider install "$W/site/probe-1.ipa" --dest "$W/apps" >"$W/install.log" 2>&1 \
  || { cat "$W/install.log"; fatal "the CLI could not install the probe"; }
eider source add "$W/site/source.json" >"$W/source.log" 2>&1 \
  || { cat "$W/source.log"; fatal "the CLI could not add the local source"; }
if [ -n "$BENCH" ]; then
  eider source add "$W/site/bench.json" >"$W/bench-source.log" 2>&1 \
    || { cat "$W/bench-source.log"; fatal "the CLI could not add the bench source"; }
fi

echo "Launching the app with --snapshot (background, no activation) ..."
rm -rf "$SNAP"; mkdir -p "$SNAP"
# -W returns when the app quits; -g keeps it in the background; -n a fresh instance.
BENCH_ENV=()
[ -n "$BENCH" ] && BENCH_ENV=(--env "EIDER_SCROLL_BENCH=$BENCH_FRAMES")
open -g -n -W "$APP" --env "EIDER_HOME=$W/home" ${BENCH_ENV[@]+"${BENCH_ENV[@]}"} --args --snapshot "$SNAP" >"$W/open.log" 2>&1 &
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
for name in library browse activity sources browse-detail browse-update \
            library-dark browse-dark activity-dark sources-dark browse-detail-dark browse-update-dark; do
  file="$SNAP/$name.png"
  if [ ! -f "$file" ]; then bad "$name.png exists"; continue; fi
  size=$(stat -f %z "$file")
  width=$(sips -g pixelWidth "$file" 2>/dev/null | awk '/pixelWidth/ { print $2 }')
  echo "        $name.png: $size bytes, ${width:-?} px wide"
  check "$name.png is larger than a blank window ($size > $MIN_PNG_BYTES) and wide enough" \
    test "$size" -gt "$MIN_PNG_BYTES" -a "${width:-0}" -ge "$MIN_PNG_WIDTH"
done

if [ -n "$BENCH" ]; then
  if [ -f "$SNAP/scroll-bench.txt" ]; then
    ok "the scroll bench ran"
    sed 's/^/        /' "$SNAP/scroll-bench.txt"
  else
    bad "the scroll bench wrote no result"
  fi
fi

mkdir -p "$OUT"
rm -f "$OUT"/*.png "$OUT"/scroll-bench*.txt
cp "$SNAP"/*.png "$OUT"/ 2>/dev/null
[ -f "$SNAP/scroll-bench.txt" ] && cp "$SNAP/scroll-bench.txt" "$OUT/scroll-bench-$BENCH.txt"
echo "PNGs: $OUT"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
