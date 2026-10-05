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

`ios-test` and `ios-build` need `ios-engine` first. Open `apps/ios/OpenCaptions.xcodeproj`
in Xcode to run on a simulator or device.

## Layout

```
project.yml              # XcodeGen: the app target, signing, resources (the .xcodeproj is generated)
OpenCaptions/            # the app target: SwiftUI views and wiring only
OpenCaptionsKit/         # a Swift package with everything testable
  Sources/…  Tests/…
Build/                   # gitignored: the engine xcframework, DerivedData
```

The simulator slice is Apple-silicon only; Intel Macs are not supported.
