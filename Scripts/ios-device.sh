#!/usr/bin/env bash
# Builds Eider for iOS (Apps/EiderMobile) and installs it on a connected
# device with devicectl.
#
#   TEAM=... PROFILE=... IDENTITY=... DEVICE=... Scripts/ios-device.sh [Debug|Release]
#
#   TEAM      Apple Developer team id.
#   PROFILE   Provisioning profile name or UUID; it must cover
#             io.github.ayush5harma.EideriOS (a wildcard profile does) and DEVICE.
#   IDENTITY  Signing certificate: "Apple Development", "iPhone Developer" or its full name.
#   DEVICE    The device's UDID or name, as `xcrun devicectl list devices` shows it.
#   LAUNCH=1  Also launch the app after installing.
#
# Signing values never go into the committed project (it is public). They are
# passed as EIDER_* build settings, which only the app target reads (project.yml);
# passing PROVISIONING_PROFILE_SPECIFIER itself would also apply it to every
# Swift package target, which Xcode refuses.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-${CONFIGURATION:-Debug}}"
case "$CONFIGURATION" in
  Debug|Release) ;;
  *) echo "usage: $0 [Debug|Release]" >&2; exit 64 ;;
esac

: "${TEAM:?set TEAM to the Apple Developer team id}"
: "${PROFILE:?set PROFILE to the provisioning profile name or UUID}"
: "${IDENTITY:?set IDENTITY to the signing certificate, e.g. \"Apple Development\"}"
: "${DEVICE:?set DEVICE to the device UDID or name (xcrun devicectl list devices)}"

DERIVED="${DERIVED_DATA:-$ROOT/build/ios-device}"
APP="$DERIVED/Build/Products/$CONFIGURATION-iphoneos/Eider.app"
BUNDLE_ID="io.github.ayush5harma.EideriOS"

echo "building Eider ($CONFIGURATION) for iOS, team $TEAM"
xcodebuild \
  -project "$ROOT/Apps/EiderMobile/EiderMobile.xcodeproj" \
  -scheme EiderMobile \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED" \
  EIDER_TEAM="$TEAM" \
  EIDER_PROFILE="$PROFILE" \
  EIDER_IDENTITY="$IDENTITY" \
  EIDER_SIGN_STYLE=Manual \
  -quiet build

# A structural check before handing the bundle to the device, whose own
# refusal messages are much less specific.
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|TeamIdentifier)='

echo "installing on $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP"

if [ "${LAUNCH:-0}" = "1" ]; then
  xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
fi
echo "installed $BUNDLE_ID ($CONFIGURATION) on $DEVICE"
