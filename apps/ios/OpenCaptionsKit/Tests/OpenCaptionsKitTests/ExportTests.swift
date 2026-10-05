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

        func clip(width: Int = 270, height: Int = 480, rotation: CGFloat = 0, audio: Bool = false) async throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
            try await SampleVideo.write(to: url, width: width, height: height, seconds: 2, fps: 10, rotation: rotation)
            return audio ? try await SampleVideo.addingAudio(to: url, seconds: 2) : url
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
