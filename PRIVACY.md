# Privacy Policy

*Last updated: 8 October 2026. Applies to the OpenCaptions iPhone and iPad app. The self-hosted web
app runs on your own server and keeps nothing anywhere else; see [docs/SELF-HOSTING.md](docs/SELF-HOSTING.md).*

OpenCaptions does not collect your data. There is no account, no analytics, no advertising, and no
tracking, and the app has no servers of ours to send anything to.

## What stays on your phone

- **Your videos and captions.** Projects live in the app's own storage on your device. Transcription
  runs on the phone, with a speech model that has been downloaded to it.
- **Your settings**, such as the language you chose and your last save options.
- **A diagnostics log** of what the app did (launches, exports, errors), kept on the phone. It is
  never sent anywhere. If you choose *Share diagnostics* in Settings, you decide where it goes.

## What the app asks the internet for

Only when you use the feature that needs it, and always from your phone straight to the service, never
through us:

| When | Who is contacted | What they receive |
|---|---|---|
| You download a speech model | Hugging Face | The request for the model file (your IP address, as with any download) |
| You use a font that is not built in | Google Fonts (`fonts.google.com`, `fonts.googleapis.com`, `fonts.gstatic.com`) | The request for that font (your IP address) |
| You buy Pro | Apple (App Store) | Apple handles the purchase under its own terms. We receive no payment or personal details. |
| You turn on **Remote server** | The OpenCaptions server **you** connect | The audio of the video you transcribe, to transcribe it there |

The remote server option is off until you set it up. It is for people who run their own OpenCaptions
server, or one they trust. That server deletes the audio when the job ends and the transcript after a
time its operator sets (24 hours by default). Treat it like any service you send audio to: only connect
to servers you trust. The app asks before it accepts a server from a link.

## Photos

The app asks only for permission to **add** videos to your Photos library when you save one. It cannot
read your library; you pick videos to import through the system picker, which gives the app only the
videos you choose.

## Children

The app collects no data from anyone, including children.

## Changes

If this ever changes, the new policy is published here, with the date above updated, before the app
changes. The history is in this file's git log.

## Contact

Questions about privacy: [open an issue](https://github.com/leogaudin/opencaptions/issues), or use
[private vulnerability reporting](https://github.com/leogaudin/opencaptions/security/advisories/new) for
anything sensitive.

OpenCaptions is open source (AGPL-3.0): everything stated here can be checked in the code.
