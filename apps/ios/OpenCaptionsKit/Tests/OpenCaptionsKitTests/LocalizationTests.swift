import Foundation
import Testing

/// The app is translated by its string catalogs. A word nobody translated would show in English in the
/// middle of a French screen, and a translation that lost a placeholder would show the wrong number, so
/// both are checked here for every language the app claims.
@Suite struct LocalizationTests {
    static let languages = ["fr", "es", "de"]
    static let catalogs = [
        "apps/ios/OpenCaptions/Resources/Localizable.xcstrings",
        "apps/ios/OpenCaptions/Resources/InfoPlist.xcstrings",
        "apps/ios/OpenCaptionsKit/Sources/OpenCaptionsKit/Resources/Localizable.xcstrings",
    ]

    struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct Unit: Decodable { var value: String }
                var stringUnit: Unit?
            }
            var localizations: [String: Localization]?
        }
        var strings: [String: Entry]
    }

    static func placeholders(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:@|lld|d|f)")
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).map {
            String(text[Range($0.range, in: text)!]).replacingOccurrences(of: "\\d+\\$", with: "", options: .regularExpression)
        }.sorted()
    }

    @Test func everyStringIsTranslatedIntoEveryLanguageKeepingItsPlaceholders() throws {
        for path in Self.catalogs {
            let data = try Data(contentsOf: Repo.root.appendingPathComponent(path))
            let catalog = try JSONDecoder().decode(Catalog.self, from: data)
            #expect(!catalog.strings.isEmpty, "\(path) has strings")
            for (key, entry) in catalog.strings {
                for language in Self.languages {
                    let value = entry.localizations?[language]?.stringUnit?.value
                    #expect(value?.isEmpty == false, "\(path): “\(key)” is not translated into \(language)")
                    guard let value else { continue }
                    #expect(
                        Self.placeholders(value) == Self.placeholders(key),
                        "\(path): “\(key)” in \(language) changes its placeholders: \(value)")
                }
            }
        }
    }
}
