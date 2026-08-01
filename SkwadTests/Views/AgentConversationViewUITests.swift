import XCTest
import SwiftUI
import ViewInspector
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
    }

    func testAlwaysIncludesPromptComposer() throws {
        let agent = Agent(name: "Builder", folder: "/tmp/project", agentType: "codex")
        let view = AgentConversationView(agent: agent, store: store, onSend: { _ in true })

        XCTAssertNoThrow(try view.inspect().find(AgentPromptComposer.self))
    }
}
