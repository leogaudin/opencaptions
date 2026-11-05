import Foundation
import Testing
@testable import OpenCaptionsKit

/// This build draws what the others draw: the scenes and their fingerprints are the file the engine's own
/// test writes, and `scripts/check-wasm-frames.mjs` holds the WebAssembly build to the same one.
extension EngineSuites {
    @Suite struct FramesTests {
        /// FNV-1a over a frame's bytes, as the engine's test takes it.
        func fingerprint(_ frame: Data, _ start: UInt64) -> UInt64 {
            frame.withUnsafeBytes { bytes in
                var h = start
                for byte in bytes { h = (h ^ UInt64(byte)) &* 0x100_0000_01b3 }
                return h
            }
        }

        @Test func everyLookIsByteForByteWhatTheOtherBuildsDraw() async throws {
            let engine = CaptionEngine.shared
            try await engine.registerBundledFonts(in: Repo.fonts)
            let file = Repo.root.appendingPathComponent("apps/engine/testdata/frames.json")
            let kept = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let times = try #require(kept["times"] as? [Double])
            let looks = try #require(kept["cases"] as? [[String: Any]])
            #expect(!looks.isEmpty)
            for look in looks {
                let input = try #require(look["input"] as? [String: Any])
                let (width, height) = (try #require(input["width"] as? Int), try #require(input["height"] as? Int))
                try await engine.setScene(json: JSONSerialization.data(withJSONObject: input))
                // A frame that did not change comes back as nil, and a new scene starts empty.
                var frame = Data(count: width * height * 4)
                var h: UInt64 = 0xcbf2_9ce4_8422_2325
                for t in times {
                    if let drawn = await engine.render(at: t) { frame = drawn.rgba }
                    h = fingerprint(frame, h)
                }
                let got = String(format: "%016llx", h)
                #expect(got == look["fingerprint"] as? String, "\(look["name"] ?? "?")")
            }
        }
    }
}
