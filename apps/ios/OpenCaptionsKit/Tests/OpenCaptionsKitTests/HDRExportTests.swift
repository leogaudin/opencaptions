import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import OpenCaptionsKit

/// An HDR source stays HDR, and the captions sit near the top of its range, brighter than the picture's own whites.
extension EngineSuites {
    @Suite struct HDRExportTests {
        let fonts = FontCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("oc-fonts"))

        func fixture(_ name: String) -> URL {
            Bundle.module.url(forResource: name, withExtension: "mov", subdirectory: "Fixtures")!
        }

        func project(from clip: URL, store: ProjectStore) async throws -> Project {
            try await CaptionEngine.shared.registerBundledFonts(in: Repo.fonts)
            var p = try await store.importVideo(from: clip, title: "hdr", style: Repo.defaultStyle())
            p.transcript = Transcript(
                language: "en", languageDetection: .manual, duration: 1,
                segments: [
                    TranscriptSegment(
                        id: "a", words: [Word(text: "HELLO", start: 0, end: 1)], start: 0, end: 1, text: "HELLO")
                ])
            // Plain white text, fully opaque while spoken: the brightest thing in the caption.
            p.styleConfig.background = .none
            p.styleConfig.animation = .wordFade
            p.styleConfig.textColor = "#FFFFFF"
            p.styleConfig.strokeWidth = 0
            p.styleConfig.shadowBlur = 0
            p.styleConfig.fontSize = 140
            return p
        }

        func store() -> ProjectStore {
            ProjectStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID().uuidString)"))
        }

        /// The brightest luma in a block of the first frame, as the 10-bit code value.
        func peakLuma(_ url: URL, rows: Range<Int>, columns: Range<Int>) async throws -> Int {
            let asset = AVURLAsset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
            reader.add(output)
            reader.startReading()
            let sample = try #require(output.copyNextSampleBuffer())
            let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
            var peak = 0
            for y in rows {
                for x in columns {
                    let value = base.advanced(by: y * stride + x * 2).loadUnaligned(as: UInt16.self)
                    peak = max(peak, Int(value >> 6))  // 10 bits, stored left-aligned
                }
            }
            return peak
        }

        @Test(arguments: [("hlg", HDRTransfer.hlg, 945), ("pq", HDRTransfer.pq, 730)])
        func anHDRSourceStaysHDRWithTheCaptionsNearItsPeak(
            name: String, transfer: HDRTransfer, captionWhite: Int
        ) async throws {
            let store = store()
            let p = try await project(from: fixture(name), store: store)
            #expect(p.hdrTransfer == transfer, "the probe recognises the source as \(name)")

            let url = try await CaptionExporter(fonts: fonts).export(
                project: p, source: store.sourceURL(for: p.id)!,
                in: FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID())"), progress: { _ in })

            let info = try await VideoProbe.probe(url)
            #expect(info.hdr == transfer, "the file is tagged \(name)")
            #expect((info.width, info.height) == (270, 480))
            let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
            let format = try #require(try await track.load(.formatDescriptions).first)
            #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC, "HEVC, as 10-bit needs")
            let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            #expect(primaries == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)

            // A saved caption's white is at five times reference white (PQ: 203 nits is code 573 and
            // about 1000 nits about 730; HLG: 721, and 945 at the top of its range). A real clip's
            // walls sit at about one and a half times reference white (code ~780 in HLG).
            let peak = try await peakLuma(url, rows: 380..<430, columns: 30..<240)
            #expect(abs(peak - captionWhite) < 20, "caption white is code \(peak); expected about \(captionWhite)")
            #expect(peak <= 940 + 8, "not past the top of the range")
            // The background (a grey of the source) is still there, darker than the caption.
            let corner = try await peakLuma(url, rows: 10..<20, columns: 10..<20)
            #expect(corner < peak - 100)
        }

        /// The brightest 8-bit luma in a block of the first frame of an SDR file.
        func peakLuma8(_ url: URL, rows: Range<Int>, columns: Range<Int>) async throws -> Int {
            let asset = AVURLAsset(url: url)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
            reader.add(output)
            reader.startReading()
            let sample = try #require(output.copyNextSampleBuffer())
            let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
            var peak = 0
            for y in rows { for x in columns { peak = max(peak, Int(base.advanced(by: y * stride + x).load(as: UInt8.self))) } }
            return peak
        }

        @Test(arguments: [("hlg", HDRTransfer.hlg), ("pq", HDRTransfer.pq)])
        func anHDRSourceCanBeSavedAsAnOrdinarySDRVideo(name: String, transfer: HDRTransfer) async throws {
            let store = store()
            let p = try await project(from: fixture(name), store: store)
            #expect(p.hdrTransfer == transfer)
            let options = ExportOptions(codec: .h264, keepHDR: false)
            let url = try await CaptionExporter(fonts: fonts).export(
                project: p, source: store.sourceURL(for: p.id)!,
                in: FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID())"), options: options,
                progress: { _ in })
            let info = try await VideoProbe.probe(url)
            #expect(info.hdr == nil, "an SDR file")
            #expect((info.width, info.height) == (270, 480))
            let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
            let format = try #require(try await track.load(.formatDescriptions).first)
            #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
            // White captions are white in SDR (video-range luma tops out at 235), over a picture that
            // is darker than them and still there.
            let caption = try await peakLuma8(url, rows: 380..<430, columns: 30..<240)
            let corner = try await peakLuma8(url, rows: 10..<20, columns: 10..<20)
            #expect(caption > 200, "caption luma \(caption)")
            #expect(corner < caption - 40, "the picture is not blown out: corner \(corner)")
        }

        @Test func theOptionsDecideTheFormatAndTheNameButNeverGiveHDRToH264() throws {
            var p = Project(
                title: "x", transcript: try Repo.transcript(), styleConfig: try Repo.defaultStyle(), videoWidth: 1080,
                videoHeight: 1920, videoFps: 30, videoDuration: 10)
            // An SDR project: the codec is the user's.
            #expect(ExportOptions(codec: .hevc).plan(for: p) == .init(transfer: nil, codec: .hevc))
            #expect(ExportOptions().plan(for: p) == .init(transfer: nil, codec: .h264))
            // An HDR one kept as HDR is HEVC whatever codec was chosen, and SDR when asked.
            p.hdrTransfer = .hlg
            #expect(ExportOptions(codec: .h264).plan(for: p) == .init(transfer: .hlg, codec: .hevc))
            #expect(ExportOptions(codec: .h264, keepHDR: false).plan(for: p) == .init(transfer: nil, codec: .h264))
            let names = [
                ExportOptions(), ExportOptions(codec: .hevc, keepHDR: false), ExportOptions(frameRate: .fps30),
                ExportOptions(resolution: .p720), ExportOptions(keepHDR: false),
            ].map { ExportKey.hash(for: p, options: $0) }
            #expect(Set(names).count == names.count, "each choice is a different file")
            // A choice that changes nothing for this source does not make another file: codec is moot in HDR.
            #expect(ExportKey.hash(for: p, options: ExportOptions(codec: .h264)) == ExportKey.hash(for: p, options: ExportOptions(codec: .hevc)))
        }

        @Test func sizesAreNeverLargerThanTheSourceAndAlwaysEven() {
            let options = { (r: ExportOptions.Resolution) in ExportOptions(resolution: r) }
            #expect(options(.original).outputSize(width: 1080, height: 1920) == (1080, 1920))
            #expect(options(.p720).outputSize(width: 1080, height: 1920) == (720, 1280))
            #expect(options(.p720).outputSize(width: 1920, height: 1080) == (1280, 720), "sideways")
            #expect(options(.p1080).outputSize(width: 720, height: 1280) == (720, 1280), "never upscaled")
            #expect(options(.p720).outputSize(width: 1000, height: 1777) == (720, 1278), "even")
            #expect(ExportOptions.Resolution.available(forShortSide: 1080) == [.original, .p720])
            #expect(ExportOptions.Resolution.available(forShortSide: 2160) == [.original, .p1080, .p720])
            #expect(ExportOptions.Resolution.available(forShortSide: 540) == [.original])
        }

        @Test func theEstimateFollowsCodecSizeAndFrameRate() throws {
            let p = Project(
                title: "x", transcript: nil, styleConfig: try Repo.defaultStyle(), videoWidth: 1080, videoHeight: 1920,
                videoFps: 60, videoDuration: 10)
            let full = try #require(ExportOptions().estimatedBytes(for: p))
            #expect(full > 40_000_000 && full < 48_000_000, "35 Mbit/s for ten seconds: \(full)")
            #expect(try #require(ExportOptions(codec: .hevc).estimatedBytes(for: p)) < full)
            #expect(try #require(ExportOptions(resolution: .p720).estimatedBytes(for: p)) < full)
            #expect(try #require(ExportOptions(frameRate: .fps30).estimatedBytes(for: p)) < full)
            #expect(ExportOptions().estimatedBytes(for: Project(title: "n", styleConfig: try Repo.defaultStyle())) == nil)
        }

        @Test func anSDRSourceStillMakesAnSDRFile() async throws {
            let store = store()
            let clip = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
            try await SampleVideo.write(to: clip, width: 270, height: 480, seconds: 1, fps: 10)
            let p = try await project(from: clip, store: store)
            #expect(p.hdrTransfer == nil)
            let url = try await CaptionExporter(fonts: fonts).export(
                project: p, source: store.sourceURL(for: p.id)!,
                in: FileManager.default.temporaryDirectory.appendingPathComponent("oc-\(UUID())"), progress: { _ in })
            #expect(try await VideoProbe.probe(url).hdr == nil)
            let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
            let format = try #require(try await track.load(.formatDescriptions).first)
            #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_H264)
        }

        @Test func theExportKeyKnowsTheFormat() throws {
            var p = Project(title: "x", transcript: try Repo.transcript(), styleConfig: try Repo.defaultStyle())
            let sdr = ExportKey.hash(for: p)
            p.hdrTransfer = .hlg
            let hlg = ExportKey.hash(for: p)
            p.hdrTransfer = .pq
            let pq = ExportKey.hash(for: p)
            #expect(Set([sdr, hlg, pq]).count == 3)
        }
    }
}
