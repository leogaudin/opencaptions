import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import OpenCaptionsKit

extension EngineSuites {
    @Suite struct ExportTests {
        let fonts = FontCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("oc-fonts"))

        func directory() -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent("oc-export-\(UUID())")
        }

        /// A project over a clip, with one caption showing the whole time.
        func project(for clip: URL, in store: ProjectStore) async throws -> Project {
            try await CaptionEngine.shared.registerBundledFonts(in: Repo.fonts)
            var p = try await store.importVideo(from: clip, title: "clip", style: Repo.defaultStyle())
            p.transcript = Transcript(
                language: "en", languageDetection: .manual, duration: p.videoDuration ?? 2,
                segments: [
                    TranscriptSegment(
                        id: "a", words: [Word(text: "hello", start: 0, end: 1), Word(text: "world", start: 1, end: 2)],
                        start: 0, end: 2, text: "hello world")
                ])
            p.styleConfig.fontSize = 120
            return p
        }

        func store() -> ProjectStore {
            ProjectStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString)"))
        }

        func clip(
            width: Int = 270, height: Int = 480, rotation: CGFloat = 0, audio: Bool = false, seconds: Int = 2
        ) async throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
            try await SampleVideo.write(to: url, width: width, height: height, seconds: seconds, fps: 10, rotation: rotation)
            return audio ? try await SampleVideo.addingAudio(to: url, seconds: Double(seconds)) : url
        }

        /// The pixel at (`x`, `y`) of the frame at `seconds`, as RGB 0...255.
        func pixel(_ url: URL, at seconds: Double, x: Int, y: Int) async throws -> (r: Int, g: Int, b: Int) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.appliesPreferredTrackTransform = true
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = CGContext(
                data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
        }

        func codec(of url: URL) async throws -> FourCharCode {
            let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
            return CMFormatDescriptionGetMediaSubType(try #require(try await track.load(.formatDescriptions).first))
        }

        @Test func aSmallerSizeAndHEVCAreWhatWasAskedFor() async throws {
            let store = store()
            let p = try await project(for: try await clip(width: 1080, height: 1920, seconds: 1), in: store)
            let options = ExportOptions(codec: .hevc, resolution: .p720)
            let url = try await CaptionExporter(fonts: fonts).export(
                project: p, source: store.sourceURL(for: p.id)!, in: directory(), options: options, progress: { _ in })
            let info = try await VideoProbe.probe(url)
            #expect((info.width, info.height) == (720, 1280), "the short side is 720")
            #expect(try await codec(of: url) == kCMVideoCodecType_HEVC)
            #expect(info.hdr == nil)
            // The captions were drawn at the new size, so they are in the picture.
            let (r, g, b) = try await pixel(url, at: 0.2, x: 360, y: Int(0.84 * 1280))
            #expect(max(r, g, b) > 100, "the caption is there: \(r) \(g) \(b)")
        }

        @Test func aGreenScreenIsTheCaptionsOverSolidGreenWithTheClipsLengthAndNoSound() async throws {
            let store = store()
            let p = try await project(for: try await clip(width: 270, height: 480, audio: true, seconds: 2), in: store)
            let url = try await CaptionExporter(fonts: fonts).export(
                project: p, source: store.sourceURL(for: p.id)!, in: directory(),
                options: ExportOptions(greenScreen: true), progress: { _ in })
            let (r, g, b) = try await pixel(url, at: 0.5, x: 8, y: 8)
            // Green to a keyer. A clip this small is untagged and decoded with another matrix than the
            // encoder used, so the red and blue are not exactly zero.
            #expect(g > 200 && r < 100 && b < 40, "the picture is green, not the clip: \(r) \(g) \(b)")
            let asset = AVURLAsset(url: url)
            #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty, "no sound")
            #expect(abs(try await asset.load(.duration).seconds - 2) < 0.3)
        }

        @Test func savingSmallerDoesNotGrowMemoryFrameAfterFrame() async throws {
            let store = store()
            let clip = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
            try await SampleVideo.write(to: clip, width: 1080, height: 1920, seconds: 3, fps: 30)
            let p = try await project(for: clip, in: store)
            let samples = Samples()
            _ = try await CaptionExporter(fonts: fonts).export(
                project: p, source: store.sourceURL(for: p.id)!, in: directory(),
                options: ExportOptions(codec: .hevc, resolution: .p720),
                progress: { _ in samples.add(Diagnostics.footprintMB()) })
            let all = samples.values
            #expect((all.max() ?? 0) - (all.first ?? 0) < 400, "memory held while saving: \(all.first ?? 0) to \(all.max() ?? 0) MB")
        }

        final class Samples: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [Int] = []
            func add(_ value: Int) { lock.lock(); storage.append(value); lock.unlock() }
            var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
        }

        /// The video frames of a file, counted, and their span in seconds.
        func frames(of url: URL) async throws -> (count: Int, span: Double) {
            let asset = AVURLAsset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            reader.startReading()
            var times: [Double] = []
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetNumSamples(sample) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
            }
            return (times.count, (times.max() ?? 0) - (times.min() ?? 0))
        }

        @Test func anotherFrameRateGivesTheFramesOfThatRateOverTheWholeClip() async throws {
            // 60 → 30 keeps every other frame; 10 → 30 repeats each source frame three times.
            for (source, rate, expected) in [(60, ExportOptions.FrameRate.fps30, 60), (10, .fps30, 60)] {
                let store = store()
                let clip = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
                try await SampleVideo.write(to: clip, width: 64, height: 48, seconds: 2, fps: source)
                let p = try await project(for: clip, in: store)
                let url = try await CaptionExporter(fonts: fonts).export(
                    project: p, source: store.sourceURL(for: p.id)!, in: directory(), options: ExportOptions(frameRate: rate),
                    progress: { _ in })
                let (count, span) = try await frames(of: url)
                #expect(abs(count - expected) <= 2, "\(count) frames for 2 s at 30 fps from \(source) fps")
                #expect(span > 1.9 - 1 / 30, "spread over the whole clip: \(span) s")
            }
        }

        @Test func frameRatesOfferedAreTheOtherOnesAndNameTheFile() throws {
            #expect(ExportOptions.FrameRate.available(forSourceFps: 120) == [.original, .fps30, .fps60])
            #expect(ExportOptions.FrameRate.available(forSourceFps: 59.94) == [.original, .fps30])
            #expect(ExportOptions.FrameRate.available(forSourceFps: 30) == [.original, .fps60])
            #expect(ExportOptions.FrameRate.available(forSourceFps: 24) == [.original, .fps30, .fps60])
            #expect(ExportOptions(frameRate: .fps60).outputFps(source: 24) == 60, "above the source's is allowed")
            let p = Project(
                title: "x", transcript: try Repo.transcript(), styleConfig: try Repo.defaultStyle(), videoWidth: 1080,
                videoHeight: 1920, videoFps: 30, videoDuration: 10)
            #expect(ExportKey.hash(for: p, options: ExportOptions()) != ExportKey.hash(for: p, options: ExportOptions(frameRate: .fps60)))
            let at60 = try #require(ExportOptions(frameRate: .fps60).estimatedBytes(for: p))
            #expect(at60 > (try #require(ExportOptions().estimatedBytes(for: p))), "more frames, a larger file")
        }

        @Test func anOptionIsPartOfTheNameOfTheFile() async throws {
            let store = store()
            let p = try await project(for: try await clip(seconds: 1), in: store)
            let dir = directory()
            let exporter = CaptionExporter(fonts: fonts)
            let source = store.sourceURL(for: p.id)!
            let standard = try await exporter.export(project: p, source: source, in: dir, progress: { _ in })
            let again = try await exporter.export(project: p, source: source, in: dir, progress: { _ in })
            let hevc = try await exporter.export(
                project: p, source: source, in: dir, options: ExportOptions(codec: .hevc), progress: { _ in })
            #expect(standard == again, "the same options reuse the file")
            #expect(standard != hevc, "other options make another")
            #expect(try await codec(of: standard) == kCMVideoCodecType_H264)
            #expect(try await codec(of: hevc) == kCMVideoCodecType_HEVC)
        }

        @Test func theExportIsTheSizeRateAndLengthOfTheClipWithItsAudio() async throws {
            let store = store()
            let source = try await clip(audio: true)
            let p = try await project(for: source, in: store)
            let url = try await CaptionExporter(fonts: fonts).export(
                project: p, source: store.sourceURL(for: p.id)!, in: directory(), progress: { _ in })
            let info = try await VideoProbe.probe(url)
            #expect((info.width, info.height) == (270, 480))
            #expect(abs(info.fps - 10) < 0.5 && abs(info.duration - 2) < 0.3)
            #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count == 1)
            let samples = try await AudioExtractor.samples(from: url)
            #expect(samples.count > 16_000, "about two seconds of audio survived")
        }

        @Test func theCaptionsAreBurnedIn() async throws {
            let store = store()
            let source = try await clip()
            let p = try await project(for: source, in: store)
            let url = try await CaptionExporter(fonts: fonts).export(
                project: p, source: store.sourceURL(for: p.id)!, in: directory(), progress: { _ in })
            // The caption sits low in the frame (position_y 0.84); the left half is red, and
            // the caption's white text and dark pill change pixels in that block.
            var changed = 0
            for x in stride(from: 40, to: 230, by: 6) {
                for y in stride(from: 380, to: 420, by: 4) {
                    let out = try await pixel(url, at: 0.5, x: x, y: y)
                    let original = try await pixel(store.sourceURL(for: p.id)!, at: 0.5, x: x, y: y)
                    if abs(out.r - original.r) + abs(out.g - original.g) + abs(out.b - original.b) > 90 { changed += 1 }
                }
            }
            #expect(changed > 20, "the caption block differs from the plain clip in \(changed) places")
            // Away from the caption the picture is the clip's.
            let top = try await pixel(url, at: 0.5, x: 10, y: 10)
            #expect(top.r > 150 && top.b < 100, "left half red, got \(top)")
        }

        @Test func aRotatedClipComesOutUprightAtTheSizeItIsShown() async throws {
            let store = store()
            // Stored 64 x 48 (left half red), rotated 90° clockwise: shown 48 x 64 with red on top.
            let source = try await clip(width: 64, height: 48, rotation: .pi / 2)
            let p = try await project(for: source, in: store)
            #expect((p.videoWidth, p.videoHeight) == (48, 64))
            var plain = p
            plain.styleConfig.fontSize = 20
            let url = try await CaptionExporter(fonts: fonts).export(
                project: plain, source: store.sourceURL(for: p.id)!, in: directory(), progress: { _ in })
            let info = try await VideoProbe.probe(url)
            #expect((info.width, info.height) == (48, 64))
            let top = try await pixel(url, at: 0.5, x: 24, y: 4)
            let bottom = try await pixel(url, at: 0.5, x: 24, y: 59)
            #expect(top.r > 150 && top.b < 100, "red on top, got \(top)")
            #expect(bottom.b > 150 && bottom.r < 100, "blue below, got \(bottom)")
        }

        @Test func anUnchangedProjectIsNotExportedAgainAndAChangedOneIs() async throws {
            let store = store()
            let source = try await clip()
            let p = try await project(for: source, in: store)
            let out = directory()
            let exporter = CaptionExporter(fonts: fonts)
            let first = try await exporter.export(project: p, source: store.sourceURL(for: p.id)!, in: out, progress: { _ in })
            let written = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date
            try await Task.sleep(for: .milliseconds(1100))
            let again = try await exporter.export(project: p, source: store.sourceURL(for: p.id)!, in: out, progress: { _ in })
            #expect(again == first)
            #expect(try FileManager.default.attributesOfItem(atPath: again.path)[.modificationDate] as? Date == written)
            var edited = p
            edited.styleConfig.textColor = "#FF0000"
            let other = try await exporter.export(project: edited, source: store.sourceURL(for: p.id)!, in: out, progress: { _ in })
            #expect(other != first)
            #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).count == 2, "no partial files")
        }

        @Test func progressRisesToOneAndNothingToExportIsRefused() async throws {
            let store = store()
            let source = try await clip()
            let p = try await project(for: source, in: store)
            let log = ProgressLog()
            _ = try await CaptionExporter(fonts: fonts).export(
                project: p, source: store.sourceURL(for: p.id)!, in: directory(), progress: { log.add($0) })
            #expect(log.fractions.last == 1 && log.fractions == log.fractions.sorted())
            var empty = p
            empty.transcript = nil
            await #expect(throws: ExportError.nothingToExport) {
                try await CaptionExporter(fonts: fonts).export(
                    project: empty, source: store.sourceURL(for: p.id)!, in: directory(), progress: { _ in })
            }
        }

        /// The writer holds each input back until the other keeps up, so audio rationed to a point
        /// just ahead of the video left both waiting forever. A short clip fits the writer's
        /// buffers and never showed it; a real one (here half a minute with sound) does.
        @Test func aLongClipWithAudioFinishesInsteadOfStalling() async throws {
            let store = store()
            let source = try await clip(width: 270, height: 480, audio: true, seconds: 30)
            let p = try await project(for: source, in: store)
            let src = store.sourceURL(for: p.id)!
            let out = directory()
            let task = Task { try await CaptionExporter(fonts: fonts).export(project: p, source: src, in: out, progress: { _ in }) }
            let watchdog = Task {
                try await Task.sleep(for: .seconds(60))
                task.cancel()
            }
            let url = try await task.value
            watchdog.cancel()
            let info = try await VideoProbe.probe(url)
            #expect(abs(info.duration - 30) < 0.5)
            #expect(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).count == 1)
        }

        @Test func cancellingLeavesNoFileBehind() async throws {
            let store = store()
            let source = try await clip()
            let p = try await project(for: source, in: store)
            let out = directory()
            let exporter = CaptionExporter(fonts: fonts)
            let src = store.sourceURL(for: p.id)!
            let task = Task { try await exporter.export(project: p, source: src, in: out, progress: { _ in }) }
            task.cancel()
            await #expect(throws: (any Error).self) { try await task.value }
            let left = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
            #expect(left.isEmpty, "found \(left)")
        }
    }
}

@MainActor @Suite struct ExportControllerTests {
    func project() throws -> Project { Project(title: "x", styleConfig: try Repo.defaultStyle()) }

    @Test func itRunsReportsAndFinishes() async throws {
        let url = URL(fileURLWithPath: "/tmp/out.mp4")
        let controller = ExportController { _, _, progress in
            progress(0.5)
            try await Task.sleep(for: .milliseconds(30))
            return url
        }
        controller.start(project: try project(), source: url)
        #expect(controller.isRunning)
        while controller.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.state == .done(url))
        controller.dismiss()
        #expect(controller.state == .idle)
    }

    @Test func anExportThatStopsMakingProgressIsStoppedAndSaysSo() async throws {
        // Never reports, never finishes: what a stall looks like from here.
        let stuck = ExportController(stallLimit: .milliseconds(150)) { _, _, _ in
            try await Task.sleep(for: .seconds(60))
            return URL(fileURLWithPath: "/never")
        }
        stuck.start(project: try project(), source: URL(fileURLWithPath: "/x"))
        try await Task.sleep(for: .milliseconds(900))
        #expect(!stuck.isRunning)
        guard case .failed(let reason) = stuck.state else {
            Issue.record("expected a failure, got \(stuck.state)")
            return
        }
        #expect(reason.contains("stopped making progress"))

        // One that keeps reporting is left alone, however long it takes.
        let slow = ExportController(stallLimit: .milliseconds(300)) { _, _, progress in
            for step in 1...8 {
                try await Task.sleep(for: .milliseconds(100))
                progress(Double(step) / 8)
            }
            return URL(fileURLWithPath: "/done")
        }
        slow.start(project: try project(), source: URL(fileURLWithPath: "/x"))
        while slow.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        #expect(slow.state == .done(URL(fileURLWithPath: "/done")))
    }

    @Test func anInterruptedExportSaysWhyAndIsNotAFailureOfTheFile() async throws {
        let slow = ExportController { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return URL(fileURLWithPath: "/never")
        }
        slow.start(project: try project(), source: URL(fileURLWithPath: "/x"))
        slow.interrupt("The app left the screen.")
        try await Task.sleep(for: .milliseconds(100))
        #expect(slow.state == .failed("The app left the screen."))
        slow.interrupt("again")  // nothing is running: nothing changes
        #expect(slow.state == .failed("The app left the screen."))
    }

    @Test func aFailureIsReportedAndCancelGoesBackToIdle() async throws {
        let failing = ExportController { _, _, _ in throw ExportError.noVideo }
        failing.start(project: try project(), source: URL(fileURLWithPath: "/x"))
        while failing.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        #expect(failing.state == .failed("This project has no video."))

        let slow = ExportController { _, _, _ in
            try await Task.sleep(for: .seconds(30))
            return URL(fileURLWithPath: "/never")
        }
        slow.start(project: try project(), source: URL(fileURLWithPath: "/x"))
        slow.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(slow.state == .idle, "a cancel is not a failure")
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    var fractions: [Double] { lock.withLock { values } }
    func add(_ fraction: Double) { lock.withLock { values.append(fraction) } }
}
