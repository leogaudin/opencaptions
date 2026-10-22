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
            big.highlightColors = ["#FF0000"]
            big.fontSize = 90
            let frames = await engine.samples(of: [plain, big], words: ["Make", "it", "pop"], width: 600, height: 300)
            #expect(frames.count == 2)
            let (a, b) = (try #require(frames[0]), try #require(frames[1]))
            #expect(a.width == 600 && a.height == 300)
            #expect(a.rgba != b.rgba, "different styles draw differently")
            #expect(a.rgba.contains { $0 != 0 }, "something is drawn")
            // The editor's scene was never touched: the same time is unchanged since its last frame,
            // and it still has its caption showing.
            #expect(await engine.render(at: 1.0) == nil)
            #expect(await engine.activeCaption() != nil)
            #expect(before.width == 270)
        }

        @Test func aSampleOfALeftAlignedLookIsDrawnCentredInItsFrame() async throws {
            let centred = try Repo.defaultStyle()
            var left = centred
            left.align = .left
            left.positionX = 0.06
            let frames = await engine.samples(of: [centred, left], words: ["Make", "it", "pop"], width: 600, height: 300)
            #expect(try #require(frames[0]).rgba == (try #require(frames[1])).rgba, "a tile is not held by an edge")
        }

        @Test func everyPresetDrawsAndEachIsADifferentLook() async throws {
            try await engine.registerBundledFonts(in: Repo.fonts)
            let presets = try Presets.load(from: Repo.presets)
            let frames = await engine.samples(
                of: presets.map(\.config), words: ["Make", "it", "pop"], width: 600, height: 300)
            #expect(frames.count == presets.count)
            for (preset, frame) in zip(presets, frames) {
                #expect(frame?.rgba.contains { $0 != 0 } == true, "\(preset.id) draws something")
            }
            #expect(Set(frames.compactMap { $0?.rgba }).count == presets.count, "no two presets look the same")
        }

        @Test func aPresetThatMixesLooksShowsThemOnItsSampleWords() async throws {
            try await engine.registerBundledFonts(in: Repo.fonts)
            let editorial = try #require(try Presets.load(from: Repo.presets).first { $0.id == "builtin:editorial" })
            #expect(editorial.config.variants.count == 5)
            let shown = try #require(editorial.tileVariants)
            #expect(shown.count == 3 && shown.allSatisfy { $0 == nil || $0! < editorial.config.variants.count })
            let words = ["Make", "it", "pop"]
            let plain = await engine.samples(of: [editorial.config], words: words, width: 600, height: 300)
            let mixed = await engine.samples(
                of: [editorial.config], words: words, variants: shown, width: 600, height: 300)
            #expect(try #require(mixed[0]).rgba != (try #require(plain[0])).rgba, "the looks are drawn")
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
            #expect(await engine.watermarkRect() == nil)
            let marked = try await frame(Entitlements.watermarkText)
            let rect = try #require(await engine.watermarkRect(), "the preview keeps the mark in place by this")
            #expect(rect.x > 200 && rect.y < 120 && rect.x + rect.width <= 540)
            var corner = 0
            for (i, byte) in marked.rgba.enumerated() where i % 4 == 3 && byte != 0 {
                let (x, y) = ((i / 4) % 540, (i / 4) / 540)
                #expect(x > 200 && y < 120, "only in the top right: \(x),\(y)")
                corner += 1
            }
            #expect(corner > 100)
        }

        @Test func theFontsAScriptNeedsAreNamedByTheEnginesOwnRule() async throws {
            func transcript(_ language: String, _ words: [String]) -> Transcript {
                let spoken = words.enumerated().map { Word(text: $1, start: Double($0), end: Double($0) + 1) }
                return Transcript(
                    language: language, languageDetection: .manual, duration: Double(words.count),
                    segments: [TranscriptSegment(id: "a", words: spoken, start: 0, end: Double(words.count), text: words.joined(separator: " "))])
            }
            #expect(try await engine.fallbackFamilies(for: try Repo.transcript()) == [])
            #expect(try await engine.fallbackFamilies(for: transcript("ja", ["こんにちは", "世界"])) == ["Noto Sans JP"])
            #expect(try await engine.fallbackFamilies(for: transcript("zh", ["你好", "世界"])) == ["Noto Sans SC"])
            #expect(try await engine.fallbackFamilies(for: transcript("ko", ["안녕하세요"])) == ["Noto Sans KR"])
        }

        @Test func bundledFontsRegisterOnceAndInterIsOne() async throws {
            let families = try await engine.registerBundledFonts(in: Repo.fonts)
            #expect(families.contains("Inter"))
            #expect(families.contains("Poppins"), "the default preset's font ships with the engine")
            #expect(families.contains("Montserrat"), "the Bold preset's font ships with the engine")
            #expect(families.contains("Nimbus Roman"), "the Title Card preset's font ships with the engine")
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

        @Test func theCaptionSnapsToTheCentreAndTheMarginsWithinThePull() async throws {
            // A 400 pt axis with 8 pt of pull (0.02 of it), margins of 0.06, a block 0.25 long held by its middle.
            func snap(_ p: Double, _ anchor: BlockAnchor = .middle) -> SnappedAxis {
                CaptionEngine.snappedAxis(position: p, extent: 0.25, anchor: anchor, size: 400, threshold: 8, margin: 0.06)
            }
            #expect(snap(0.51) == SnappedAxis(position: 0.5, line: 0.5))
            #expect(snap(0.53).line == nil && abs(snap(0.53).position - 0.53) < 1e-6)
            // Its start on the near margin (held at 0.06 + 0.125), its end on the far one (0.94 - 0.125).
            #expect(snap(0.19).line == Float(0.06).asDouble && abs(snap(0.19).position - 0.185) < 1e-6)
            #expect(snap(0.82).line == Float(0.94).asDouble && abs(snap(0.82).position - 0.815) < 1e-6)
            // A block held by its start has that edge, and not its middle, at the position.
            #expect(abs(snap(0.07, .start).position - 0.06) < 1e-6)
            #expect(abs(snap(0.38, .start).position - 0.375) < 1e-6, "its middle goes to the centre")
            #expect(abs(snap(0.93, .end).position - 0.94) < 1e-6)
        }

        @Test func linesAreCutLikeTheExportAndShowShiftedTimes() async throws {
            let t = try Repo.transcript()
            let lines = try await engine.lines(t, wordsPerLine: 3, offsetMs: 0)
            #expect(lines.map(\.text) == ["one two three", "four"])
            #expect(lines[0].from == 0 && lines[0].count == 3 && lines[1].from == 3)
            let shifted = try await engine.lines(t, wordsPerLine: 3, offsetMs: 500)
            #expect(abs(shifted[0].start - 1.0) < 1e-5 && abs(shifted[0].end - 2.2) < 1e-5)
        }

        @Test func retimingPushesNeighboursAlongAndWritesUnshiftedTimes() async throws {
            let t = try Repo.transcript()
            let past = try await engine.retimeWord(t, index: 2, edge: .end, time: 3.5, offsetMs: 0)
            #expect(abs(past.words[2].end - 2.95) < 1e-5, "four gives way, down to its minimum")
            #expect(abs(past.words[3].start - 2.95) < 1e-5 && past.words[3].end == t.words[3].end)
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

        @Test func aWordIsGivenALookAndLosesItAgain() async throws {
            let t = try Repo.transcript()
            let styled = try await engine.setVariant(t, index: 2, variant: 4)
            #expect(styled.words[2].variant == 4 && styled.words[1].variant == nil)
            #expect(styled.words.map(\.text) == t.words.map(\.text), "the text stays")
            #expect(styled.words[2].start == t.words[2].start && styled.words[2].end == t.words[2].end)
            let renamed = try await engine.setWord(styled, index: 2, text: "tres")
            #expect(renamed.words[2].variant == 4, "a look survives a rename")
            let cleared = try await engine.setVariant(styled, index: 2, variant: nil)
            #expect(cleared.words[2].variant == nil)
            await #expect(throws: EngineError.self) {
                try await engine.setVariant(t, index: 9, variant: 0)
            }
        }

        @Test func looksAreDealtFromASeedAndAnotherSeedDealsAgain() async throws {
            let t = try Repo.transcript()
            let a = try await engine.shuffleVariants(t, count: 5, seed: 7)
            let again = try await engine.shuffleVariants(t, count: 5, seed: 7)
            #expect(a.words.map(\.variant) == again.words.map(\.variant))
            #expect(a.words.map(\.text) == t.words.map(\.text), "the text stays")
            #expect(a.words.allSatisfy { ($0.variant ?? 0) < 5 })
            var differs = false
            for seed in UInt32(0)..<40 {
                let other = try await engine.shuffleVariants(t, count: 5, seed: seed)
                differs = differs || other.words.map(\.variant) != a.words.map(\.variant)
            }
            #expect(differs)
        }

        @Test func subtitlesAreTheCaptionLinesWithTheOffset() async throws {
            let t = try Repo.transcript()
            let srt = try await engine.subtitles(t, wordsPerLine: 2, offsetMs: 0, format: .srt)
            let lines = try await engine.lines(t, wordsPerLine: 2, offsetMs: 0)
            #expect(srt.hasPrefix("1\n00:00:"))
            #expect(srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count == lines.count)
            for line in lines { #expect(srt.contains(line.text)) }
            let vtt = try await engine.subtitles(t, wordsPerLine: 2, offsetMs: 1000, format: .vtt)
            #expect(vtt.hasPrefix("WEBVTT\n\n"))
            #expect(vtt.contains("<00:00:0"), "each word is tagged with its time")
            #expect(vtt != (try await engine.subtitles(t, wordsPerLine: 2, offsetMs: 0, format: .vtt)))
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

private extension Float { var asDouble: Double { Double(self) } }
