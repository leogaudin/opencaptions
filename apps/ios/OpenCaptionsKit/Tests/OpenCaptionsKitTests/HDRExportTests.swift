import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import OpenCaptionsKit

/// An HDR source stays HDR, and the captions sit at reference white in it.
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

        @Test(arguments: [("hlg", HDRTransfer.hlg, 721), ("pq", HDRTransfer.pq, 573)])
        func anHDRSourceStaysHDRWithTheCaptionsAtReferenceWhite(
            name: String, transfer: HDRTransfer, referenceWhite: Int
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

            // The caption's white is at reference white, not at the top of the range.
            let peak = try await peakLuma(url, rows: 380..<430, columns: 30..<240)
            #expect(abs(peak - referenceWhite) < 20, "caption white is code \(peak); reference white is about \(referenceWhite)")
            #expect(peak < 900, "not at peak brightness")
            // The background (a grey of the source) is still there, darker than the caption.
            let corner = try await peakLuma(url, rows: 10..<20, columns: 10..<20)
            #expect(corner < peak - 100)
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
