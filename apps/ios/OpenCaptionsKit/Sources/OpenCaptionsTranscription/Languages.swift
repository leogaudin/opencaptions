import Foundation
import OpenCaptionsKit
import WhisperKit

public struct TranscriptionLanguage: Equatable, Sendable, Identifiable {
    public let code: String
    public let label: String
    public var id: String { code }
    /// A flag to recognise it by: the country most associated with the language. A language is not a
    /// country, so this is a landmark in a list, not a claim.
    public var flag: String { TranscriptionLanguages.flag(for: code) }
}

public enum TranscriptionLanguages {
    /// Every language the models accept, labelled in the device's language. The list is
    /// WhisperKit's own, so it cannot drift from what the models take.
    public static var all: [TranscriptionLanguage] {
        Constants.languageCodes.map { code in
            TranscriptionLanguage(
                code: code, label: Locale.current.localizedString(forLanguageCode: code) ?? code)
        }
        .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// The languages a model can be asked for, in alphabetical order of their names. Apple's model
    /// offers only the languages this iOS has it for.
    public static func offered(by model: SpeechModel) async -> [TranscriptionLanguage] {
        var languages = all.filter { model.covers($0.code) }
        #if canImport(Speech) && compiler(>=6.2)
            if model.engine == .appleSpeech, #available(iOS 26.0, macOS 26.0, *) {
                let supported = await AppleSpeechTranscriber.supportedLanguageCodes()
                languages = languages.filter { supported.contains($0.code) }
            }
        #endif
        return languages
    }

    /// The country a language's flag stands for, where it has a natural one.
    private static let regions: [String: String] = [
        "en": "GB", "zh": "CN", "de": "DE", "es": "ES", "ru": "RU", "ko": "KR", "fr": "FR", "ja": "JP",
        "pt": "BR", "tr": "TR", "pl": "PL", "ca": "AD", "nl": "NL", "ar": "SA", "sv": "SE", "it": "IT",
        "id": "ID", "hi": "IN", "fi": "FI", "vi": "VN", "he": "IL", "uk": "UA", "el": "GR", "ms": "MY",
        "cs": "CZ", "ro": "RO", "da": "DK", "hu": "HU", "ta": "IN", "no": "NO", "th": "TH", "ur": "PK",
        "hr": "HR", "bg": "BG", "lt": "LT", "la": "VA", "mi": "NZ", "ml": "IN", "sk": "SK", "te": "IN",
        "fa": "IR", "lv": "LV", "bn": "BD", "sr": "RS", "az": "AZ", "sl": "SI", "kn": "IN", "et": "EE",
        "mk": "MK", "br": "FR", "eu": "ES", "is": "IS", "hy": "AM", "ne": "NP", "mn": "MN", "bs": "BA",
        "kk": "KZ", "sq": "AL", "sw": "KE", "gl": "ES", "mr": "IN", "pa": "IN", "si": "LK", "km": "KH",
        "sn": "ZW", "yo": "NG", "so": "SO", "af": "ZA", "oc": "FR", "ka": "GE", "be": "BY", "tg": "TJ",
        "sd": "PK", "gu": "IN", "am": "ET", "yi": "IL", "lo": "LA", "uz": "UZ", "fo": "FO", "ht": "HT",
        "ps": "AF", "tk": "TM", "nn": "NO", "mt": "MT", "sa": "IN", "lb": "LU", "my": "MM", "tl": "PH",
        "mg": "MG", "as": "IN", "tt": "RU", "haw": "US", "ln": "CD", "ha": "NG", "ba": "RU", "jw": "ID",
        "su": "ID", "yue": "HK",
    ]

    /// The flag emoji for a language code, or a globe when the language has no country of its own.
    public static func flag(for code: String) -> String {
        if code == "cy" { return "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}" }  // Wales
        guard let region = regions[code] else { return "\u{1F310}" }
        return String(String.UnicodeScalarView(region.unicodeScalars.compactMap {
            UnicodeScalar(0x1F1E6 + $0.value - 0x41)
        }))
    }
}
