import Foundation
import Testing
@testable import OpenCaptionsKit

@Suite struct ReviewPromptTests {
    private func defaults() throws -> UserDefaults {
        let name = "review-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func theFirstVideoIsNotAskedAbout() throws {
        #expect(!ReviewPrompt.finishedVideo(version: "1.1.0", defaults: try defaults()))
    }

    @Test func theSecondVideoIsAskedAboutAndOnlyOnceForAVersion() throws {
        let store = try defaults()
        #expect(!ReviewPrompt.finishedVideo(version: "1.1.0", defaults: store))
        #expect(ReviewPrompt.finishedVideo(version: "1.1.0", defaults: store))
        #expect(!ReviewPrompt.finishedVideo(version: "1.1.0", defaults: store))
        #expect(!ReviewPrompt.finishedVideo(version: "1.1.0", defaults: store))
    }

    @Test func aNewVersionMayAskAgainOnItsFirstVideo() throws {
        let store = try defaults()
        _ = ReviewPrompt.finishedVideo(version: "1.1.0", defaults: store)
        _ = ReviewPrompt.finishedVideo(version: "1.1.0", defaults: store)
        #expect(ReviewPrompt.finishedVideo(version: "1.2.0", defaults: store))
    }
}
