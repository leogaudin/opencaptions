import XCTest

/// The caption's drag and pinch, driven by real touches on a simulator, on a portrait and a landscape
/// clip. The unit tests cover the maths; only this shows that the recognisers receive the touches, that
/// the caption follows them, and that what they settle on is what is saved.
///
/// The app reads its clip and captions from the files named in the launch environment (debug builds
/// only) and shows the caption's size and place as an invisible label the tests read.
final class CaptionGestureTests: XCTestCase {
    struct CaptionStyle: Equatable {
        var size: Int
        var x: Int
        var y: Int
    }

    override func setUp() {
        continueAfterFailure = false
    }

    private func file(_ name: String, _ ext: String) throws -> String {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext), "\(name).\(ext) is missing").path
    }

    private func launch(_ clip: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "OC_RESET": "1",
            "OC_SEED_VIDEO": try file(clip, "mp4"),
            "OC_SEED_TRANSCRIPT": try file("transcript", "json"),
            "OC_OPEN_FIRST": "1",
            "OC_SEEK": "1.0",  // a moment where a caption is showing
        ]
        app.launch()
        XCTAssertTrue(preview(app).waitForExistence(timeout: 30), "the editor did not open")
        XCTAssertTrue(readout(app).waitForExistence(timeout: 10))
        // Not before the first caption frame is on screen: until then there is nothing to grab.
        let drawn = NSPredicate(format: "value == 'drawn'")
        wait(for: [expectation(for: drawn, evaluatedWith: preview(app))], timeout: 30)
        return app
    }

    private func preview(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["preview"]
    }

    private func readout(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["debug-style"]
    }

    private func style(_ app: XCUIApplication) -> CaptionStyle {
        // "size=48 x=50 y=84"
        let numbers = readout(app).label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        return numbers.count == 3 ? CaptionStyle(size: numbers[0], x: numbers[1], y: numbers[2]) : CaptionStyle(size: 0, x: 0, y: 0)
    }

    /// Waits for the saved style to differ from `before`, which is the commit after the fingers lift.
    private func settled(_ app: XCUIApplication, after before: CaptionStyle) -> CaptionStyle {
        let deadline = Date().addingTimeInterval(6)
        while style(app) == before, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        return style(app)
    }

    private func at(_ app: XCUIApplication, _ x: Double, _ y: Double) -> XCUICoordinate {
        preview(app).coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func drag(_ app: XCUIApplication, to target: (x: Double, y: Double)) {
        // From where the caption is (Classic sits at the middle, low), to somewhere off the centre lines.
        at(app, 0.5, 0.84).press(
            forDuration: 0.05, thenDragTo: at(app, target.x, target.y), withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    // MARK: Portrait

    func testPinchingOutMakesTheCaptionBiggerOnAPortraitVideo() throws {
        let app = try launch("portrait")
        let before = style(app)
        preview(app).pinch(withScale: 1.8, velocity: 2)
        let after = settled(app, after: before)
        XCTAssertGreaterThan(after.size, before.size + 10, "from \(before) to \(after)")
        XCTAssertEqual(after.x, before.x, "a pinch does not move it")
        XCTAssertEqual(after.y, before.y)
    }

    func testPinchingInMakesItSmaller() throws {
        let app = try launch("portrait")
        let before = style(app)
        preview(app).pinch(withScale: 0.5, velocity: -2)
        let after = settled(app, after: before)
        XCTAssertLessThan(after.size, before.size - 8, "from \(before) to \(after)")
    }

    func testDraggingTheCaptionMovesIt() throws {
        let app = try launch("portrait")
        let before = style(app)
        drag(app, to: (0.3, 0.4))
        let after = settled(app, after: before)
        XCTAssertEqual(Double(after.x), 30, accuracy: 6, "from \(before) to \(after)")
        XCTAssertEqual(Double(after.y), 40, accuracy: 6, "from \(before) to \(after)")
        XCTAssertEqual(after.size, before.size, "a drag does not resize it")
    }

    func testDraggingWhileTheVideoPlays() throws {
        let app = try launch("portrait")
        let before = style(app)
        preview(app).tap()  // plays
        drag(app, to: (0.7, 0.3))
        let after = settled(app, after: before)
        XCTAssertEqual(Double(after.x), 70, accuracy: 7, "from \(before) to \(after)")
        XCTAssertEqual(Double(after.y), 30, accuracy: 7, "from \(before) to \(after)")
    }

    // MARK: Landscape

    func testPinchingOnALandscapeVideo() throws {
        let app = try launch("landscape")
        let before = style(app)
        preview(app).pinch(withScale: 1.8, velocity: 2)
        let after = settled(app, after: before)
        XCTAssertGreaterThan(after.size, before.size + 10, "from \(before) to \(after)")
    }

    func testDraggingTheCaptionOnALandscapeVideo() throws {
        let app = try launch("landscape")
        let before = style(app)
        drag(app, to: (0.3, 0.4))
        let after = settled(app, after: before)
        XCTAssertEqual(Double(after.x), 30, accuracy: 6, "from \(before) to \(after)")
        XCTAssertEqual(Double(after.y), 40, accuracy: 6, "from \(before) to \(after)")
    }

    func testDraggingTheCaptionOnALandscapeVideoWhileItPlays() throws {
        let app = try launch("landscape")
        let before = style(app)
        preview(app).tap()
        drag(app, to: (0.7, 0.3))
        let after = settled(app, after: before)
        XCTAssertEqual(Double(after.x), 70, accuracy: 7, "from \(before) to \(after)")
        XCTAssertEqual(Double(after.y), 30, accuracy: 7, "from \(before) to \(after)")
    }
}
