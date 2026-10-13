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
public struct SpeechModel: Equatable, Sendable, Identifiable {
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

public enum SpeechModels {
    /// Parakeet's 25 European languages.
    public static let parakeetLanguages: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
        "lv", "lt", "mt", "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk",
    ]

    public static let parakeetUltraID = "parakeet-ultra"
    public static let parakeetReduxID = "parakeet-redux"

    /// The speech model built into iOS 26. Only offered where it exists.
    public static let appleSpeechID = "apple-speech"

    /// Ascending size. Downloaded on demand, never bundled. Short on purpose: no English-only
    /// models (the multilingual ones are as good in English), nothing superseded or redundant.
    private static let downloadable: [SpeechModel] = [
        .init(id: "small", label: "Whisper Small", variant: "openai_whisper-small_216MB", megabytes: 217),
        // Moondream's Parakeet Redux through FluidAudio: v3 with a ternary encoder, a third of the download for
        // a few more errors, worse in noise and in some languages (iOS 18; the first load takes minutes).
        .init(
            id: parakeetReduxID, label: "Parakeet Redux", megabytes: 220, engine: .parakeet,
            languages: parakeetLanguages),
        .init(id: "large-v3-turbo", label: "Whisper Large v3", variant: "openai_whisper-large-v3-v20240930_626MB", megabytes: 627),
        // Moondream's Parakeet Ultra (v3 trained further) through FluidAudio, about 630 MB. Faster than
        // Whisper for somewhat more errors; see docs/project/speech-model-benchmarks.md.
        .init(
            id: parakeetUltraID, label: "Parakeet Ultra", megabytes: 632, engine: .parakeet,
            languages: parakeetLanguages),
    ]

    private static let appleSpeech = SpeechModel(
        id: appleSpeechID, label: "Apple Speech", megabytes: 0, engine: .appleSpeech)

    /// What this phone offers: the downloadable models, and Apple's where iOS has it.
    public static var all: [SpeechModel] {
        if #available(iOS 26.0, macOS 26.0, *) { return downloadable + [appleSpeech] }
        return downloadable
    }

    /// The model selected the first time someone asks to transcribe, and the one kept loaded at launch. Parakeet
    /// Ultra: the fastest of the accurate ones, for the 25 European languages most captions are in.
    public static let defaultID = parakeetUltraID

    /// The model to start from: the one chosen last if this phone still offers it, else the default.
    public static func initial(stored: String) -> String {
        model(stored)?.id ?? defaultID
    }

    public static func model(_ id: String) -> SpeechModel? {
        all.first { $0.id == id }
    }
}
