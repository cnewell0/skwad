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

    func testCompletionLeavesRoomForAnArgumentOnlyWhenOneIsExpected() {
        let model = SlashCommandCatalog.commands(for: "claude").first { $0.name == "model" }!
        let usage = SlashCommandCatalog.commands(for: "claude").first { $0.name == "usage" }!

        XCTAssertEqual(SlashCommandCatalog.completion(for: model), "/model ")
        XCTAssertEqual(SlashCommandCatalog.completion(for: usage), "/usage")
    }
}
