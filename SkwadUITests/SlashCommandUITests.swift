import XCTest

/// Drives the real app through XCUITest. Unlike synthetic CGEvents this owns the
/// keyboard for the duration, so it can type into the composer without the input
/// landing in whatever app happens to be frontmost.
final class SlashCommandUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Isolate from the user's real agents and keep the MCP server off a live port
        app.launchArguments += [
            "-uiTesting", "YES",
            "-restoreLayoutOnLaunch", "NO",
            "-mcpServerEnabled", "NO",
            "-SUHasLaunchedBefore", "YES",
            "-SUEnableAutomaticChecks", "NO",
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Helpers

    private var composer: XCUIElement {
        app.textFields["Agent prompt"]
    }

    /// Open the first agent so the chat surface is on screen, skipping the test when
    /// the launch state has none rather than asserting on someone else's data.
    private func openFirstAgent() throws {
        let agentButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Open '")).firstMatch
        guard agentButton.waitForExistence(timeout: 10) else {
            throw XCTSkip("No agent available in this launch state")
        }
        agentButton.click()
        XCTAssertTrue(composer.waitForExistence(timeout: 5), "composer should appear for an agent")
    }

    private func type(_ text: String) {
        composer.click()
        composer.typeText(text)
    }

    // MARK: - Palette

    func testTypingSlashOffersTheCommandPalette() throws {
        try openFirstAgent()
        type("/")

        // Rows are buttons labelled "/name: summary"
        let usage = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '/usage'")).firstMatch
        XCTAssertTrue(usage.waitForExistence(timeout: 3), "palette should list /usage")

        let context = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '/context'")).firstMatch
        XCTAssertTrue(context.exists, "palette should list /context")
    }

    func testPaletteFiltersAsYouType() throws {
        try openFirstAgent()
        type("/us")

        let usage = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '/usage'")).firstMatch
        XCTAssertTrue(usage.waitForExistence(timeout: 3), "/us should still match /usage")

        let help = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '/help'")).firstMatch
        XCTAssertFalse(help.exists, "/us should not match /help")
    }

    func testEscapeDismissesThePalette() throws {
        try openFirstAgent()
        type("/")

        let usage = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '/usage'")).firstMatch
        XCTAssertTrue(usage.waitForExistence(timeout: 3))

        composer.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(usage.waitForExistence(timeout: 1), "escape should close the palette")
    }

    func testClickingACommandFillsTheComposerWithoutSending() throws {
        try openFirstAgent()
        type("/")

        let usage = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '/usage'")).firstMatch
        XCTAssertTrue(usage.waitForExistence(timeout: 3))
        usage.click()

        XCTAssertEqual(composer.value as? String, "/usage", "selection should fill the composer")
    }

    // MARK: - Commands Skwad answers itself

    /// The regression that started this: /usage ran but its panel only ever existed
    /// in the terminal, so the chat showed nothing.
    func testUsageAnswersInTheChat() throws {
        try openFirstAgent()
        type("/usage")
        composer.typeKey(.return, modifierFlags: [])

        let report = app.staticTexts.containing(
            NSPredicate(format: "value CONTAINS 'usage' OR value CONTAINS 'turn' OR value CONTAINS 'token'")
        ).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 5), "/usage should answer in the chat")
    }

    func testStatusAnswersInTheChat() throws {
        try openFirstAgent()
        type("/status")
        composer.typeKey(.return, modifierFlags: [])

        let report = app.staticTexts.containing(
            NSPredicate(format: "value CONTAINS 'folder' OR value CONTAINS 'permissions'")
        ).firstMatch
        XCTAssertTrue(report.waitForExistence(timeout: 5), "/status should answer in the chat")
    }

    /// Return on an open palette should run the highlighted command, not send the
    /// half-typed text as a message.
    func testReturnRunsTheHighlightedCommandRatherThanSendingPartialText() throws {
        try openFirstAgent()
        type("/us")
        composer.typeKey(.return, modifierFlags: [])

        XCTAssertFalse(
            app.staticTexts["/us"].exists,
            "the partial command should never be sent as a message"
        )
    }

    // MARK: - Composer chrome

    func testComposerExposesModelAndPermissionControls() throws {
        try openFirstAgent()

        XCTAssertTrue(app.buttons["Edit agent settings"].exists, "folder and type chips open the editor")
        let permission = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Permission mode'")
        ).firstMatch
        XCTAssertTrue(permission.exists, "permission mode should be reachable from the composer")
    }
}
