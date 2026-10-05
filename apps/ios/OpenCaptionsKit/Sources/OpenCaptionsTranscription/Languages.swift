import Foundation
import WhisperKit

public struct TranscriptionLanguage: Equatable, Sendable, Identifiable {
    public let code: String
    public let label: String
    public var id: String { code }
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
}
