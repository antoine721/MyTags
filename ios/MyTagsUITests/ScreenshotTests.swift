import XCTest

/// Screenshots of the main screens on demo data, kept as test attachments.
/// Run by `.github/workflows/ios-screenshots.yml` (light and dark); skipped by the regular CI.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-uitest-demo"]
        app.launch()
    }

    func testCaptureMainScreens() {
        let firstRow = app.buttons.matching(identifier: "trackRow").firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 30))
        snap("01-bibliotheque")

        let artists = app.buttons["Artistes"]
        if artists.exists {
            artists.tap()
            snap("02-artistes")
            app.buttons["Morceaux"].tap()
        }

        firstRow.tap()
        XCTAssertTrue(app.buttons["Fermer"].waitForExistence(timeout: 10))
        snap("03-taguer", settle: 2)

        for value in ["SHATTA", "VERT", "FR", "EXTEND"] where app.buttons[value].exists {
            app.buttons[value].tap()
        }
        snap("04-taguer-valeurs-choisies")

        app.buttons["4 étoiles"].tap()
        if app.buttons["undoButton"].waitForExistence(timeout: 3) {
            snap("05-morceau-suivant-et-annuler", settle: 0.6)
        }

        let options = app.buttons["Options"]
        if options.exists {
            options.tap()
            snap("06-options")
            let quick = app.buttons["Passe rapide"]
            if quick.waitForExistence(timeout: 2) {
                quick.tap()
                let genre = app.buttons["Genre"]
                if genre.waitForExistence(timeout: 2) {
                    genre.tap()
                    snap("07-passe-rapide-genre")
                    if app.buttons["Terminer"].exists { app.buttons["Terminer"].tap() }
                }
            } else {
                app.tap()
            }
        }

        let close = app.buttons["Fermer"]
        if close.waitForExistence(timeout: 3) { close.tap() }
        _ = firstRow.waitForExistence(timeout: 10)

        let filters = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Filtres'")).firstMatch
        if filters.waitForExistence(timeout: 3) {
            filters.tap()
            snap("08-filtres")
            app.swipeDown(velocity: .fast)
            sleep(1)
        }

        let settings = app.buttons["Réglages"]
        if settings.waitForExistence(timeout: 3) {
            settings.tap()
            snap("09-reglages")
            let fields = app.buttons["Champs et valeurs"]
            if fields.waitForExistence(timeout: 3) {
                fields.tap()
                snap("10-champs")
            }
        }
    }

    private func snap(_ name: String, settle: TimeInterval = 1) {
        Thread.sleep(forTimeInterval: settle)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
