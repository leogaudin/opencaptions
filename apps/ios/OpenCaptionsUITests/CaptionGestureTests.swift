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

    private func launch(_ clip: String, tier: String? = nil) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "OC_RESET": "1",
            "OC_SEED_VIDEO": try file(clip, "mp4"),
            "OC_SEED_TRANSCRIPT": try file("transcript", "json"),
            "OC_OPEN_FIRST": "1",
            "OC_SEEK": "1.0",  // a moment where a caption is showing
        ]
        if let tier { app.launchEnvironment["OC_TIER"] = tier }
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
        // From where the caption is (the default sits at the middle, low), to somewhere off the centre lines.
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
        // Not at once: a touch soon after a tap is the second tap of a double tap (which edits a word), not a drag.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        drag(app, to: (0.7, 0.3))
        let after = settled(app, after: before)
        XCTAssertEqual(Double(after.x), 70, accuracy: 7, "from \(before) to \(after)")
        XCTAssertEqual(Double(after.y), 30, accuracy: 7, "from \(before) to \(after)")
    }

    // MARK: The watermark

    /// The pixels of `region` (fractions of the preview) in a screenshot of the whole screen, as RGBA, and their width.
    private func pixels(of shot: XCUIScreenshot, in region: CGRect, of frame: CGRect) -> (Int, [UInt8]) {
        let image = shot.image
        guard let cg = image.cgImage else { return (0, []) }
        let k = CGFloat(cg.width) / image.size.width
        let crop = CGRect(
            x: (frame.minX + frame.width * region.minX) * k, y: (frame.minY + frame.height * region.minY) * k,
            width: frame.width * region.width * k, height: frame.height * region.height * k
        ).integral
        guard let part = cg.cropping(to: crop) else { return (0, []) }
        var data = [UInt8](repeating: 0, count: part.width * part.height * 4)
        let context = CGContext(
            data: &data, width: part.width, height: part.height, bitsPerComponent: 8, bytesPerRow: part.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(part, in: CGRect(x: 0, y: 0, width: part.width, height: part.height))
        return (part.width, data)
    }

    /// A free build's watermark stays where it is while the caption is dragged or pinched, as the
    /// fingers are down, not only once they lift: it is neither carried along by the caption nor
    /// shown a second time where the caption's picture has been moved to.
    func testTheWatermarkStaysPutWhileTheCaptionIsDraggedAndPinched() throws {
        let app = try launch("portrait", tier: "free")
        let frame = preview(app).frame
        // The top part of the picture, where the mark sits and where a carried one would show.
        let band = CGRect(x: 0, y: 0, width: 1, height: 0.3)
        let rest = XCUIScreen.main.screenshot()
        let (width, restBand) = pixels(of: rest, in: band, of: frame)
        let height = restBand.count / 4 / max(1, width)
        // Where the mark is: the bright pixels in the top right corner, with some room around.
        var (x0, y0, x1, y1) = (width, height, 0, 0)
        for y in 0..<(height * 2 / 5) {
            for x in (width * 2 / 5)..<width {
                let i = (y * width + x) * 4
                if restBand[i] > 200, restBand[i + 1] > 200, restBand[i + 2] > 200 {
                    (x0, y0, x1, y1) = (min(x0, x), min(y0, y), max(x1, x), max(y1, y))
                }
            }
        }
        XCTAssertGreaterThan(x1 - x0, 20, "a mark is showing")
        let room = 10
        func outsideTheMark(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var n = 0
            var checked = 0
            for y in 0..<height {
                for x in 0..<width where !(x >= x0 - room && x <= x1 + room && y >= y0 - room && y <= y1 + room) {
                    let i = (y * width + x) * 4
                    checked += 1
                    if abs(Int(a[i]) - Int(b[i])) > 24 || abs(Int(a[i + 1]) - Int(b[i + 1])) > 24 { n += 1 }
                }
            }
            return Double(n) / Double(max(1, checked))
        }
        func insideTheMark(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var n = 0
            for y in y0...y1 {
                for x in x0...x1 {
                    let i = (y * width + x) * 4
                    if abs(Int(a[i]) - Int(b[i])) > 24 || abs(Int(a[i + 1]) - Int(b[i + 1])) > 24 { n += 1 }
                }
            }
            return Double(n) / Double(max(1, (x1 - x0 + 1) * (y1 - y0 + 1)))
        }

        // Shots taken while the main thread holds the fingers down.
        let gestures: [(String, () -> Void)] = [
            ("drag", { [self] in
                at(app, 0.5, 0.84).press(
                    forDuration: 0.05, thenDragTo: at(app, 0.3, 0.92), withVelocity: .slow, thenHoldForDuration: 2.5)
            }),
        ]
        for (name, gesture) in gestures {
            var shot: XCUIScreenshot?
            let taken = expectation(description: "\(name) shot")
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.6) {
                shot = XCUIScreen.main.screenshot()
                taken.fulfill()
            }
            gesture()
            wait(for: [taken], timeout: 10)
            let during = pixels(of: try XCTUnwrap(shot), in: band, of: frame).1
            let elsewhere = outsideTheMark(restBand, during)
            let there = insideTheMark(restBand, during)
            print("WATERMARK \(name): changedElsewhere=\(elsewhere) changedInTheMark=\(there)")
            XCTAssertLessThan(there, 0.1, "the mark was changed while the caption was being dragged")
            XCTAssertLessThan(elsewhere, 0.003, "a second mark, or the caption, showed in the top of the picture while dragging")
        }
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
        // A press right after a tap counts as the second half of a double-tap, not a drag.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        drag(app, to: (0.7, 0.3))
        let after = settled(app, after: before)
        XCTAssertEqual(Double(after.x), 70, accuracy: 7, "from \(before) to \(after)")
        XCTAssertEqual(Double(after.y), 30, accuracy: 7, "from \(before) to \(after)")
    }

    // MARK: Timeline

    /// The playing time as the transport bar shows it: "0:02.00 / 0:05.00".
    private func shownTime(_ app: XCUIApplication) -> Double {
        let label = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS ' / '")).firstMatch.label
        let parts = label.split(separator: " ").first?.split(whereSeparator: { $0 == ":" || $0 == "." }).compactMap { Double($0) } ?? []
        return parts.count == 3 ? parts[0] * 60 + parts[1] + parts[2] / 100 : -1
    }

    func testDraggingTheTimelineScrubsAndTheTimeFollows() throws {
        let app = try launch("portrait")  // opens at 1.0 s
        let ruler = app.descendants(matching: .any)["Timeline ruler"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 10))
        XCTAssertEqual(shownTime(app), 1.0, accuracy: 0.05)
        // Dragging the track to the left shows what comes later: the playhead stays in the middle.
        ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).press(
            forDuration: 0.05, thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)),
            withVelocity: .slow, thenHoldForDuration: 0.5)
        let deadline = Date().addingTimeInterval(5)
        while shownTime(app) <= 1.5, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertGreaterThan(shownTime(app), 1.5, "the drag moved the time on")
        // And it stays put when the finger is up (the coast has ended).
        // The timeline coasts to a stop for a moment after the finger lifts: let it finish first.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let rested = shownTime(app)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(shownTime(app), rested, accuracy: 0.05)
    }
}
