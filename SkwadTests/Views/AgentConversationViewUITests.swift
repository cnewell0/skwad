import XCTest
import SwiftUI
import ViewInspector
import MarkdownUI
@testable import Skwad

@MainActor
final class AgentConversationViewUITests: XCTestCase {
    private var store: AgentConversationStore!

    override func setUp() {
        super.setUp()
        store = AgentConversationStore()
    }

    func testEmptyConversationExplainsTextFirstWorkflow() throws {
        let agent = Agent(name: "Builder", folder: "/tmp/project", agentType: "codex")
        let view = AgentConversationView(agent: agent, store: store, onSend: { _ in true })

        let text = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        XCTAssertTrue(text.contains("What should we build with Builder?"))
        XCTAssertTrue(text.contains("Send a task here. Open Terminal when you need the live agent session."))
    }

    func testRendersUserAndAssistantMessagesFromStore() throws {
        let agent = Agent(name: "Builder", folder: "/tmp/project", agentType: "codex")
        store.append(role: .user, text: "Add the workspace rail", for: agent.id)
        store.append(role: .assistant, text: "I’ll start with tests.", for: agent.id)
        let view = AgentConversationView(agent: agent, store: store, onSend: { _ in true })

        let text = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        XCTAssertTrue(text.contains("Add the workspace rail"))
        XCTAssertTrue(text.contains("I’ll start with tests."))
        XCTAssertNoThrow(try view.inspect().find(Markdown.self))
    }

    func testAlwaysIncludesPromptComposer() throws {
        let agent = Agent(name: "Builder", folder: "/tmp/project", agentType: "codex")
        let view = AgentConversationView(agent: agent, store: store, onSend: { _ in true })

        XCTAssertNoThrow(try view.inspect().find(AgentPromptComposer.self))
    }

    func testRunningAgentShowsLiveActivityLine() throws {
        var agent = Agent(name: "Builder", folder: "/tmp/project", agentType: "codex")
        agent.state = .running
        let view = AgentConversationView(agent: agent, store: store, onSend: { _ in true })

        let text = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        XCTAssertTrue(text.contains("Working…"))
    }

    func testPendingPromptAloneDoesNotClaimAgentIsWorking() throws {
        let agent = Agent(name: "Builder", folder: "/tmp/project", agentType: "codex")
        store.append(
            role: .user,
            text: "Find the failure",
            for: agent.id,
            delivery: .pending
        )
        let view = AgentConversationView(agent: agent, store: store, onSend: { _ in true })

        let text = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        XCTAssertFalse(text.contains("Working…"))
        XCTAssertTrue(text.contains("Waiting for agent"))
    }

    func testIdleConversationDoesNotShowLiveAgentActivity() throws {
        let agent = Agent(name: "Builder", folder: "/tmp/project", agentType: "codex")
        store.append(role: .assistant, text: "Finished", for: agent.id)
        let view = AgentConversationView(agent: agent, store: store, onSend: { _ in true })

        let text = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }

        XCTAssertFalse(text.contains("Working…"))
    }

    func testActivityLabelDescribesCurrentTimelineEntry() {
        XCTAssertEqual(
            AgentConversationView.liveActivityLabel(
                lastMessage: AgentConversationMessage(role: .assistant, kind: .toolUse, text: "make test", toolName: "Bash"),
                terminalTitle: ""
            ),
            "Running Bash…"
        )
        XCTAssertEqual(
            AgentConversationView.liveActivityLabel(
                lastMessage: AgentConversationMessage(role: .assistant, kind: .thinking, text: "hmm"),
                terminalTitle: ""
            ),
            "Thinking…"
        )
        XCTAssertEqual(
            AgentConversationView.liveActivityLabel(lastMessage: nil, terminalTitle: "Editing ContentView.swift"),
            "Editing ContentView.swift"
        )
        XCTAssertEqual(
            AgentConversationView.liveActivityLabel(lastMessage: nil, terminalTitle: ""),
            "Working…"
        )
        // The registration prompt lands in the terminal title and must not be reported
        XCTAssertEqual(
            AgentConversationView.liveActivityLabel(
                lastMessage: nil,
                terminalTitle: "List other agents names and project (no ID) in a table based on context"
            ),
            "Working…"
        )
    }

    func testDetachedWorkspaceSurfaceUsesConversationAsPrimarySurface() throws {
        let agent = Agent(name: "Detached Builder", folder: "/tmp/project", agentType: "codex")
        let view = DetachedWorkspaceConversationSurface(
            agent: agent,
            contextPaths: [],
            onAddContext: {},
            onRemoveContext: { _ in },
            onContextsSent: {},
            onSend: { _ in true }
        )

        XCTAssertNoThrow(try view.inspect().find(AgentConversationView.self))
        XCTAssertNoThrow(try view.inspect().find(AgentPromptComposer.self))
    }

    func testElapsedTextUsesCompactMinuteSecondForm() {
        XCTAssertEqual(AgentConversationView.liveElapsedText(0), "0s")
        XCTAssertEqual(AgentConversationView.liveElapsedText(12), "12s")
        XCTAssertEqual(AgentConversationView.liveElapsedText(59), "59s")
        XCTAssertEqual(AgentConversationView.liveElapsedText(60), "1m 0s")
        XCTAssertEqual(AgentConversationView.liveElapsedText(106), "1m 46s")
        XCTAssertEqual(AgentConversationView.liveElapsedText(-5), "0s")
    }
}
