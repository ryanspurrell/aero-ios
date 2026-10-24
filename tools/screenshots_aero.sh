#!/bin/sh
# Simulator screenshots of Aero's main screens, one picture per screen, on one simulator.
# Usage: tools/screenshots_aero.sh APP_PATH BUNDLE_ID UDID KIND OUT_DIR   (KIND is iphone or ipad, only used in the file names)
# Each screen is a launch with invented data (DemoMode.swift): nothing is asked of a server. Location and Parts Home need a saved address
# (an unreachable one) so the part tiles that need a PC are drawn; Location then shows its "can't reach" page, not a map.
set -eu
app="$1"; bundle="$2"; udid="$3"; kind="$4"; out="$5"
mkdir -p "$out"
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b
xcrun simctl ui "$udid" appearance light || true
xcrun simctl install "$udid" "$app"
shoot() {
  name="$1"; shift
  xcrun simctl launch "$udid" "$bundle" -aero-demo phone "$@" >/dev/null
  sleep 8
  xcrun simctl io "$udid" screenshot "$out/$kind-$name.png"
  xcrun simctl terminate "$udid" "$bundle" || true
}
shoot day
shoot week -aero-demo-screen week
shoot month -aero-demo-screen month
shoot shopping -aero-demo-page shopping
shoot chatlist -aero-demo-page chatlist
shoot chat -aero-demo-page chat
shoot partshome -FingusPartsHome YES -FingusAddedParts organizer,messages,photos,location -AeroServerAddress http://127.0.0.1:9
shoot location -FingusPartsHome YES -FingusAddedParts organizer,messages,photos,location -AeroServerAddress http://127.0.0.1:9 -aero-demo-page location
shoot you -aero-demo-page you
shoot devices -aero-demo-page devices
shoot devices-approve -aero-demo-page devices-approve
xcrun simctl shutdown "$udid" || true
ls -l "$out"
