---
title: "The iPhone and iPad app"
description: "Caption a video on your iPhone or iPad with OpenCaptions, with on-device speech models, no account and no upload, or send the audio to your own server."
sidebar:
  order: 5
---

# The iPhone and iPad app

The app does everything the web editor does, on the phone: transcribe, style, fix words, retime, and
save a captioned video. There is no account and no server, and nothing is uploaded. It needs
**iOS 18** or later and works on iPhone and iPad.

:::note[Availability]
The app is being prepared for the App Store. Until it is there, you can
[build it from source](https://github.com/leogaudin/opencaptions/blob/main/apps/ios/README.md) with Xcode.
:::

## On the Mac

The same app runs on a Mac with Apple silicon (**macOS 15** or later), in one window with the editor
laid out wide: the video and the style controls side by side, the timeline under them. It does everything
the phone does, with the Mac's ways of doing it:

- **Import** a video by dragging it from Finder onto the window, with **File → Import Video…** (⌘O), or from Photos.
- **Click** the video to play or pause (the Space bar does too), **double-click** a word to fix it, **drag** the
  caption to move it (it snaps to the centre lines and the margins), and **pinch** on the trackpad to change its size.
- **Save…** asks where to put the captioned video, named after the project (⌘E opens the save options). Share and
  Photos are there too.
- **Settings** is a window of its own (⌘,).

One purchase of Pro covers the iPhone, the iPad and the Mac, with no account: it is the same App Store app.

## Make captions

1. **Add a video** from your photos. You see it with its length and size, and can rename it, before it is imported.
2. **Transcribe.** The sheet asks, as the web app does, for the speech model and then the language.
   The first use of a model downloads it, and a card shows the progress.
3. **Edit.** The video takes the screen with a compact timeline under it. Tap to play or pause. The corner button takes the picture full screen, leaving a smaller timeline under it.
   While paused, **drag** the caption to move it (it snaps to the centre lines and the margins, with a small haptic tick),
   **pinch** to change the size, and **double-tap** a word to fix it. Drag the edges of a caption on the
   timeline to retime it, pinch the timeline to zoom, and scrub by dragging it.
4. **Style.** Open the style controls: the same nineteen looks and the same settings as the web.
5. **Save.** Choose the size and frame rate. Videos are saved as H.264, or 10-bit HEVC when the video is HDR,
   and HDR videos stay HDR.

Your work is saved by itself, after a quiet moment and whenever you leave the app. There is no Save button.
Undo and redo are in the toolbar.

## Speech models on the phone

| Model | Download | Notes |
|---|---|---|
| **Whisper Small** | 217 MB | OpenAI's smaller, less precise model. |
| **Parakeet Redux** | 220 MB | NVIDIA's smaller, less precise model, for 25 European languages. It does worse in noise. The first time it is optimized for your device, which takes several minutes (see below). |
| **Whisper Large v3** | 627 MB | OpenAI's bigger model, the best all-round accuracy, for about 100 languages. |
| **Parakeet Ultra** | 632 MB | The default: NVIDIA's bigger model, fast, for 25 European languages. |
| **Apple Speech** | Built into iOS 26 and later | Needs nothing to download. |

Models are downloaded once and run on the phone.

**The first transcription is slower.** A model must be optimized for your device's Neural Engine before it runs
fast, and the screen says "Optimizing for this device…". It takes from about half
a minute (Parakeet Ultra on an M1 Mac) to several minutes (the biggest models on an older iPhone). The system keeps
the result, so every later load takes a few seconds. It is done again after an update of OpenCaptions or of
iOS or macOS, because the result belongs to that exact version of the app and of the system.

 Each model's row shows a few flags and how many more
languages it covers. **Settings** lists them with their size on disk, and you can delete the ones you do not
use. The language list follows the model, as it does on the web, and the model you chose last is the one
offered next time.

On iOS 26 and later, a save you started goes on when you leave the app, and its progress shows on the
lock screen and in the Dynamic Island, with a button to stop it. A transcription needs the app open, so keep
it on the screen until it finishes. If the speech model skips a loud stretch, a **second pass** re-reads it and keeps only the words two readings agree on.

## Use your own server instead

If you [run an OpenCaptions server](../self-hosting/installation.md) with a graphics card, the phone can send
the audio there for a faster transcription. The video itself never leaves the phone, only its audio, and
only if you set this up.

1. In the web app, open **Account** and create an API key in the **API keys** section. It comes with a
   QR code and a link.
2. On the phone, scan the QR code with the Camera and tap the banner that appears. Or open **Settings**,
   find **Where to transcribe**, and paste the link, or enter the address and the key.
3. Choose **Remote server** there. The app asks before it accepts a server from a link.

The app says whenever audio is about to be sent to a server, and names its host.

## Free and Pro

The free app has everything you need to caption a video and save it up to 1080p at 30 fps, with a small
mark in the corner. **Pro** is a single purchase, with no subscription: it removes the mark and adds 4K,
60 fps, HDR, and every caption style. The code is the same either way,
and a [build you make yourself](https://github.com/leogaudin/opencaptions/blob/main/apps/ios/README.md) has
everything unlocked.

## Privacy

The app has no analytics and no tracking. Your videos stay on the device. The only network requests are
model downloads, Google Fonts for a font that is not bundled, and the server you connect yourself. See the
[privacy policy](https://github.com/leogaudin/opencaptions/blob/main/PRIVACY.md).
