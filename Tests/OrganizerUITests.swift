import XCTest

/// Native iPhone-simulator UI tests. Every screen is driven through the real app and captured
/// as a kept XCTAttachment screenshot (exported by scripts/test-ui.sh). The app seeds synthetic
/// data when launched with `--ui-testing` (see MixCapture/SimulatorFixtures.swift).
/// Missing controls fail the test; nothing here is skipped.
/// The microphone/recording path is intentionally not exercised (no fixture microphone).
@MainActor
final class OrganizerUITests: XCTestCase {
    private let recipeTitle = "مكرونة بالطماطم"
    private let timeout: TimeInterval = 20

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Helpers

    private func launch(dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(ar)", "-AppleLocale", "ar_EG"]
        if dark { app.launchArguments += ["-AppleInterfaceStyle", "Dark"] }
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func element(_ app: XCUIApplication, labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @discardableResult
    private func require(_ element: XCUIElement, _ what: String, file: StaticString = #filePath,
                         line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "Missing UI element: \(what)",
                      file: file, line: line)
        return element
    }

    /// Tab by accessibility identifier; falls back to the tab-bar position (home, library,
    /// expenses, settings) because SwiftUI tab items may only expose their Arabic label.
    private func openTab(_ app: XCUIApplication, id: String, index: Int) {
        let byID = element(app, id: id)
        if byID.waitForExistence(timeout: 5), byID.isHittable {
            byID.tap()
            return
        }
        let buttons = app.tabBars.buttons
        require(buttons.element(boundBy: 0), "tab bar (\(id))")
        XCTAssertGreaterThan(buttons.count, index, "Tab bar has no tab at index \(index) for \(id)")
        buttons.element(boundBy: index).tap()
    }

    private func waitForHome(_ app: XCUIApplication) {
        let homeTab = element(app, id: "tab.home")
        let anyTab = app.tabBars.buttons.firstMatch
        XCTAssertTrue(homeTab.waitForExistence(timeout: 30) || anyTab.waitForExistence(timeout: 5),
                      "Home screen did not appear")
        require(element(app, id: "action.record"), "action.record on home")
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        require(back, "navigation back button").tap()
    }

    private func openRecipe(_ app: XCUIApplication) {
        // Chips are optional; use the recipe filter when present to bring the recipe into view.
        let chip = element(app, id: "library.filter.recipe")
        if chip.waitForExistence(timeout: 3) { chip.tap() }
        let recipe = element(app, labelContaining: recipeTitle)
        require(recipe, "recipe row «\(recipeTitle)»")
        recipe.tap()
    }

    // MARK: Tests

    /// Walks every main screen in order and records screenshots 1-6.
    func testNativeNavigationAndScreenshots() throws {
        let app = launch()
        waitForHome(app)
        screenshot(app, "01-home")

        openTab(app, id: "tab.library", index: 1)
        require(element(app, id: "library.add"), "library.add on library")
        require(element(app, labelContaining: recipeTitle), "seeded recipe in library")
        screenshot(app, "02-library")

        openRecipe(app)
        // Detail shows ingredients and steps seeded for the recipe.
        require(element(app, labelContaining: "حبات طماطم"), "recipe ingredient in detail")
        XCTAssertTrue(element(app, labelContaining: "اسلق المكرونة").exists, "recipe step missing in detail")
        screenshot(app, "03-recipe-detail")
        goBack(app)
        require(element(app, id: "library.add"), "library after back from recipe")

        openTab(app, id: "tab.expenses", index: 2)
        let egp = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "EGP")).firstMatch
        let usd = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "USD")).firstMatch
        require(egp, "EGP total on expenses")
        require(usd, "USD total on expenses (currencies must stay separate)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "350.50")).firstMatch
            .waitForExistence(timeout: 5), "EGP expense amount missing")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "12.99")).firstMatch
            .exists, "USD expense amount missing")
        screenshot(app, "04-expenses")

        openTab(app, id: "tab.settings", index: 3)
        require(element(app, id: "settings.backup"), "settings.backup")
        require(element(app, id: "settings.import"), "settings.import")
        screenshot(app, "05-settings")

        openTab(app, id: "tab.home", index: 0)
        let review = element(app, id: "home.review")
        require(review, "home.review card (ambiguous reminder seeded for review)")
        review.tap()
        require(app.navigationBars["المراجعة"], "review screen navigation bar")
        // The seeded ambiguous reminder must be listed as a reviewable item.
        let draft = app.cells.firstMatch
        require(draft, "review queue row for the ambiguous reminder")
        screenshot(app, "06-review")
        draft.tap()
        let reviewSave = require(element(app, id: "review.save"), "review.save in review editor")
        XCTAssertFalse(reviewSave.isEnabled, "Ambiguous reminder cannot save without an explicit date")
        screenshot(app, "06b-review-editor")
    }

    /// Settings with the dark appearance (also exercises launch with a different style).
    func testDarkAppearanceScreenshots() throws {
        let app = launch(dark: true)
        waitForHome(app)
        screenshot(app, "07-home-dark")
        openTab(app, id: "tab.library", index: 1)
        require(element(app, labelContaining: recipeTitle), "seeded recipe in dark library")
        screenshot(app, "08-library-dark")
    }

    func testTaskCompletionPersistsAcrossRelaunch() throws {
        var app = launch()
        waitForHome(app)
        openTab(app, id: "tab.library", index: 1)
        require(element(app, id: "library.filter.task"), "task filter").tap()
        require(element(app, labelContaining: "مراجعة ميزانية مشروع Home"), "fixture task").tap()
        require(element(app, id: "library.toggle"), "complete task").tap()
        XCTAssertTrue(element(app, id: "library.toggle").label.contains("إلغاء"), "Task did not complete")
        app.terminate()
        app = launch()
        waitForHome(app)
        openTab(app, id: "tab.library", index: 1)
        require(element(app, id: "library.filter.task"), "task filter after relaunch").tap()
        require(element(app, labelContaining: "مراجعة ميزانية مشروع Home"), "saved task").tap()
        let toggle = require(element(app, id: "library.toggle"), "saved completed task")
        XCTAssertTrue(toggle.label.contains("إلغاء"), "Task completion was not persisted")
        screenshot(app, "14-completed-task")
    }

    /// A typed command is organized and saved; the expense shows up in the expenses tab.
    func testTypedCommandCreatesExpense() throws {
        let app = launch()
        waitForHome(app)

        require(element(app, id: "action.type"), "action.type").tap()
        let input = require(element(app, id: "input.command"), "input.command")
        input.tap()
        input.typeText("paid 73.25 EGP for Uber")
        screenshot(app, "09-typed-command")
        require(element(app, id: "action.saveCommand"), "action.saveCommand").tap()

        // The sheet shows an undoable receipt once the command is organized and committed.
        require(element(app, id: "receipt.undo"), "receipt with undo after saving the command")
        screenshot(app, "10-command-receipt")
        let close = app.buttons["إغلاق"]
        require(close, "command sheet close button").tap()

        openTab(app, id: "tab.expenses", index: 2)
        let amount = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "73.25")).firstMatch
        require(amount, "expense with amount 73.25 after typed command")
        XCTAssertTrue(element(app, labelContaining: "Uber").exists, "expense title Uber missing")
        screenshot(app, "11-expense-after-command")
    }

    /// Relaunch without resetting data: fixtures persist and are not seeded a second time.
    func testUndoTypedCommandRefreshesReceiptAndRemovesExpense() throws {
        let app = launch()
        waitForHome(app)
        require(element(app, id: "action.type"), "type command").tap()
        let input = require(element(app, id: "input.command"), "command input")
        input.tap()
        input.typeText("paid 61.35 EGP for taxi")
        require(element(app, id: "action.saveCommand"), "save command").tap()
        require(element(app, id: "receipt.undo"), "undo receipt").tap()
        require(app.buttons["تراجع"], "confirm undo").tap()
        require(app.staticTexts["تم التراجع"], "receipt refresh after undo")
        screenshot(app, "13-undone-receipt")
        require(app.buttons["إغلاق"], "close command").tap()
        openTab(app, id: "tab.expenses", index: 2)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "61.35")).firstMatch.exists,
                       "Undone expense remains in the app")
    }

    /// Relaunch without resetting data: fixtures persist and are not seeded a second time.
    func testRelaunchDoesNotDuplicateFixtures() throws {
        var app = launch()
        waitForHome(app)
        openTab(app, id: "tab.library", index: 1)
        require(element(app, labelContaining: recipeTitle), "seeded recipe on first launch")
        app.terminate()

        app = launch()
        waitForHome(app)
        openTab(app, id: "tab.library", index: 1)
        require(element(app, labelContaining: recipeTitle), "seeded recipe after relaunch")
        let titles = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", recipeTitle))
        XCTAssertLessThanOrEqual(titles.count, 1, "Recipe fixture was duplicated on relaunch")
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "اجتماع الأسبوع القادم"))
        XCTAssertLessThanOrEqual(note.count, 1, "Note fixture was duplicated on relaunch")

        // The EGP total is 350.50 on a clean store; seeding twice would show 701.00 instead.
        openTab(app, id: "tab.expenses", index: 2)
        require(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "350.50")).firstMatch,
                "EGP 350.50 after relaunch")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "701.00")).firstMatch.exists,
                       "Expense fixtures were seeded twice")
        screenshot(app, "12-expenses-after-relaunch")
    }
}
