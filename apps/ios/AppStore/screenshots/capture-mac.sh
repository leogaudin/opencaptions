#!/usr/bin/env bash
# One screenshot of the debug Mac app in a chosen state: capture.sh, for the Mac.
# usage: APP=/path/to/OpenCaptions.app WINDOW=/path/to/window-id MAC_HOME=/path/to/folder capture-mac.sh out.png /path/to/video.mp4 [OC_VAR=value ...]
#   The variables are capture.sh's, with absolute paths. WINDOW is window-id.swift, compiled.
#   The debug build is not sandboxed, so it runs with MAC_HOME as its home: OC_RESET empties the projects of
#   whatever home it sees, and that must not be the real one.
set -u
APP=${APP:?the built debug OpenCaptions.app}
WINDOW=${WINDOW:?the compiled window-id.swift}
MAC_HOME=${MAC_HOME:?a folder to use as home}
out=$1; video=$2; shift 2
mkdir -p "$MAC_HOME"
args=(--env "CFFIXED_USER_HOME=$MAC_HOME" --env OC_TIER=pro --env OC_RESET=1 --env "OC_SEED_VIDEO=$video")
for v in "$@"; do args+=(--env "$v"); done
# UI_LANG shows the app in that language, as a person with that language on their Mac sees it, numbers included.
lang=()
if [ -n "${UI_LANG:-}" ]; then lang=(--args -AppleLanguages "($UI_LANG)" -AppleLocale "${UI_LANG//-/_}"); fi
binary=$APP/Contents/MacOS/OpenCaptions
# Not with -g: a SwiftUI app started in the background makes no window, so it takes the focus for a moment.
open -n "${args[@]}" "$APP" "${lang[@]}"
trap 'pkill -f "$binary"' EXIT
id=
for _ in $(seq 1 40); do
  sleep 1
  pid=$(pgrep -nf "$binary")
  if [ -n "$pid" ]; then id=$("$WINDOW" "$pid"); fi
  if [ -n "$id" ]; then break; fi
done
if [ -z "$id" ]; then
  echo "no window after 40 s: $out" >&2
  exit 1
fi
# The switches open their screens one after the other, and a clip's first frame takes a moment.
sleep "${SETTLE:-6}"
screencapture -x -o -l "$id" "$out"
