import XCTest
import SwiftUI
import ViewInspector
@testable import Skwad

@MainActor
final class WorkspaceSidebarViewUITests: XCTestCase {
    func testRendersEveryAttachedWorkspaceAndItsAgents() throws {
        let manager = AgentManager()
        let firstAgent = Agent(name: "Implementer", folder: "/tmp/first")
        let secondAgent = Agent(name: "Reviewer", folder: "/tmp/second")
        let first = Workspace(name: "Application", agentIds: [firstAgent.id], activeAgentIds: [firstAgent.id])
        let second = Workspace(name: "Server", agentIds: [secondAgent.id], activeAgentIds: [secondAgent.id])
        manager.agents = [firstAgent, secondAgent]
        manager.workspaces = [first, second]
        manager.currentWorkspaceId = first.id

        let view = WorkspaceSidebarView(
            agentManager: manager,
            showNewAgentSheet: .constant(false),
            forkPrefill: .constant(nil),
            sidebarVisible: .constant(true)
        )
        .environment(manager)

        let text = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        XCTAssertTrue(text.contains("Application"))
        XCTAssertTrue(text.contains("Server"))
        XCTAssertTrue(text.contains("Implementer"))
        XCTAssertTrue(text.contains("Reviewer"))
    }

    func testCompanionRendersBelowItsParent() throws {
        let manager = AgentManager()
        let parent = Agent(name: "Lead", folder: "/tmp/project")
        let companion = Agent(
            name: "Tester",
            folder: "/tmp/project",
            createdBy: parent.id,
            isCompanion: true
        )
        let workspace = Workspace(
            name: "Project",
            agentIds: [parent.id, companion.id],
            activeAgentIds: [parent.id]
        )
        manager.agents = [parent, companion]
        manager.workspaces = [workspace]
        manager.currentWorkspaceId = workspace.id

        let view = WorkspaceSidebarView(
            agentManager: manager,
            showNewAgentSheet: .constant(false),
            forkPrefill: .constant(nil),
            sidebarVisible: .constant(true)
        )
        .environment(manager)

        let text = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        XCTAssertTrue(text.contains("Lead"))
        XCTAssertTrue(text.contains("Tester"))
    }

    func testRendersNewAgentAndNewWorkspaceActions() throws {
        let manager = AgentManager()
        let view = WorkspaceSidebarView(
            agentManager: manager,
            showNewAgentSheet: .constant(false),
            forkPrefill: .constant(nil),
            sidebarVisible: .constant(true)
        )
        .environment(manager)

        let labels = try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
        XCTAssertTrue(labels.contains("New agent"))
        XCTAssertTrue(labels.contains("New workspace"))
    }
}
