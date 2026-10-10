import Foundation

/// What runs a speech model on the phone.
public enum SpeechEngine: Equatable, Sendable {
    /// Whisper through WhisperKit (Core ML, the Neural Engine).
    case whisperKit
    /// Parakeet through FluidAudio (Core ML, the Neural Engine).
    case parakeet
    /// The speech model built into iOS 26 (`SpeechTranscriber`), which Apple downloads and keeps.
    case appleSpeech
}

/// A speech model the phone can run. The ids are the desktop's (`asr_models.py`) where it has the
/// same model; for WhisperKit's, `variant` is the folder in `argmaxinc/whisperkit-coreml`.
public struct WhisperModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    /// The folder in the Core ML repository (WhisperKit's models).
    public let variant: String
    /// The download, in megabytes (measured from the repository). 0 for a model that ships with iOS.
    public let megabytes: Int
    public let engine: SpeechEngine
    /// ISO 639-1 codes the model transcribes; nil when it takes any language Whisper does.
    public let languages: Set<String>?
    public var englishOnly: Bool { id.hasSuffix(".en") }
    /// Whether the model ships with iOS: nothing for the app to download, size or delete.
    public var isBuiltIn: Bool { megabytes == 0 }

    init(
        id: String, label: String, variant: String = "", megabytes: Int,
        engine: SpeechEngine = .whisperKit, languages: Set<String>? = nil
    ) {
        self.id = id
        self.label = label
        self.variant = variant
        self.megabytes = megabytes
        self.engine = engine
        self.languages = languages
    }

    /// Whether the model can be asked for this language. `nil` (detect it) is always allowed:
    /// what a model does with a language it was not trained on is not up to the caller.
    public func covers(_ language: String?) -> Bool {
        guard let languages, let language, language != "auto" else { return true }
        return languages.contains(language)
    }
}

public enum WhisperModels {
    /// Parakeet TDT v3's 25 European languages.
    public static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk",
    ]

    /// The speech model built into iOS 26. Only offered where it exists.
    public static let appleSpeechID = "apple-speech"

    /// Ascending size. Downloaded on demand, never bundled. Short on purpose: no English-only
    /// models (the multilingual ones are as good in English), nothing superseded or redundant.
    private static let downloadable: [WhisperModel] = [
        .init(id: "tiny", label: "Tiny", variant: "openai_whisper-tiny", megabytes: 77),
        .init(id: "base", label: "Base", variant: "openai_whisper-base", megabytes: 147),
        .init(id: "small", label: "Small", variant: "openai_whisper-small_216MB", megabytes: 217),
        // FluidAudio's Core ML build of Parakeet TDT v3 (about 480 MB). Faster than Whisper for
        // somewhat more errors; see docs/ASR-MODELS.md.
        .init(
            id: "parakeet-tdt-0.6b-v3", label: "Parakeet v3", megabytes: 480, engine: .parakeet,
            languages: parakeetLanguages),
        .init(id: "large-v3-turbo", label: "Large v3 Turbo", variant: "openai_whisper-large-v3-v20240930_626MB", megabytes: 627),
        .init(id: "large-v3", label: "Large v3", variant: "openai_whisper-large-v3_947MB", megabytes: 948),
    ]

    private static let appleSpeech = WhisperModel(
        id: appleSpeechID, label: "Apple Speech", megabytes: 0, engine: .appleSpeech)

    /// What this phone offers: the downloadable models, and Apple's where iOS has it.
    public static var all: [WhisperModel] {
        if #available(iOS 26.0, macOS 26.0, *) { return downloadable + [appleSpeech] }
        return downloadable
    }

    /// Large v3 quality at two thirds of the size and much faster; the one to recommend.
    public static let defaultID = "large-v3-turbo"

    public static func model(_ id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }
}
