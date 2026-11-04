import Foundation

/// When to ask for a rating: as someone leaves a finished video, from the second one on, and once for
/// each version of the app. One video is a try; two is someone who came back. It is only ever asked
/// after a save that worked. The system decides whether the prompt shows at all, and the count never
/// leaves the phone.
public enum ReviewPrompt {
    public static let savesBeforeAsking = 2

    private static let savesKey = "review.saves"
    private static let askedKey = "review.askedVersion"

    public static func shouldAsk(saves: Int, askedVersion: String?, version: String) -> Bool {
        saves >= savesBeforeAsking && askedVersion != version
    }

    /// Notes one finished video, and says whether to ask now. A yes is remembered as asked.
    public static func finishedVideo(version: String, defaults: UserDefaults = .standard) -> Bool {
        let saves = defaults.integer(forKey: savesKey) + 1
        defaults.set(saves, forKey: savesKey)
        guard shouldAsk(saves: saves, askedVersion: defaults.string(forKey: askedKey), version: version) else {
            return false
        }
        defaults.set(version, forKey: askedKey)
        return true
    }
}
