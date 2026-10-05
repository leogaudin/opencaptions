import AVFoundation
import CoreImage
import Foundation

public enum ExportError: Error, Equatable, Sendable, LocalizedError {
    case nothingToExport
    case noVideo
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .nothingToExport: "There are no captions to add yet."
        case .noVideo: "This project has no video."
        case .failed(let reason): "The video could not be saved: \(reason)"
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
        project: Project, source: URL, in directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard let transcript = project.transcript, let key = ExportKey.hash(for: project) else {
            throw ExportError.nothingToExport
        }
        let final = directory.appendingPathComponent("\(key).mp4")
        if FileManager.default.fileExists(atPath: final.path) { return final }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent("\(key).partial.mp4")
        try? FileManager.default.removeItem(at: partial)

        do {
            try await write(project: project, transcript: transcript, source: source, to: partial, progress: progress)
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: partial, to: final)
            return final
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    // MARK: The pipeline

    private func write(
        project: Project, transcript: Transcript, source: URL, to output: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.noVideo }
        let (size, transform, nominalFps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let shown = CGRect(origin: .zero, size: size).applying(transform)
        // Encoders need even dimensions, and the engine's overlay must match exactly.
        let width = max(2, Int(abs(shown.width).rounded()) & ~1)
        let height = max(2, Int(abs(shown.height).rounded()) & ~1)
        let fps = nominalFps > 0 ? Double(nominalFps) : 30
        let orientation = VideoOrientation.from(transform)

        await engine.ensureFont(project.styleConfig.font, cache: fonts)
        try await engine.setScene(
            transcript: transcript, style: project.styleConfig, width: width, height: height,
            captionOffsetMs: project.captionOffsetMs)

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(videoOut)
        let audio = try await audioPipeline(asset: asset, reader: reader)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let bitrate = min(50_000_000, max(2_000_000, Int(Double(width * height) * fps * 0.15)))
        let videoIn = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: fps,
                ],
            ])
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(videoIn)
        if let audio { writer.add(audio.input) }

        guard reader.startReading() else { throw ExportError.failed(reader.error?.localizedDescription ?? "cannot read") }
        guard writer.startWriting() else { throw ExportError.failed(writer.error?.localizedDescription ?? "cannot write") }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        var overlay: CIImage?
        do {
            while let sample = videoOut.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                try await ready(videoIn, writer: writer, audio: audio, before: time.seconds)
                guard let decoded = CMSampleBufferGetImageBuffer(sample), let pool = adaptor.pixelBufferPool else { continue }
                // Unchanged since the last frame: the same overlay, no redraw.
                if let frame = await engine.render(at: time.seconds) { overlay = frame.ciImage }
                let picture = CIImage(cvPixelBuffer: decoded).oriented(orientation)
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { throw ExportError.failed("out of memory") }
                context.render(overlay.map { $0.composited(over: picture) } ?? picture, to: buffer, bounds: bounds, colorSpace: sRGB)
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw ExportError.failed(writer.error?.localizedDescription ?? "cannot encode")
                }
                if duration > 0 { progress(min(1, time.seconds / duration)) }
            }
            try await drain(audio, writer: writer)
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
        var waiting: CMSampleBuffer?
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

    /// Waits until the video input takes a frame, feeding audio up to `time` meanwhile:
    /// the writer holds back one input until the other keeps up, so they go together.
    private func ready(
        _ videoIn: AVAssetWriterInput, writer: AVAssetWriter, audio: AudioPipeline?, before time: Double
    ) async throws {
        while true {
            try Task.checkCancellation()
            if writer.status == .failed { throw ExportError.failed(writer.error?.localizedDescription ?? "cannot write") }
            if let audio { feed(audio, upTo: time + 0.5) }
            if videoIn.isReadyForMoreMediaData { return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func feed(_ audio: AudioPipeline, upTo time: Double) {
        while !audio.done, audio.input.isReadyForMoreMediaData {
            guard let next = audio.waiting ?? audio.output.copyNextSampleBuffer() else {
                audio.input.markAsFinished()
                audio.done = true
                return
            }
            if CMSampleBufferGetPresentationTimeStamp(next).seconds > time {
                audio.waiting = next
                return
            }
            audio.waiting = nil
            audio.input.append(next)
        }
    }

    private func drain(_ audio: AudioPipeline?, writer: AVAssetWriter) async throws {
        guard let audio else { return }
        while !audio.done {
            try Task.checkCancellation()
            if writer.status == .failed { throw ExportError.failed(writer.error?.localizedDescription ?? "cannot write") }
            feed(audio, upTo: .infinity)
            if !audio.done { try await Task.sleep(for: .milliseconds(2)) }
        }
    }
}
