---
title: "Press kit"
description: "Facts about OpenCaptions for writers and reviewers: what it is, what it costs, how it is built, and where to find the icon and screenshots."
sidebar:
  order: 9
---

# Press kit

Everything here may be quoted. The name and the icon may be used to write about OpenCaptions, as the
[trademark policy](https://github.com/leogaudin/opencaptions/blob/main/TRADEMARK.md) says.

## In one line

OpenCaptions adds animated, word-by-word captions to videos: on your iPhone with nothing uploaded, or on your own
server with one Docker file.

## The facts

| | |
|---|---|
| Maker | Léo Gaudin |
| Licence | AGPL-3.0 |
| First release | 3 November 2026 on the App Store, version 1.0.0 of the self-hosted stack on 4 November 2026, the Mac on 9 November 2026 |
| iPhone and iPad | [App Store](https://apps.apple.com/app/id6820548922), iOS 18 or later |
| Mac | [Mac App Store](https://apps.apple.com/app/id6820548922), macOS 15 or later on Apple silicon, the same purchase |
| Price | The app is free, up to 1080p at 30 fps with a small mark. Pro is one purchase with no subscription, 14,99 € at launch, and adds 4K, 60 fps, HDR and every look. Self-hosting is free. |
| Try it | [opencaptions.app](https://opencaptions.app), in the browser, with nothing to install |
| Source | [github.com/leogaudin/opencaptions](https://github.com/leogaudin/opencaptions) |
| Interface | 13 languages |
| Speech models | Whisper (about 100 languages), Parakeet (25 European languages), Apple Speech on iOS 26 |

## What is different about it

- **All of it is open source**: the app, the web editor, the server and the engine that draws the captions.
- **One engine draws everything.** A Rust engine runs in the browser as WebAssembly, in the app, and on the render
  server, so the preview and the export are the same code.
- **Nothing leaves the phone.** The app transcribes on the device, has no account, no analytics and no tracking. See the
  [privacy policy](https://github.com/leogaudin/opencaptions/blob/main/PRIVACY.md).
- **You can run it yourself**, on a server or a Raspberry Pi, with amd64 and arm64 images.

## What it does not have

No Android app. No emoji, B-roll or virality scoring. Fewer templates than hosted tools. The first transcription on
a phone is slow, while the model is prepared for the device.

## Images

- [The icon](https://github.com/leogaudin/opencaptions/blob/main/apps/ios/OpenCaptions/Resources/Assets.xcassets/AppIcon.appiconset/icon.png)
- [The web editor](https://github.com/leogaudin/opencaptions/blob/main/docs/screenshot.webp), on *Sprite Fright* by Blender
  Studio, CC BY 4.0

## Contact

[support@opencaptions.app](mailto:support@opencaptions.app)
