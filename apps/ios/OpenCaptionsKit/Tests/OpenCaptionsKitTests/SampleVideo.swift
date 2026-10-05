import AVFoundation
import Foundation
import Testing

/// A tiny real H.264 clip, written with AVAssetWriter, for the probe and import tests.
enum SampleVideo {
    static func write(
        to url: URL, width: Int = 64, height: Int = 48, seconds: Int = 1, fps: Int = 10,
        rotation: CGFloat = 0
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
        input.transform = CGAffineTransform(rotationAngle: rotation)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            fill(buffer!)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// The left half of the stored picture red, the right half blue: where each ends up
    /// on screen says whether a rotation was applied.
    private static func fill(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let (w, h) = (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let p = base + y * stride + x * 4
                (p[0], p[1], p[2], p[3]) = x < w / 2 ? (0, 0, 255, 255) : (255, 0, 0, 255)  // BGRA
            }
        }
    }

    /// `video` with a 440 Hz tone as its audio, written to a new file.
    static func addingAudio(to video: URL, seconds: Double) async throws -> URL {
        let tone = try tone(seconds: seconds)
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let toneAsset = AVURLAsset(url: tone)
        let range = CMTimeRange(start: .zero, duration: try await videoAsset.load(.duration))
        if let source = try await videoAsset.loadTracks(withMediaType: .video).first,
            let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        {
            try target.insertTimeRange(range, of: source, at: .zero)
            target.preferredTransform = try await source.load(.preferredTransform)
        }
        if let source = try await toneAsset.loadTracks(withMediaType: .audio).first,
            let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        {
            try target.insertTimeRange(range, of: source, at: .zero)
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        try await session.export(to: out, as: .mov)
        return out
    }

    /// A tone as a WAV, stereo at 44.1 kHz.
    static func tone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = 0.5 * sinf(2 * .pi * 440 * Float(i) / 44_100) }
        }
        try file.write(from: buffer)
        return url
    }
}
