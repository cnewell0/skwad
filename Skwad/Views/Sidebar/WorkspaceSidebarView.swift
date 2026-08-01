import SwiftUI

/// Main navigation rail: workspaces are first-class sections and agents branch beneath them.
struct WorkspaceSidebarView: View {
    let agentManager: AgentManager
    @Binding var showNewAgentSheet: Bool
    @Binding var forkPrefill: AgentPrefill?
    @Binding var sidebarVisible: Bool

    @ObservedObject private var settings = AppSettings.shared
    @State private var showNewWorkspaceSheet = false
    @State private var workspaceToEdit: Workspace?

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    commandCenter

                    ForEach(agentManager.attachedWorkspaces) { workspace in
                        WorkspaceSidebarSection(
                            workspace: workspace,
                            agentManager: agentManager,
                            forkPrefill: $forkPrefill,
                            onEditWorkspace: { workspaceToEdit = workspace }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
            }

            Divider().opacity(0.5)
            actions
        }
        .frame(minWidth: 220)
        .background(settings.sidebarBackgroundColor)
        .sheet(isPresented: $showNewWorkspaceSheet) {
            WorkspaceSheet()
        }
        .sheet(item: $workspaceToEdit) { workspace in
            WorkspaceSheet(workspace: workspace)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "person.3.sequence.fill")
                .foregroundStyle(.secondary)
            Text("Skwad")
                .font(.system(size: 16, weight: .semibold))

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = false }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .help("Hide sidebar")
            .accessibilityLabel("Hide sidebar")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var commandCenter: some View {
        Button {
            agentManager.showGlobalDashboard = true
        } label: {
            Label("Command Center", systemImage: "square.grid.2x2")
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(agentManager.showGlobalDashboard ? Theme.selectionBackground : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var actions: some View {
        VStack(spacing: 3) {
            Button {
                showNewAgentSheet = true
            } label: {
                Label("New agent", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Button {
                showNewWorkspaceSheet = true
            } label: {
                Label("New workspace", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
    }
}
