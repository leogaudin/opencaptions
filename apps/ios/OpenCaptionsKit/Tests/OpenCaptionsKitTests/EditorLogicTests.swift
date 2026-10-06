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

    @Test func theTrackMovesUnderThePlayheadInTheMiddle() {
        // A 300 pt wide view at 20 pt/s: at 10 s the start of the track is 50 pt left of the view.
        #expect(TimelineScale.trackOrigin(time: 10, pointsPerSecond: 20, viewport: 300) == -50)
        #expect(TimelineScale.trackOrigin(time: 0, pointsPerSecond: 20, viewport: 300) == 150, "the start sits at the playhead")
        // What is under the middle of the view is the playhead's time, and a tap elsewhere is offset from it.
        #expect(TimelineScale.time(atX: 150, playheadTime: 10, pointsPerSecond: 20, viewport: 300, span: 60) == 10)
        #expect(TimelineScale.time(atX: 250, playheadTime: 10, pointsPerSecond: 20, viewport: 300, span: 60) == 15)
        #expect(TimelineScale.time(atX: 0, playheadTime: 1, pointsPerSecond: 20, viewport: 300, span: 60) == 0, "never before the start")
        #expect(TimelineScale.time(atX: 900, playheadTime: 59, pointsPerSecond: 20, viewport: 300, span: 60) == 60, "or past the end")
    }

    @Test func draggingTheTrackLeftShowsLaterAndFitKeepsTheWholeVideoInView() {
        #expect(TimelineScale.scrubbed(from: 10, translation: -40, pointsPerSecond: 20, span: 60) == 12)
        #expect(TimelineScale.scrubbed(from: 10, translation: 60, pointsPerSecond: 20, span: 60) == 7)
        #expect(TimelineScale.scrubbed(from: 1, translation: 900, pointsPerSecond: 20, span: 60) == 0)
        #expect(TimelineScale.scrubbed(from: 59, translation: -900, pointsPerSecond: 20, span: 60) == 60)
        // At fit the whole video spans half the view: with the playhead in the middle, all of it is in view
        // at the start (middle to the right edge), in the middle, and at the end (left edge to the middle).
        let fit = TimelineScale.fit(viewport: 400, span: 40)
        #expect(fit == 5)
        for time in [0.0, 20, 40] {
            let start = TimelineScale.trackOrigin(time: time, pointsPerSecond: fit, viewport: 400)
            #expect(start >= 0 && start + 40 * fit <= 400)
        }
    }

    @Test func theTimecodeIsMinutesSecondsAndHundredths() {
        #expect(TimelineScale.timecode(0) == "0:00.00")
        #expect(TimelineScale.timecode(4) == "0:04.00")
        #expect(TimelineScale.timecode(65.257) == "1:05.25")
        #expect(TimelineScale.timecode(-3) == "0:00.00")
        #expect(TimelineScale.timecode(.nan) == "0:00.00")
    }

    // MARK: Gestures

    @Test func aPinchScalesAboutTheCaptionWhereverItIs() {
        // A layer turns about its middle: a caption low on a landscape view must stay put as it
        // grows, not drift towards the middle of the view.
        let size = CGSize(width: 390, height: 220)
        let caption = CGPoint(x: 120, y: 190)
        // The layer's own coordinates are about its middle, as Core Animation applies them.
        func shown(_ p: CGPoint, _ t: CGAffineTransform) -> CGPoint {
            let local = CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2).applying(t)
            return CGPoint(x: local.x + size.width / 2, y: local.y + size.height / 2)
        }
        let grown = CaptionGestures.liveTransform(offset: .zero, scale: 1.8, pivot: caption, in: size)
        let centre = shown(caption, grown)
        #expect(abs(centre.x - caption.x) < 0.001 && abs(centre.y - caption.y) < 0.001)
        let edge = shown(CGPoint(x: caption.x + 10, y: caption.y), grown)
        #expect(abs(edge.x - (caption.x + 18)) < 0.001, "and grows about it")
        let moved = CaptionGestures.liveTransform(offset: CGSize(width: 30, height: -40), scale: 1.8, pivot: caption, in: size)
        let there = shown(caption, moved)
        #expect(abs(there.x - 150) < 0.001 && abs(there.y - 150) < 0.001, "then follows the fingers")
    }

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

@Suite struct PinchTests {
    @Test func aPinchScalesTheSizeWithinTheRange() {
        #expect(CaptionGestures.pinchedFontSize(from: 48, scale: 1) == 48)
        #expect(CaptionGestures.pinchedFontSize(from: 48, scale: 1.5) == 72)
        #expect(CaptionGestures.pinchedFontSize(from: 48, scale: 0.5) == 24)
        #expect(CaptionGestures.pinchedFontSize(from: 48, scale: 0.1) == 20, "not smaller than the range")
        #expect(CaptionGestures.pinchedFontSize(from: 100, scale: 9) == 160, "not larger")
        #expect(CaptionGestures.pinchedFontSize(from: 48, scale: .nan) == 48)
    }
}

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
        model.setWord(index: 2, text: "drei  vier")  // spaces stay inside: still one word
        await model.settled()
        #expect(model.transcript?.words.map(\.text) == ["one", "zwei", "drei vier", "four"])
        await model.flush()
        #expect(try store.load(model.project.id).transcript?.words.map(\.text) == ["one", "zwei", "drei vier", "four"])
        #expect(model.saveState == .saved)
    }

    @Test func aPresetChangesTheLookButNotWhereOrHowBigTheCaptionIs() async throws {
        let (model, _) = try make()
        model.setPosition(x: 0.3, y: 0.2)
        model.updateStyle { $0.fontSize = 77 }
        var look = try Repo.defaultStyle()
        look.font = "Anton"
        look.highlightColor = "#123456"
        look.fontSize = 104
        look.positionX = 0.5
        look.positionY = 0.9
        let preset = Preset(id: "p", name: "P", config: look)
        model.apply(preset)
        let style = model.project.styleConfig
        #expect(style.font == "Anton" && style.highlightColor == "#123456", "the look")
        #expect(style.fontSize == 77 && style.positionX == 0.3 && style.positionY == 0.2, "not the placement")
        #expect(style.matches(preset), "and it still reads as that preset")
    }

    @Test func aDragAndAPinchSettleInOneChangeWithinLimits() async throws {
        let (model, _) = try make()
        await model.settled()
        let lines = model.lines
        let before = model.project.updatedAt
        model.adjustCaption(position: (x: 1.7, y: 0.25), fontSize: 999)
        let style = model.project.styleConfig
        #expect(style.positionX == 1 && style.positionY == 0.25, "kept in the frame")
        #expect(Double(style.fontSize) == CaptionGestures.fontSizeRange.upperBound, "kept in the size range")
        #expect(model.project.updatedAt > before)
        model.adjustCaption(position: nil, fontSize: 5)
        #expect(Double(model.project.styleConfig.fontSize) == CaptionGestures.fontSizeRange.lowerBound)
        #expect(model.project.styleConfig.positionY == 0.25, "the part not given is left alone")
        await model.settled()
        #expect(model.lines == lines, "where and how big does not change what is on each line")
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

    @Test func undoAndRedoStepThroughStyleWordsAndOffset() async throws {
        let (model, _) = try make()
        model.historyWindow = 0  // every change its own step
        #expect(!model.canUndo && !model.canRedo)
        let original = model.project.styleConfig
        model.updateStyle { $0.fontSize = 70 }
        model.updateStyle { $0.textColor = "#112233" }
        model.setOffset(ms: 300)
        model.setWord(index: 0, text: "uno")
        await model.settled()
        #expect(model.canUndo && !model.canRedo)

        model.undo()
        await model.settled()
        #expect(model.transcript?.words.first?.text == "one", "the word edit is undone first")
        #expect(model.project.captionOffsetMs == 300)
        model.undo()
        #expect(model.project.captionOffsetMs == 0)
        model.undo()
        #expect(model.project.styleConfig.textColor == original.textColor && model.project.styleConfig.fontSize == 70)
        model.undo()
        #expect(model.project.styleConfig == original && !model.canUndo)

        model.redo()
        model.redo()
        #expect(model.project.styleConfig.textColor == "#112233" && model.canRedo)
        // A new change ends what could be redone.
        model.updateStyle { $0.fontSize = 90 }
        #expect(!model.canRedo)
        model.undo()
        #expect(model.project.styleConfig.fontSize == 70 && model.project.styleConfig.textColor == "#112233")
    }

    @Test func aRunOfTheSameKindOfChangeIsOneStep() async throws {
        let (model, _) = try make()
        model.historyWindow = 3600  // everything of one kind merges
        let original = model.project.styleConfig
        for size in [50, 55, 60, 65] { model.updateStyle { $0.fontSize = size } }  // a slider drag
        for time in [1.8, 2.0, 2.2] { model.retime(index: 2, edge: .end, time: time) }  // an edge drag
        await model.settled()
        model.undo()  // the edge drag, whole
        await model.settled()
        #expect(abs((model.transcript?.words[2].end ?? 0) - 1.7) < 1e-4, "back to where the edge was")
        #expect(model.project.styleConfig.fontSize == 65, "the style is untouched")
        model.undo()  // the slider drag, whole
        #expect(model.project.styleConfig == original && !model.canUndo)
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

    @Test func aDragKeepsThePositionInFrame() throws {
        let (model, _) = try make()
        model.setPosition(x: 1.4, y: -0.2)
        #expect(model.project.styleConfig.positionX == 1 && model.project.styleConfig.positionY == 0)
        let presets = try Presets.load(from: Repo.presets)
        model.apply(presets[1])
        #expect(model.project.styleConfig.matches(presets[1]))
        #expect(model.project.styleConfig.positionX == 1 && model.project.styleConfig.positionY == 0)
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
