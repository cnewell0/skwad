import SwiftUI

/// A standalone view for a workspace detached to its own window.
/// Shows sidebar + terminal area for a single workspace (no workspace bar).
struct DetachedWorkspaceView: View {
    @Environment(AgentManager.self) var agentManager
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AppSettings.shared
    @State private var sidebarWidth: CGFloat = 250
    @State private var sidebarDragStartWidth: CGFloat?
    @State private var sidebarVisible = true
    @State private var showGitPanel = false
    @State private var gitPanelFolder: String?
    @State private var gitPanelHasUnsavedEdits = false
    @State private var showCloseGitPanelAlert = false
    @State private var showFileFinder = false
    @State private var showNewAgentSheet = false
    @State private var agentToEdit: Agent?
    @State private var forkPrefill: AgentPrefill?
    @State private var artifactExpanded = false
    @State private var lastPaneRects: [UUID: CGRect] = [:]
    @State private var showCloseDialog = false
    @State private var showTerminalDrawer = false
    @AppStorage("terminalDrawerHeightDetached") private var terminalDrawerHeight: Double = 280
    @State private var terminalDrawerDragStartHeight: CGFloat?
    @AppStorage("terminalDrawerMode") private var terminalDrawerModeRaw = TerminalDrawerMode.shell.rawValue
    @State private var contextPathsByAgent: [UUID: [String]] = [:]

    let workspaceId: UUID

    private var workspace: Workspace? {
        agentManager.workspaces.first { $0.id == workspaceId }
    }

    private var workspaceAgents: [Agent] {
        guard let workspace else { return [] }
        return workspace.agentIds.compactMap { id in agentManager.agents.first { $0.id == id } }
    }

    /// Non-companion agents for sidebar display
    private var sidebarAgents: [Agent] {
        workspaceAgents.filter { !$0.isCompanion }
    }

    private var activeAgent: Agent? {
        guard let workspace else { return nil }
        let activeIds = workspace.activeAgentIds
        let focusedIndex = workspace.focusedPaneIndex
        guard focusedIndex < activeIds.count else {
            guard let firstId = activeIds.first else { return nil }
            return agentManager.agents.first { $0.id == firstId }
        }
        let agentId = activeIds[focusedIndex]
        return agentManager.agents.first { $0.id == agentId }
    }

    private var activeAgentIds: [UUID] {
        workspace?.activeAgentIds ?? []
    }

    private var layoutMode: LayoutMode {
        workspace?.layoutMode ?? .single
    }

    private var canShowGitPanel: Bool {
        guard let agent = activeAgent else { return false }
        return GitWorktreeManager.shared.isGitRepo(agent.workingFolder)
    }

    /// AppStorage persists Double; the resize bar works in CGFloat
    private var terminalDrawerHeightBinding: Binding<CGFloat> {
        Binding(
            get: { CGFloat(terminalDrawerHeight) },
            set: { terminalDrawerHeight = Double($0) }
        )
    }

    private var terminalDrawerMode: TerminalDrawerMode {
        TerminalDrawerMode(rawValue: terminalDrawerModeRaw) ?? .shell
    }

    private var terminalDrawerModeBinding: Binding<TerminalDrawerMode> {
        Binding(
            get: { TerminalDrawerMode(rawValue: terminalDrawerModeRaw) ?? .shell },
            set: { terminalDrawerModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            conversationColumn
            gitPanel
            artifactPanel
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            mainContentWidth = width
        }
        .background(settings.sidebarBackgroundColor)
        .frame(minWidth: 700, minHeight: 500)
        .ignoresSafeArea()
        .background(WindowTitleSetter(title: workspace?.name ?? "Workspace"))
        .overlay {
            if showFileFinder, let agent = activeAgent {
                FileFinderView(
                    folder: agent.workingFolder,
                    onDismiss: { showFileFinder = false },
                    onSelect: { path in
                        var contextPaths = contextPathsByAgent[agent.id] ?? []
                        if !contextPaths.contains(path) {
                            contextPaths.append(path)
                            contextPathsByAgent[agent.id] = contextPaths
                        }
                        showFileFinder = false
                    }
                )
                .transition(.opacity)
            }
        }
        .onChange(of: showGitPanel) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if let agent = activeAgent {
                    agentManager.notifyTerminalResize(for: agent.id)
                }
            }
        }
        .onChange(of: activeAgent?.id) { _, _ in
            if showGitPanel { requestCloseGitPanel() }
            if showFileFinder { showFileFinder = false }
        }
        .onChange(of: showTerminalDrawer) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                for id in activeAgentIds {
                    agentManager.notifyTerminalResize(for: id)
                }
            }
        }
        .onChange(of: workspace?.isDetachedFromMain) { _, isDetached in
            if isDetached != true {
                dismiss()
            }
        }
        .sheet(isPresented: $showNewAgentSheet) {
            AgentSheet(targetWorkspaceId: workspaceId)
                .environment(agentManager)
        }
        .sheet(item: $agentToEdit) { agent in
            AgentSheet(editing: agent)
                .environment(agentManager)
        }
        .sheet(item: $forkPrefill) { prefill in
            AgentSheet(prefill: prefill)
                .environment(agentManager)
        }
        .background(
            WindowCloseInterceptor(
                workspaceId: workspaceId,
                agentManager: agentManager,
                onCloseAttempt: {
                    showCloseDialog = true
                }
            )
        )
        .alert("Close Workspace Window", isPresented: $showCloseDialog) {
            Button("Re-attach") {
                if let ws = workspace {
                    agentManager.reattachWorkspace(ws)
                }
            }
            Button("Close Workspace", role: .destructive) {
                if let ws = workspace {
                    agentManager.removeWorkspace(ws)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let ws = workspace {
                Text("What would you like to do with \"\(ws.name)\"?")
            }
        }
        .alert("Discard unsaved worktree edits?", isPresented: $showCloseGitPanelAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Discard and Close", role: .destructive) {
                closeGitPanel()
            }
        } message: {
            Text("The editor contains changes that have not been saved to this worktree.")
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        if !workspaceAgents.isEmpty && sidebarVisible {
            VStack(spacing: 0) {
                workspaceHeader

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(sidebarAgents) { agent in
                            sidebarAgentMenu(for: agent) {
                                sidebarAgentButton(for: agent)
                            }

                            ForEach(companions(for: agent)) { companion in
                                sidebarAgentMenu(for: companion) {
                                    sidebarAgentButton(for: companion, isCompanion: true)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                }

                Spacer(minLength: 0)
            }
            .frame(width: sidebarWidth)

            Rectangle()
                .fill(Color.clear)
                .frame(width: 6)
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    // Global coordinate space: the handle moves with the sidebar edge,
                    // so local translation would fight the drag and jitter.
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { value in
                            if sidebarDragStartWidth == nil {
                                sidebarDragStartWidth = sidebarWidth
                            }
                            let newWidth = (sidebarDragStartWidth ?? sidebarWidth) + value.translation.width
                            sidebarWidth = min(max(newWidth, ContentView.minSidebarWidth), ContentView.maxSidebarWidth)
                        }
                        .onEnded { _ in sidebarDragStartWidth = nil }
                )
        }
    }

    private func companions(for agent: Agent) -> [Agent] {
        workspaceAgents.filter { $0.isCompanion && $0.createdBy == agent.id }
    }

    private func isSelected(_ agent: Agent) -> Bool {
        guard let focusedId = activeAgent?.id else { return false }
        return agent.id == focusedId || companions(for: agent).contains { $0.id == focusedId }
    }

    private func sidebarAgentButton(for agent: Agent, isCompanion: Bool = false) -> some View {
        Button {
            agentManager.selectAgent(agent.id, in: workspaceId)
        } label: {
            WorkspaceSidebarAgentRow(
                agent: agent,
                isSelected: isCompanion ? activeAgent?.id == agent.id : isSelected(agent),
                isCompanion: isCompanion
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCompanion ? "Open companion \(agent.name)" : "Open \(agent.name)")
    }

    private func sidebarAgentMenu<Content: View>(
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

    private var workspaceHeader: some View {
        WindowDragView {
            // no-op tap
        }
        .frame(height: 0)
        .overlay(alignment: .bottom) {
            HStack(spacing: 8) {
                Circle()
                    .fill(workspace?.color ?? .blue)
                    .frame(width: 10, height: 10)

                Text(workspace?.name ?? "Workspace")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                Button {
                    if let ws = workspace {
                        agentManager.reattachWorkspace(ws)
                    }
                } label: {
                    Image(systemName: "arrow.uturn.left")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("Re-attach to main window")
            }
            .padding(.horizontal, 12)
            .padding(.top, 24)
            .padding(.bottom, 8)
        }
        .frame(height: 64)
        .background(settings.sidebarBackgroundColor.withAddedContrast(by: 0.03))
    }

    // MARK: - Conversation and Terminal

    /// See ContentView: measured, not wrapped in a GeometryReader
    @State private var conversationColumnHeight: CGFloat = 0
    @State private var mainContentWidth: CGFloat = 0

    private var gitPanelAvailableWidth: CGFloat {
        guard mainContentWidth > 0 else { return .infinity }
        let sidebar = (!workspaceAgents.isEmpty && sidebarVisible) ? sidebarWidth + 6 : 0
        return max(300, mainContentWidth - sidebar - ContentView.minConversationWidth)
    }

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            conversationToolbar

            Group {
                if let agent = activeAgent {
                    DetachedWorkspaceConversationSurface(
                        agent: agent,
                        contextPaths: contextPathsByAgent[agent.id] ?? [],
                        onAddContext: { showFileFinder = true },
                        onRemoveContext: { path in
                            contextPathsByAgent[agent.id]?.removeAll { $0 == path }
                        },
                        onContextsSent: { contextPathsByAgent[agent.id] = [] },
                        onSend: { prompt in agentManager.sendPrompt(prompt, for: agent.id) },
                        onEditAgent: { agentToEdit = agent },
                        onSelectModel: { agentManager.setModel($0, for: agent.id) },
                        onInterrupt: { agentManager.interruptAgent(agent.id) },
                        onCyclePermission: { agentManager.cyclePermissionMode(for: agent.id) },
                        onSelectPermission: { agentManager.setPermissionMode($0, for: agent.id) },
                        onRevealAgentTerminal: {
                            terminalDrawerModeRaw = TerminalDrawerMode.agent.rawValue
                            withAnimation(.easeInOut(duration: 0.2)) { showTerminalDrawer = true }
                        },
                        onAnswerChoice: { agentManager.answerChoice($0, question: $1, for: agent.id) }
                    )
                    .id(agent.id)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            terminalDrawer(availableHeight: conversationColumnHeight)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            conversationColumnHeight = height
        }
        .frame(minWidth: artifactExpanded ? 0 : ContentView.minConversationWidth)
        .opacity(artifactExpanded ? 0 : 1)
        .frame(width: artifactExpanded ? 0 : nil)
        .allowsHitTesting(!artifactExpanded)
        .clipped()
        .background(settings.effectiveBackgroundColor)
    }

    private var conversationToolbar: some View {
        HStack(spacing: 10) {
            if !sidebarVisible {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = true }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .help("Show sidebar")
                .accessibilityLabel("Show sidebar")
            }

            if let agent = activeAgent {
                AvatarView(avatar: agent.avatar, size: 22, font: .caption)
                Text(agent.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Circle()
                    .fill(agent.state.color)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(agent.state.rawValue)
            }

            Spacer()

            if canShowGitPanel {
                Button {
                    toggleChangesPanel()
                } label: {
                    Label("Changes", systemImage: "rectangle.rightthird.inset.filled")
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .foregroundStyle(showGitPanel ? Color.accentColor : Color.secondary)
                .help(showGitPanel ? "Hide changes" : "Review changes")
                .accessibilityLabel(showGitPanel ? "Hide changes" : "Review changes")
            }

            Button {
                guard activeAgent != nil else { return }
                withAnimation(.easeInOut(duration: 0.2)) { showTerminalDrawer.toggle() }
            } label: {
                Label("Terminal", systemImage: "terminal")
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .foregroundStyle(showTerminalDrawer ? Color.accentColor : Color.secondary)
            .disabled(activeAgent == nil)
            .help(showTerminalDrawer ? "Hide terminal" : "Open terminal")
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(settings.sidebarBackgroundColor)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func terminalDrawer(availableHeight: CGFloat) -> some View {
        let resolved = TerminalDrawerSizing.resolvedHeight(
            stored: CGFloat(terminalDrawerHeight),
            available: availableHeight
        )
        return VStack(spacing: 0) {
            if showTerminalDrawer {
                TerminalDrawerResizeBar(
                    height: terminalDrawerHeightBinding,
                    dragStartHeight: $terminalDrawerDragStartHeight
                ) {
                    for id in activeAgentIds {
                        agentManager.notifyTerminalResize(for: id)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "terminal")

                    Text(terminalDrawerMode.title)
                        .fontWeight(.semibold)

                    if let agent = activeAgent {
                        Text(agent.workingFolder)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button {
                        terminalDrawerModeBinding.wrappedValue = terminalDrawerMode == .agent ? .shell : .agent
                    } label: {
                        Image(systemName: terminalDrawerMode == .agent ? "eye.fill" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(terminalDrawerMode == .agent ? Color.accentColor : Color.secondary)
                    .help(terminalDrawerMode == .agent ? "Back to work shell" : "Show raw agent session")
                    .accessibilityLabel(terminalDrawerMode == .agent ? "Back to work shell" : "Show raw agent session")

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showTerminalDrawer = false }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .help("Close terminal")
                    .accessibilityLabel("Close terminal")
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(settings.sidebarBackgroundColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(workspaceAgents) { agent in
                        terminalView(for: agent, in: geo)
                    }

                    DrawerShellStage(
                        agents: workspaceAgents,
                        activeAgentId: activeAgent?.id,
                        isVisible: showTerminalDrawer && terminalDrawerMode == .shell
                    )
                }
            }
            .frame(height: showTerminalDrawer ? max(1, resolved - 46) : 1)
            .opacity(showTerminalDrawer ? 1 : 0.001)
            .allowsHitTesting(showTerminalDrawer)
            .clipped()
        }
        .background(settings.effectiveBackgroundColor)
        .onChange(of: terminalDrawerModeRaw) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                for id in activeAgentIds {
                    agentManager.notifyTerminalResize(for: id)
                    agentManager.notifyDrawerShellResize(for: id)
                }
            }
        }
    }

    private func terminalView(for agent: Agent, in geo: GeometryProxy) -> some View {
        let visible = activeAgentIds.contains(agent.id) && terminalDrawerMode == .agent
        let rect = visible ? paneRect(for: agent.id, in: geo.size) : (lastPaneRects[agent.id] ?? CGRect(origin: .zero, size: geo.size))
        let paneIdx = activeAgentIds.firstIndex(of: agent.id) ?? 0

        return AgentTerminalView(
            agent: agent,
            paneIndex: paneIdx,
            suppressFocus: showFileFinder || !showTerminalDrawer || terminalDrawerMode != .agent,
            sidebarVisible: $sidebarVisible,
            forkPrefill: $forkPrefill,
            onGitStatsTap: {
                if GitWorktreeManager.shared.isGitRepo(agent.workingFolder) {
                    toggleChangesPanel(folder: agent.workingFolder)
                }
            },
            onPaneTap: {
                if let pane = activeAgentIds.firstIndex(of: agent.id) {
                    agentManager.focusPane(pane, in: workspaceId)
                }
            }
        )
        .id("\(agent.id)-\(agent.restartToken)")
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .onAppear {
            if lastPaneRects[agent.id] == nil {
                lastPaneRects[agent.id] = CGRect(origin: .zero, size: geo.size)
            }
        }
        .onChange(of: visible) { _, isVisible in
            if isVisible {
                lastPaneRects[agent.id] = paneRect(for: agent.id, in: geo.size)
            }
        }
    }

    private func paneRect(for agentId: UUID, in size: CGSize) -> CGRect {
        if layoutMode == .single {
            return CGRect(origin: .zero, size: size)
        }
        let pane = activeAgentIds.firstIndex(of: agentId) ?? 0
        return ContentView.computePaneRect(
            pane: pane,
            layoutMode: layoutMode,
            splitRatio: workspace?.splitRatio ?? 0.5,
            splitRatioSecondary: workspace?.effectiveSplitRatioSecondary ?? 0.5,
            in: size
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(workspace?.name ?? "Workspace")
                .font(.title)
                .foregroundColor(.primary)

            Text("No agents in this workspace")
                .font(.body)
                .foregroundColor(.secondary)

            Button("New Agent...") {
                showNewAgentSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(settings.effectiveBackgroundColor)
    }

    // MARK: - Git Panel

    @ViewBuilder
    private var gitPanel: some View {
        if showGitPanel, let folder = gitPanelFolder {
            GitPanelView(
                folder: folder,
                availableWidth: gitPanelAvailableWidth,
                onUnsavedChangesChange: { gitPanelHasUnsavedEdits = $0 },
                onClose: { requestCloseGitPanel() }
            )
            .transition(.move(edge: .trailing))
        }
    }

    private func toggleChangesPanel(folder: String? = nil) {
        if showGitPanel {
            requestCloseGitPanel()
        } else if let folder = folder ?? activeAgent?.workingFolder {
            gitPanelFolder = folder
            withAnimation(.easeInOut(duration: 0.2)) {
                showGitPanel = true
            }
        }
    }

    private func requestCloseGitPanel() {
        guard !gitPanelHasUnsavedEdits else {
            showCloseGitPanelAlert = true
            return
        }
        closeGitPanel()
    }

    private func closeGitPanel() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showGitPanel = false
        }
        gitPanelFolder = nil
        gitPanelHasUnsavedEdits = false
    }

    // MARK: - Artifact Panel

    @ViewBuilder
    private var artifactPanel: some View {
        if let agent = activeAgent, agent.markdownFilePath != nil || agent.mermaidSource != nil {
            ArtifactPanelView(
                agent: agent,
                isExpanded: $artifactExpanded,
                onCloseMarkdown: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        agentManager.closeMarkdownPanel(for: agent.id)
                        if agent.mermaidSource == nil {
                            artifactExpanded = false
                        }
                    }
                },
                onCloseMermaid: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        agentManager.closeMermaidPanel(for: agent.id)
                        if agent.markdownFilePath == nil {
                            artifactExpanded = false
                        }
                    }
                },
                onMarkdownApprove: { text in
                    agentManager.injectText(text, for: agent.id)
                },
                onMarkdownComment: { text in
                    agentManager.sendText(text, for: agent.id)
                },
                onMarkdownSubmitReview: {
                    agentManager.submitReturn(for: agent.id)
                }
            )
            .transition(.move(edge: .trailing))
        }
    }
}

/// Testable chat-first surface shared by every detached workspace window.
struct DetachedWorkspaceConversationSurface: View {
    let agent: Agent
    let contextPaths: [String]
    let onAddContext: () -> Void
    let onRemoveContext: (String) -> Void
    let onContextsSent: () -> Void
    let onSend: (String) -> Bool
    var onEditAgent: (() -> Void)? = nil
    var onSelectModel: ((String?) -> Void)? = nil
    var onInterrupt: (() -> Void)? = nil
    var onCyclePermission: (() -> Void)? = nil
    var onSelectPermission: ((String) -> Void)? = nil
    var onRevealAgentTerminal: (() -> Void)? = nil
    var onAnswerChoice: ((Int, String) -> Void)? = nil

    var body: some View {
        AgentConversationView(
            agent: agent,
            contextPaths: contextPaths,
            onAddContext: onAddContext,
            onRemoveContext: onRemoveContext,
            onContextsSent: onContextsSent,
            onSend: onSend,
            onEditAgent: onEditAgent,
            onSelectModel: onSelectModel,
            onInterrupt: onInterrupt,
            onCyclePermission: onCyclePermission,
            onSelectPermission: onSelectPermission,
            onRevealAgentTerminal: onRevealAgentTerminal,
            onAnswerChoice: onAnswerChoice
        )
    }
}

// MARK: - Window Title Setter

/// Sets the NSWindow title for use in Mission Control and Window menu
private struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.title = title
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.title = title
    }
}

// MARK: - Window Close Interceptor

/// NSViewRepresentable that intercepts the window close button and registers the window
/// in AgentManager's detachedWindowMap for Cmd+W routing.
private struct WindowCloseInterceptor: NSViewRepresentable {
    let workspaceId: UUID
    let agentManager: AgentManager
    let onCloseAttempt: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Defer window access to next runloop (view isn't in window yet)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.window = window
            // Register this window for Cmd+W routing
            agentManager.detachedWindowMap[ObjectIdentifier(window)] = workspaceId
            // Replace close button target
            if let closeButton = window.standardWindowButton(.closeButton) {
                closeButton.target = context.coordinator
                closeButton.action = #selector(Coordinator.closeButtonClicked)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCloseAttempt = onCloseAttempt
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // Unregister when view is removed
        if let window = coordinator.window {
            coordinator.agentManager?.detachedWindowMap.removeValue(forKey: ObjectIdentifier(window))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCloseAttempt: onCloseAttempt, agentManager: agentManager)
    }

    class Coordinator: NSObject {
        var onCloseAttempt: () -> Void
        weak var window: NSWindow?
        weak var agentManager: AgentManager?

        init(onCloseAttempt: @escaping () -> Void, agentManager: AgentManager) {
            self.onCloseAttempt = onCloseAttempt
            self.agentManager = agentManager
        }

        @objc func closeButtonClicked() {
            onCloseAttempt()
        }
    }
}
