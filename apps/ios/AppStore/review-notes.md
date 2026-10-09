# App Review notes

The notes sent to App Review with each version (App Review Information, "Notes"). They describe the
app as a reviewer meets it, and stay in line with `Entitlements.swift` and the Pro screen. No sign-in
is needed, so the sign-in fields stay empty.

---

OpenCaptions adds animated, word-by-word captions to a video. It has no accounts and nothing to sign in to.

HOW TO TRY IT
1. Tap + on the Projects screen and pick any video with speech from Photos.
2. Tap Transcribe, choose the language (or leave it on automatic) and tap the button. Speech recognition runs on the device. The first time, the app downloads the speech model it needs (by default "Large v3 Turbo", about 627 MB; a smaller one, about 217 MB, can be chosen in Settings), so an internet connection is required once, and Wi-Fi is advisable.
3. Pick a look in the style sheet, move the caption on the video, tap a word to correct it, and use Save to export the captioned video to Photos.

IN-APP PURCHASE
"OpenCaptions Pro" is a single non-consumable purchase (product ID org.leogaudin.opencaptions.pro). The app is fully usable without it: free users can transcribe, caption, and save up to 1080p at 30 fps (with a small mark in the corner), with five styles. Pro unlocks the other styles, saving above 1080p or above 30 fps, keeping HDR, saving without the mark, and the largest speech model.
You can reach the purchase screen from Settings (the first row, "OpenCaptions Pro", then "Unlock Pro"), or by tapping anything marked as Pro: a locked style in the style sheet, a locked size, frame rate or HDR choice in the Save sheet, or a locked speech model. "Restore purchases" is on the same screen.

OPTIONAL FEATURE YOU CAN IGNORE
Settings has an optional "Where to transcribe" section for people who run their own OpenCaptions server (the app is open source, AGPL-3.0). It is not needed for any feature, and the local network permission exists only for that option.

NETWORK AND PRIVACY
No account, no analytics, no tracking, and videos and transcripts stay on the device. The app contacts the internet only to download the speech model once and, when a style uses a font that is not built in, to fetch that font from Google Fonts. The privacy policy is at https://github.com/leogaudin/opencaptions/blob/main/PRIVACY.md. The app uses only standard encryption provided by the system (ITSAppUsesNonExemptEncryption is set to NO).

Source code: https://github.com/leogaudin/opencaptions

---
