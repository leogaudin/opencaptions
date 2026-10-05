// swift-tools-version: 6.0
import PackageDescription

// Everything testable lives here; the app target is SwiftUI views and wiring.
// `make ios-engine` builds the engine into ../Build/OpenCaptionsEngine.xcframework.
let package = Package(
    name: "OpenCaptionsKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "OpenCaptionsKit", targets: ["OpenCaptionsKit"]),
        .library(name: "OpenCaptionsTranscription", targets: ["OpenCaptionsTranscription"]),
    ],
    dependencies: [
        // Pinned exactly: a transcription change should be a deliberate bump.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.0"),
    ],
    targets: [
        .binaryTarget(name: "OpenCaptionsEngine", path: "../Build/OpenCaptionsEngine.xcframework"),
        .target(name: "OpenCaptionsKit", dependencies: ["OpenCaptionsEngine"]),
        // WhisperKit lives in its own target so the core tests do not build it.
        .target(
            name: "OpenCaptionsTranscription",
            dependencies: [
                "OpenCaptionsKit",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
        .testTarget(
            name: "OpenCaptionsTranscriptionTests",
            dependencies: ["OpenCaptionsTranscription"]
        ),
        .testTarget(
            name: "OpenCaptionsKitTests",
            dependencies: ["OpenCaptionsKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
