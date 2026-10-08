# OpenCaptions for iOS

The native app: everything runs on the phone, with no server and no accounts. It
reuses the caption engine (`apps/engine`) for drawing and edits, WhisperKit for
transcription, and AVFoundation for decode and encode. See
[`docs/DESIGN.md`](../../docs/DESIGN.md).

## Prerequisites (macOS only)

iOS work is **not** part of `make ci` and never required of a contributor who
doesn't touch it: everything else builds on Linux.

- Full Xcode (not just the Command Line Tools):
  `sudo xcode-select -s /Applications/Xcode.app && xcodebuild -runFirstLaunch`
- Rust 1.85+ with the Apple targets:
  `rustup update stable && rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin`
- `brew install xcodegen`

## Make targets

```bash
make ios-engine    # build the engine into apps/ios/Build/OpenCaptionsEngine.xcframework
make ios-test      # run the OpenCaptionsKit tests on the Mac (no simulator)
make ios-project   # generate OpenCaptions.xcodeproj
make ios-build     # build the app for the Apple-silicon simulator
```

`ios-test` and `ios-build` need `ios-engine` first. `OC_WHISPER_E2E=1 make ios-test` also runs one
test that downloads the `tiny` model and transcribes real speech (network, about a minute;
`OC_WHISPER_MODELS=<dir>` keeps the model between runs). Open `apps/ios/OpenCaptions.xcodeproj`
in Xcode to run on a simulator or device.

Transcription runs on the phone by default. Settings → "Where to transcribe" can point it at
another OpenCaptions server instead (paste the link the web app's Account page makes when you
create a key); see "Transcribing on a server" in `docs/DESIGN.md`.

## Layout

```
project.yml              # XcodeGen: the app target, signing, resources (the .xcodeproj is generated)
OpenCaptions/            # the app target: SwiftUI views and wiring only
OpenCaptionsKit/         # a Swift package with everything testable
  Sources/…  Tests/…
Build/                   # gitignored: the engine xcframework, DerivedData
```

The simulator slice is Apple-silicon only; Intel Macs are not supported.

## Releasing to the App Store

`make ios-upload` archives the `AppStore` configuration (Release plus the `APPSTORE` flag: it starts
free and sells Pro, see `Entitlements.swift`) and sends it to App Store Connect, where it appears in
TestFlight. The build number is the date and time (`IOS_BUILD=<n>` overrides it); the version is
`MARKETING_VERSION` in `project.yml`. It needs an active Apple Developer membership and the App ID
`org.leogaudin.opencaptions` with the In-App Purchase capability. `make ios-archive` stops before
the upload. The store text is in `AppStore/listing.md`, the privacy policy is `PRIVACY.md` at the
repository root, and `OpenCaptions/PrivacyInfo.xcprivacy` is the manifest the app ships.

Two things that stop an upload. The export runs with the system tools only on the `PATH` (Homebrew's
rsync does not take the flags Xcode gives it, and the export stops at "Copy failed"). And a certificate
that Apple holds in the cloud (the one Xcode makes by itself) signs a requirement that spells an accented
name differently from the certificate's own, which Apple's check refuses as "Invalid Signature": a team
named with an accent signs with a distribution certificate made from a signing request of your own, its
private key in the keychain, and exports with `IOS_EXPORT_OPTIONS=<a plist with signingStyle manual, the
certificate and the App Store profile>`.
