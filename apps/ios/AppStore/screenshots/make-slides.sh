#!/usr/bin/env bash
# Rebuilds the iPhone App Store screenshots from the three Pexels photos. See README.md.
# usage: PHOTOS=/path/to/pexels SIM="iPhone 18 Pro" OUT=/path/to/out ./make-slides.sh
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
IOS=$(cd "$HERE/../.." && pwd)
PHOTOS=${PHOTOS:?the folder holding the three Pexels photos (see README.md)}
SIM=${SIM:?the booted simulator, e.g. SIM="iPhone 18 Pro"}
OUT=${OUT:-$PWD/appstore-screenshots}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)  # absolute: the app reads files by the paths it is given
WORK=$OUT/work
SIZES=(1320x2868 1290x2796 1284x2778 1242x2688 1206x2622 1179x2556)
mkdir -p "$WORK"

echo "==> the debug app, on $SIM"
(cd "$IOS/../.." && make ios-build)
APP=$(find "$IOS/Build/DerivedData/Build/Products/Debug-iphonesimulator" -name OpenCaptions.app -maxdepth 1 | head -1)
xcrun simctl install "$SIM" "$APP"

echo "==> the composer (the path must be absolute: the headline face is found from it)"
swiftc -O "$HERE/compose.swift" -o "$WORK/compose"

echo "==> clips and transcripts"
python3 - "$WORK" <<'PY'
import json, sys
def make(name, lang, lines, t0=0.6, step=0.40, gap=0.5):
    t = t0; segs = []
    for i, line in enumerate(lines, 1):
        words = []
        for w in line.split():
            words.append({"text": w, "start": round(t, 3), "end": round(t + step * 0.92, 3), "confidence": 0.95}); t += step
        segs.append({"id": f"s{i}", "words": words, "start": words[0]["start"], "end": words[-1]["end"], "text": line}); t += gap
    json.dump({"schema_version": 1, "language": lang, "language_detection": "manual", "duration": 12.0, "segments": segs},
              open(f"{sys.argv[1]}/{name}", "w"), ensure_ascii=False)
make("man.json", "en", ["Here is the one tip nobody tells you:", "start with the ending,", "then work backwards."])
make("cat.json", "en", ["Meet Mochi, the boss of the house.", "She watches every video I make."])
make("pierogi_pl.json", "pl", ["Złóż ciasto nad farszem,", "sklej brzegi razem", "i gotuj trzy minuty."])
PY
clip() {  # photo -> a 12 s 1080x1920 clip with a slow zoom and a silent track
  ffmpeg -loglevel error -y -loop 1 -framerate 30 -i "$2" -f lavfi -i anullsrc=r=44100:cl=stereo -t 12 \
    -vf "scale=2160:3840:force_original_aspect_ratio=increase,crop=2160:3840,zoompan=z='1+0.0006*on':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=1:s=1080x1920:fps=30,format=yuv420p" \
    -c:v libx264 -crf 18 -c:a aac -shortest "$1"
}
clip "$WORK/man.mp4" "$PHOTOS"/pexels-vincent-santamaria-194760512-37148334.jpg
clip "$WORK/cat.mp4" "$PHOTOS"/pexels-sefa-demirtas-2152709769-32557420.jpg
clip "$WORK/pierogi.mp4" "$PHOTOS"/pexels-elly-fairytale-3893708.jpg

echo "==> five captures"
cap() { SIM=$SIM "$HERE/capture.sh" "$WORK/$1.png" "$WORK/$2" "${@:3}"; }
cap h1 man.mp4 "OC_SEED_TRANSCRIPT=$WORK/man.json" OC_OPEN_FIRST=1 OC_SEEK=2.3 OC_SHOW_STYLE=1
cap h2 pierogi.mp4 OC_OPEN_FIRST=1 OC_SHOW_TRANSCRIBE=1
cap h3 pierogi.mp4 "OC_SEED_TRANSCRIPT=$WORK/pierogi_pl.json" OC_OPEN_FIRST=1 OC_SEEK=1.8
cap h4 cat.mp4 "OC_SEED_TRANSCRIPT=$WORK/cat.json" OC_OPEN_FIRST=1 OC_SEEK=1.6 OC_SHOW_SAVE=1
cap h5 cat.mp4 "OC_SEED_TRANSCRIPT=$WORK/cat.json" OC_OPEN_FIRST=1 OC_SEEK=5.5

echo "==> the slides, at every size"
for size in "${SIZES[@]}"; do
  mkdir -p "$OUT/iphone-$size"
  W=${size%x*}; H=${size#*x}
  c() { "$WORK/compose" "$WORK/$1.png" "$OUT/iphone-$size/$2.png" "$3" "$4" "$W" "$H"; }
  c h1 01 "Captions that|[stop the scroll]" yellow
  c h2 02 "[Nothing] leaves|your phone" dark
  c h3 03 "About [100 languages].|One tap." yellow
  c h4 04 "Up to [4K].|HDR stays HDR." dark
  c h5 05 "[Open source].|Pay once.|No subscription." yellow
done
echo "done: $OUT"
