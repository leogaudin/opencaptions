import XCTest

/// The two steps of the transcribe sheet, driven by real taps. A phone once reported the back arrow doing
/// nothing; this does not reproduce that on a simulator, it keeps the way back working.
final class TranscribeSheetTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func file(_ name: String, _ ext: String) throws -> String {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext), "\(name).\(ext) is missing").path
    }

    func testTheLanguageStepGoesBackToTheModels() throws {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "OC_RESET": "1",
            "OC_SEED_VIDEO": try file("portrait", "mp4"),
            "OC_SEED_TRANSCRIPT": try file("transcript", "json"),
            "OC_OPEN_FIRST": "1",
            "OC_SHOW_TRANSCRIBE": "1",
        ]
        app.launch()

        let next = app.buttons["Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "the sheet did not open on its first step")
        next.tap()
        let title = app.staticTexts["Spoken language"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Next did not reach the language step")

        app.buttons["language-back"].tap()
        XCTAssertTrue(next.waitForExistence(timeout: 5), "the back arrow did not return to the models")
        XCTAssertFalse(title.exists, "the language step stayed on screen")
    }
}
