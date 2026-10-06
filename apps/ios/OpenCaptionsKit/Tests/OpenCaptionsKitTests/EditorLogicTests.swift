import CoreGraphics
import Foundation
import Testing
@testable import OpenCaptionsKit

@MainActor
final class Counter { var value = 0 }

@Suite struct EditorLogicTests {
    @MainActor @Test func muteIsStateAViewCanShowAndTheDefaultIsSound() {
        let playback = Playback()
        #expect(!playback.isMuted && !playback.player.isMuted)
        playback.isMuted = true
        #expect(playback.isMuted && playback.player.isMuted)
        playback.isMuted.toggle()
        #expect(!playback.player.isMuted)
    }

    // MARK: Autosave

    @MainActor @Test func autosaveWaitsForQuietAndSavesOnce() async throws {
        let saves = Counter()
        // Generous margins: the point is the order of events, not the speed of the machine.
        let saver = Autosaver(delay: .milliseconds(300)) { saves.value += 1 }
        for _ in 0..<5 {
            saver.schedule()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(saves.value == 0, "still being edited")
        try await Task.sleep(for: .milliseconds(900))
        #expect(saves.value == 1)
    }

    @MainActor @Test func flushSavesAtOnceOnlyWhenSomethingIsPending() async throws {
        let saves = Counter()
        let saver = Autosaver(delay: .seconds(60)) { saves.value += 1 }
        await saver.flush()
        #expect(saves.value == 0)
        saver.schedule()
        await saver.flush()
        await saver.flush()
        #expect(saves.value == 1)
    }

    // MARK: Timeline scale

    @Test func ticksStayApartAndLabelsAreReadable() {
        #expect(TimelineScale.tickStep(pointsPerSecond: 1000) == 0.1)
        #expect(TimelineScale.tickStep(pointsPerSecond: 70) == 1)
        #expect(TimelineScale.tickStep(pointsPerSecond: 30) == 5, "5 s x 30 pt = 150, 2 s x 30 = 60 < 70")
        #expect(TimelineScale.tickStep(pointsPerSecond: 0.001) == 3600)
        #expect(TimelineScale.tickLabel(65, step: 5) == "1:05")
        #expect(TimelineScale.tickLabel(1.5, step: 0.5) == "0:01.5")
    }

    @Test func zoomStaysBetweenFitAndTheMaximum() {
        #expect(TimelineScale.clampZoom(5, fit: 20) == 20)
        #expect(TimelineScale.clampZoom(900, fit: 20) == 400)
        #expect(TimelineScale.clampZoom(100, fit: 20) == 100)
        #expect(TimelineScale.clampZoom(100, fit: 500) == 500, "a short clip fits past the limit")
    }

    @Test func zoomingKeepsTheTimeUnderThePinch() {
        // 100 s on screen at 10 pt/s, scrolled 200 pt; the pinch is at x = 300, so at 50 s.
        let time = TimelineScale.time(atX: 300, scrollOffset: 200, pointsPerSecond: 10, span: 100)
        #expect(time == 50)
        let offset = TimelineScale.scrollOffset(keeping: time, at: 300, pointsPerSecond: 40)
        #expect(TimelineScale.time(atX: 300, scrollOffset: offset, pointsPerSecond: 40, span: 100) == 50)
        #expect(TimelineScale.scrollOffset(keeping: 1, at: 300, pointsPerSecond: 10) == 0, "never before the start")
        #expect(TimelineScale.time(atX: 5000, scrollOffset: 0, pointsPerSecond: 10, span: 4) == 4, "clamped to the end")
    }

    @Test func theTimecodeIsMinutesSecondsAndHundredths() {
        #expect(TimelineScale.timecode(0) == "0:00.00")
        #expect(TimelineScale.timecode(4) == "0:04.00")
        #expect(TimelineScale.timecode(65.257) == "1:05.25")
        #expect(TimelineScale.timecode(-3) == "0:00.00")
        #expect(TimelineScale.timecode(.nan) == "0:00.00")
    }

    // MARK: Gestures

    @Test func aDragMovesTheCaptionByTheFractionOfThePreviewAndStaysInFrame() {
        let size = CGSize(width: 200, height: 400)
        let moved = CaptionGestures.draggedPosition(
            from: (0.5, 0.84), translation: CGSize(width: 20, height: -40), size: size)
        #expect(abs(moved.x - 0.6) < 1e-9 && abs(moved.y - 0.74) < 1e-9)
        let past = CaptionGestures.draggedPosition(
            from: (0.9, 0.1), translation: CGSize(width: 500, height: -500), size: size)
        #expect(past.x == 1 && past.y == 0)
        let none = CaptionGestures.draggedPosition(from: (0.3, 0.3), translation: .init(width: 9, height: 9), size: .zero)
        #expect(none.x == 0.3 && none.y == 0.3)
    }

    @Test func aTapPicksTheWordUnderItAsAFlatTranscriptIndex() {
        let caption = ActiveCaption(
            bounds: FrameRect(x: 0, y: 0, width: 100, height: 20), index: 2,
            words: [FrameRect(x: 0, y: 0, width: 40, height: 20), FrameRect(x: 50, y: 0, width: 40, height: 20)])
        #expect(CaptionGestures.wordIndex(at: CGPoint(x: 60, y: 5), in: caption, wordsPerLine: 3) == 7)
        #expect(CaptionGestures.wordIndex(at: CGPoint(x: 5, y: 5), in: caption, wordsPerLine: 3) == 6)
        #expect(CaptionGestures.wordIndex(at: CGPoint(x: 45, y: 5), in: caption, wordsPerLine: 3) == nil, "the gap")
    }

    @Test func aTypedWordHasNoSpaces() {
        #expect(CaptionGestures.sanitizedWord(" hello world\n") == "helloworld")
        #expect(CaptionGestures.sanitizedWord("   ") == "")
    }

    // MARK: Fonts

    @Test func theFontURLIsFoundInTheCSSAPIReturns() throws {
        let css = """
            /* latin */
            @font-face {
              font-family: 'Poppins';
              font-weight: 800;
              src: url(https://fonts.gstatic.com/s/poppins/v22/abc.ttf) format('truetype');
            }
            """
        #expect(FontCache.fontURL(inCSS: css)?.absoluteString == "https://fonts.gstatic.com/s/poppins/v22/abc.ttf")
        #expect(FontCache.fontURL(inCSS: "no fonts here") == nil)
        #expect(FontCache.fontURL(inCSS: "src: url(https://evil.example/a.ttf)") == nil, "only Google's host")
    }

    @Test func aCachedFontIsReadFromDiskWithoutTheNetwork() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fonts-\(UUID())")
        let cache = FontCache(directory: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("cached".utf8).write(to: dir.appendingPathComponent("Open-Sans.ttf"))
        #expect(await cache.data(for: "Open Sans") == Data("cached".utf8))
    }
}

// MARK: The editor model, on the real engine

@Suite struct DragRegionTests {
    let frame = CGSize(width: 1080, height: 1920)

    @Test func aSmallCaptionCanBeGrabbedFromAFingerWidthAround() {
        // A caption 60 x 24 px on a preview drawn at 3 px per point: a 20 x 8 pt target.
        let small = FrameRect(x: 500, y: 900, width: 60, height: 24)
        let region = CaptionGestures.dragRegion(caption: small, position: (0.5, 0.5), frame: frame, pixelsPerPoint: 3)
        #expect(region.contains(x: 530, y: 912), "on the caption")
        #expect(region.contains(x: 530 + 70, y: 912), "a little to the side (24 pt is 72 px)")
        #expect(region.contains(x: 530, y: 912 + 70), "a little below")
        #expect(!region.contains(x: 530 + 200, y: 912), "but not far away")
        #expect(region.width >= 48 * 3 && region.height >= 48 * 3, "at least 48 pt each way")
    }

    @Test func withNothingShowingTheCaptionsPlaceStillCanBeGrabbed() {
        let region = CaptionGestures.dragRegion(caption: nil, position: (0.5, 0.84), frame: frame, pixelsPerPoint: 3)
        #expect(region.contains(x: 540, y: 0.84 * 1920))
        #expect(!region.contains(x: 540, y: 0.2 * 1920))
    }
}

@MainActor
@Suite(.serialized) struct EditorModelTests {
    func make(offset: Int = 0, empty: Bool = false) throws -> (EditorModel, ProjectStore) {
        let store = ProjectStore(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString)"))
        var project = Project(
            title: "clip", transcript: empty ? nil : try Repo.transcript(), styleConfig: try Repo.defaultStyle(),
            captionOffsetMs: offset)
        project = try store.save(project)
        return (EditorModel(project: project, store: store), store)
    }

    @Test func linesAppearAndFollowTheStyleAndOffset() async throws {
        let (model, _) = try make(offset: 500)
        await model.settled()
        #expect(model.lines.map(\.text) == ["one two three", "four"])
        #expect(abs(model.lines[0].start - 1.0) < 1e-5)
        model.updateStyle { $0.wordsPerLine = 2 }
        await model.settled()
        #expect(model.lines.map(\.text) == ["one two", "three four"])
    }

    @Test func aWordEditIsTheEnginesAndIsSavedAfterAQuietMoment() async throws {
        let (model, store) = try make()
        model.setWord(index: 1, text: " zwei ")
        model.setWord(index: 2, text: "drei vier")  // spaces dropped, as typed
        await model.settled()
        #expect(model.transcript?.words.map(\.text) == ["one", "zwei", "dreivier", "four"])
        await model.flush()
        #expect(try store.load(model.project.id).transcript?.words.map(\.text) == ["one", "zwei", "dreivier", "four"])
        #expect(model.saveState == .saved)
    }

    @Test func renamingTrimsKeepsTheOldNameForABlankOneAndIsSaved() async throws {
        let (model, store) = try make()
        #expect(!model.rename(to: "   "), "blank is not a name")
        #expect(!model.rename(to: "clip"), "unchanged is not a change")
        #expect(model.project.title == "clip")
        #expect(model.rename(to: "  Beach day \n"))
        #expect(model.project.title == "Beach day")
        await model.flush()
        #expect(try store.load(model.project.id).title == "Beach day")
    }

    @Test func clearingAWordDeletesIt() async throws {
        let (model, _) = try make()
        model.setWord(index: 0, text: "")
        await model.settled()
        #expect(model.transcript?.words.map(\.text) == ["two", "three", "four"])
    }

    @Test func aFastDragCommitsWhereItEndsAndNeverCrossesTheNeighbour() async throws {
        let (model, _) = try make()
        for time in stride(from: 1.8, through: 3.4, by: 0.2) {
            model.retime(index: 2, edge: .end, time: time)
        }
        await model.settled()
        let end = try #require(model.transcript?.words[2].end)
        #expect(abs(end - 2.6) < 1e-4, "the last request was past four, so it stops at four")
        #expect(model.transcript?.words[0].start == 0.5, "nothing else moved")
    }

    @Test func retimingTakesAndWritesTimesAcrossTheOffset() async throws {
        let (model, _) = try make(offset: 500)
        model.retime(index: 2, edge: .end, time: 2.1)  // as shown
        await model.settled()
        #expect(abs((model.transcript?.words[2].end ?? 0) - 1.6) < 1e-4, "stored unshifted")
    }

    @Test func theOffsetIsClampedToTheAPIsRange() throws {
        let (model, _) = try make()
        model.setOffset(ms: 9000)
        #expect(model.project.captionOffsetMs == 2000)
        model.setOffset(ms: -9000)
        #expect(model.project.captionOffsetMs == -2000)
    }

    @Test func aDragKeepsThePositionInFrameAndAPresetReplacesTheStyle() throws {
        let (model, _) = try make()
        model.setPosition(x: 1.4, y: -0.2)
        #expect(model.project.styleConfig.positionX == 1 && model.project.styleConfig.positionY == 0)
        let presets = try Presets.load(from: Repo.presets)
        model.apply(presets[1])
        #expect(model.project.styleConfig == presets[1].config)
    }

    struct Stub: Transcriber {
        var result: Result<Transcript, Error>
        func transcribe(
            source: URL, language: String?, model: String,
            progress: @escaping @Sendable (Double, String) -> Void
        ) async throws -> Transcript {
            progress(0.5, "halfway")
            return try result.get()
        }
    }

    @Test func transcribingFillsTheTranscriptAndReportsFailure() async throws {
        let (model, store) = try make(empty: true)
        // The model transcribes the copied-in source; give it one.
        try Data("x".utf8).write(to: store.directory(for: model.project.id).appendingPathComponent("source.mov"))
        let fresh = try Repo.transcript()
        model.startTranscription(with: Stub(result: .success(fresh)), model: "base", language: nil)
        #expect(model.isTranscribing)
        while model.isTranscribing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.transcript == fresh)
        #expect(model.transcription == .idle)

        let (other, otherStore) = try make(empty: true)
        try Data("x".utf8).write(to: otherStore.directory(for: other.project.id).appendingPathComponent("source.mov"))
        other.startTranscription(with: Stub(result: .failure(TranscriptionError.noAudio)), model: "base", language: nil)
        while other.isTranscribing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(other.transcription == .failed("This video has no audio to transcribe."))
        #expect(other.transcript == nil)
    }
}
