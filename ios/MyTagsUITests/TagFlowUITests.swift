import XCTest

/// The tag journey on demo data (spec section 19, "Parcours de tag"): choose values, rate,
/// move to the next track, missing required field, undo.
final class TagFlowUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-uitest-demo"]
        app.launch()
    }

    private func openFirstTrack() {
        let firstRow = app.buttons.matching(identifier: "trackRow").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 20))
        firstRow.tap()
        XCTAssertTrue(app.buttons["Fermer"].waitForExistence(timeout: 5))
    }

    private var position: String {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'File '")).firstMatch.label
    }

    func testRatingWithoutRequiredFieldsDoesNotAdvance() {
        openFirstTrack()
        let before = position
        app.buttons["5 étoiles"].tap()
        XCTAssertEqual(position, before)
    }

    func testValidateAdvancesAndUndoComesBack() {
        openFirstTrack()
        let before = position
        app.buttons["SHATTA"].tap()
        app.buttons["VERT"].tap()
        app.buttons["FR"].tap()
        app.buttons["EXTEND"].tap()
        app.buttons["4 étoiles"].tap()
        XCTAssertNotEqual(position, before)
        let undo = app.buttons["undoButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: 2))
        undo.tap()
        XCTAssertEqual(position, before)
    }
}
