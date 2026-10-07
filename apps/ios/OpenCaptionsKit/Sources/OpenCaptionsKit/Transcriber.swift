import Foundation

public enum TranscriptionError: Error, Equatable, Sendable, LocalizedError {
    case unknownModel(String)
    case modelNotDownloaded(String)
    case noAudio
    case noSpeech

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): String(localized: "Unknown model \(id).", bundle: .module)
        case .modelNotDownloaded(let id): String(localized: "The \(id) model has not been downloaded.", bundle: .module)
        case .noAudio: String(localized: "This video has no audio to transcribe.", bundle: .module)
        case .noSpeech: String(localized: "No speech was found in this video.", bundle: .module)
        }
    }
}

/// A source of transcripts: WhisperKit on the phone, and later a hosted endpoint.
/// Anything that yields words with timings fits behind it.
public protocol Transcriber: Sendable {
    /// Transcribes the speech in a video or audio file. `language` is an ISO 639-1
    /// code, or nil to detect it. `progress` is called with a fraction and a message.
    func transcribe(
        source: URL, language: String?, model: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> Transcript
}
