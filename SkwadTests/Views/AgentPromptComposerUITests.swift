import XCTest
import SwiftUI
import ViewInspector
@testable import Skwad

@MainActor
final class AgentPromptComposerUITests: XCTestCase {
    func testRendersPromptFieldAndSendButton() throws {
        let agent = Agent(name: "Builder", folder: "/tmp/project", agentType: "codex")
        let view = AgentPromptComposer(agent: agent, onSend: { _ in true })

        XCTAssertNotNil(try? view.inspect().find(ViewType.TextField.self))
        let buttons = try view.inspect().findAll(ViewType.Button.self)
        XCTAssertFalse(buttons.isEmpty)
    }

    func testRendersWorkspaceAgentAndModelContext() throws {
        let agent = Agent(name: "Builder", folder: "/tmp/project", agentType: "codex")
        let view = AgentPromptComposer(agent: agent, onSend: { _ in true })

        let labels = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        XCTAssertTrue(labels.contains("project"))
        XCTAssertTrue(labels.contains("codex"))
    }

    func testAddContextButtonInvokesHandler() throws {
        let agent = Agent(name: "Builder", folder: "/tmp/project", agentType: "codex")
        var didRequestContext = false
        let view = AgentPromptComposer(
            agent: agent,
            onAddContext: { didRequestContext = true },
            onSend: { _ in true }
        )

        let buttons = try view.inspect().findAll(ViewType.Button.self)
        try buttons[0].tap()

        XCTAssertTrue(didRequestContext)
    }

    func testContextFileIsVisibleAndIncludedInDeliveredPrompt() throws {
        let agent = Agent(name: "Builder", folder: "/tmp/project", agentType: "codex")
        let path = "Sources/App.swift"
        let view = AgentPromptComposer(
            agent: agent,
            contextPaths: [path],
            onSend: { _ in true }
        )

        let labels = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        XCTAssertTrue(labels.contains(path))
        XCTAssertEqual(
            AgentPromptComposer.message(prompt: "Review this", contextPaths: [path]),
            "Review this\n\nContext files:\n- Sources/App.swift"
        )
    }

    func testSlashPaletteOffersClaudeCommandsAndFiltersAsYouType() {
        let all = SlashCommandCatalog.suggestions(for: "/", agentType: "claude")
        XCTAssertEqual(all?.isEmpty, false)
        XCTAssertEqual(all?.contains { $0.name == "usage" }, true)

        let filtered = SlashCommandCatalog.suggestions(for: "/co", agentType: "claude")
        XCTAssertEqual(filtered?.allSatisfy { $0.name.hasPrefix("co") }, true)
        XCTAssertEqual(filtered?.contains { $0.name == "compact" }, true)
    }

    func testSlashPaletteStaysOutOfTheWayWhenItShould() {
        // Not a command
        XCTAssertNil(SlashCommandCatalog.suggestions(for: "fix the bug", agentType: "claude"))
        // Argument being typed
        XCTAssertNil(SlashCommandCatalog.suggestions(for: "/model son", agentType: "claude"))
        // No match
        XCTAssertNil(SlashCommandCatalog.suggestions(for: "/zzz", agentType: "claude"))
        // Claude only
        XCTAssertNil(SlashCommandCatalog.suggestions(for: "/", agentType: "codex"))
        XCTAssertNil(SlashCommandCatalog.suggestions(for: "/", agentType: "shell"))
    }

    func testCompletionNeverAppendsASpaceThatWouldStrandThePreviousCommand() {
        let model = SlashCommandCatalog.commands(for: "claude").first { $0.name == "model" }!
        let usage = SlashCommandCatalog.commands(for: "claude").first { $0.name == "usage" }!

        // A trailing space turned a following "/usage" into "/model /usage"
        XCTAssertEqual(SlashCommandCatalog.completion(for: model), "/model")
        XCTAssertEqual(SlashCommandCatalog.completion(for: usage), "/usage")
    }

    func testCommandsThatDrawTheirOwnPanelAreRecognisedForCapture() {
        // Output exists only on the terminal screen, so it gets lifted into the chat
        XCTAssertTrue(SlashCommandCatalog.rendersInTerminal("/cost", agentType: "claude"))
        XCTAssertTrue(SlashCommandCatalog.rendersInTerminal("/mcp", agentType: "claude"))
        XCTAssertTrue(SlashCommandCatalog.rendersInTerminal("/export", agentType: "claude"))
        // Skwad answers this one itself, so there is nothing to capture
        XCTAssertFalse(SlashCommandCatalog.rendersInTerminal("/usage", agentType: "claude"))
        // Skwad shows its own model list instead of the agent's picker
        XCTAssertFalse(SlashCommandCatalog.rendersInTerminal("/model", agentType: "claude"))
        // These produce a real assistant turn, which the transcript already carries
        XCTAssertFalse(SlashCommandCatalog.rendersInTerminal("/review", agentType: "claude"))
        XCTAssertFalse(SlashCommandCatalog.rendersInTerminal("/init", agentType: "claude"))
        XCTAssertFalse(SlashCommandCatalog.rendersInTerminal("fix the bug", agentType: "claude"))
        XCTAssertFalse(SlashCommandCatalog.rendersInTerminal("/cost", agentType: "shell"))
    }

    func testSkwadAnswersTheCommandsItHasTheDataFor() {
        // Derived from the transcript and Skwad's own state — no agent round trip
        XCTAssertNotNil(SlashCommandCatalog.locallyHandled("/usage", agentType: "claude"))
        XCTAssertNotNil(SlashCommandCatalog.locallyHandled("/context", agentType: "claude"))
        XCTAssertNotNil(SlashCommandCatalog.locallyHandled("/status", agentType: "claude"))
        XCTAssertNotNil(SlashCommandCatalog.locallyHandled("/model", agentType: "claude"))
        // Genuinely the agent's own state, so these still go to it
        XCTAssertNil(SlashCommandCatalog.locallyHandled("/mcp", agentType: "claude"))
        XCTAssertNil(SlashCommandCatalog.locallyHandled("/usage", agentType: "shell"))
    }

    func testUsageReportBreaksDownByModel() {
        var usage = AgentUsage(turns: 3)
        usage.byModel["claude-opus-5"] = ModelUsage(input: 1200, output: 800, cacheRead: 40_000, cacheWrite: 500)
        usage.byModel["claude-haiku-4-5"] = ModelUsage(input: 560, output: 16, cacheRead: 0, cacheWrite: 0)

        let report = usage.report()

        XCTAssertTrue(report.contains("3 assistant turns"))
        XCTAssertTrue(report.contains("claude-opus-5"))
        XCTAssertTrue(report.contains("claude-haiku-4-5"))
        XCTAssertTrue(report.contains("40.0k"))
        XCTAssertTrue(report.contains("total"))
    }

    func testUsageReportSaysSoWhenThereIsNothingYet() {
        XCTAssertEqual(AgentUsage().report(), "No usage recorded for this session yet.")
    }

    /// Every command in the palette must have a defined destination: answered by
    /// Skwad, captured off the screen, or carried by the transcript. A command that
    /// matches none of those would silently do nothing when you pick it.
    @MainActor
    func testEveryPaletteCommandHasSomewhereItsAnswerAppears() {
        let agent = Agent(name: "A", folder: "/tmp/a", agentType: "claude")

        for command in SlashCommandCatalog.commands(for: "claude") {
            let text = SlashCommandCatalog.completion(for: command)
            let local = SlashCommandCatalog.locallyHandled(text, agentType: "claude") != nil
            let captured = SlashCommandCatalog.rendersInTerminal(text, agentType: "claude")
            let producesTurn = !local && !captured

            XCTAssertTrue(
                local || captured || producesTurn,
                "\(command.display) has no destination for its output"
            )

            if local {
                let report = AgentManager.localReport(for: command, agent: agent)
                XCTAssertFalse(
                    report.isEmpty,
                    "\(command.display) is handled locally but produced an empty report"
                )
                XCTAssertFalse(
                    report.hasPrefix("No local report"),
                    "\(command.display) is marked handled locally but has no implementation"
                )
            }
        }
    }

    @MainActor
    func testLocalReportsCoverModelFolderPermissionsAndContext() {
        var agent = Agent(name: "server", folder: "/tmp/repo", agentType: "claude")
        agent.isRegistered = true
        agent.metadata["model"] = "claude-opus-5[1m]"
        agent.permissionMode = "acceptEdits"

        let status = AgentManager.localReport(
            for: SlashCommandCatalog.commands(for: "claude").first { $0.name == "status" }!,
            agent: agent
        )

        XCTAssertTrue(status.contains("server"))
        XCTAssertTrue(status.contains("/tmp/repo"))
        XCTAssertTrue(status.contains("claude-opus-5[1m]"))
        XCTAssertTrue(status.contains("Auto"))
        XCTAssertTrue(status.contains("connected"))
    }

    func testContextReportUsesTheModelsWindowSize() {
        var usage = AgentUsage()
        usage.latestContextTokens = 50_000

        let oneM = usage.contextReport(model: "claude-opus-5[1m]", limit: AgentManager.contextLimit(forModel: "claude-opus-5[1m]"))
        XCTAssertTrue(oneM.contains("5%"), oneM)

        let standard = usage.contextReport(model: "claude-sonnet-5", limit: AgentManager.contextLimit(forModel: "claude-sonnet-5"))
        XCTAssertTrue(standard.contains("25%"), standard)

        XCTAssertTrue(AgentUsage().contextReport(model: nil, limit: nil).contains("No context recorded"))
    }
}
