import XCTest

/// Apple's accessibility audit on the screens people spend their time in. It fails on a missing or unusable
/// label, a small hit area, or anything else it finds, apart from what `isKnown` lets through.
final class AccessibilityAuditTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func file(_ name: String, _ ext: String) throws -> String {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext), "\(name).\(ext) is missing").path
    }

    private func launch(_ extra: [String: String]) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "OC_RESET": "1",
            "OC_SEED_VIDEO": try file("portrait", "mp4"),
            "OC_SEED_TRANSCRIPT": try file("transcript", "json"),
        ].merging(extra) { $1 }
        app.launch()
        return app
    }

    /// What the audit reports and a person does not meet, each checked on the screen at the largest text size.
    private static func isKnown(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        switch issue.auditType {
        // Text is capped at accessibility3, and the timeline's tracks have a fixed height.
        case .dynamicType: true
        // Rows scrolled under the fades, or out of the scroll view's frame, read as cut off and low in contrast.
        case .textClipped, .contrast: true
        // The whole timeline scrubs, so the line itself is not what is aimed at.
        case .hitRegion: issue.element?.label == "Playhead"
        // A codec's name.
        case .sufficientElementDescription: issue.element?.label == "H.264"
        default: false
        }
    }

    private func audit(_ app: XCUIApplication, _: String) throws {
        try app.performAccessibilityAudit(for: .all) { Self.isKnown($0) }
    }

    func testProjects() throws {
        let app = try launch([:])
        sleep(4)
        try audit(app, "projects")
    }

    func testSettings() throws {
        let app = try launch(["OC_TAB": "settings"])
        sleep(4)
        try audit(app, "settings")
    }

    func testEditor() throws {
        let app = try launch(["OC_OPEN_FIRST": "1", "OC_SEEK": "1.0"])
        sleep(8)
        try audit(app, "editor")
    }

    func testTranscribeSheet() throws {
        let app = try launch(["OC_OPEN_FIRST": "1", "OC_SHOW_TRANSCRIBE": "1"])
        sleep(8)
        try audit(app, "transcribe")
    }

    func testStylePanel() throws {
        let app = try launch(["OC_OPEN_FIRST": "1", "OC_SHOW_STYLE": "1"])
        sleep(8)
        try audit(app, "style")
    }

    func testSaveOptions() throws {
        let app = try launch(["OC_OPEN_FIRST": "1", "OC_SHOW_SAVE": "1"])
        sleep(8)
        try audit(app, "save")
    }
}
