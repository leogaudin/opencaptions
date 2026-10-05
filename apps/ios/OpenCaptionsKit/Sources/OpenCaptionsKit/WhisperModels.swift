import Foundation

/// A speech model the phone can run. The ids are the desktop's (`whisper_models.py`),
/// limited to what WhisperKit publishes as Core ML in `argmaxinc/whisperkit-coreml`;
/// `variant` is that repository's folder.
public struct WhisperModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    /// The folder in the Core ML repository.
    public let variant: String
    /// The download, in megabytes (measured from the repository).
    public let megabytes: Int
    public var englishOnly: Bool { id.hasSuffix(".en") }
}

public enum WhisperModels {
    /// Ascending size. Downloaded on demand, never bundled.
    public static let all: [WhisperModel] = [
        .init(id: "tiny", label: "Tiny", variant: "openai_whisper-tiny", megabytes: 77),
        .init(id: "base.en", label: "Base (English-only)", variant: "openai_whisper-base.en", megabytes: 147),
        .init(id: "base", label: "Base", variant: "openai_whisper-base", megabytes: 147),
        .init(id: "tiny.en", label: "Tiny (English-only)", variant: "openai_whisper-tiny.en", megabytes: 153),
        .init(id: "small.en", label: "Small (English-only)", variant: "openai_whisper-small.en_217MB", megabytes: 218),
        .init(id: "small", label: "Small", variant: "openai_whisper-small_216MB", megabytes: 217),
        .init(id: "distil-large-v3", label: "Distil-Large v3", variant: "distil-whisper_distil-large-v3_594MB", megabytes: 595),
        .init(id: "large-v3-turbo", label: "Large v3 Turbo", variant: "openai_whisper-large-v3-v20240930_626MB", megabytes: 627),
        .init(id: "large-v3", label: "Large v3", variant: "openai_whisper-large-v3_947MB", megabytes: 948),
        .init(id: "large-v2", label: "Large v2", variant: "openai_whisper-large-v2_949MB", megabytes: 952),
        .init(id: "medium.en", label: "Medium (English-only)", variant: "openai_whisper-medium.en", megabytes: 1530),
        .init(id: "medium", label: "Medium", variant: "openai_whisper-medium", megabytes: 1530),
    ].sorted { $0.megabytes < $1.megabytes }

    /// First launch: small enough that an App Store reviewer can finish a job quickly.
    public static let defaultID = "base"

    public static func model(_ id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }
}
