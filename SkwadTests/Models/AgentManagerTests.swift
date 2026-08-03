import Testing
import SwiftUI
@testable import Skwad

/// Tests for AgentManager that actually test the real implementation
@Suite("AgentManager", .serialized)
struct AgentManagerTests {

    // MARK: - Test Setup

    /// Create a fresh AgentManager for testing
    @MainActor
    static func createTestManager() -> AgentManager {
        let manager = AgentManager()
        manager.agents = []
        manager.workspaces = []
        manager.currentWorkspaceId = nil
        return manager
    }

    /// Create test agents
    static func createTestAgents(count: Int, agentType: String = "claude") -> [Agent] {
        (0..<count).map { i in
            Agent(name: "Agent\(i)", folder: "/tmp/test/agent\(i)", agentType: agentType)
        }
    }

    /// Set up a manager with a workspace and agents
    @MainActor
    static func setupManager(agentCount: Int, agentType: String = "claude", mode: LayoutMode = .single) -> AgentManager {
        let manager = createTestManager()
        let agents = createTestAgents(count: agentCount, agentType: agentType)

        manager.agents = agents
        let workspace = Workspace(
            name: "Test",
            agentIds: agents.map { $0.id },
            layoutMode: mode,
            activeAgentIds: agents.isEmpty ? [] : [agents[0].id],
            focusedPaneIndex: 0
        )
        manager.workspaces = [workspace]
        manager.currentWorkspaceId = workspace.id

        return manager
    }

    // MARK: - Workspace Tests

    @Suite("Prompt delivery")
    struct PromptDeliveryTests {
        @Test("sendPrompt submits through the active terminal controller and records pending chat")
        @MainActor
        func sendPromptDeliversAndRecords() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agent = manager.agents[0]
            let controller = manager.createController(for: agent)
            let adapter = MockTerminalAdapter()
            controller.attach(to: adapter)
            AgentConversationStore.shared.clearAll()

            let delivered = manager.sendPrompt("  Build the feature  ", for: agent.id)

            #expect(delivered)
            #expect(adapter.sentTexts == ["Build the feature"])
            #expect(AgentConversationStore.shared.messages(for: agent.id).map(\.text) == ["Build the feature"])
            #expect(AgentConversationStore.shared.messages(for: agent.id).first?.delivery == .pending)
        }

        @Test("sendPrompt rejects blank text")
        @MainActor
        func sendPromptRejectsBlankText() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agent = manager.agents[0]
            let controller = manager.createController(for: agent)
            let adapter = MockTerminalAdapter()
            controller.attach(to: adapter)

            let delivered = manager.sendPrompt(" \n ", for: agent.id)

            #expect(!delivered)
            #expect(adapter.sentTexts.isEmpty)
        }

        @Test("sendPrompt reports unavailable controller instead of losing prompt")
        @MainActor
        func sendPromptRequiresController() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agent = manager.agents[0]

            let delivered = manager.sendPrompt("Hello", for: agent.id)

            #expect(!delivered)
            #expect(AgentConversationStore.shared.messages(for: agent.id).isEmpty)
        }
    }

    @Suite("Workspace CRUD")
    struct WorkspaceCRUDTests {

        @Test("addAgent can target an empty detached workspace without switching the main workspace")
        @MainActor
        func addAgentTargetsRequestedWorkspace() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let mainWorkspace = manager.workspaces[0]
            let detachedWorkspace = Workspace(name: "Detached", isDetached: true)
            manager.workspaces.append(detachedWorkspace)

            let newAgentId = manager.addAgent(
                folder: "/tmp/detached-agent",
                name: "Detached Agent",
                targetWorkspaceId: detachedWorkspace.id
            )

            #expect(newAgentId != nil)
            #expect(manager.currentWorkspaceId == mainWorkspace.id)
            #expect(manager.workspaces.first { $0.id == mainWorkspace.id }?.agentIds == mainWorkspace.agentIds)
            #expect(manager.workspaces.first { $0.id == detachedWorkspace.id }?.agentIds == [newAgentId!])
            #expect(manager.workspaces.first { $0.id == detachedWorkspace.id }?.activeAgentIds == [newAgentId!])
        }

        @Test("removeAgent cleans up its detached workspace without changing the main workspace")
        @MainActor
        func removeAgentFromDetachedWorkspace() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let mainWorkspace = manager.workspaces[0]
            let detachedAgent = Agent(name: "Detached", folder: "/tmp/detached")
            let detachedWorkspace = Workspace(
                name: "Detached",
                agentIds: [detachedAgent.id],
                activeAgentIds: [detachedAgent.id],
                isDetached: true
            )
            manager.agents.append(detachedAgent)
            manager.workspaces.append(detachedWorkspace)

            manager.removeAgent(detachedAgent)

            #expect(manager.currentWorkspaceId == mainWorkspace.id)
            #expect(manager.workspaces.first { $0.id == mainWorkspace.id }?.agentIds == mainWorkspace.agentIds)
            #expect(manager.workspaces.first { $0.id == detachedWorkspace.id }?.agentIds.isEmpty == true)
            #expect(manager.workspaces.first { $0.id == detachedWorkspace.id }?.activeAgentIds.isEmpty == true)
            #expect(!manager.agents.contains { $0.id == detachedAgent.id })
        }

        @Test("addWorkspace creates new workspace")
        @MainActor
        func addWorkspaceCreatesNew() async {
            let manager = AgentManagerTests.createTestManager()

            let workspace = manager.addWorkspace(name: "New Workspace", color: .blue)

            #expect(manager.workspaces.count == 1)
            #expect(manager.workspaces[0].name == "New Workspace")
            #expect(manager.currentWorkspaceId == workspace.id)
        }

        @Test("addWorkspace sets as current")
        @MainActor
        func addWorkspaceSetsAsCurrent() async {
            let manager = AgentManagerTests.createTestManager()

            let ws1 = manager.addWorkspace(name: "First")
            let ws2 = manager.addWorkspace(name: "Second")

            #expect(manager.currentWorkspaceId == ws2.id)
            #expect(manager.workspaces.count == 2)
            _ = ws1
        }

        @Test("updateWorkspace changes name and color")
        @MainActor
        func updateWorkspaceChangesNameAndColor() async {
            let manager = AgentManagerTests.createTestManager()
            let workspace = manager.addWorkspace(name: "Original", color: .blue)

            manager.updateWorkspace(id: workspace.id, name: "Updated", colorHex: WorkspaceColor.green.rawValue)

            #expect(manager.workspaces[0].name == "Updated")
            #expect(manager.workspaces[0].colorHex == WorkspaceColor.green.rawValue)
        }

        @Test("switchToWorkspace changes current workspace")
        @MainActor
        func switchToWorkspaceChangesCurrent() async {
            let manager = AgentManagerTests.createTestManager()
            let ws1 = manager.addWorkspace(name: "First")
            _ = manager.addWorkspace(name: "Second")

            manager.switchToWorkspace(ws1.id)

            #expect(manager.currentWorkspaceId == ws1.id)
        }

        @Test("switchToWorkspace ignores invalid id")
        @MainActor
        func switchToWorkspaceIgnoresInvalid() async {
            let manager = AgentManagerTests.createTestManager()
            _ = manager.addWorkspace(name: "First")
            let currentId = manager.currentWorkspaceId

            manager.switchToWorkspace(UUID())

            #expect(manager.currentWorkspaceId == currentId)
        }

        @Test("removeWorkspace removes and switches to another")
        @MainActor
        func removeWorkspaceSwitchesToAnother() async {
            let manager = AgentManagerTests.createTestManager()
            let ws1 = manager.addWorkspace(name: "First")
            let ws2 = manager.addWorkspace(name: "Second")

            manager.removeWorkspace(ws2)

            #expect(manager.workspaces.count == 1)
            #expect(manager.currentWorkspaceId == ws1.id)
        }

        @Test("moveWorkspace reorders workspaces")
        @MainActor
        func moveWorkspaceReorders() async {
            let manager = AgentManagerTests.createTestManager()
            _ = manager.addWorkspace(name: "First")
            _ = manager.addWorkspace(name: "Second")
            _ = manager.addWorkspace(name: "Third")

            manager.moveWorkspace(from: IndexSet(integer: 0), to: 2)

            #expect(manager.workspaces[0].name == "Second")
            #expect(manager.workspaces[1].name == "First")
        }
    }

    // MARK: - Agent CRUD Tests

    @Suite("Agent CRUD")
    struct AgentCRUDTests {

        @Test("addAgent creates agent and workspace if needed")
        @MainActor
        func addAgentCreatesAgentAndWorkspace() async {
            let manager = AgentManagerTests.createTestManager()

            manager.addAgent(folder: "/tmp/test", name: "TestAgent")

            #expect(manager.agents.count == 1)
            #expect(manager.agents[0].name == "TestAgent")
            #expect(manager.workspaces.count == 1)
            #expect(manager.currentWorkspaceAgents.count == 1)
        }

        @Test("addAgent uses folder name if no name provided")
        @MainActor
        func addAgentUsesFolderName() async {
            let manager = AgentManagerTests.createTestManager()

            manager.addAgent(folder: "/tmp/my-project")

            #expect(manager.agents[0].name == "my-project")
        }

        @Test("addAgent with insertAfterId inserts at correct position")
        @MainActor
        func addAgentInsertsAtCorrectPosition() async {
            let manager = AgentManagerTests.setupManager(agentCount: 2)
            let firstAgentId = manager.agents[0].id

            manager.addAgent(folder: "/tmp/new", name: "NewAgent", insertAfterId: firstAgentId)

            #expect(manager.agents.count == 3)
            #expect(manager.agents[1].name == "NewAgent")
        }

        @Test("updateAgent changes name and avatar")
        @MainActor
        func updateAgentChangesNameAndAvatar() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id

            manager.updateAgent(id: agentId, name: "Updated", avatar: "🚀")

            #expect(manager.agents[0].name == "Updated")
            #expect(manager.agents[0].avatar == "🚀")
        }

        @Test("updateAgent with folder change updates folder")
        @MainActor
        func updateAgentWithFolderChange() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id

            manager.updateAgent(id: agentId, name: "Updated", avatar: "🚀", folder: "/tmp/new-folder")

            #expect(manager.agents[0].folder == "/tmp/new-folder")
        }

        @Test("updateAgent with relocateCompanions updates matching companions")
        @MainActor
        func updateAgentRelocatesCompanions() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let parent = manager.agents[0]

            // Add companions: one with same folder, one with different folder
            let companion1 = Agent(name: "Comp1", folder: parent.folder, createdBy: parent.id, isCompanion: true)
            let companion2 = Agent(name: "Comp2", folder: "/tmp/other", createdBy: parent.id, isCompanion: true)
            manager.agents.append(companion1)
            manager.agents.append(companion2)

            manager.updateAgent(id: parent.id, name: parent.name, avatar: "🤖", folder: "/tmp/new-folder", relocateCompanions: true)

            #expect(manager.agents[0].folder == "/tmp/new-folder")
            // companion1 had same folder as parent -> relocated
            #expect(manager.agents.first(where: { $0.id == companion1.id })?.folder == "/tmp/new-folder")
            // companion2 had different folder -> unchanged
            #expect(manager.agents.first(where: { $0.id == companion2.id })?.folder == "/tmp/other")
        }

        @Test("updateAgent without relocateCompanions leaves companions unchanged")
        @MainActor
        func updateAgentDoesNotRelocateCompanions() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let parent = manager.agents[0]

            let companion = Agent(name: "Comp", folder: parent.folder, createdBy: parent.id, isCompanion: true)
            manager.agents.append(companion)

            manager.updateAgent(id: parent.id, name: parent.name, avatar: "🤖", folder: "/tmp/new-folder", relocateCompanions: false)

            #expect(manager.agents[0].folder == "/tmp/new-folder")
            #expect(manager.agents.first(where: { $0.id == companion.id })?.folder == parent.folder)
        }

        @Test("duplicateAgent creates copy with suffix")
        @MainActor
        func duplicateAgentCreatesCopy() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let original = manager.agents[0]

            manager.duplicateAgent(original)

            #expect(manager.agents.count == 2)
            #expect(manager.agents[1].name == "\(original.name) (copy)")
            #expect(manager.agents[1].folder == original.folder)
        }

        @Test("duplicateCompanions copies companions to new agent")
        @MainActor
        func duplicateCompanionsCopies() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let source = manager.agents[0]

            // Add companions to source
            let comp1 = Agent(name: "Comp1", avatar: "🔧", folder: source.folder, agentType: "shell", createdBy: source.id, isCompanion: true)
            let comp2 = Agent(name: "Comp2", avatar: "🔨", folder: source.folder, agentType: "claude", createdBy: source.id, isCompanion: true)
            manager.agents.append(comp1)
            manager.agents.append(comp2)

            // Create a new "forked" agent
            let newAgentId = manager.addAgent(folder: "/tmp/forked", name: "Forked")!

            // Duplicate companions from source to new agent with new folder
            manager.duplicateCompanions(from: source.id, to: newAgentId, newFolder: "/tmp/forked")

            let newCompanions = manager.companions(of: newAgentId)
            #expect(newCompanions.count == 2)
            #expect(newCompanions.allSatisfy { $0.folder == "/tmp/forked" })
            #expect(newCompanions.allSatisfy { $0.isCompanion })
            #expect(newCompanions.allSatisfy { $0.createdBy == newAgentId })
            // Original companions unchanged
            #expect(manager.companions(of: source.id).count == 2)
        }

        @Test("duplicateAgent preserves personaId")
        @MainActor
        func duplicateAgentPreservesPersonaId() async {
            let manager = AgentManagerTests.setupManager(agentCount: 0)
            let personaId = UUID()
            manager.addAgent(folder: "/tmp/test", name: "Original", agentType: "claude", personaId: personaId)
            let original = manager.agents[0]

            manager.duplicateAgent(original)

            #expect(manager.agents.count == 2)
            #expect(manager.agents[1].personaId == personaId)
        }

        @Test("duplicateCompanions preserves personaId")
        @MainActor
        func duplicateCompanionsPreservesPersonaId() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let source = manager.agents[0]
            let personaId = UUID()

            let comp = Agent(name: "Comp", folder: source.folder, agentType: "codex", createdBy: source.id, isCompanion: true, personaId: personaId)
            manager.agents.append(comp)

            let newAgentId = manager.addAgent(folder: "/tmp/forked", name: "Forked")!
            manager.duplicateCompanions(from: source.id, to: newAgentId, newFolder: "/tmp/forked")

            let newCompanions = manager.companions(of: newAgentId)
            #expect(newCompanions.count == 1)
            #expect(newCompanions[0].personaId == personaId)
        }

        @Test("addAgent with personaId persists it")
        @MainActor
        func addAgentWithPersonaId() async {
            let manager = AgentManagerTests.setupManager(agentCount: 0)
            let personaId = UUID()
            manager.addAgent(folder: "/tmp/test", name: "Test", personaId: personaId)

            #expect(manager.agents.count == 1)
            #expect(manager.agents[0].personaId == personaId)
        }

        @Test("duplicateCompanions with nil folder keeps original folders")
        @MainActor
        func duplicateCompanionsKeepsOriginalFolders() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let source = manager.agents[0]

            let comp = Agent(name: "Comp", folder: source.folder, createdBy: source.id, isCompanion: true)
            manager.agents.append(comp)

            let newAgentId = manager.addAgent(folder: source.folder, name: "Forked")!

            manager.duplicateCompanions(from: source.id, to: newAgentId, newFolder: nil)

            let newCompanions = manager.companions(of: newAgentId)
            #expect(newCompanions.count == 1)
            #expect(newCompanions[0].folder == source.folder)
        }

        @Test("moveAgent reorders in workspace")
        @MainActor
        func moveAgentReorders() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)

            manager.moveAgent(from: IndexSet(integer: 0), to: 2)

            let workspace = manager.currentWorkspace!
            #expect(workspace.agentIds[0] == manager.agents[1].id)
        }
    }

    // MARK: - Navigation Tests

    @Suite("Navigation")
    struct NavigationTests {

        @Test("selectNextAgent cycles forward")
        @MainActor
        func selectNextAgentCyclesForward() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            let agents = manager.currentWorkspaceAgents

            #expect(manager.activeAgentIds == [agents[0].id])

            manager.selectNextAgent()
            #expect(manager.activeAgentIds == [agents[1].id])

            manager.selectNextAgent()
            #expect(manager.activeAgentIds == [agents[2].id])
        }

        @Test("selectNextAgent wraps around")
        @MainActor
        func selectNextAgentWrapsAround() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            let agents = manager.currentWorkspaceAgents

            manager.activeAgentIds = [agents[2].id]

            manager.selectNextAgent()
            #expect(manager.activeAgentIds == [agents[0].id])
        }

        @Test("selectPreviousAgent cycles backward")
        @MainActor
        func selectPreviousAgentCyclesBackward() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            let agents = manager.currentWorkspaceAgents

            manager.selectPreviousAgent()
            #expect(manager.activeAgentIds == [agents[2].id])
        }

        @Test("selectAgent sets active in single mode")
        @MainActor
        func selectAgentSetsActiveInSingleMode() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            let agents = manager.currentWorkspaceAgents

            manager.selectAgent(agents[2].id)

            #expect(manager.activeAgentIds == [agents[2].id])
        }

        @Test("selectAgentAtIndex selects correct agent")
        @MainActor
        func selectAgentAtIndexSelectsCorrect() async {
            let manager = AgentManagerTests.setupManager(agentCount: 4)
            let agents = manager.currentWorkspaceAgents

            manager.selectAgentAtIndex(2)

            #expect(manager.activeAgentIds == [agents[2].id])
        }

        @Test("selectAgentAtIndex ignores out of bounds")
        @MainActor
        func selectAgentAtIndexIgnoresOutOfBounds() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            let original = manager.activeAgentIds

            manager.selectAgentAtIndex(10)

            #expect(manager.activeAgentIds == original)
        }

        @Test("selectAgent with companions applies companion layout when pane 0 focused")
        @MainActor
        func selectAgentWithCompanionsAppliesLayout() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            let parent = manager.agents[0]

            // Add a companion for agent 0
            let companion = Agent(name: "Companion", folder: "/tmp/comp", createdBy: parent.id, isCompanion: true)
            manager.agents.append(companion)

            // Select agent 0 (which has companions) with pane 0 focused
            manager.focusedPaneIndex = 0
            manager.selectAgent(parent.id)

            #expect(manager.activeAgentIds.contains(parent.id))
            #expect(manager.activeAgentIds.contains(companion.id))
            #expect(manager.layoutMode == .splitVertical)
        }

        @Test("selectAgent collapses to single when current agent has companions")
        @MainActor
        func selectAgentCollapsesCompanionLayout() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            let parent = manager.agents[0]
            let otherAgent = manager.agents[1]

            // Add a companion for agent 0
            let companion = Agent(name: "Companion", folder: "/tmp/comp", createdBy: parent.id, isCompanion: true)
            manager.agents.append(companion)

            // Set up companion layout: parent + companion in split
            manager.activeAgentIds = [parent.id, companion.id]
            manager.layoutMode = .splitVertical
            manager.focusedPaneIndex = 0

            // Now select a different agent — should collapse to single
            manager.selectAgent(otherAgent.id)

            #expect(manager.activeAgentIds == [otherAgent.id])
            #expect(manager.layoutMode == .single)
            #expect(manager.focusedPaneIndex == 0)
        }

        @Test("selectAgent focuses existing pane when agent already displayed")
        @MainActor
        func selectAgentFocusesExistingPane() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            let agents = manager.currentWorkspaceAgents

            // Set up split with agents 0 and 1
            manager.activeAgentIds = [agents[0].id, agents[1].id]
            manager.layoutMode = .splitVertical
            manager.focusedPaneIndex = 0

            // Select agent 1 which is already in pane 1
            manager.selectAgent(agents[1].id)

            #expect(manager.focusedPaneIndex == 1)
            #expect(manager.activeAgentIds == [agents[0].id, agents[1].id])
        }

        @Test("selectAgent replaces focused pane in split mode")
        @MainActor
        func selectAgentReplacesFocusedPane() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            let agents = manager.currentWorkspaceAgents

            // Set up split with agents 0 and 1, focus on pane 1
            manager.activeAgentIds = [agents[0].id, agents[1].id]
            manager.layoutMode = .splitVertical
            manager.focusedPaneIndex = 1

            // Select agent 2 (not in any pane) — should replace pane 1
            manager.selectAgent(agents[2].id)

            #expect(manager.activeAgentIds == [agents[0].id, agents[2].id])
        }

        @Test("selectAgent can update a detached workspace without changing the main workspace")
        @MainActor
        func selectAgentInWorkspaceDoesNotRetargetMainWorkspace() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            let mainWorkspace = manager.workspaces[0]
            let detachedWorkspace = Workspace(
                name: "Detached",
                agentIds: manager.agents.map(\.id),
                activeAgentIds: [manager.agents[0].id],
                isDetached: true
            )
            manager.workspaces.append(detachedWorkspace)

            manager.selectAgent(manager.agents[2].id, in: detachedWorkspace.id)

            #expect(manager.currentWorkspaceId == mainWorkspace.id)
            #expect(manager.workspaces.first { $0.id == mainWorkspace.id }?.activeAgentIds == [manager.agents[0].id])
            #expect(manager.workspaces.first { $0.id == detachedWorkspace.id }?.activeAgentIds == [manager.agents[2].id])
        }

        @Test("selectAgent applies companion layout in the requested workspace")
        @MainActor
        func selectAgentInWorkspaceAppliesCompanionLayout() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let parent = manager.agents[0]
            let companion = Agent(
                name: "Companion",
                folder: parent.folder,
                createdBy: parent.id,
                isCompanion: true
            )
            manager.agents.append(companion)
            let detachedWorkspace = Workspace(
                name: "Detached",
                agentIds: [parent.id, companion.id],
                activeAgentIds: [parent.id],
                isDetached: true
            )
            manager.workspaces.append(detachedWorkspace)

            manager.selectAgent(parent.id, in: detachedWorkspace.id)

            let updated = manager.workspaces.first { $0.id == detachedWorkspace.id }
            #expect(updated?.activeAgentIds == [parent.id, companion.id])
            #expect(updated?.layoutMode == .splitVertical)
            #expect(updated?.focusedPaneIndex == 0)
        }

        @Test("new companion enters split in its detached workspace")
        @MainActor
        func enterSplitWithNewAgentUpdatesOwningWorkspace() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let mainWorkspace = manager.workspaces[0]
            let parent = Agent(name: "Detached Parent", folder: "/tmp/detached")
            let companion = Agent(
                name: "Detached Companion",
                folder: parent.folder,
                createdBy: parent.id,
                isCompanion: true
            )
            let detachedWorkspace = Workspace(
                name: "Detached",
                agentIds: [parent.id, companion.id],
                activeAgentIds: [parent.id],
                isDetached: true
            )
            manager.agents.append(contentsOf: [parent, companion])
            manager.workspaces.append(detachedWorkspace)

            manager.enterSplitWithNewAgent(newAgentId: companion.id, creatorId: parent.id)

            #expect(manager.currentWorkspaceId == mainWorkspace.id)
            #expect(manager.workspaces.first { $0.id == mainWorkspace.id } == mainWorkspace)
            let updated = manager.workspaces.first { $0.id == detachedWorkspace.id }
            #expect(updated?.activeAgentIds == [parent.id, companion.id])
            #expect(updated?.layoutMode == .splitVertical)
            #expect(updated?.focusedPaneIndex == 1)
        }
    }

    // MARK: - Layout Tests

    @Suite("Layout")
    struct LayoutTests {

        @Test("enterSplit sets up two panes")
        @MainActor
        func enterSplitSetsTwoPanes() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)

            manager.enterSplit(.splitVertical)

            #expect(manager.layoutMode == .splitVertical)
            #expect(manager.activeAgentIds.count == 2)
        }

        @Test("enterSplit requires at least 2 agents")
        @MainActor
        func enterSplitRequiresTwoAgents() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)

            manager.enterSplit(.splitVertical)

            #expect(manager.layoutMode == .single)
        }

        @Test("focusPane changes focused pane index")
        @MainActor
        func focusPaneChangesFocusedIndex() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            manager.enterSplit(.splitVertical)

            manager.focusPane(1)

            #expect(manager.focusedPaneIndex == 1)
        }

        @Test("focusPane can update a detached workspace without changing the main workspace")
        @MainActor
        func focusPaneInWorkspaceDoesNotRetargetMainWorkspace() async {
            let manager = AgentManagerTests.setupManager(agentCount: 2)
            let mainWorkspace = manager.workspaces[0]
            let detachedWorkspace = Workspace(
                name: "Detached",
                agentIds: manager.agents.map(\.id),
                layoutMode: .splitVertical,
                activeAgentIds: manager.agents.map(\.id),
                focusedPaneIndex: 0,
                isDetached: true
            )
            manager.workspaces.append(detachedWorkspace)

            manager.focusPane(1, in: detachedWorkspace.id)

            #expect(manager.currentWorkspaceId == mainWorkspace.id)
            #expect(manager.workspaces.first { $0.id == mainWorkspace.id }?.focusedPaneIndex == 0)
            #expect(manager.workspaces.first { $0.id == detachedWorkspace.id }?.focusedPaneIndex == 1)
        }

        // @Test("selectNextPane cycles through panes")
        // @MainActor
        // func selectNextPaneCycles() async {
        //     let manager = AgentManagerTests.setupManager(agentCount: 3)
        //     manager.enterSplit(.splitVertical)

        //     #expect(manager.focusedPaneIndex == 0)

        //     manager.selectNextPane()
        //     #expect(manager.focusedPaneIndex == 1)

        //     manager.selectNextPane()
        //     #expect(manager.focusedPaneIndex == 0)
        // }

        // @Test("selectPreviousPane cycles backward")
        // @MainActor
        // func selectPreviousPaneCycles() async {
        //     let manager = AgentManagerTests.setupManager(agentCount: 3)
        //     manager.enterSplit(.splitVertical)

        //     manager.selectPreviousPane()
        //     #expect(manager.focusedPaneIndex == 1)
        // }

        @Test("paneIndex returns correct position")
        @MainActor
        func paneIndexReturnsCorrectPosition() async {
            let manager = AgentManagerTests.setupManager(agentCount: 4)
            let agents = manager.currentWorkspaceAgents
            manager.enterSplit(.splitVertical)

            #expect(manager.paneIndex(for: agents[0].id) == 0)
            #expect(manager.paneIndex(for: agents[1].id) == 1)
            #expect(manager.paneIndex(for: agents[2].id) == nil)
        }

        @Test("splitRatio can be changed")
        @MainActor
        func splitRatioCanBeChanged() async {
            let manager = AgentManagerTests.setupManager(agentCount: 2)
            manager.enterSplit(.splitVertical)

            manager.splitRatio = 0.7

            #expect(manager.splitRatio == 0.7)
        }

        // MARK: - enterSplitWithNewAgent Tests

        @Test("enterSplitWithNewAgent from single creates dual vertical")
        @MainActor
        func enterSplitWithNewAgentFromSingleCreatesDualVertical() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let creatorId = manager.agents[0].id

            // Add a new agent
            let newAgentId = manager.addAgent(folder: "/tmp/new", name: "NewAgent")!

            manager.enterSplitWithNewAgent(newAgentId: newAgentId, creatorId: creatorId)

            #expect(manager.layoutMode == .splitVertical)
            #expect(manager.activeAgentIds.count == 2)
            #expect(manager.activeAgentIds[0] == creatorId)
            #expect(manager.activeAgentIds[1] == newAgentId)
            #expect(manager.focusedPaneIndex == 1)  // New agent gets focus
        }

        @Test("enterSplitWithNewAgent from dual vertical creates three pane")
        @MainActor
        func enterSplitWithNewAgentFromDualCreatesThreePane() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            let agents = manager.currentWorkspaceAgents
            manager.enterSplit(.splitVertical)
            let creatorId = agents[0].id

            // Add a new agent
            let newAgentId = manager.addAgent(folder: "/tmp/new", name: "NewAgent")!

            manager.enterSplitWithNewAgent(newAgentId: newAgentId, creatorId: creatorId)

            #expect(manager.layoutMode == .threePane)
            #expect(manager.activeAgentIds.count == 3)
            #expect(manager.activeAgentIds.contains(newAgentId))
            // New agent should be focused
            let newAgentPane = manager.paneIndex(for: newAgentId)
            #expect(newAgentPane == manager.focusedPaneIndex)
        }

        @Test("enterSplitWithNewAgent from dual horizontal creates three pane")
        @MainActor
        func enterSplitWithNewAgentFromDualHorizontalCreatesThreePane() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            let agents = manager.currentWorkspaceAgents
            manager.enterSplit(.splitHorizontal)
            let creatorId = agents[0].id

            // Add a new agent
            let newAgentId = manager.addAgent(folder: "/tmp/new", name: "NewAgent")!

            manager.enterSplitWithNewAgent(newAgentId: newAgentId, creatorId: creatorId)

            #expect(manager.layoutMode == .threePane)
            #expect(manager.activeAgentIds.contains(newAgentId))
        }

        @Test("enterSplitWithNewAgent in four pane replaces pane 4 (index 3)")
        @MainActor
        func enterSplitWithNewAgentInGridReplacesPane4() async {
            let manager = AgentManagerTests.setupManager(agentCount: 5)
            let agents = manager.currentWorkspaceAgents

            // Set up four-pane with agents 0, 1, 2, 3
            manager.activeAgentIds = [agents[0].id, agents[1].id, agents[2].id, agents[3].id]
            manager.layoutMode = .gridFourPane
            let creatorId = agents[0].id  // Creator in pane 0

            // Add new agent
            let newAgentId = manager.addAgent(folder: "/tmp/new", name: "NewAgent")!

            manager.enterSplitWithNewAgent(newAgentId: newAgentId, creatorId: creatorId)

            #expect(manager.layoutMode == .gridFourPane)
            #expect(manager.activeAgentIds[3] == newAgentId)  // Replaced pane 4 (index 3)
            #expect(manager.activeAgentIds[0] == creatorId)  // Creator preserved
            #expect(manager.focusedPaneIndex == 3)
        }

        @Test("enterSplitWithNewAgent in four pane skips creator pane")
        @MainActor
        func enterSplitWithNewAgentInGridSkipsCreatorPane() async {
            let manager = AgentManagerTests.setupManager(agentCount: 5)
            let agents = manager.currentWorkspaceAgents

            // Set up four-pane with creator in pane 4 (index 3)
            manager.activeAgentIds = [agents[0].id, agents[1].id, agents[2].id, agents[3].id]
            manager.layoutMode = .gridFourPane
            let creatorId = agents[3].id  // Creator in pane 4

            // Add new agent
            let newAgentId = manager.addAgent(folder: "/tmp/new", name: "NewAgent")!

            manager.enterSplitWithNewAgent(newAgentId: newAgentId, creatorId: creatorId)

            #expect(manager.layoutMode == .gridFourPane)
            #expect(manager.activeAgentIds[3] == creatorId)  // Creator still in pane 4
            #expect(manager.activeAgentIds[2] == newAgentId)  // New agent in pane 3 (index 2)
            #expect(manager.focusedPaneIndex == 2)
        }

        @Test("enterSplitWithNewAgent replacement follows priority 4-3-2-1")
        @MainActor
        func enterSplitWithNewAgentFollowsReplacementPriority() async {
            let manager = AgentManagerTests.setupManager(agentCount: 5)
            let agents = manager.currentWorkspaceAgents

            // Set up four-pane with creator in pane 3 (index 2)
            manager.activeAgentIds = [agents[0].id, agents[1].id, agents[2].id, agents[3].id]
            manager.layoutMode = .gridFourPane
            let creatorId = agents[2].id  // Creator in pane 3

            // Add new agent
            let newAgentId = manager.addAgent(folder: "/tmp/new", name: "NewAgent")!

            manager.enterSplitWithNewAgent(newAgentId: newAgentId, creatorId: creatorId)

            // Should replace pane 4 first (index 3) since creator is in pane 3
            #expect(manager.activeAgentIds[3] == newAgentId)
            #expect(manager.activeAgentIds[2] == creatorId)  // Creator preserved
            #expect(manager.focusedPaneIndex == 3)
        }

        @Test("enterSplitWithNewAgent focuses new agent")
        @MainActor
        func enterSplitWithNewAgentFocusesNewAgent() async {
            let manager = AgentManagerTests.setupManager(agentCount: 2)
            let creatorId = manager.agents[0].id
            manager.focusedPaneIndex = 0

            let newAgentId = manager.addAgent(folder: "/tmp/new", name: "NewAgent")!

            manager.enterSplitWithNewAgent(newAgentId: newAgentId, creatorId: creatorId)

            // New agent should always be focused after split
            let newAgentPane = manager.paneIndex(for: newAgentId)
            #expect(newAgentPane == manager.focusedPaneIndex)
        }
    }

    // MARK: - Registration Tests

    @Suite("Registration")
    struct RegistrationTests {

        @Test("setRegistered updates agent state")
        @MainActor
        func setRegisteredUpdatesState() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id

            manager.setRegistered(for: agentId, registered: true)

            #expect(manager.agents[0].isRegistered == true)
            #expect(manager.isRegistered(agentId: agentId) == true)
        }

        @Test("isRegistered returns false for unregistered")
        @MainActor
        func isRegisteredReturnsFalseForUnregistered() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id

            #expect(manager.isRegistered(agentId: agentId) == false)
        }

        @Test("isRegistered returns false for unknown agent")
        @MainActor
        func isRegisteredReturnsFalseForUnknown() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)

            #expect(manager.isRegistered(agentId: UUID()) == false)
        }
    }

    // MARK: - Status Tests

    @Suite("Status")
    struct StatusTests {

        @Test("workspaceStatus returns .running if any agent is running")
        @MainActor
        func workspaceStatusReturnsRunningIfRunning() async {
            let manager = AgentManagerTests.setupManager(agentCount: 2)
            manager.agents[0].state = .running

            let status = manager.workspaceStatus(manager.currentWorkspace!)

            #expect(status == .running)
        }

        @Test("workspaceStatus returns nil if all agents idle")
        @MainActor
        func workspaceStatusReturnsNilIfAllIdle() async {
            let manager = AgentManagerTests.setupManager(agentCount: 2)

            let status = manager.workspaceStatus(manager.currentWorkspace!)

            #expect(status == nil)
        }

        @Test("workspaceStatus returns .input if any agent awaits input")
        @MainActor
        func workspaceStatusReturnsInputIfInput() async {
            let manager = AgentManagerTests.setupManager(agentCount: 2)
            manager.agents[0].state = .running
            manager.agents[1].state = .input

            let status = manager.workspaceStatus(manager.currentWorkspace!)

            #expect(status == .input)
        }
    }

    // MARK: - Hook Activity Guard Tests

    @Suite("Hook Activity Guard")
    struct HookActivityGuardTests {

        @Test("terminal output is accepted for hook agents (claude)")
        @MainActor
        func terminalOutputAcceptedForHookAgent() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "claude")
            manager.agents[0].state = .idle

            manager.updateStatus(for: manager.agents[0].id, status: .running, source: .terminal)

            #expect(manager.agents[0].state == .running)
        }

        @Test("hook source is accepted for hook agents (claude)")
        @MainActor
        func hookSourceAcceptedForHookAgent() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "claude")
            manager.agents[0].state = .idle

            manager.updateStatus(for: manager.agents[0].id, status: .running, source: .hook)

            #expect(manager.agents[0].state == .running)
        }

        @Test("terminal output is accepted for non-hook agents")
        @MainActor
        func terminalOutputAcceptedForNonHookAgent() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "codex")
            manager.agents[0].state = .idle

            manager.updateStatus(for: manager.agents[0].id, status: .running, source: .terminal)

            #expect(manager.agents[0].state == .running)
        }
    }

    // MARK: - Derived State Tests

    @Suite("Derived State")
    struct DerivedStateTests {

        @Test("currentWorkspaceAgents returns agents in workspace order")
        @MainActor
        func currentWorkspaceAgentsReturnsInOrder() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)

            let workspaceAgents = manager.currentWorkspaceAgents

            #expect(workspaceAgents.count == 3)
            #expect(workspaceAgents[0].id == manager.agents[0].id)
        }

        @Test("selectedAgent returns first active agent")
        @MainActor
        func selectedAgentReturnsFirstActive() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)

            #expect(manager.selectedAgent?.id == manager.agents[0].id)
        }

        @Test("activeAgentId returns focused pane agent in split mode")
        @MainActor
        func activeAgentIdReturnsFocusedInSplit() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            let agents = manager.currentWorkspaceAgents
            manager.enterSplit(.splitVertical)

            manager.focusPane(1)

            #expect(manager.activeAgentId == agents[1].id)
        }
    }

    // MARK: - Markdown Panel Tests

    @Suite("Markdown Panel")
    struct MarkdownPanelTests {

        @Test("showMarkdownPanel sets file path")
        @MainActor
        func showMarkdownPanelSetsFilePath() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id

            manager.showMarkdownPanel(filePath: "/tmp/test.md", forAgent: agentId)

            #expect(manager.agents[0].markdownFilePath == "/tmp/test.md")
        }

        @Test("showMarkdownPanel adds to history")
        @MainActor
        func showMarkdownPanelAddsToHistory() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id

            manager.showMarkdownPanel(filePath: "/tmp/test.md", forAgent: agentId)

            #expect(manager.agents[0].markdownFileHistory.count == 1)
            #expect(manager.agents[0].markdownFileHistory[0] == "/tmp/test.md")
        }

        @Test("showMarkdownPanel maintains history order (most recent first)")
        @MainActor
        func showMarkdownPanelMaintainsHistoryOrder() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id

            manager.showMarkdownPanel(filePath: "/tmp/first.md", forAgent: agentId)
            manager.showMarkdownPanel(filePath: "/tmp/second.md", forAgent: agentId)
            manager.showMarkdownPanel(filePath: "/tmp/third.md", forAgent: agentId)

            #expect(manager.agents[0].markdownFileHistory.count == 3)
            #expect(manager.agents[0].markdownFileHistory[0] == "/tmp/third.md")
            #expect(manager.agents[0].markdownFileHistory[1] == "/tmp/second.md")
            #expect(manager.agents[0].markdownFileHistory[2] == "/tmp/first.md")
        }

        @Test("showMarkdownPanel moves duplicate to front of history")
        @MainActor
        func showMarkdownPanelMovesDuplicateToFront() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id

            manager.showMarkdownPanel(filePath: "/tmp/first.md", forAgent: agentId)
            manager.showMarkdownPanel(filePath: "/tmp/second.md", forAgent: agentId)
            manager.showMarkdownPanel(filePath: "/tmp/first.md", forAgent: agentId)

            #expect(manager.agents[0].markdownFileHistory.count == 2)
            #expect(manager.agents[0].markdownFileHistory[0] == "/tmp/first.md")
            #expect(manager.agents[0].markdownFileHistory[1] == "/tmp/second.md")
        }

        @Test("showMarkdownPanel ignores unknown agent")
        @MainActor
        func showMarkdownPanelIgnoresUnknownAgent() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)

            manager.showMarkdownPanel(filePath: "/tmp/test.md", forAgent: UUID())

            #expect(manager.agents[0].markdownFilePath == nil)
            #expect(manager.agents[0].markdownFileHistory.isEmpty)
        }

        @Test("closeMarkdownPanel clears file path")
        @MainActor
        func closeMarkdownPanelClearsFilePath() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id
            manager.showMarkdownPanel(filePath: "/tmp/test.md", forAgent: agentId)

            manager.closeMarkdownPanel(for: agentId)

            #expect(manager.agents[0].markdownFilePath == nil)
        }

        @Test("closeMarkdownPanel preserves history")
        @MainActor
        func closeMarkdownPanelPreservesHistory() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id
            manager.showMarkdownPanel(filePath: "/tmp/test.md", forAgent: agentId)

            manager.closeMarkdownPanel(for: agentId)

            #expect(manager.agents[0].markdownFileHistory.count == 1)
            #expect(manager.agents[0].markdownFileHistory[0] == "/tmp/test.md")
        }

        @Test("closeMarkdownPanel ignores unknown agent")
        @MainActor
        func closeMarkdownPanelIgnoresUnknownAgent() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id
            manager.showMarkdownPanel(filePath: "/tmp/test.md", forAgent: agentId)

            manager.closeMarkdownPanel(for: UUID())

            #expect(manager.agents[0].markdownFilePath == "/tmp/test.md")
        }
    }

    // MARK: - Mermaid Panel Tests

    @Suite("Mermaid Panel")
    struct MermaidPanelTests {

        @Test("showMermaidPanel sets source")
        @MainActor
        func showMermaidPanelSetsSource() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id

            manager.showMermaidPanel(source: "graph TD; A-->B;", title: nil, forAgent: agentId)

            #expect(manager.agents[0].mermaidSource == "graph TD; A-->B;")
        }

        @Test("showMermaidPanel sets title")
        @MainActor
        func showMermaidPanelSetsTitle() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id

            manager.showMermaidPanel(source: "graph TD; A-->B;", title: "Flow", forAgent: agentId)

            #expect(manager.agents[0].mermaidTitle == "Flow")
        }

        @Test("showMermaidPanel with nil title")
        @MainActor
        func showMermaidPanelWithNilTitle() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id

            manager.showMermaidPanel(source: "graph TD; A-->B;", title: nil, forAgent: agentId)

            #expect(manager.agents[0].mermaidTitle == nil)
        }

        @Test("showMermaidPanel ignores unknown agent")
        @MainActor
        func showMermaidPanelIgnoresUnknownAgent() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)

            manager.showMermaidPanel(source: "graph TD; A-->B;", title: nil, forAgent: UUID())

            #expect(manager.agents[0].mermaidSource == nil)
        }

        @Test("closeMermaidPanel clears source and title")
        @MainActor
        func closeMermaidPanelClearsSourceAndTitle() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id
            manager.showMermaidPanel(source: "graph TD; A-->B;", title: "Flow", forAgent: agentId)

            manager.closeMermaidPanel(for: agentId)

            #expect(manager.agents[0].mermaidSource == nil)
            #expect(manager.agents[0].mermaidTitle == nil)
        }

        @Test("closeMermaidPanel ignores unknown agent")
        @MainActor
        func closeMermaidPanelIgnoresUnknownAgent() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id
            manager.showMermaidPanel(source: "graph TD; A-->B;", title: "Flow", forAgent: agentId)

            manager.closeMermaidPanel(for: UUID())

            #expect(manager.agents[0].mermaidSource == "graph TD; A-->B;")
        }

        @Test("showMermaidPanel replaces previous source")
        @MainActor
        func showMermaidPanelReplacesPrevious() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id

            manager.showMermaidPanel(source: "graph TD; A-->B;", title: "First", forAgent: agentId)
            manager.showMermaidPanel(source: "graph LR; X-->Y;", title: "Second", forAgent: agentId)

            #expect(manager.agents[0].mermaidSource == "graph LR; X-->Y;")
            #expect(manager.agents[0].mermaidTitle == "Second")
        }
    }

    // MARK: - Restart Tests

    @Suite("Restart")
    struct RestartTests {

        @Test("restartAgent clears runtime state")
        @MainActor
        func restartAgentClearsRuntimeState() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agentId = manager.agents[0].id

            // Set various runtime state
            manager.agents[0].state = .running
            manager.agents[0].isRegistered = true
            manager.agents[0].sessionId = "old-session"
            manager.agents[0].resumeSessionId = "resume-session"
            manager.agents[0].forkSession = true
            manager.agents[0].terminalTitle = "Some title"

            manager.restartAgent(manager.agents[0])

            let agent = manager.agents.first(where: { $0.id == agentId })!
            #expect(agent.state == .idle)
            #expect(agent.isRegistered == false)
            #expect(agent.sessionId == nil)
            #expect(agent.resumeSessionId == nil)
            #expect(agent.forkSession == false)
            #expect(agent.terminalTitle == "")
        }

        @Test("restartAgent generates new restart token")
        @MainActor
        func restartAgentGeneratesNewToken() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let originalToken = manager.agents[0].restartToken

            manager.restartAgent(manager.agents[0])

            #expect(manager.agents[0].restartToken != originalToken)
        }

        @Test("restartAgent preserves agent identity")
        @MainActor
        func restartAgentPreservesIdentity() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let originalId = manager.agents[0].id
            let originalName = manager.agents[0].name
            let originalFolder = manager.agents[0].folder

            manager.restartAgent(manager.agents[0])

            #expect(manager.agents[0].id == originalId)
            #expect(manager.agents[0].name == originalName)
            #expect(manager.agents[0].folder == originalFolder)
        }
    }

    // MARK: - Resume Session Tests

    @Suite("Resume Session")
    struct ResumeSessionTests {

        @Test("resumeSession sets resumeSessionId and sessionId")
        @MainActor
        func resumeSessionSetsIds() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agent = manager.agents[0]

            manager.resumeSession(agent, sessionId: "target-session")

            #expect(manager.agents[0].resumeSessionId == "target-session")
            #expect(manager.agents[0].sessionId == "target-session")
            #expect(manager.agents[0].forkSession == false)
        }

        @Test("resumeSession clears previous registration")
        @MainActor
        func resumeSessionClearsRegistration() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            manager.agents[0].isRegistered = true
            manager.agents[0].state = .running

            manager.resumeSession(manager.agents[0], sessionId: "new-session")

            #expect(manager.agents[0].isRegistered == false)
            #expect(manager.agents[0].state == .idle)
        }

        @Test("resumeSession generates new restart token")
        @MainActor
        func resumeSessionGeneratesNewToken() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let originalToken = manager.agents[0].restartToken

            manager.resumeSession(manager.agents[0], sessionId: "session")

            #expect(manager.agents[0].restartToken != originalToken)
        }

        @Test("resumeSession preserves agent identity")
        @MainActor
        func resumeSessionPreservesIdentity() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let originalId = manager.agents[0].id
            let originalName = manager.agents[0].name

            manager.resumeSession(manager.agents[0], sessionId: "session")

            #expect(manager.agents[0].id == originalId)
            #expect(manager.agents[0].name == originalName)
        }
    }

    // MARK: - Detach / Reattach Tests

    @Suite("Detach and Reattach")
    struct DetachReattachTests {

        @Test("attachedWorkspaces excludes detached")
        @MainActor
        func attachedWorkspacesExcludesDetached() async {
            let manager = AgentManagerTests.createTestManager()
            let ws1 = manager.addWorkspace(name: "Attached")
            let ws2 = manager.addWorkspace(name: "Detached")

            manager.detachWorkspace(ws2)

            #expect(manager.attachedWorkspaces.count == 1)
            #expect(manager.attachedWorkspaces[0].id == ws1.id)
        }

        @Test("detachedWorkspaces returns only detached")
        @MainActor
        func detachedWorkspacesReturnsOnlyDetached() async {
            let manager = AgentManagerTests.createTestManager()
            _ = manager.addWorkspace(name: "Attached")
            let ws2 = manager.addWorkspace(name: "Detached")

            manager.detachWorkspace(ws2)

            #expect(manager.detachedWorkspaces.count == 1)
            #expect(manager.detachedWorkspaces[0].id == ws2.id)
        }

        @Test("detachWorkspace sets isDetached flag")
        @MainActor
        func detachWorkspaceSetsFlag() async {
            let manager = AgentManagerTests.createTestManager()
            let ws = manager.addWorkspace(name: "Test")

            manager.detachWorkspace(ws)

            #expect(manager.workspaces[0].isDetachedFromMain == true)
        }

        @Test("detachWorkspace switches main to next attached")
        @MainActor
        func detachWorkspaceSwitchesMain() async {
            let manager = AgentManagerTests.createTestManager()
            let ws1 = manager.addWorkspace(name: "First")
            let ws2 = manager.addWorkspace(name: "Second")

            // Current is ws2 (last added)
            manager.switchToWorkspace(ws2.id)
            manager.detachWorkspace(ws2)

            #expect(manager.currentWorkspaceId == ws1.id)
        }

        @Test("detachWorkspace bumps restartToken for all agents")
        @MainActor
        func detachWorkspaceBumpsTokens() async {
            let manager = AgentManagerTests.setupManager(agentCount: 2)
            let token0 = manager.agents[0].restartToken
            let token1 = manager.agents[1].restartToken

            manager.detachWorkspace(manager.workspaces[0])

            #expect(manager.agents[0].restartToken != token0)
            #expect(manager.agents[1].restartToken != token1)
        }

        @Test("detachWorkspace clears agent runtime state")
        @MainActor
        func detachWorkspaceClearsState() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            manager.agents[0].state = .running
            manager.agents[0].isRegistered = true
            manager.agents[0].terminalTitle = "some title"

            manager.detachWorkspace(manager.workspaces[0])

            #expect(manager.agents[0].state == .idle)
            #expect(manager.agents[0].isRegistered == false)
            #expect(manager.agents[0].terminalTitle == "")
        }

        @Test("reattachWorkspace clears isDetached flag")
        @MainActor
        func reattachWorkspaceClearsFlag() async {
            let manager = AgentManagerTests.createTestManager()
            let ws = manager.addWorkspace(name: "Test")
            manager.detachWorkspace(ws)

            manager.reattachWorkspace(manager.workspaces[0])

            #expect(manager.workspaces[0].isDetachedFromMain == false)
        }

        @Test("reattachWorkspace switches main to reattached workspace")
        @MainActor
        func reattachWorkspaceSwitchesMain() async {
            let manager = AgentManagerTests.createTestManager()
            let ws1 = manager.addWorkspace(name: "First")
            let ws2 = manager.addWorkspace(name: "Second")
            manager.detachWorkspace(ws2)

            #expect(manager.currentWorkspaceId == ws1.id)

            manager.reattachWorkspace(manager.workspaces.first { $0.id == ws2.id }!)

            #expect(manager.currentWorkspaceId == ws2.id)
        }

        @Test("reattachWorkspace bumps restartToken for all agents")
        @MainActor
        func reattachWorkspaceBumpsTokens() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            manager.detachWorkspace(manager.workspaces[0])
            let tokenAfterDetach = manager.agents[0].restartToken

            manager.reattachWorkspace(manager.workspaces[0])

            #expect(manager.agents[0].restartToken != tokenAfterDetach)
        }

        @Test("cycleWorkspace skips detached workspaces")
        @MainActor
        func cycleWorkspaceSkipsDetached() async {
            let manager = AgentManagerTests.createTestManager()
            let ws1 = manager.addWorkspace(name: "First")
            let ws2 = manager.addWorkspace(name: "Second")
            let ws3 = manager.addWorkspace(name: "Third")

            manager.switchToWorkspace(ws1.id)
            manager.detachWorkspace(ws2)

            // Cycling from ws1 should skip ws2 (detached) and go to ws3
            manager.cycleWorkspace()

            #expect(manager.currentWorkspaceId == ws3.id)
        }

        @Test("workspace defaults to not detached")
        @MainActor
        func workspaceDefaultsToNotDetached() async {
            let ws = Workspace(name: "Test")
            #expect(ws.isDetachedFromMain == false)
        }

        @Test("detach then reattach round trip")
        @MainActor
        func detachReattachRoundTrip() async {
            let manager = AgentManagerTests.setupManager(agentCount: 2)
            let wsId = manager.workspaces[0].id

            manager.detachWorkspace(manager.workspaces[0])
            #expect(manager.attachedWorkspaces.isEmpty)
            #expect(manager.detachedWorkspaces.count == 1)

            manager.reattachWorkspace(manager.workspaces[0])
            #expect(manager.attachedWorkspaces.count == 1)
            #expect(manager.detachedWorkspaces.isEmpty)
            #expect(manager.currentWorkspaceId == wsId)
        }
    }

    @Suite("Agent shortcuts")
    struct AgentShortcutTests {
        @Test("Command-N selects the Nth sidebar agent and ignores out-of-range slots")
        @MainActor
        func selectsByIndex() async {
            let manager = AgentManagerTests.setupManager(agentCount: 3)
            let second = manager.sidebarAgentsInDisplayOrder[1]

            #expect(manager.selectAgent(atSidebarIndex: 2))
            #expect(manager.activeAgentId == second.id)

            #expect(!manager.selectAgent(atSidebarIndex: 9))
            #expect(!manager.selectAgent(atSidebarIndex: 0))
            #expect(manager.activeAgentId == second.id)
        }

        @Test("companions are not addressable by Command-N")
        @MainActor
        func skipsCompanions() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let primary = manager.agents[0]
            var companion = Agent(name: "Shell", folder: "/tmp/test/agent0", agentType: "shell")
            companion.isCompanion = true
            companion.createdBy = primary.id
            manager.agents.append(companion)
            manager.workspaces[0].agentIds.append(companion.id)

            #expect(manager.sidebarAgentsInDisplayOrder.map(\.id) == [primary.id])
            #expect(!manager.selectAgent(atSidebarIndex: 2))
        }
    }

    @Suite("Slash commands")
    struct SlashCommandTests {
        @Test("a slash command is submitted without the Escape that cancels it")
        @MainActor
        func slashCommandSkipsEscape() async throws {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "claude")
            let agent = manager.agents[0]
            let controller = manager.createController(for: agent)
            let adapter = MockTerminalAdapter()
            controller.attach(to: adapter)
            AgentConversationStore.shared.clearAll()

            #expect(manager.sendPrompt("/model sonnet", for: agent.id))
            try await Task.sleep(for: .seconds(1))

            #expect(adapter.sentTexts == ["/model sonnet"])
            #expect(adapter.sentEscapes == 0)
            #expect(adapter.sentReturns == 1)
            // Slash commands need not produce a reply, so nothing should sit pending
            #expect(AgentConversationStore.shared.messages(for: agent.id).first?.delivery == .confirmed)
        }

        @Test("a normal prompt still gets Escape before Return")
        @MainActor
        func promptKeepsEscape() async throws {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "claude")
            let agent = manager.agents[0]
            let controller = manager.createController(for: agent)
            let adapter = MockTerminalAdapter()
            controller.attach(to: adapter)

            #expect(manager.sendPrompt("do the thing", for: agent.id))
            try await Task.sleep(for: .seconds(1))

            #expect(adapter.sentEscapes == 1)
        }
    }

    @Suite("Model command")
    struct ModelCommandTests {
        @Test("bare /model offers the models as choices in the chat")
        @MainActor
        func bareModelOffersChoices() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "claude")
            let agent = manager.agents[0]
            AgentConversationStore.shared.clearAll()

            #expect(manager.sendPrompt("/model", for: agent.id))

            let last = AgentConversationStore.shared.messages(for: agent.id).last
            #expect(last?.kind == .choice)
            #expect(last?.choices.contains("Opus 5") == true)
            // Never sent to the agent: its own picker cannot be seen from the chat
            #expect(manager.agents[0].model == nil)
        }

        @Test("/model with an argument sets it without asking")
        @MainActor
        func modelWithArgumentApplies() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "claude")
            let agent = manager.agents[0]
            let controller = manager.createController(for: agent)
            controller.attach(to: MockTerminalAdapter())
            AgentConversationStore.shared.clearAll()

            #expect(manager.sendPrompt("/model sonnet", for: agent.id))

            #expect(manager.agents[0].model == "sonnet")
            #expect(AgentConversationStore.shared.messages(for: agent.id).last?.kind == .report)
        }

        @Test("an unknown model says so rather than failing silently")
        @MainActor
        func unknownModelReports() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "claude")
            let agent = manager.agents[0]
            AgentConversationStore.shared.clearAll()

            #expect(manager.sendPrompt("/model gpt-9", for: agent.id))

            let last = AgentConversationStore.shared.messages(for: agent.id).last
            #expect(last?.text.contains("Unknown model") == true)
            #expect(manager.agents[0].model == nil)
        }

        @Test("choosing from the model card sets the model")
        @MainActor
        func choosingFromTheCardApplies() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "claude")
            let agent = manager.agents[0]
            let controller = manager.createController(for: agent)
            controller.attach(to: MockTerminalAdapter())
            AgentConversationStore.shared.clearAll()
            manager.sendPrompt("/model", for: agent.id)

            manager.answerChoice(1, for: agent.id)

            let models = TerminalCommandBuilder.selectableModels(for: "claude")
            #expect(manager.agents[0].model == models[1].id)
        }
    }

    @Suite("Locally answered commands")
    struct LocallyAnsweredTests {
        @Test("/usage answers even before the agent's terminal exists")
        @MainActor
        func answersWithoutAController() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "claude")
            let agent = manager.agents[0]
            AgentConversationStore.shared.clearAll()
            // Deliberately no createController: nothing has opened the session yet

            #expect(manager.sendPrompt("/usage", for: agent.id))

            let kinds = AgentConversationStore.shared.messages(for: agent.id).map(\.kind)
            #expect(kinds.contains(.report))
        }

        @Test("a prompt for the agent still needs a terminal to send to")
        @MainActor
        func normalPromptStillRequiresAController() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "claude")
            let agent = manager.agents[0]

            #expect(!manager.sendPrompt("do the thing", for: agent.id))
        }
    }

    @Suite("Slash command output")
    struct SlashCommandOutputTests {
        @Test("the panel is lifted out of the surrounding terminal furniture")
        @MainActor
        func trimsToThePanel() async {
            let screen = """
            > /usage
            Settings  Status  Config  Usage  Stats

            Session
              Total cost: $0.2676
              Total duration (API): 28s

            esc to cancel
            """

            let panel = AgentManager.panelText(from: screen, command: "/usage")

            #expect(panel.hasPrefix("Settings"))
            #expect(panel.contains("Total cost: $0.2676"))
            // The echoed command and the prompt hint aren't part of the answer
            #expect(!panel.contains("/usage"))
            #expect(!panel.contains("esc to cancel"))
        }

        @Test("a screen with nothing but furniture yields no report")
        @MainActor
        func emptyPanel() async {
            let panel = AgentManager.panelText(from: "> /usage\n\nesc to cancel", command: "/usage")
            #expect(panel.isEmpty)
        }
    }

    @Suite("Permission mode")
    struct PermissionModeTests {
        @Test("cycling advances the mode and presses Shift-Tab in the agent")
        @MainActor
        func cyclesLive() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "claude")
            let agent = manager.agents[0]
            let controller = manager.createController(for: agent)
            let adapter = MockTerminalAdapter()
            controller.attach(to: adapter)

            #expect(manager.cyclePermissionMode(for: agent.id) == "acceptEdits")
            #expect(adapter.sentShiftTabs == 1)
            // Never as text: that path drops the ESC and leaves "[Z" in the prompt
            #expect(adapter.sentTexts.isEmpty)
            #expect(manager.agents[0].permissionMode == "acceptEdits")
        }

        @Test("cycling wraps back to the first mode")
        @MainActor
        func wrapsAround() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "claude")
            let agent = manager.agents[0]
            let controller = manager.createController(for: agent)
            controller.attach(to: MockTerminalAdapter())

            #expect(manager.cyclePermissionMode(for: agent.id) == "acceptEdits")
            #expect(manager.cyclePermissionMode(for: agent.id) == "plan")
            #expect(manager.cyclePermissionMode(for: agent.id) == "default")
        }

        @Test("agents whose CLI has no mode cycle are left alone")
        @MainActor
        func shellDoesNotCycle() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "shell")
            let agent = manager.agents[0]
            let controller = manager.createController(for: agent)
            let adapter = MockTerminalAdapter()
            controller.attach(to: adapter)

            #expect(manager.cyclePermissionMode(for: agent.id) == nil)
            #expect(adapter.sentShiftTabs == 0)
        }
    }

    @Suite("Session-scoped diff")
    struct SessionDiffTests {
        @Test("stats subtract the worktree state the session started from")
        @MainActor
        func subtractsBaseline() async {
            var agent = Agent(name: "A", folder: "/tmp/a")
            agent.baselineGitStats = GitLineStats(insertions: 7975, deletions: 1584, files: 62)
            agent.gitStats = GitLineStats(insertions: 8100, deletions: 1600, files: 64)

            #expect(agent.sessionGitStats == GitLineStats(insertions: 125, deletions: 16, files: 2))
        }

        @Test("a reverted change never renders as a negative count")
        @MainActor
        func clampsAtZero() async {
            var agent = Agent(name: "A", folder: "/tmp/a")
            agent.baselineGitStats = GitLineStats(insertions: 500, deletions: 100, files: 5)
            agent.gitStats = GitLineStats(insertions: 200, deletions: 40, files: 2)

            #expect(agent.sessionGitStats == GitLineStats(insertions: 0, deletions: 0, files: 0))
        }

        @Test("without a baseline the full worktree state is shown")
        @MainActor
        func fallsBackToAbsolute() async {
            var agent = Agent(name: "A", folder: "/tmp/a")
            agent.gitStats = GitLineStats(insertions: 12, deletions: 3, files: 1)

            #expect(agent.sessionGitStats == GitLineStats(insertions: 12, deletions: 3, files: 1))
        }
    }

    @Suite("Sidebar numbering")
    struct SidebarNumberingTests {
        @Test("numbering runs across workspaces so a row keeps its shortcut")
        @MainActor
        func numbersAcrossWorkspaces() async {
            let manager = AgentManagerTests.setupManager(agentCount: 2)
            let first = manager.agents[0]
            let second = manager.agents[1]
            let other = Agent(name: "Other", folder: "/tmp/other")
            manager.agents.append(other)
            manager.workspaces.append(
                Workspace(name: "Second", agentIds: [other.id], activeAgentIds: [other.id])
            )

            #expect(manager.sidebarShortcutIndex(for: first.id) == 1)
            #expect(manager.sidebarShortcutIndex(for: second.id) == 2)
            #expect(manager.sidebarShortcutIndex(for: other.id) == 3)
        }

        @Test("Command-N reaches an agent in another workspace")
        @MainActor
        func reachesOtherWorkspace() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let other = Agent(name: "Other", folder: "/tmp/other")
            manager.agents.append(other)
            manager.workspaces.append(
                Workspace(name: "Second", agentIds: [other.id], activeAgentIds: [other.id])
            )

            #expect(manager.selectAgent(atSidebarIndex: 2))
            #expect(manager.currentWorkspace?.agentIds.contains(other.id) == true)
        }
    }

    @Suite("Model switching")
    struct ModelSwitchingTests {
        @Test("claude switches model live via /model and persists the choice")
        @MainActor
        func claudeSwitchesLive() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "claude")
            let agent = manager.agents[0]
            let controller = manager.createController(for: agent)
            let adapter = MockTerminalAdapter()
            controller.attach(to: adapter)

            let applied = manager.setModel("opus", for: agent.id)

            #expect(applied)
            #expect(manager.agents[0].model == "opus")
            #expect(adapter.sentTexts == ["/model opus"])
        }

        @Test("agents without a runtime switch only store the model for next launch")
        @MainActor
        func geminiDefersToRestart() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "gemini")
            let agent = manager.agents[0]
            let controller = manager.createController(for: agent)
            let adapter = MockTerminalAdapter()
            controller.attach(to: adapter)

            let applied = manager.setModel("gemini-2.5-pro", for: agent.id)

            #expect(!applied)
            #expect(manager.agents[0].model == "gemini-2.5-pro")
            #expect(adapter.sentTexts.isEmpty)
        }

        @Test("selecting the model already in use is a no-op")
        @MainActor
        func noOpWhenUnchanged() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1, agentType: "claude")
            let agent = manager.agents[0]
            let controller = manager.createController(for: agent)
            let adapter = MockTerminalAdapter()
            controller.attach(to: adapter)
            manager.setModel("opus", for: agent.id)

            let applied = manager.setModel("opus", for: agent.id)

            #expect(!applied)
            #expect(adapter.sentTexts == ["/model opus"])
        }
    }

    @Suite("Drawer shell terminals")
    struct DrawerShellTests {
        @Test("drawer shell is created lazily, reused, and configured as a plain work shell")
        @MainActor
        func drawerShellLazyCreationAndReuse() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agent = manager.agents[0]

            #expect(!manager.hasDrawerShell(for: agent.id))

            let controller = manager.drawerShellController(for: agent)

            #expect(manager.hasDrawerShell(for: agent.id))
            #expect(controller.agentType == "shell")
            #expect(controller.folder == agent.workingFolder)
            #expect(controller.fontSize == AppSettings.shared.drawerTerminalFontSize)
            #expect(controller.agentId != agent.id)  // must never collide with the agent session pane

            let again = manager.drawerShellController(for: agent)
            #expect(controller === again)
        }

        @Test("removing an agent's controller also disposes its drawer shell")
        @MainActor
        func removeControllerDisposesDrawerShell() async {
            let manager = AgentManagerTests.setupManager(agentCount: 1)
            let agent = manager.agents[0]
            manager.drawerShellController(for: agent)
            #expect(manager.hasDrawerShell(for: agent.id))

            manager.removeController(for: agent.id)

            #expect(!manager.hasDrawerShell(for: agent.id))
        }
    }
}
