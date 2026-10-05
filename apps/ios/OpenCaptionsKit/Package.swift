// swift-tools-version: 6.0
import PackageDescription

// Everything testable lives here; the app target is SwiftUI views and wiring.
// `make ios-engine` builds the engine into ../Build/OpenCaptionsEngine.xcframework.
let package = Package(
    name: "OpenCaptionsKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OpenCaptionsKit", targets: ["OpenCaptionsKit"]),
    ],
    targets: [
        .binaryTarget(name: "OpenCaptionsEngine", path: "../Build/OpenCaptionsEngine.xcframework"),
        .target(name: "OpenCaptionsKit", dependencies: ["OpenCaptionsEngine"]),
        .testTarget(
            name: "OpenCaptionsKitTests",
            dependencies: ["OpenCaptionsKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
