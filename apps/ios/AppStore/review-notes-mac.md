# App Review notes, Mac

`review-notes.md`, for the Mac version: the same rules, with what differs on a Mac. `scripts/asc.py push-notes
<version> mac` sends what lies between the two rules.

---

OpenCaptions adds animated, word-by-word captions to a video. It has no accounts and nothing to sign in to. This is the first Mac version of the iPhone and iPad app already on the App Store, under the same App Store record, so one purchase of Pro covers all three. It needs an Apple silicon Mac and macOS 15 or later.

HOW TO TRY IT
1. Click + in the Projects window, or choose File > Import Video... (Command-O), and pick any video with speech.
2. Click Transcribe, choose the model and click Next, then choose the spoken language and click the button. Speech recognition runs on the Mac. The first time, the app downloads the speech model it needs (by default "Parakeet Ultra", about 632 MB; a smaller one, about 217 MB, can be chosen in Settings), so an internet connection is required once.
3. Pick a look in the style panel, move the caption on the video, click a word to correct it, and choose File > Export... (Command-E) to make the captioned video. It can then be saved to a file you choose, shared, or added to Photos.

IN-APP PURCHASE
"OpenCaptions Pro" is a single non-consumable purchase (product ID org.leogaudin.opencaptions.pro), the same one as on the iPhone and iPad. The app is fully usable without it: free users can transcribe, caption, and save up to 1080p at 30 fps (with a small mark in the corner), with five styles. Pro unlocks the other styles, saving above 1080p or above 30 fps, keeping HDR and saving without the mark.
You can reach the purchase screen from Settings (Command-comma, the first row, "OpenCaptions Pro", then "Unlock Pro"), or by clicking anything marked as Pro: a locked style, or a locked size, frame rate or HDR choice when saving. "Restore purchases" is on the same screen.

OPTIONAL FEATURE YOU CAN IGNORE
Settings has an optional "Where to transcribe" section for people who run their own OpenCaptions server (the app is open source, AGPL-3.0). It is not needed for any feature.

SANDBOX
The app is sandboxed. It reads and writes only the files you pick in the system's open and save panels, connects out to download what is described below, and asks for access to Photos only to add a video you chose to save there.

THIRD-PARTY AI AND FACE DATA
No third-party AI service is built into the app. Transcription runs on the device, with open speech models downloaded once from Hugging Face and then used offline, or Apple's on-device speech model. The app collects no face data: it has no face detection or recognition, and does not use the camera, ARKit or Face ID. The privacy policy covers both, under "Face data" and "Third-party AI".

NETWORK AND PRIVACY
No account, no analytics, no tracking, and videos and transcripts stay on the device. The app contacts the internet only to download the speech model once and, when a style uses a font that is not built in, to fetch that font from Google Fonts. The privacy policy is at https://github.com/leogaudin/opencaptions/blob/main/PRIVACY.md. The app uses only standard encryption provided by the system (ITSAppUsesNonExemptEncryption is set to NO).

Source code: https://github.com/leogaudin/opencaptions

---
