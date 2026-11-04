# Changelog

Every change to OpenCaptions, from its commit messages.
## 1.1.0 (2026-11-04)

### Documentation
- The images are published for arm64 now
- Use-case pages for the questions people actually ask: bold word-by-word captions, self-hosting instead of a subscription, Whisper with Docker, and green screen captions
- The listing's names and keywords work harder: a local name in each language, no word repeated from the name or subtitle, and the freed space used

### Features
- Ask for a rating when someone leaves their second finished video, once per version, and never after a failed save
- Settings links to the full licences and credits, which name Parakeet and FluidAudio too
- A video can come from outside the app: Open In from Files and other apps, and a Caption a Video action in Shortcuts, both landing on the import screen
- Scripts/asc.py checks the listing against Apple's limits and sends it to a draft version; What's New for 1.1 in 13 languages
- Text follows the system text size, secondary text passes contrast on every surface, and Apple's accessibility audit runs as a UI test

### Fixes
- Open In keeps the file in place, as macOS requires, so the Mac app builds again
- The editor no longer reads the dismiss action: since Open In it re-rendered the screen without end on iOS 26.7, which froze the app when a project opened

### Maintenance
- Edge images are built for arm64 too, so the default compose file runs natively on an Apple-silicon Mac

### Tests
- The transcribe sheet's way back is driven by real taps
## 1.0.0 (2026-11-04)

### Changes
- Own the caption timing offset
- Edit captions one word at a time
- Serialized engine state instead of per-thread
- Presets as shared data, default style from them
- One layout tree with a timeline dock
- Drop the transcript list; edits live on the preview and timeline
- A word edit keeps its inner spaces as one word; drop the pipeline version; pinch while dragging
- The preview draws only what changed while a video plays
- A pause is judged against the speaker's tempo, not a fixed number of seconds
- Drop the stray-mark joining, rename Edit text to Edit JSON, colour the JSON
- The web app is compressed, cached by what changes, and loads the editor on demand
- Captions with fades, shadows and glows draw 2 to 14 times faster, to the same pixel
- Drop key words and emphasis: the rule, the Key word toggle, the size setting and the C ABI call
- Engine maths read as ramp, lerp and named easing
- Split the scene into layout, animation, drawing, pixels and renderer
- One list of animations in the engine tests and the web types
- One segment builder for the transcription providers
- The editor fetches script fonts when a caption needs them
- The iPhone app does not keep Parakeet v3's id or files
- The preview's drawing and caption state is a core shared by the platform hosts
- Whisper's five tuning thresholds are constants, not settings, and the iOS debug launch switches are listed in one place
- The Whisper voice filter and second look, the Postgres port, the render server address and the entitlement policy are constants in the code, not settings
- The server drops Whisper's voice filter and second look, which were never on: the dead code and its tests are gone
- The render server works out its own fallback fonts and reads them from the API with the job's token
- The engine ABI holds one scene per handle, and the web page runs one WebAssembly module
- One catalog of API errors, raised and documented from the same entry
- CI is defined once: each check is a Makefile target in its pinned container, and GitHub runs the same list
- Transcription providers and engines are kept apart: local.py is the local provider, whisper.py an engine, and providers are registered in one place
- No CORS middleware (one origin), and password-reset links need PUBLIC_BASE_URL instead of falling back to a CORS origin
- A job always has an owner: jobs.user_id is required, and the project fallbacks are gone
- One Postgres driver: psycopg 3 for the API, the workers and Alembic, and asyncpg is dropped
- A project stores no status: the list reads it from the transcript and the transcription jobs, so a failed render no longer marks a project as an error
- Each animation's static facts (boxed, reach, lift, lights the word) are one entry in Animation::traits
- The web's API client is typed end to end: openapi-fetch over the generated paths, with CSRF, the 401 handler and the non-JSON guard as middleware
- One transcription choice on the web: a new project and a re-transcription use the same provider, model and language components
- The render server is behind a server feature and split into modules, so the library the apps link carries no HTTP stack

### Documentation
- Editor timeline and on-preview editing
- The app is built
- A leaner README, the rest moved to a self-hosting guide; test that the watermark stays put
- The store name is OpenCaptions: Auto Captions, and the subtitles no longer repeat it
- Update screenshot
- The README screenshot is a 54 KB WebP instead of a 1.2 MB PNG
- The README screenshot shows the sliding box over a public-domain clip
- Say why a transcription worker handles one job and exits
- Language identification result
- Qwen3-ASR 1.7B and 0.6B in bf16, measured; the int8 build misled
- What Whisper still skips, the Qwen int8 export, Omnilingual for the long tail
- The listening verdicts on the film's 18 empty stretches, scored
- A documentation set (quick start, guides, self-hosting, API and format reference, FAQ) with the design and the speech model report under docs/project
- The speech model report reads as a reference (results, settings, reasons), not as the story of the investigation; the compose file's comments are short
- The architecture page is reordered (the engine, the editors, transcription, languages, then the iOS app in sections) with its run-on paragraphs as lists; the docs commands in Contributing are the make targets
- Seventeen looks, and the architecture names the new ones
- Parakeet Ultra and Redux on the phone, the Photon licence, and credit for the Parakeet models in NOTICE
- Parakeet Ultra on the server and as its default, with the measurements against v3 and Whisper Large v3 Turbo
- Donation addresses with QR codes in the README, and the documentation link at the top
- The API's errors are not claimed to be RFC 9457, and the transcription routes are tagged
- The caption engine has its own page, the architecture page stays an overview, and the animations are a table of eighteen
- The privacy policy says outright that there is no face data, names Apple's speech model, and says a remote server may use a speech service of its own
- The app is out: the README and guides link to it, say what is not on the Mac yet, explain Pro, and the screenshot shows the current editor on an animated film

### Features
- Transport controls in the timeline dock
- Full-width timeline with ruler, tracks and zoom
- Magnetism toward the video's centre lines
- Project skeleton
- Models and the caption engine binding
- Projects stored as files
- On-device transcription with WhisperKit
- The editor's logic layer
- The editor: projects, preview, timeline and style
- Save the captioned video
- Keep HDR sources HDR on save
- Magnetism toward the video's centre lines
- Video-first editor, and a transcription that outlives its screen
- A look of its own
- Light and dark, a tighter header, and a card for editing a word
- Settings tab, a confirmation before importing, and a sturdier save
- Twenty presets in the style of short-form editors
- Trim the model list and default to Large v3 Turbo; fix Save to Photos trap, thumbnail crop
- Keep ten presets; recolour Sunset, set Terminal in JetBrains Mono
- Preset tiles drawn by the engine, a font picker with previews and Google Fonts, and refilling missed speech
- HDR captions at twice reference white, an easier drag, and renaming
- Several words in one word edit, pinch to resize, presets keep position and size
- Save options (format, size, quality, HDR or SDR) and a cache key that knows the pipeline
- The iOS app's look
- A transcription API, and a provider that uses another instance's
- Choose another OpenCaptions server to transcribe on, and pair a phone to this one
- Transcribe on another OpenCaptions server
- Centered confirmations, and a project's size on its card
- A simpler server setting, a one-off source in Transcribe, rename from home only
- The caption follows the fingers live, and the gestures are tested on a simulator
- IOS parity on the home page and style panel, a QR for pairing, and visual fixes
- A frame rate choice when saving
- Size, quality and frame rate when downloading
- The presets in a sideways strip, as on iOS
- Purple Punch is the default, and saving has no quality choice
- Any frame rate when saving, also above the source's
- Preset tiles on a plain card, and the tab bar's content fades into the page
- The playhead stays in the middle and the timeline moves, with undo and redo
- Inline pickers, one tab bar fade, a Download dialog on the web, and a drag then pinch that stays put
- The style panel in tabs on iOS and the web, with tiles for background and animation
- Tiles in a grid that fills the width, no em dashes, and a drag that ignores a second finger
- Faster model load, words per line stay with the video, room under the tab bar, steadier drag
- A free tier with a watermark and limits, and the interface in French, Spanish and German
- Captions in Arabic, Hebrew, Devanagari and Thai
- Asian fonts on demand, twelve interface languages, a price on the Pro sheet, and fixes
- Short labels for automatic language, Subtle among the free styles, a steadier watermark, larger caption sizes, and fixes
- Pinch anywhere around the video, and a drag that follows the finger
- Medium is back, saved videos are called cached videos, the export buttons share a height, and the language guess goes in the diagnostics
- Any save size or frame rate can be chosen, Medium is removed, and the App Store build, privacy manifest, privacy policy and store text are in place
- Karaoke, typewriter and underline animations, a hard extruded shadow, glow, upper case and italic, with six new presets: Karaoke, Bold, Neon, Typewriter, Handwritten and Elegant
- Bold is Montserrat in capitals with a thick black outline carried out into a black shadow, as in the promo video
- Bold draws in Montserrat Black, bundled with the engine like Poppins
- The engine refuses a render that does not carry the token it shares with the render worker
- Eight new caption looks and a green screen export
- Sizes and frame rates are listed as numbers, smallest first, and the launch screen carries the logo
- A Pro row in Settings, the App Review notes, and the store screenshots as a script
- Sunset is removed and Subtitle becomes Plain
- A style has a list of highlight colours, the first being the primary
- Undo and redo, an editable transcript text with subtitle import, flat timeline clips
- The render server refuses what it cannot draw, sends FFmpeg only the captions' box, and cleans up after itself
- Theme choice (system, light, dark) moves to the account settings
- Public demo site for opencaptions.app (Cloudflare Pages)
- Demo polish (system theme, Inter, sound button, autoplay on clip change, icons); reject non-JSON API answers
- Demo clip tooling (make-demo-clip.sh) and per-clip credits in the footer
- A model registry and a second local engine, Parakeet v3 on sherpa-onnx
- Parakeet v3 and Apple SpeechTranscriber beside Whisper (uncompiled)
- An opt-in second look at long empty stretches of a Whisper transcript
- The gap fill reads each stretch twice and keeps what both readings agree on
- Whisper Small and Large v3 Turbo only, default kept loaded; Pro sheet spinner, auto-dismiss and plain buttons; monospaced times
- Transcribe in two steps (where and model, then a flagged language list that follows the model); SpeechModel naming; download card first
- A model's source is shown as an icon (Hugging Face, built into iOS)
- The demo is one looping clip, Sprite Fright (14 s, 720x1280, 1.4 MB)
- The public demo is readable without script: prerendered page, structured data, icons, link preview, crawler files
- The demo page in every language (/fr/, /es/, ...), and copy that names the speech models
- The demo page's outside links open in a new tab
- Boom grows less and is drawn over its neighbours, Lyric no longer zooms, Handwritten gets a marker stroke; Documentary, Gradient and Elegant are gone; Bold second, Paper fifth
- No auto language (the language is always chosen, from the model's list, starting with the device's), no source logos on the models
- The web upload is two steps like the iPhone's (video, provider and model, then a searchable flagged language list that follows the model); no auto language; the API says which languages a model takes
- The gap-filling step reads 'Second pass (n of m)'; the progress bars and spinners are drawn in black and an outlined yellow so they show on a light background
- The demo video pauses while its tab is hidden or it is scrolled out of view
- A Docusaurus site builds the documentation (apps/docs, the pages are docs/), checked by CI and by make ci
- The documentation site is Starlight instead of Docusaurus (485 packages instead of 1316, near-zero JavaScript per page), with the pages still plain Markdown that GitHub shows
- The web and the server offer the iPhone's models (Small, Parakeet, Large v3 Turbo, Large v3), and Re-transcribe asks for the model first, the language below it
- The demo, the README and llms.txt link the documentation site, docs.opencaptions.app
- Motion blur averages eight sub-frames within a shutter of 1/30 s, so moving words smear alike in the preview and the export (default 0.5, Bold 0.6, Boom 0.8, Stickers 0.6, Lyric off), and the shadow offset reaches 40
- Gradient fills, shaded extrusion and the Press animation, with the Chunky 3D look; Bold and Boom take a shaded extrusion
- The Rise animation lifts each word's letters into place one after another (a connected script's word as one piece), with the Cascade look
- Key words (a rule the user overrides with a Key word toggle) are set larger on a row of their own, and the Slam animation drops each word in and jolts the line, with the Slam look
- The Stack layout sets short rows each scaled to the widest one's width, and every animation follows each word's own size, with the Poster look
- The iPhone editor goes full screen from a corner button; the settings drop the spoken language, which follows the last one used; the progress bar loses its outline
- Full screen shrinks the timeline to a ruler and the captions
- Chunky 3D lifts the word being said off a back that stays put, with an extrusion that fades to a back colour; Slam goes without motion blur
- The Drift animation brings words into focus out of a blur, floats the line and brightens the glow of the word being said, with the Glow Intro look
- The iPhone app offers Parakeet Ultra in place of Parakeet v3, and Parakeet Redux as the small download
- The server runs Parakeet Ultra, and makes it the default model
- Parakeet Ultra first on the phone, motion blur and the second Large v3 removed, Pop preset, steadier Slam, model download progress
- A transcription or a save goes on when the user leaves the iPhone app, with progress on the lock screen
- Alignment, letter spacing and stretch, a square background, and the Title Card preset in a bundled Times-style bold
- The app builds for macOS: one multiplatform target, macOS 15, a sandbox, and the platform differences in one file
- A dragged caption snaps its start, middle and end to the margins and the centre, across and down
- The Mac window, menus, Finder import and save panel, trackpad editing, and the Mac archive and upload targets
- Title Card has a faint white glow
- A caption can mix looks word by word, with a BlurIn entrance and a bundled serif
- Editorial preset, and a word can be given one of a preset's looks from the word card
- Picking a preset with looks deals them to the words at random, and Shuffle looks deals again
- Subtitles are written by the engine: cues are the caption lines, with the offset, and the iOS Save sheet shares SRT and VTT
- The site leads to the App Store: its buttons, structured data, Safari's app banner, and short /app, /privacy and /support addresses

### Fixes
- Apply the caption offset to SRT and VTT exports
- Keep a caption drag alive across scene updates
- Chown the cargo cache volume before the engine targets use it
- Transcribe in the spoken language and show real progress
- Play sound
- Stop the save from freezing on a clip with sound
- Calmer transcription, and a model list that reads as one choice
- Fewer Whisper retries per window, so music no longer stalls for long
- HDR captions near the top of the range, so they are brighter than the picture's own whites
- No Dolby Vision metadata in an HDR export, and Save checks there is room
- A failed image build fails the local gate
- A saved HDR video's captions a little brighter
- Grabbing the caption right after tapping play
- A pinch grows the caption about itself, wherever it is
- The watermark stays put under a drag, a pinch lays the caption out live, iPhone is portrait only
- Wider touch areas on the editor's selectors, a big caption's drag and pinch land where the engine puts it, models load as soon as they are downloaded, and the first load says it is slow
- A phone's transcriptions count in the account's usage, the language choice moves to the Account page, the Transcribe sheet can connect or change the server, and the export buttons share a height
- An unsure language guess asks which language it is instead of forcing the guess on the model
- The upload runs with the system tools so Xcode's rsync works, takes another export plist, and the README says why an accented team name needs its own certificate
- The Pro sheet says when the price is loading or unavailable and offers another try, asks the store again when it opens, and puts Restore purchases and Not now side by side
- The diagnostics say why the store offered no Pro product
- A sweep leaves no pale fringe, the multicolour palette is gone, the timeline panel is flat, and a green screen has no sound
- Bold lights its word in yellow again
- Cancelling a server transcription is always a cancellation, however far its request had got
- The preview draws the captions at the size it is shown, whatever the video's resolution
- English purpose strings for Photos and local network were the raw key names
- Outlines, shadows and glows keep their weight when the letters pass 100
- A caption never joins words said a second or more apart
- Transcription stages are stored, stray marks rejoin their word, segments end at long pauses
- A caption's edge can be dragged past a neighbour it touches
- A failed save no longer replaces the editor, saves never overlap, and uploads show progress
- The API no longer blocks on password hashing, fails live jobs at boot, or cuts long tasks short
- The phone no longer lays the captions out again after every save, and does less while it saves
- The demo dev server serves the demo at /, not the application
- Demo dev server builds the engine assets; dark by default; feature sections
- Decode everything by default, voice filter off
- Clippy 1.99 prefers as_chunks to chunks_exact with a constant size
- The demo's dev server fills in the page's head only (the body showed unstyled until the script loaded its styles)
- The compose file pulls the edge images until the first release (there is no latest tag yet, so the one-file start failed)
- Words a speech model invents past the end of the video are dropped (and a transcript left empty is 'no speech')
- The upload page's Next button no longer submits the form as it turns into Create project
- The colour pickers keep the colour they are given while open, instead of being written back to the style's older one (which lost the choice)
- Make docs starts on a fresh checkout (the update check restarted the dev server and lost the pages)
- A caption block wider than the frame is centred and spills over both sides, not out of the right
- The engine library exports only its oc_ functions, so linking it beside FluidAudio's Rust library no longer finds _rust_eh_personality twice
- The timeline panel is as tall as its content, no Fit button, presets two to a row beside the video, Projects and Speech models translated, the language list scrolls to the download, and the import shows its progress and does not copy the video twice
- Letters rise at their word's own size and finish sooner, Slam drops in and blurs less, and Chunky 3D extrudes and colours only the word being said
- A transcription needs the iPhone app open again, since the speech models stop when it leaves the screen
- Preset tiles draw a left or right aligned look centred in its tile, not from the middle of it
- The Pro description no longer promises a speech model that Pro does not lock
- A glow is drawn under the extrusion and surrounds it, so Pop's soft shadow sits below everything
- A test's JSON literal uses a raw string that can hold its own quotes
- The Editorial preset's small words use a light condensed italic, since a variable face is always drawn heavy
- Only transcription models the local provider lists are accepted from a client
- A render prunes only its own format, which has a folder of its own in storage
- The render hash includes the engine's render revision, and is one sorted JSON object
- Editorial's accent word follows the highlight colour, and the background look and the Glow Intro preset are gone; the subtitle exports sit in a menu, the optimizing text is shorter, the language step's back arrow is a plain flag
- The API's render revision follows the engine's, and the Editorial test knows its four looks

### Maintenance
- Script the Apple xcframework
- Debug launch options for simulator screenshots
- Build and test the app on macOS
- The local gate builds each image once, skips the GPU one unless it changed, and cleans up
- Upgrade what Dependabot proposed
- Icon in the README and as the favicon, no Why section, fewer READMEs, a build crash on CI's compiler worked around
- Make ios-ipa exports the signed file, the upload takes an API key, and the export signs with a certificate whose key is in the keychain
- CI caches what it builds and stops what is superseded, the images build leaner, and compose says things once
- Demo clips are cut at 1080x1920
- Remove Dependabot
- Deploy the demo as a Cloudflare Worker with static assets (Pages is in maintenance)
- After publishing, start the compose file alone, from the published images, and check the app answers
- Publish-docs deploys the documentation site to a Cloudflare Worker on main, like the demo (apps/docs/wrangler.jsonc)
- The local CI checks free disk first, runs the browser tests without the multi-GB Playwright image, and keeps 2 GB of build cache
- Translations, the store listing and a test use the ASCII apostrophe
- Lint suppressions work: BLE and RUF100 are selected, so a broad except is a decision and an unused noqa fails
- Make release VERSION=x.y.z prepares a release without making it: manifests, a git-cliff changelog, and the tag commands
- Scripts/asc.py reads App Store Connect from the command line, with nothing to install and the key kept outside the repository
- Release 1.0.0, the version the App Store shows: a changelog from the commits, the first tagged images, and a release script that names the right git-cliff image

### Tests
- Cover editing a word on the preview
- Serialize every suite that uses the engine's scene
- Do not look for an <option> to be visible
- Let the timeline finish coasting before checking that it rests
- A check fails when an iOS purpose string is missing or is its own key name
- Retiming past a neighbour pushes it along, as the engine now does
- The fast-drag test expects the engine's rolling edit
- Parakeet and Apple's model transcribe real speech (opt-in, with the Whisper one)
- The shared transcription fixture lists each model's languages
- The language search spec looks for German by its name
- Assertions wait up to 15 s, since the preview's video and engine start slowly when workers share a machine
- Token mapping and second look held to shared fixtures in Swift and Python
- E2E waits on state instead of fixed delays
- The animation, flag and Parakeet language lists are written once and tested on every side
- An accent word is drawn in the highlight colour, whatever the highlight is, through the Swift engine path

### Revert
- Leave the encoder's Dolby Vision metadata on, as the source has it

### Style
- Ruff format
