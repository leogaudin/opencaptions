import Foundation
import Testing
@testable import OpenCaptionsKit

enum Repo {
    /// The checkout this test file lives in (apps/ios/OpenCaptionsKit/Tests/<target>/<file>).
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()
    static let fonts = root.appendingPathComponent("apps/engine/fonts")
    static let presets = root.appendingPathComponent("apps/web/src/lib/presets.json")

    static func transcript() throws -> Transcript {
        let url = Bundle.module.url(forResource: "transcript", withExtension: "json", subdirectory: "Fixtures")!
        return try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
    }

    /// The application default: the first preset, as the web and the API have it.
    static func defaultStyle() throws -> StyleConfig {
        try Presets.load(from: presets)[0].config
    }
}

/// The engine holds one scene for the whole process, so every suite that sets a scene or
/// exports must run one at a time, against the others too (a serialized suite only orders
/// its own tests). The app never has two at once; the tests are what must be told.
@Suite(.serialized) enum EngineSuites {}
