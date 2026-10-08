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
    /// Ascending size. Downloaded on demand, never bundled. Short on purpose: no English-only
    /// models (the multilingual ones are as good in English), nothing superseded or redundant.
    public static let all: [WhisperModel] = [
        .init(id: "tiny", label: "Tiny", variant: "openai_whisper-tiny", megabytes: 77),
        .init(id: "base", label: "Base", variant: "openai_whisper-base", megabytes: 147),
        .init(id: "small", label: "Small", variant: "openai_whisper-small_216MB", megabytes: 217),
        .init(id: "large-v3-turbo", label: "Large v3 Turbo", variant: "openai_whisper-large-v3-v20240930_626MB", megabytes: 627),
        .init(id: "large-v3", label: "Large v3", variant: "openai_whisper-large-v3_947MB", megabytes: 948),
    ]

    /// Large v3 quality at two thirds of the size and much faster; the one to recommend.
    public static let defaultID = "large-v3-turbo"

    public static func model(_ id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }
}
