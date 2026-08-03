import SwiftUI

struct WorkspaceSidebarSection: View {
    let workspace: Workspace
    let agentManager: AgentManager
    @Binding var forkPrefill: AgentPrefill?
    let onEditWorkspace: () -> Void

    @ObservedObject private var settings = AppSettings.shared
    @State private var isExpanded = true
    @State private var agentToEdit: Agent?

    private var workspaceAgents: [Agent] {
        workspace.agentIds.compactMap { id in agentManager.agents.first { $0.id == id } }
    }

    private var primaryAgents: [Agent] {
        workspaceAgents.filter { !$0.isCompanion }
    }

    /// Numbering runs down the whole sidebar, not per workspace, so the hint on a
    /// row never changes as you move between workspaces.
    private func shortcutIndex(for agent: Agent) -> Int? {
        agentManager.sidebarShortcutIndex(for: agent.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            workspaceHeader

            if isExpanded {
                if primaryAgents.isEmpty {
                    Text("No agents yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 30)
                        .padding(.vertical, 5)
                }

                ForEach(primaryAgents) { agent in
                    agentMenu(for: agent) {
                        Button {
                            select(agent)
                        } label: {
                            WorkspaceSidebarAgentRow(
                                agent: agent,
                                isSelected: isSelected(agent),
                                shortcutIndex: shortcutIndex(for: agent)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(agent.name)")
                    }

                    ForEach(workspaceAgents.filter { $0.isCompanion && $0.createdBy == agent.id }) { companion in
                        agentMenu(for: companion) {
                            Button {
                                select(companion)
                            } label: {
                                WorkspaceSidebarAgentRow(
                                    agent: companion,
                                    isSelected: isSelected(companion),
                                    isCompanion: true
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open companion \(companion.name)")
                        }
                    }
                }
            }
        }
        .sheet(item: $agentToEdit) { agent in
            AgentSheet(editing: agent)
        }
    }

    private var workspaceHeader: some View {
        Button {
            if agentManager.currentWorkspaceId == workspace.id {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } else {
                agentManager.switchToWorkspace(workspace.id)
                isExpanded = true
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)

                Image(systemName: "folder")
                    .foregroundStyle(workspace.color)

                Text(workspace.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)

                Spacer()

                Text("\(workspaceAgents.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit Workspace…", action: onEditWorkspace)
            Button("Detach Workspace") { agentManager.detachWorkspace(workspace) }
            Divider()
            Button("Delete Workspace", role: .destructive) { agentManager.removeWorkspace(workspace) }
        }
    }

    private func isSelected(_ agent: Agent) -> Bool {
        agentManager.currentWorkspaceId == workspace.id && agentManager.isAgentActive(agent.id)
    }

    private func select(_ agent: Agent) {
        agentManager.switchToWorkspace(workspace.id)
        agentManager.selectAgent(agent.id)
        agentManager.showDashboard = false
        agentManager.showGlobalDashboard = false
    }

    private func agentMenu<Content: View>(
        for agent: Agent,
        @ViewBuilder content: () -> Content
    ) -> some View {
        AgentContextMenu(
            agent: agent,
            onEdit: { agentToEdit = agent },
            onFork: { forkPrefill = agent.forkPrefill() },
            onNewCompanion: { forkPrefill = agent.companionPrefill() },
            onShellCompanion: { agentManager.createShellCompanion(for: agent) },
            onSaveToBench: { settings.addToBench(agent) },
            suppliedAgentManager: agentManager,
            content: content
        )
    }
}
