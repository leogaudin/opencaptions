#!/usr/bin/env bash
# One simulator screenshot of the debug app in a chosen state.
# usage: capture.sh out.png video.mp4 [OC_VAR=value ...]
#   The variables are the debug build's launch switches (OC_SEED_TRANSCRIPT, OC_OPEN_FIRST, OC_SEEK,
#   OC_SHOW_STYLE, OC_SHOW_SAVE, OC_SHOW_TRANSCRIBE, ...): the app opens straight into that state.
#   SIM is the booted simulator's name or UDID. The app is a Pro one with fresh data every time.
set -u
SIM=${SIM:?the simulator to use, e.g. SIM="iPhone 18 Pro"}
out=$1; video=$2; shift 2
BUNDLE=org.leogaudin.opencaptions
timeout 20 xcrun simctl terminate "$SIM" $BUNDLE 2>/dev/null
args=(SIMCTL_CHILD_OC_TIER=pro SIMCTL_CHILD_OC_RESET=1 "SIMCTL_CHILD_OC_SEED_VIDEO=$(cd "$(dirname "$video")" && pwd)/$(basename "$video")")
for v in "$@"; do args+=("SIMCTL_CHILD_$v"); done
timeout 40 env "${args[@]}" xcrun simctl launch "$SIM" $BUNDLE >/dev/null
# The simulator can be slow to draw (and shows the home screen or a blank frame first): take
# a picture every ten seconds until one is large enough to hold a real screen.
for _ in $(seq 1 14); do
  sleep 10
  timeout 30 xcrun simctl io "$SIM" screenshot "$out" >/dev/null 2>&1
  if [ "$(stat -f %z "$out")" -gt 230000 ]; then
    sleep 3
    timeout 30 xcrun simctl io "$SIM" screenshot "$out" >/dev/null 2>&1
    exit 0
  fi
done
echo "no real screen after 140 s: $out" >&2
exit 1
