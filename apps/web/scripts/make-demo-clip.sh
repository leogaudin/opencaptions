#!/usr/bin/env bash
# Cuts a demo clip out of a long 16:9 source: a vertical 9:16 window, trimmed, as the one file
# every browser plays (H.264 High, 8-bit 4:2:0, AAC, moov up front) at 720x1280.
#
#   scripts/make-demo-clip.sh SOURCE ID START DURATION [CX]
#
#   SOURCE    the downloaded film (any container ffmpeg reads; SDR, see below)
#   ID        the clip's id: writes demo-public/demo/clips/ID.mp4
#   START     where the clip begins, in seconds or HH:MM:SS
#   DURATION  its length in seconds (12 to 20 is plenty)
#   CX        where the 9:16 window sits across the frame, 0 (left) to 1 (right), default 0.5
#
# Then edit demo-public/demo/clips.json (width 720, height 1280, duration, fps 30) and add ID.json,
# the transcript (OpenCaptions can make it: upload the clip and export the transcript).
# An HDR source must be tone-mapped to SDR first, or it looks washed out.
set -euo pipefail
[ $# -ge 4 ] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
SRC=$1 ID=$2 START=$3 DUR=$4 CX=${5:-0.5}
OUT="$(dirname "$0")/../demo-public/demo/clips/$ID.mp4"
mkdir -p "$(dirname "$OUT")"
# The window is as wide as 9:16 needs at the source's height, kept to an even number of pixels.
CROP="crop=trunc(ih*9/16/2)*2:ih:(iw-trunc(ih*9/16/2)*2)*$CX:0"
ffmpeg -v error -stats -y -ss "$START" -t "$DUR" -i "$SRC" \
  -vf "$CROP,scale=720:1280:flags=lanczos,fps=30,format=yuv420p" \
  -c:v libx264 -preset slow -crf 23 -profile:v high -level 4.0 -movflags +faststart \
  -af "loudnorm=I=-16:TP=-1.5:LRA=11" -c:a aac -b:a 128k -ac 2 -ar 48000 \
  "$OUT"
echo "Wrote $OUT ($(du -h "$OUT" | cut -f1))"
