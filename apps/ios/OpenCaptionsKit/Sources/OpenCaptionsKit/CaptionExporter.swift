import AVFoundation
import CoreImage
import Foundation
import VideoToolbox

public enum ExportError: Error, Equatable, Sendable, LocalizedError {
    case nothingToExport
    case noVideo
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .nothingToExport: String(localized: "There are no captions to add yet.", bundle: .module)
        case .noVideo: String(localized: "This project has no video.", bundle: .module)
        case .failed(let reason): String(localized: "The video could not be saved: \(reason)", bundle: .module)
        }
    }
}

/// Burns the captions into the video. AVAssetReader decodes each frame, the engine
/// draws the caption overlay for its time (the same code and fonts as the preview
/// and the server's export), Core Image composites it, and AVAssetWriter encodes the
/// result with the audio. The picture comes out upright, at the size it is shown.
///
/// The engine holds one scene for the whole process, so the preview must not draw
/// while this runs (its scene is rebuilt afterwards).
public struct CaptionExporter: Sendable {
    private let engine: CaptionEngine
    private let fonts: FontCache

    public init(engine: CaptionEngine = .shared, fonts: FontCache) {
        self.engine = engine
        self.fonts = fonts
    }

    /// The file for this project's current state in `directory`, writing it unless an
    /// identical export is already there. `progress` gets a fraction from 0 to 1.
    public func export(
        project: Project, source: URL, in directory: URL, options: ExportOptions = .standard,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let transcript = project.transcript, let key = ExportKey.hash(for: project, options: options) else {
            throw ExportError.nothingToExport
        }
        let final = directory.appendingPathComponent("\(key).mp4")
        if FileManager.default.fileExists(atPath: final.path) { return final }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A save that was killed leaves its partial file behind; none of them is any use.
        for stale in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where stale.hasSuffix(".partial.mp4") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(stale))
        }
        let partial = directory.appendingPathComponent("\(key).partial.mp4")

        Diagnostics.log("export start \(key) \(options.signature(for: project)) mem=\(Diagnostics.footprintMB())MB")
        do {
            try await write(
                project: project, transcript: transcript, source: source, to: partial, options: options,
                progress: progress)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
            Diagnostics.log("export done \(key) mem=\(Diagnostics.footprintMB())MB")
            return final
        } catch {
            Diagnostics.log("export failed \(key): \(error)")
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// How frames are decoded, composited and encoded. SDR is 8-bit H.264. An HDR source
    /// stays HDR: decoded to 10 bits so nothing is clipped, and written as 10-bit HEVC
    /// with the source's BT.2020 primaries and transfer function. Core Image works in
    /// light relative to reference white, so the sRGB captions land at `CaptionFrame.hdrExportWhiteScale`
    /// times reference white in the HDR signal, not at peak brightness.
    private struct Encoding {
        var pixelFormat: OSType
        var settings: [String: Any]
        var compression: [String: Any]
        var colorSpace: CGColorSpace?
        var attachments: [CFString: CFString] = [:]
        /// How much the captions are scaled (in linear light) on the way into this
        /// encoding. Core Image places sRGB white well above reference white in an HDR
        /// signal, so a measured factor brings it down to reference white (203 nits in PQ,
        /// 75% signal in HLG). `HDRExportTests` measures the result, so a change in how
        /// the system maps sRGB into HDR fails there.
        var overlayGain = 1.0

        static func make(
            for transfer: HDRTransfer?, codec: ExportOptions.Codec = .h264, width: Int, height: Int, bitrate: Int,
            fps: Double
        ) -> Encoding {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: fps,
            ]
            guard let transfer else {
                let hevc = codec == .hevc
                compression[AVVideoProfileLevelKey] =
                    hevc ? kVTProfileLevel_HEVC_Main_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel
                return Encoding(
                    pixelFormat: kCVPixelFormatType_32BGRA,
                    settings: [
                        AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                        AVVideoWidthKey: width, AVVideoHeightKey: height,
                    ],
                    compression: compression, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            }
            let pq = transfer == .pq
            let avTransfer = pq ? AVVideoTransferFunction_SMPTE_ST_2084_PQ : AVVideoTransferFunction_ITU_R_2100_HLG
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            var encoding = Encoding(
                pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                settings: [
                    AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: width, AVVideoHeightKey: height,
                    AVVideoColorPropertiesKey: [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                        AVVideoTransferFunctionKey: avTransfer,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
                    ],
                ],
                compression: compression,
                colorSpace: CGColorSpace(name: pq ? CGColorSpace.itur_2100_PQ : CGColorSpace.itur_2100_HLG),
                attachments: [
                    kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_2020,
                    kCVImageBufferTransferFunctionKey: pq ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ : kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                    kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_2020,
                ])
            encoding.overlayGain = (pq ? 0.277 : 0.282) * CaptionFrame.hdrExportWhiteScale
            return encoding
        }
    }

    // MARK: The pipeline

    private func write(
        project: Project, transcript: Transcript, source: URL, to output: URL, options: ExportOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let (size, transform, nominalFps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        // Encoders need even dimensions, and the engine's overlay must match exactly. The picture is
        // made at the size asked for (larger than the source too), and the captions are drawn at it.
        let (width, height) = options.outputSize(
            width: Int(abs(shown.width).rounded()), height: Int(abs(shown.height).rounded()))
        let sourceHeight = max(2, Int(abs(shown.height).rounded()) & ~1)
        let scale = Double(height) / Double(sourceHeight)
        let sourceFps = nominalFps > 0 ? Double(nominalFps) : 30
        let fps = options.outputFps(source: sourceFps)
        // Another rate than the source's: output frames sit on a grid of 1/fps, each showing the
        // latest source frame at or before it. Otherwise every source frame is kept as it is.
        let resampling = options.frameRate != .original && abs(fps - sourceFps) > 0.5
        var nextSlot: Double?
        var held: CMSampleBuffer?
        var lastSourceTime = 0.0
        let orientation = VideoOrientation.from(transform)
        let plan = options.plan(for: project)
        // An HDR source made into an SDR video is tone-mapped down before the captions go on.
        let toneMap = project.hdrTransfer != nil && plan.transfer == nil && !options.greenScreen
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        let fallbacks = await engine.ensureFonts(for: transcript, style: project.styleConfig, cache: fonts)
        try await engine.setScene(
            transcript: transcript, style: project.styleConfig, width: width, height: height,
            captionOffsetMs: project.captionOffsetMs, watermark: options.watermark, fallbackFonts: fallbacks)

        let bitrate = options.bitrate(width: width, height: height, fps: fps, plan: plan)
        let encoding = Encoding.make(
            for: plan.transfer, codec: plan.codec, width: width, height: height, bitrate: bitrate, fps: fps)
        // What the reader hands over: an HDR source is read at 10 bits, so nothing is clipped on the
        // way to either an HDR file or a tone-mapped SDR one.
        let decodeFormat =
            project.hdrTransfer != nil ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : encoding.pixelFormat

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: decodeFormat])
        reader.add(videoOut)
        // A green screen is the captions alone: no sound either.
        let audio = options.greenScreen ? nil : try await audioPipeline(asset: asset, reader: reader)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        var settings = encoding.settings
        settings[AVVideoCompressionPropertiesKey] = encoding.compression
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: encoding.pixelFormat,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(videoIn)
        if let audio { writer.add(audio.input) }

        guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "cannot read") }
        guard writer.startWriting() else { throw ExportError.failed(writer.error?.localizedDescription ?? "cannot write") }
        writer.startSession(atSourceTime: .zero)

        // Half-float working precision, so HDR values above reference white survive.
        // Nothing kept between frames: every frame is new, and a cache of each one's intermediate
        // pictures (a resized 4K frame is several megabytes) grows until the system ends the app.
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var overlay: CIImage?
        var logged = 0
        var reportedPercent = -1
        var framesWritten = 0
        /// Draws the captions for `time` over `sample`'s picture and writes the frame there.
        func write(_ sample: CMSampleBuffer, at time: CMTime) async throws {
            try Task.checkCancellation()
            try await ready(videoIn, writer: writer, reader: reader, audio: audio)
            guard let decoded = CMSampleBufferGetImageBuffer(sample), let pool = adaptor.pixelBufferPool else { return }
            // Unchanged since the last frame: the same overlay, no redraw.
            if let frame = await engine.render(at: time.seconds) { overlay = frame.ciImage.scaled(by: encoding.overlayGain) }
            // Each frame holds tens of megabytes of pixel buffers; a pool per frame returns them
            // at once instead of whenever the long-running task next unwinds.
            try autoreleasepool {
                // Green screen: the frame only sets the timing; the picture is solid green.
                var picture = options.greenScreen ? green : CIImage(cvPixelBuffer: decoded).oriented(orientation)
                if scale < 1 && !options.greenScreen { picture = picture.downscaled(by: scale).cropped(to: bounds) }
                if toneMap { picture = picture.toneMappedToSDR() }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw ExportError.failed("out of memory") }
                for (key, value) in encoding.attachments { CVBufferSetAttachment(buffer, key, value, .shouldPropagate) }
                context.render(
                    overlay.map { $0.composited(over: picture) } ?? picture, to: buffer, bounds: bounds,
                    colorSpace: encoding.colorSpace)
                // Calling into a writer that has failed raises an exception, which ends the app.
                guard writer.status == .writing, adaptor.append(buffer, withPresentationTime: time) else {
                    throw ExportError.failed(writer.error?.localizedDescription ?? "cannot encode")
                }
                framesWritten += 1
                if framesWritten % 30 == 0 { context.clearCaches() }
            }
        }
        /// The frames for every slot before `until`, showing `held`.
        func fillSlots(before until: Double) async throws {
            guard let held, var slot = nextSlot else { return }
            while slot < until {
                try await write(held, at: CMTime(seconds: slot, preferredTimescale: 60_000))
                slot += 1 / fps
            }
            nextSlot = slot
        }
        do {
            while let sample = videoOut.copyNextSampleBuffer() {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                lastSourceTime = time.seconds
                if resampling {
                    if nextSlot == nil { nextSlot = time.seconds }
                    // A tenth of a source frame of slack, so rounding in the timestamps cannot skip one.
                    try await fillSlots(before: time.seconds - 0.1 / sourceFps)
                    held = sample
                } else {
                    try await write(sample, at: time)
                }
                if duration > 0 {
                    let fraction = min(1, time.seconds / duration)
                    // Once per percent: the sheet redraws for each report, and a frame is not a percent.
                    if Int(fraction * 100) != reportedPercent {
                        reportedPercent = Int(fraction * 100)
                        progress(fraction)
                    }
                    if Int(fraction * 20) > logged {  // every 5%: where it was, and how much memory it held
                        logged = Int(fraction * 20)
                        Diagnostics.log("export \(Int(fraction * 100))% mem=\(Diagnostics.footprintMB())MB")
                    }
                }
            }
            // The last source frame lasts until the end of the video.
            if resampling { try await fillSlots(before: lastSourceTime + 1 / sourceFps - 0.1 / fps) }
            try await drain(audio, writer: writer, reader: reader)
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        videoIn.markAsFinished()  // the audio input was finished when it ran out
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.failed(writer.error?.localizedDescription ?? "the file was not finished")
        }
        progress(1)
    }

    // MARK: Audio

    /// The audio, decoded and re-encoded as AAC so any source codec fits the MP4.
    private final class AudioPipeline {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        var done = false

        init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
            self.output = output
            self.input = input
        }
    }

    private func audioPipeline(asset: AVURLAsset, reader: AVAssetReader) async throws -> AudioPipeline? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        reader.add(output)
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
        input.expectsMediaDataInRealTime = false
        return AudioPipeline(output: output, input: input)
    }

    /// Waits until the video input takes a frame, feeding audio meanwhile. The writer holds
    /// back each input until the other keeps up with it, so audio must be given whenever it
    /// will take it, never rationed to a point just ahead of the video: it waits for audio
    /// further ahead than that before it accepts another frame, and each would wait for the
    /// other forever. It pushes back on its own when audio gets too far ahead.
    private func ready(
        _ videoIn: AVAssetWriterInput, writer: AVAssetWriter, reader: AVAssetReader, audio: AudioPipeline?
    ) async throws {
        while true {
            try Task.checkCancellation()
            try check(writer, reader)
            if let audio { feed(audio, writer: writer, reader: reader) }
            if videoIn.isReadyForMoreMediaData { return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Stops with the real reason if either end has failed, which is what happens when the app
    /// leaves the screen mid-save and the system takes the hardware encoder away.
    private func check(_ writer: AVAssetWriter, _ reader: AVAssetReader) throws {
        if writer.status == .failed || writer.status == .cancelled {
            throw ExportError.failed(writer.error?.localizedDescription ?? "the save was interrupted")
        }
        if reader.status == .failed {
            throw ExportError.failed(reader.error?.localizedDescription ?? "the video could not be read")
        }
    }

    /// Gives the writer audio for as long as it takes it.
    private func feed(_ audio: AudioPipeline, writer: AVAssetWriter, reader: AVAssetReader) {
        while !audio.done, writer.status == .writing, audio.input.isReadyForMoreMediaData {
            guard let next = audio.output.copyNextSampleBuffer() else {
                // Out of audio (or the reader failed, which the next check reports).
                if writer.status == .writing { audio.input.markAsFinished() }
                audio.done = true
                return
            }
            audio.input.append(next)
        }
    }

    private func drain(_ audio: AudioPipeline?, writer: AVAssetWriter, reader: AVAssetReader) async throws {
        guard let audio else { return }
        while !audio.done {
            try Task.checkCancellation()
            try check(writer, reader)
            feed(audio, writer: writer, reader: reader)
            if !audio.done { try await Task.sleep(for: .milliseconds(2)) }
        }
    }
}

extension CIImage {
    /// Resized with Lanczos resampling, the sharp way to make a picture smaller.
    func downscaled(by scale: Double) -> CIImage {
        applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
    }

    /// An HDR picture brought into SDR range: the highlights above reference white are compressed
    /// rather than clipped (a 1000-nit HDR peak is about five times SDR white).
    func toneMappedToSDR() -> CIImage {
        applyingFilter("CIToneMapHeadroom", parameters: ["inputSourceHeadroom": 4.93, "inputTargetHeadroom": 1.0])
    }
}
