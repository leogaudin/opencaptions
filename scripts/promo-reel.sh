#!/usr/bin/env bash
# Makes the promo reels: a clip becomes a 9:16 video captioned in one of the striking looks, with a
# short outro that says where to get the app. It posts nothing: the reels land in a folder to look
# through and publish by hand.
#   scripts/promo-reel.sh <clip or link> [--look Glint] [--out DIR]   (default: ~/Documents/opencaptions-plans/reels)
#   scripts/promo-reel.sh --batch DIR [--out DIR]     every clip in DIR, the looks taking turns
# Needs FFmpeg, and yt-dlp for links. The captions are the opencaptions package's, on this computer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${OPENCAPTIONS_CLI:-npx -y opencaptions@latest}"
ICON="$ROOT/apps/ios/OpenCaptions/Resources/Assets.xcassets/AppIcon.appiconset/icon.png"
LOOKS=(Glint Liquid Depth Trailer Fill Weight Rays Echo)
OUTRO_LOOK="${OUTRO_LOOK:-Glint}"
OUT="${PROMO_OUT:-$HOME/Documents/opencaptions-plans/reels}"
LOOK=""
BATCH=""
INPUTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --look) LOOK="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --batch) BATCH="$2"; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) INPUTS+=("$1"); shift ;;
  esac
done
if [ -n "$BATCH" ]; then
  while IFS= read -r f; do INPUTS+=("$f"); done < <(
    find "$BATCH" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' -o -iname '*.webm' \) | sort)
fi
[ ${#INPUTS[@]} -gt 0 ] || { echo "no clip given (see --help)" >&2; exit 2; }

mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The outro: the app's icon on black, its two lines captioned by the engine like any other video.
outro() {
  local look="$1" file="$WORK/outro-$1.mp4"
  [ -f "$file" ] && return
  cat >"$WORK/outro.json" <<'JSON'
{"schema_version":1,"language":"en","language_detection":"auto","duration":3.4,"segments":[
{"id":"a","start":0.3,"end":3.2,"text":"Get OpenCaptions free on App Store","words":[
{"text":"Get","start":0.3,"end":0.6,"confidence":1},{"text":"OpenCaptions","start":0.6,"end":1.3,"confidence":1},
{"text":"Free","start":1.5,"end":1.9,"confidence":1},{"text":"on","start":1.9,"end":2.2,"confidence":1},
{"text":"App","start":2.4,"end":2.8,"confidence":1},{"text":"Store","start":2.8,"end":3.2,"confidence":1}]}]}
JSON
  ffmpeg -v error -y -f lavfi -i "color=c=black:s=1080x1920:r=30:d=3.4" -i "$ICON" \
    -f lavfi -i "anullsrc=r=44100:cl=stereo" -t 3.4 \
    -filter_complex "[1:v]scale=360:360,format=rgba[i];[0:v][i]overlay=(W-w)/2:560,format=yuv420p" \
    -c:v libx264 -c:a aac -shortest "$WORK/outro-base.mp4"
  $CLI caption "$WORK/outro-base.mp4" --look "$look" --transcript "$WORK/outro.json" \
    --style '{"position_y":0.68,"words_per_line":2}' -o "$file" >/dev/null
}

# One clip: scaled to the frame over a blurred copy of itself, captioned, then the outro.
make() {
  local src="$1" look="$2" name base
  if [[ "$src" == http* ]]; then
    yt-dlp -q -f 'bv*[height<=1080]+ba/b' --merge-output-format mp4 -o "$WORK/dl.%(ext)s" "$src"
    src="$WORK/dl.mp4"
    name="reel-$(date +%s)"
  else
    name="$(basename "${src%.*}")"
  fi
  base="$WORK/base.mp4"
  local audio=(-map 0:a:0)
  ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$src" | grep -q . \
    || audio=(-f lavfi -i "anullsrc=r=44100:cl=stereo" -map 1:a -shortest)
  ffmpeg -v error -y -i "$src" "${audio[@]}" \
    -filter_complex "[0:v]split[a][b];[a]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=40:4[bg];[b]scale=1080:1920:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2,fps=30,format=yuv420p[v]" \
    -map "[v]" -c:v libx264 -crf 17 -c:a aac -ar 44100 -ac 2 "$base"
  $CLI caption "$base" --look "$look" -o "$WORK/captioned.mp4" >/dev/null
  outro "$OUTRO_LOOK"
  ffmpeg -v error -y -i "$WORK/captioned.mp4" -i "$WORK/outro-$OUTRO_LOOK.mp4" \
    -filter_complex "[0:v][0:a][1:v][1:a]concat=n=2:v=1:a=1[v][a]" -map "[v]" -map "[a]" \
    -c:v libx264 -crf 17 -c:a aac -movflags +faststart "$OUT/$name.$look.mp4"
  printf '%s\n\nCaptions: %s look, made with OpenCaptions. Free on the App Store.\n#captions #subtitles #contentcreator\n' \
    "$name" "$look" >"$OUT/$name.$look.txt"
  echo "$OUT/$name.$look.mp4"
}

i=0
for src in "${INPUTS[@]}"; do
  look="${LOOK:-${LOOKS[$((i % ${#LOOKS[@]}))]}}"
  make "$src" "$look"
  i=$((i + 1))
done
