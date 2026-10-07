import CoreImage
import Foundation
import Testing
@testable import OpenCaptionsKit

/// The engine holds one scene per process, so these must not interleave.
extension EngineSuites {
    @Suite struct CaptionEngineTests {
        let engine = CaptionEngine.shared

        func scene(wordsPerLine: Int = 3, offsetMs: Int = 0) async throws {
            var style = try Repo.defaultStyle()
            style.wordsPerLine = wordsPerLine
            try await engine.registerBundledFonts(in: Repo.fonts)
            try await engine.setScene(
                transcript: Repo.transcript(), style: style, width: 270, height: 480,
                captionOffsetMs: offsetMs)
        }

        @Test func sampleFramesDrawEachStyleAndLeaveTheSceneInUseAlone() async throws {
            try await scene()
            let before = try #require(await engine.render(at: 1.0))
            let plain = try Repo.defaultStyle()
            var big = plain
            big.highlightColor = "#FF0000"
            big.fontSize = 90
            let frames = await engine.samples(of: [plain, big], words: ["Make", "it", "pop"], width: 600, height: 300)
            #expect(frames.count == 2)
            let (a, b) = (try #require(frames[0]), try #require(frames[1]))
            #expect(a.width == 600 && a.height == 300)
            #expect(a.rgba != b.rgba, "different styles draw differently")
            #expect(a.rgba.contains { $0 != 0 }, "something is drawn")
            // The editor's scene is back: drawing the same time gives the frame it gave before.
            let after = try #require(await engine.render(at: 1.0))
            #expect(after == before)
        }

        @Test func aWatermarkIsDrawnByTheEngineInTheTopRightOfEveryFrame() async throws {
            try await engine.registerBundledFonts(in: Repo.fonts)
            let style = try Repo.defaultStyle()
            func frame(_ mark: String?) async throws -> CaptionFrame {
                try await engine.setScene(
                    transcript: Repo.transcript(), style: style, width: 540, height: 960,
                    captionOffsetMs: 0, watermark: mark)
                return try #require(await engine.render(at: 100))  // no caption is showing
            }
            let plain = try await frame(nil)
            #expect(!plain.rgba.contains { $0 != 0 })
            let marked = try await frame(Entitlements.watermarkText)
            var corner = 0
            for (i, byte) in marked.rgba.enumerated() where i % 4 == 3 && byte != 0 {
                let (x, y) = ((i / 4) % 540, (i / 4) / 540)
                #expect(x > 200 && y < 120, "only in the top right: \(x),\(y)")
                corner += 1
            }
            #expect(corner > 100)
        }

        @Test func bundledFontsRegisterOnceAndInterIsOne() async throws {
            let families = try await engine.registerBundledFonts(in: Repo.fonts)
            #expect(families.contains("Inter"))
            #expect(families.contains("Poppins"), "the default preset's font ships with the engine")
            #expect(try await engine.registerBundledFonts(in: Repo.fonts) == families)
            #expect(await engine.hasFont("Inter"))
            #expect(await engine.hasFont("No Such Family") == false)
        }

        @Test func aSceneDrawsAFrameAtAWordAndNothingInALongGap() async throws {
            try await scene()
            let frame = try #require(await engine.render(at: 0.7))
            #expect((frame.width, frame.height) == (270, 480))
            #expect(frame.rgba.count == 270 * 480 * 4)
            #expect(frame.rgba.contains { $0 != 0 })
            let again = await engine.render(at: 0.7)
            #expect(again == nil, "unchanged since the last call")
            let gap = try #require(await engine.render(at: 2.2), "the gap clears the line")
            #expect(gap.rgba.allSatisfy { $0 == 0 })
            #expect(await engine.activeCaption() == nil)
        }

        @Test func theActiveCaptionReportsItsWordsInFrame() async throws {
            try await scene()
            _ = await engine.render(at: 0.7)
            let caption = try #require(await engine.activeCaption())
            #expect(caption.index == 0)
            #expect(caption.words.count == 3, "one two three")
            #expect(caption.words.allSatisfy { $0.x >= 0 && $0.x + $0.width <= 270 })
            let first = caption.words[0]
            #expect(caption.bounds.contains(x: first.x + 1, y: first.y + 1))
        }

        @Test func theOffsetShiftsWhenALineShows() async throws {
            try await scene(offsetMs: 500)
            _ = await engine.render(at: 0.7)
            #expect(await engine.activeCaption() == nil, "line one now starts at 1.0")
            _ = await engine.render(at: 1.2)
            #expect(await engine.activeCaption() != nil)
        }

        @Test func aSceneTheEngineRejectsThrowsItsReason() async throws {
            var style = try Repo.defaultStyle()
            style.textColor = "red"
            await #expect(throws: EngineError.self) {
                try await engine.setScene(
                    transcript: Repo.transcript(), style: style, width: 270, height: 480,
                    captionOffsetMs: 0)
            }
        }

        @Test func theCaptionSnapsToTheCentreLinesWithinThePull() async throws {
            // A 400 x 800 pt preview with 8 pt of pull: 0.02 across, 0.01 down.
            let near = await engine.snapPosition(x: 0.51, y: 0.84, width: 400, height: 800, threshold: 8)
            #expect(near == SnappedPosition(x: 0.5, y: Double(Float(0.84)), onX: true, onY: false))
            let both = await engine.snapPosition(x: 0.49, y: 0.505, width: 400, height: 800, threshold: 8)
            #expect(both == SnappedPosition(x: 0.5, y: 0.5, onX: true, onY: true))
            let free = await engine.snapPosition(x: 0.53, y: 0.52, width: 400, height: 800, threshold: 8)
            #expect(!free.onX && !free.onY && abs(free.x - 0.53) < 1e-6)
        }

        @Test func linesAreCutLikeTheExportAndShowShiftedTimes() async throws {
            let t = try Repo.transcript()
            let lines = try await engine.lines(t, wordsPerLine: 3, offsetMs: 0)
            #expect(lines.map(\.text) == ["one two three", "four"])
            #expect(lines[0].from == 0 && lines[0].count == 3 && lines[1].from == 3)
            let shifted = try await engine.lines(t, wordsPerLine: 3, offsetMs: 500)
            #expect(abs(shifted[0].start - 1.0) < 1e-5 && abs(shifted[0].end - 2.2) < 1e-5)
        }

        @Test func retimingStopsAtNeighboursAndWritesUnshiftedTimes() async throws {
            let t = try Repo.transcript()
            let past = try await engine.retimeWord(t, index: 2, edge: .end, time: 3.5, offsetMs: 0)
            #expect(abs(past.words[2].end - 2.6) < 1e-5, "stops at four")
            let shown = try await engine.retimeWord(t, index: 2, edge: .end, time: 2.1, offsetMs: 500)
            #expect(abs(shown.words[2].end - 1.6) < 1e-5, "unshifted on write")
            let start = try await engine.retimeWord(t, index: 0, edge: .start, time: 0.2, offsetMs: 0)
            #expect(abs(start.words[0].start - 0.2) < 1e-5)
        }

        @Test func aWordIsRenamedDeletedOrRefused() async throws {
            let t = try Repo.transcript()
            let renamed = try await engine.setWord(t, index: 2, text: "  tres ")
            #expect(renamed.words[2].text == "tres" && renamed.words[2].start == t.words[2].start)
            #expect(renamed.words[2].confidence == t.words[2].confidence)
            let removed = try await engine.setWord(t, index: 1, text: "")
            #expect(removed.words.map(\.text) == ["one", "three", "four"])
            #expect(removed.segments[0].text == "one")
            let spaced = try await engine.setWord(t, index: 0, text: " uno   dos ")
            #expect(spaced.words.map(\.text) == ["uno dos", "two", "three", "four"], "spaces inside stay: one word")
            #expect(spaced.words[0].start == t.words[0].start && spaced.words[0].end == t.words[0].end)
            await #expect(throws: EngineError.self) {
                try await engine.setWord(t, index: 9, text: "x")
            }
        }

        @Test func aFrameBecomesAPremultipliedCoreImageImage() throws {
            // One straight-alpha pixel: (200, 100, 50) at alpha 128.
            let frame = CaptionFrame(width: 1, height: 1, rgba: Data([200, 100, 50, 128]))
            let off = NSNull()
            let context = CIContext(options: [.workingColorSpace: off, .outputColorSpace: off])
            var out = [UInt8](repeating: 0, count: 4)
            context.render(
                frame.ciImage, toBitmap: &out, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8, colorSpace: nil)
            // Premultiplied: each colour scaled by 128/255.
            #expect(out[3] == 128)
            #expect(abs(Int(out[0]) - 100) <= 2 && abs(Int(out[1]) - 50) <= 2 && abs(Int(out[2]) - 25) <= 2)
        }
    }
}
