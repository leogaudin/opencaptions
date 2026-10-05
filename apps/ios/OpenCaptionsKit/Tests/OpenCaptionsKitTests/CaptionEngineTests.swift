import CoreImage
import Foundation
import Testing
@testable import OpenCaptionsKit

/// The engine holds one scene per process, so these must not interleave.
@Suite(.serialized) struct CaptionEngineTests {
    let engine = CaptionEngine.shared

    func scene(wordsPerLine: Int = 3, offsetMs: Int = 0) async throws {
        var style = try Repo.defaultStyle()
        style.wordsPerLine = wordsPerLine
        try await engine.registerBundledFonts(in: Repo.fonts)
        try await engine.setScene(
            transcript: Repo.transcript(), style: style, width: 270, height: 480,
            captionOffsetMs: offsetMs)
    }

    @Test func bundledFontsRegisterOnceAndInterIsOne() async throws {
        let families = try await engine.registerBundledFonts(in: Repo.fonts)
        #expect(families.contains("Inter"))
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
        await #expect(throws: EngineError(message: "one word at a time")) {
            try await engine.setWord(t, index: 0, text: "uno dos")
        }
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
