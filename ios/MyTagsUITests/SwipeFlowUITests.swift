import XCTest

/// "Actualité" sorting on demo data: left archives, right keeps, undo comes back.
final class SwipeFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest-demo"]
        app.launch()
    }

    private var position: String {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'File '")).firstMatch.label
    }

    private func openSwipe() {
        XCTAssertTrue(app.buttons.matching(identifier: "trackRow").firstMatch.waitForExistence(timeout: 20))
        // The demo audio is generated at launch: the first menu tap can be dropped.
        let sort = app.buttons["Trier l'actualité"]
        for _ in 0..<3 where !sort.exists {
            app.buttons["libraryMenu"].tap()
            _ = sort.waitForExistence(timeout: 3)
        }
        sort.tap()
        XCTAssertTrue(app.buttons["archiveButton"].waitForExistence(timeout: 5))
        snap("swipe-1-carte")
    }

    func testSwipeLeftArchivesAndUndoComesBack() {
        openSwipe()
        let before = position
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let middle = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.36))
        let end = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.38))
        start.press(forDuration: 0.05, thenDragTo: middle, withVelocity: .slow, thenHoldForDuration: 0.3)
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        let undo = app.buttons["undoButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Archivé"].exists)
        XCTAssertNotEqual(position, before)
        snap("swipe-2-archive-annuler")
        undo.tap()
        XCTAssertEqual(position, before)
    }

    func testKeepButtonMovesOn() {
        openSwipe()
        let before = position
        app.buttons["keepButton"].tap()
        XCTAssertTrue(app.staticTexts["D'actualité"].waitForExistence(timeout: 3))
        XCTAssertNotEqual(position, before)
    }

    private func snap(_ name: String) {
        sleep(1)
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["SNAP_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
    }
}
