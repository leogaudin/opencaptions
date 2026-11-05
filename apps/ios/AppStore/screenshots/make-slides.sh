#!/usr/bin/env bash
# Rebuilds the App Store screenshots from the three Pexels photos. See README.md.
# usage: PHOTOS=/path/to/pexels SIM="iPhone 18 Pro" OUT=/path/to/out ./make-slides.sh
#   LANGUAGES="fr de" for others than English (the words are in slides.json; a language other than en goes
#   in $OUT/<language>/), and SIZES="1206x2622" for fewer sizes.
#   PLATFORM=mac makes the Mac's instead, from the debug Mac app on this screen: no simulator, one size.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
IOS=$(cd "$HERE/../.." && pwd)
PHOTOS=${PHOTOS:?the folder holding the three Pexels photos (see README.md)}
PLATFORM=${PLATFORM:-iphone}
OUT=${OUT:-$PWD/appstore-screenshots}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)  # absolute: the app reads files by the paths it is given
WORK=$OUT/work
read -r -a LANGS <<< "${LANGUAGES:-en}"
mkdir -p "$WORK"

if [ "$PLATFORM" = mac ]; then
  read -r -a SIZES <<< "${SIZES:-2560x1600}"
  # A window on a wide slide: a small corner, and a headline sized for the height left above it.
  SHAPE=(0.02 0.05 0.28)
  # The Mac's editor keeps the style panel open beside the video.
  STYLE=()
  echo "==> the debug app, on this Mac"
  (cd "$IOS/../.." && make mac-build)
  APP=$IOS/Build/DerivedData/Build/Products/Debug/OpenCaptions.app
  swiftc -O "$HERE/window-id.swift" -o "$WORK/window-id"
else
  SIM=${SIM:?the booted simulator, e.g. SIM="iPhone 18 Pro"}
  read -r -a SIZES <<< "${SIZES:-1320x2868 1290x2796 1284x2778 1242x2688 1206x2622 1179x2556}"
  SHAPE=()
  STYLE=(OC_SHOW_STYLE=1)
  echo "==> the debug app, on $SIM"
  (cd "$IOS/../.." && make ios-build)
  APP=$(find "$IOS/Build/DerivedData/Build/Products/Debug-iphonesimulator" -name OpenCaptions.app -maxdepth 1 | head -1)
  xcrun simctl install "$SIM" "$APP"
fi

echo "==> the composer (the path must be absolute: the headline face is found from it)"
swiftc -O "$HERE/compose.swift" -o "$WORK/compose"

echo "==> clips and transcripts"
python3 - "$WORK" "$HERE/slides.json" "$PLATFORM" <<'PY'
import json, sys
work, slides, platform = sys.argv[1], json.load(open(sys.argv[2])), sys.argv[3]
def make(name, lang, lines, t0=0.6, step=0.40, gap=0.5):
    t = t0; segs = []
    for i, line in enumerate(lines, 1):
        words = []
        for w in line.split():
            words.append({"text": w, "start": round(t, 3), "end": round(t + step * 0.92, 3), "confidence": 0.95}); t += step
        segs.append({"id": f"s{i}", "words": words, "start": words[0]["start"], "end": words[-1]["end"], "text": line}); t += gap
    json.dump({"schema_version": 1, "language": lang, "language_detection": "manual", "duration": 12.0, "segments": segs},
              open(f"{work}/{name}", "w"), ensure_ascii=False)
    return segs[-1]["words"][-1]["start"]
for lang, text in slides.items():
    make(f"man-{lang}.json", lang, text["man"])
    # The last slide stops on the last word: a translation can be over sooner than the English.
    last_word = make(f"cat-{lang}.json", lang, text["cat"])
    with open(f"{work}/seek-{lang}.txt", "w") as out:
        out.write(str(last_word + 0.05))
    headlines = text["headlines"]
    if platform == "mac":
        # The second slide names the device, and a wide slide has room for two lines at most.
        headlines = [text["mac_headline"] if i == 1 else h for i, h in enumerate(headlines)]
        headlines = [h.replace("|", " ", 1) if h.count("|") > 1 else h for h in headlines]
    with open(f"{work}/headlines-{lang}.txt", "w") as out:
        out.write("\n".join(headlines) + "\n")
    with open(f"{work}/font-{lang}.txt", "w") as out:
        out.write(text.get("font", ""))
# The slide about languages shows one that is not the reader's, whatever the reader's is.
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

cap() {
  if [ "$PLATFORM" = mac ]; then
    APP=$APP WINDOW=$WORK/window-id MAC_HOME=$WORK/mac-home "$HERE/capture-mac.sh" "$WORK/$1.png" "$WORK/$2" "${@:3}"
  else
    SIM=$SIM "$HERE/capture.sh" "$WORK/$1.png" "$WORK/$2" "${@:3}"
  fi
}
for lang in "${LANGS[@]}"; do
  echo "==> five captures, $lang"
  export UI_LANG=$lang
  cap h1 man.mp4 "OC_SEED_TRANSCRIPT=$WORK/man-$lang.json" OC_OPEN_FIRST=1 OC_SEEK=2.3 ${STYLE[@]+"${STYLE[@]}"}
  cap h2 pierogi.mp4 OC_OPEN_FIRST=1 OC_SHOW_TRANSCRIBE=1
  cap h3 pierogi.mp4 "OC_SEED_TRANSCRIPT=$WORK/pierogi_pl.json" OC_OPEN_FIRST=1 OC_SEEK=1.8
  cap h4 cat.mp4 "OC_SEED_TRANSCRIPT=$WORK/cat-$lang.json" OC_OPEN_FIRST=1 OC_SEEK=1.6 OC_SHOW_SAVE=1
  cap h5 cat.mp4 "OC_SEED_TRANSCRIPT=$WORK/cat-$lang.json" OC_OPEN_FIRST=1 "OC_SEEK=$(cat "$WORK/seek-$lang.txt")"

  echo "==> the slides, $lang, at every size"
  face=$(cat "$WORK/font-$lang.txt")
  dest=$OUT
  [ "$lang" = en ] || dest=$OUT/$lang
  for size in "${SIZES[@]}"; do
    mkdir -p "$dest/$PLATFORM-$size"
    W=${size%x*}; H=${size#*x}
    n=0
    while IFS= read -r headline; do
      n=$((n + 1))
      background=yellow; [ $((n % 2)) -eq 0 ] && background=dark
      HEADLINE_FONT=$face "$WORK/compose" "$WORK/h$n.png" "$dest/$PLATFORM-$size/0$n.png" "$headline" "$background" "$W" "$H" ${SHAPE[@]+"${SHAPE[@]}"}
    done < "$WORK/headlines-$lang.txt"
  done
done
echo "done: $OUT"
