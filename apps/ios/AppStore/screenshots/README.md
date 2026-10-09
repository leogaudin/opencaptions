# App Store screenshots

How the store screenshots are made, so they can be rebuilt (a new look, a new headline, a new size)
without remembering anything. Three scripts, no manual steps:

| File | Does |
|---|---|
| `make-slides.sh` | The whole flow: build the debug app, make three clips and their transcripts, capture five screens in the simulator, compose the slides at every iPhone size. |
| `capture.sh` | One simulator screenshot of the debug app in a chosen state. |
| `compose.swift` | Puts a screenshot in a phone on a coloured background, with a headline above it. |

## Run it

You need Xcode with a simulator, `ffmpeg`, `python3`, and the three Pexels photos (below).

```sh
xcrun simctl boot "iPhone 18 Pro"     # the simulator must be booted
cd apps/ios/AppStore/screenshots
PHOTOS=~/path/to/pexels SIM="iPhone 18 Pro" OUT=~/path/to/out ./make-slides.sh
```

Most of the time is the simulator drawing each screen. It writes
`$OUT/iphone-<width>x<height>/01.png` to `05.png`, one folder per size, and keeps its working files
in `$OUT/work`.

## The five slides

| # | Screen | Headline (`|` ends a line, `[ ]` boxes the words) | Background |
|---|---|---|---|
| 1 | The editor with the style sheet open, a man mid-sentence | Captions that\|[stop the scroll] | yellow |
| 2 | The transcribe sheet | [Nothing] leaves\|your phone | dark |
| 3 | A Polish clip captioned (cooking, "Złóż ciasto nad farszem...") | About [100 languages].\|One tap. | yellow |
| 4 | The Save sheet, a cat | Up to [4K].\|HDR stays HDR. | dark |
| 5 | The finished caption on the cat | [Open source].\|Pay once.\|No subscription. | yellow |

To change a headline or a screen, edit the table in `make-slides.sh` (the `cap` and `c` lines).

## Sizes and where they go in App Store Connect

| Size | Slot |
|---|---|
| 1320 × 2868, 1290 × 2796 | iPhone 6.9" |
| 1284 × 2778, 1242 × 2688 | iPhone 6.5" |
| 1206 × 2622, 1179 × 2556 | "iPhone with Dynamic Island (medium display)" (6.3") |
| 2064 × 2752 | iPad 13" |

Each App Store slot takes one family of sizes: a picture of another size in a slot is refused with
"File dimensions are invalid". The PNGs must have no alpha (the composer draws on an opaque
background, so they have none).

The header art (3840 × 1646) and the search-results art (3:2) were made from the same screens with
a wider layout; they are not produced by these scripts.

## The iPad set

Same flow on the "iPad Pro 13-inch (M5)" simulator: `SIM="iPad Pro 13-inch (M5)"`, composed at
2064 × 2752 with a smaller corner radius, a smaller headline and a higher device:
`compose in.png out.png "<headline>" yellow|dark 2064 2752 0.035 0.072 0.29`. This path is not wired
into `make-slides.sh`.

## The debug app's launch switches

`capture.sh` starts the debug build with environment variables (passed as `SIMCTL_CHILD_*`), so the
app opens in a given state. They exist only in debug builds.

| Switch | Effect |
|---|---|
| `OC_TIER=free\|pro` | The tier (the screenshots use `pro`, so nothing is locked or watermarked). |
| `OC_RESET=1` | Start with no projects. |
| `OC_SEED_VIDEO=<file>` | Make a project from this clip on first launch. |
| `OC_SEED_TRANSCRIPT=<json>` | Give it this transcript (a file in the transcript schema) instead of none. |
| `OC_OPEN_FIRST=1` | Open the first project in the editor. |
| `OC_SEEK=<seconds>` | Move the playhead there (so a given word is lit). |
| `OC_SHOW_STYLE`, `OC_SHOW_SAVE`, `OC_SHOW_TRANSCRIBE`, `OC_SHOW_FONTS`, `OC_SHOW_IMPORT`, `OC_SHOW_CONNECT` | Open that sheet. |
| `OC_STYLE_TAB`, `OC_TAB=settings`, `OC_EDIT_WORD` | Pick a style tab, open Settings, open a word's editor. |

## The photos

The slides use three Pexels photos: a man mid-sentence
(`pexels-vincent-santamaria-194760512-37148334.jpg`), a cat
(`pexels-sefa-demirtas-2152709769-32557420.jpg`) and a hand cooking pierogi
(`pexels-elly-fairytale-3893708.jpg`). Pexels' licence allows using the images but not redistributing
them as they are, so they are not in the repository: download them from pexels.com by these names
and point `PHOTOS` at the folder.

## Reproducibility

Composing the same capture twice gives the same slide, byte for byte: the layout is fixed and the
caption-bar pattern in the background is seeded.

## Traps

- Compile `compose.swift` by its absolute path: the headline face (Poppins ExtraBold, bundled with
  the engine) is found from the file's own location, and with a relative path the face silently falls
  back to the system font and the slide differs.
- A simulator that was just booted, or low on disk, can show the home screen or a blank frame;
  `capture.sh` retries until a picture is large enough to be a real screen. If the disk is nearly
  full the capture can fail: `xcrun simctl erase all` frees gigabytes.
- A store screenshot shows only the app and images the project has the right to use.
