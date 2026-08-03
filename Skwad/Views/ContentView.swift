import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What the terminal drawer shows: a fresh work shell (default) or the live agent session.
enum TerminalDrawerMode: String, CaseIterable, Identifiable {
  case shell
  case agent

  var id: String { rawValue }

  var title: String {
    switch self {
    case .shell: "Terminal"
    case .agent: "Agent Session"
    }
  }
}

/// Keeps drawer work shells alive and shows the active agent's shell when visible.
/// Shells are created lazily the first time an agent's drawer opens in shell mode.
struct DrawerShellStage: View {
  @Environment(AgentManager.self) var agentManager
  @ObservedObject private var settings = AppSettings.shared
  let agents: [Agent]
  let activeAgentId: UUID?
  let isVisible: Bool

  var body: some View {
    ZStack {
      ForEach(agents.filter { agentManager.hasDrawerShell(for: $0.id) }) { agent in
        shellTerminal(for: agent)
      }
    }
    .onAppear { ensureShellForActiveAgent() }
    .onChange(of: isVisible) { _, _ in ensureShellForActiveAgent() }
    .onChange(of: activeAgentId) { _, _ in ensureShellForActiveAgent() }
  }

  private func ensureShellForActiveAgent() {
    guard isVisible,
          let activeAgentId,
          let agent = agents.first(where: { $0.id == activeAgentId }) else { return }
    agentManager.drawerShellController(for: agent)
  }

  @ViewBuilder
  private func shellTerminal(for agent: Agent) -> some View {
    if let controller = agentManager.drawerShells[agent.id] {
      let visible = isVisible && agent.id == activeAgentId
      Group {
        if settings.terminalEngine == "ghostty" {
          GhosttyTerminalWrapperView(
            controller: controller,
            isActive: visible,
            suppressFocus: false,
            onTerminalCreated: { _ in },
            onPaneTap: nil
          )
        } else {
          SwiftTermTerminalWrapperView(
            controller: controller,
            isActive: visible,
            suppressFocus: false,
            onPaneTap: nil
          )
        }
      }
      .opacity(visible ? 1 : 0)
      .allowsHitTesting(visible)
    }
  }
}

enum TerminalDrawerSizing {
  static let minimumHeight: CGFloat = 180
  static let maximumHeight: CGFloat = 620
  /// Space the chat keeps for its content and composer no matter how tall the drawer is
  static let reservedForChat: CGFloat = 260

  static func height(start: CGFloat, translation: CGFloat) -> CGFloat {
    min(maximumHeight, max(minimumHeight, start - translation))
  }

  /// The stored height fitted to the space actually available.
  ///
  /// Applied on every layout pass, not just while dragging: shrinking the window used
  /// to leave the drawer at its old height and squeeze the composer off screen.
  static func resolvedHeight(stored: CGFloat, available: CGFloat) -> CGFloat {
    guard available > 0 else { return max(minimumHeight, stored) }
    let ceiling = max(minimumHeight, available - reservedForChat)
    return min(min(maximumHeight, ceiling), max(minimumHeight, stored))
  }
}

struct TerminalDrawerResizeBar: View {
  @Binding var height: CGFloat
  @Binding var dragStartHeight: CGFloat?
  let onResizeEnd: () -> Void

  @State private var isHovered = false

  var body: some View {
    ZStack {
      Rectangle()
        .fill(isHovered ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))

      Capsule()
        .fill(isHovered ? Color.accentColor : Color.secondary.opacity(0.45))
        .frame(width: 42, height: 3)
    }
    .frame(height: 10)
    .contentShape(Rectangle())
    .onHover { hovering in
      isHovered = hovering
      if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
    }
    .gesture(
      // Global coordinate space: the bar moves with the drag, so local translation
      // would oscillate against itself and make resizing feel janky.
      DragGesture(minimumDistance: 0, coordinateSpace: .global)
        .onChanged { value in
          if dragStartHeight == nil {
            dragStartHeight = height
          }
          height = TerminalDrawerSizing.height(
            start: dragStartHeight ?? height,
            translation: value.translation.height
          )
        }
        .onEnded { _ in
          dragStartHeight = nil
          onResizeEnd()
        }
    )
    .accessibilityElement()
    .accessibilityLabel("Resize terminal drawer")
    .accessibilityValue("\(Int(height)) points high")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        height = TerminalDrawerSizing.height(start: height, translation: -40)
      case .decrement:
        height = TerminalDrawerSizing.height(start: height, translation: 40)
      @unknown default:
        return
      }
      onResizeEnd()
    }
  }
}

struct ContentView: View {
  @Environment(AgentManager.self) var agentManager
  @ObservedObject private var settings = AppSettings.shared
  @State private var voiceManager = VoiceInputManager.shared
  @State private var pushToTalk = PushToTalkMonitor.shared
  @State private var showGitPanel = false
  @State private var gitPanelFolder: String?
  @State private var gitPanelHasUnsavedEdits = false
  @State private var showCloseGitPanelAlert = false
  @State private var sidebarWidth: CGFloat = 250
  @State private var sidebarDragStartWidth: CGFloat?
  @State private var showVoiceOverlay = false
  @State private var escapeMonitor: Any?
  @State private var sidebarVisible = true
  @State private var dragStartRatio: CGFloat?
  @State private var dragStartRatioSecondary: CGFloat?
  @State private var isDropTargeted = false
  @State private var lastPaneRects: [UUID: CGRect] = [:]
  @State private var artifactExpanded = false
  @State private var showTerminalDrawer = false
  @AppStorage("terminalDrawerHeight") private var terminalDrawerHeight: Double = 300
  @State private var terminalDrawerDragStartHeight: CGFloat?
  @AppStorage("terminalDrawerMode") private var terminalDrawerModeRaw = TerminalDrawerMode.shell.rawValue
  @State private var contextPathsByAgent: [UUID: [String]] = [:]
  @State private var agentToEdit: Agent?

  @State private var showFileFinder = false

  // Bindings from SkwadApp for menu commands
  @Binding var showNewAgentSheet: Bool
  @Binding var toggleGitPanel: Bool
  @Binding var toggleSidebar: Bool
  @Binding var toggleTerminal: Bool
  @Binding var toggleFileFinder: Bool
  @Binding var forkPrefill: AgentPrefill?

  static let minSidebarWidth: CGFloat = 80
  static let maxSidebarWidth: CGFloat = 400
  static let compactBreakpoint: CGFloat = 160

  static func isSidebarCompact(width: CGFloat) -> Bool {
    width < compactBreakpoint
  }

  private var activeAgent: Agent? {
    guard let id = agentManager.activeAgentId else { return nil }
    return agentManager.agents.first { $0.id == id }
  }

  private var isAnyDashboardVisible: Bool {
    agentManager.showGlobalDashboard || agentManager.showDashboard
  }

  private var canShowGitPanel: Bool {
    guard let agent = activeAgent else { return false }
    return GitWorktreeManager.shared.isGitRepo(agent.workingFolder)
  }

  private var isTerminalAreaCollapsed: Bool {
    artifactExpanded || !showTerminalDrawer
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

  private var shouldShowLayoutToggle: Bool {
    !isAnyDashboardVisible && agentManager.currentWorkspaceAgents.count >= 2
  }

  private var shouldShowSplitModeOverlays: Bool {
    !isAnyDashboardVisible && agentManager.layoutMode != .single
  }

  var body: some View {
    // Split across several properties: as one chain this became large enough
    // that the type checker gave up on CI ("unable to type-check in reasonable time").
    commandedContent
  }

  private var styledContent: some View {
    mainContent
    .background(settings.sidebarBackgroundColor)
    .frame(minWidth: 1_000, minHeight: 640)
    .ignoresSafeArea()
    .animation(.easeInOut(duration: 0.25), value: agentManager.currentWorkspaceAgents.count)
    .animation(.easeInOut(duration: 0.25), value: agentManager.currentWorkspaceId)
    .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
      handleFileDrop(providers: providers)
    }
    .overlay { contentOverlays }
  }

  @ViewBuilder
  private var contentOverlays: some View {
      // Voice input overlay
      if showVoiceOverlay {
        voiceOverlay
      }

      // File finder overlay
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

  private var observedContent: some View {
    styledContent
    .onChange(of: agentManager.activeAgentIds) { _, _ in
      if showGitPanel { requestCloseGitPanel() }
      if showFileFinder { showFileFinder = false }
    }
    .onChange(of: agentManager.focusedPaneIndex) { _, _ in
      if showGitPanel { requestCloseGitPanel() }
    }
    .onChange(of: showGitPanel) { _, _ in
      // Notify terminal to resize when git panel toggles
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        if let activeId = agentManager.activeAgentId {
          agentManager.notifyTerminalResize(for: activeId)
        }
      }
    }
    .onChange(of: activeAgent?.markdownFilePath) { _, newValue in
      // Sync maximized state from agent model when panel opens
      if newValue != nil {
        artifactExpanded = activeAgent?.markdownMaximized ?? false
      } else if activeAgent?.mermaidSource == nil {
        artifactExpanded = false
      }
      // Notify terminal to resize when artifact panel toggles
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        if let activeId = agentManager.activeAgentId {
          agentManager.notifyTerminalResize(for: activeId)
        }
      }
    }
    .onChange(of: activeAgent?.mermaidSource) { _, newValue in
      if newValue == nil && activeAgent?.markdownFilePath == nil {
        artifactExpanded = false
      }
      // Notify terminal to resize when artifact panel toggles
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        if let activeId = agentManager.activeAgentId {
          agentManager.notifyTerminalResize(for: activeId)
        }
      }
    }
    .onChange(of: sidebarVisible) { _, _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        for id in agentManager.activeAgentIds {
          agentManager.notifyTerminalResize(for: id)
        }
      }
    }
    .onChange(of: showTerminalDrawer) { _, _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        for id in agentManager.activeAgentIds {
          agentManager.notifyTerminalResize(for: id)
          agentManager.notifyDrawerShellResize(for: id)
        }
      }
    }
    .onAppear {
      guard !AppRuntime.isRunningTests else { return }
      if settings.voiceEnabled {
        pushToTalk.start()
      }
    }
    .onChange(of: settings.voiceEnabled) { _, enabled in
      if enabled {
        pushToTalk.start()
      } else {
        pushToTalk.stop()
      }
    }
    .onChange(of: pushToTalk.isKeyDown) { _, isDown in
      handleVoiceKeyStateChange(isDown: isDown)
    }
    .onChange(of: showVoiceOverlay) { _, showing in
      if showing {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
          if event.keyCode == 53 {  // Escape key
            DispatchQueue.main.async {
              self.dismissVoiceOverlay()
            }
            return nil  // Consume the event
          }
          return event
        }
      } else {
        if let monitor = escapeMonitor {
          NSEvent.removeMonitor(monitor)
          escapeMonitor = nil
        }
      }
    }
  }

  private var commandedContent: some View {
    observedContent
    .sheet(isPresented: $showNewAgentSheet) {
      AgentSheet()
        .environment(agentManager)
    }
    .sheet(item: $agentToEdit) { agent in
      AgentSheet(editing: agent)
        .environment(agentManager)
    }
    .onChange(of: toggleGitPanel) { _, _ in
      if canShowGitPanel {
        toggleChangesPanel()
      } else if showGitPanel {
        requestCloseGitPanel()
      }
    }
    .onChange(of: toggleSidebar) { _, _ in
      withAnimation(.easeInOut(duration: 0.25)) {
        sidebarVisible.toggle()
      }
    }
    .onChange(of: toggleTerminal) { _, _ in
      guard activeAgent != nil else { return }
      withAnimation(.easeInOut(duration: 0.2)) {
        showTerminalDrawer.toggle()
      }
    }
    .onChange(of: toggleFileFinder) { _, _ in
      if activeAgent != nil {
        showFileFinder.toggle()
      }
    }
  }

  private var mainContent: some View {
    HStack(spacing: 0) {
      workspaceNavigation
      conversationColumn
      gitPanel
      artifactPanel
    }
    .alert("Discard unsaved worktree edits?", isPresented: $showCloseGitPanelAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Discard and Close", role: .destructive) {
        closeGitPanel()
      }
    } message: {
      Text("The editor contains changes that have not been saved to the agent's worktree.")
    }
  }

  @ViewBuilder
  private var workspaceNavigation: some View {
    if sidebarVisible && !artifactExpanded {
      WorkspaceSidebarView(
        agentManager: agentManager,
        showNewAgentSheet: $showNewAgentSheet,
        forkPrefill: $forkPrefill,
        sidebarVisible: $sidebarVisible
      )
      .frame(width: sidebarWidth)
      .transition(.move(edge: .leading).combined(with: .opacity))

      Rectangle()
        .fill(Color.primary.opacity(0.08))
        .frame(width: 1)
        .overlay {
          Rectangle()
            .fill(Color.clear)
            .frame(width: 10)
            .contentShape(Rectangle())
            .onHover { hovering in
              if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
              // Global coordinate space: the handle moves with the sidebar edge,
              // so local translation would fight the drag and jitter.
              DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                  if sidebarDragStartWidth == nil {
                    sidebarDragStartWidth = sidebarWidth
                  }
                  let startWidth = sidebarDragStartWidth ?? sidebarWidth
                  sidebarWidth = min(
                    max(startWidth + value.translation.width, Self.minSidebarWidth),
                    Self.maxSidebarWidth
                  )
                }
                .onEnded { _ in sidebarDragStartWidth = nil }
            )
        }
    }
  }

  /// Chat keeps this much width so opening Changes or an artifact can't collapse it
  static let minConversationWidth: CGFloat = 420

  private var conversationColumn: some View {
    GeometryReader { geo in
      conversationStack(availableHeight: geo.size.height)
    }
    .frame(minWidth: artifactExpanded ? 0 : Self.minConversationWidth)
  }

  private func conversationStack(availableHeight: CGFloat) -> some View {
    VStack(spacing: 0) {
      conversationToolbar

      ZStack {
        if isAnyDashboardVisible {
          dashboardOverlay
            .transition(.opacity)
        } else if let agent = activeAgent {
          AgentConversationView(
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
            onRevealAgentTerminal: {
              terminalDrawerModeRaw = TerminalDrawerMode.agent.rawValue
              withAnimation(.easeInOut(duration: 0.2)) { showTerminalDrawer = true }
            },
            onAnswerChoice: { agentManager.answerChoice($0, for: agent.id) }
          )
          .id(agent.id)
        } else {
          emptyStateView
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      terminalDrawer(availableHeight: availableHeight)
    }
    .frame(width: artifactExpanded ? 0 : nil)
    .opacity(artifactExpanded ? 0 : 1)
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

      if let workspace = agentManager.currentWorkspace {
        Circle()
          .fill(workspace.color)
          .frame(width: 8, height: 8)

        Text(workspace.name)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      if let agent = activeAgent {
        Image(systemName: "chevron.right")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        AvatarView(avatar: agent.avatar, size: 22, font: .caption)
        Text(agent.name)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        Circle()
          .fill(agent.state.color)
          .frame(width: 7, height: 7)
          .accessibilityLabel(agent.state.rawValue)
      }

      Spacer(minLength: 12)

      if shouldShowLayoutToggle {
        layoutToggleButton
      }

      if canShowGitPanel {
        Button {
          toggleChangesPanel()
        } label: {
          Label("Changes", systemImage: "rectangle.rightthird.inset.filled")
            .labelStyle(.titleAndIcon)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .foregroundStyle(showGitPanel ? Color.accentColor : Color.secondary)
        .help(showGitPanel ? "Hide changes" : "Review changes")
      }

      Button {
        withAnimation(.easeInOut(duration: 0.2)) { showTerminalDrawer.toggle() }
      } label: {
        Label("Terminal", systemImage: "terminal")
          .labelStyle(.titleAndIcon)
          .fixedSize(horizontal: true, vertical: false)
      }
      .buttonStyle(.plain)
      .foregroundStyle(showTerminalDrawer ? Color.accentColor : Color.secondary)
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
          for id in agentManager.activeAgentIds {
            agentManager.notifyTerminalResize(for: id)
            agentManager.notifyDrawerShellResize(for: id)
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

          // The raw agent TUI is an implementation detail — the chat is the way to
          // drive the agent. Keep it reachable (permission prompts still live there)
          // but out of the way.
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
        terminalStage(in: geo)
      }
      .frame(height: showTerminalDrawer && !artifactExpanded ? max(1, resolved - 46) : 1)
      .opacity(showTerminalDrawer && !artifactExpanded ? 1 : 0.001)
      .allowsHitTesting(showTerminalDrawer && !artifactExpanded && !isAnyDashboardVisible)
      .clipped()
    }
    .background(settings.effectiveBackgroundColor)
    .onChange(of: terminalDrawerModeRaw) { _, _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
        for id in agentManager.activeAgentIds {
          agentManager.notifyTerminalResize(for: id)
          agentManager.notifyDrawerShellResize(for: id)
        }
      }
    }
  }

  @ViewBuilder
  private func terminalStage(in geo: GeometryProxy) -> some View {
    ZStack(alignment: .topLeading) {
      terminalViews(in: geo)

      DrawerShellStage(
        agents: attachedAgents,
        activeAgentId: agentManager.activeAgentId,
        isVisible: showTerminalDrawer && !artifactExpanded && terminalDrawerMode == .shell
      )

      if shouldShowSplitModeOverlays && terminalDrawerMode == .agent {
        splitModeOverlays(in: geo)
      }
    }
  }

  /// Agents that belong to attached (non-detached) workspaces
  private var attachedAgents: [Agent] {
    let detachedAgentIds = Set(agentManager.detachedWorkspaces.flatMap(\.agentIds))
    return agentManager.agents.filter { !detachedAgentIds.contains($0.id) }
  }

  @ViewBuilder
  private func terminalViews(in geo: GeometryProxy) -> some View {
    ForEach(attachedAgents) { agent in
      terminalView(for: agent, in: geo)
    }
  }

  private func terminalView(for agent: Agent, in geo: GeometryProxy) -> some View {
    let visible = isTerminalVisible(agent)
    let rect = terminalRect(for: agent, in: geo.size, visible: visible)
    let paneIdx = agentManager.paneIndex(for: agent.id) ?? 0

    return AgentTerminalView(
      agent: agent,
      paneIndex: paneIdx,
      suppressFocus: showFileFinder || isAnyDashboardVisible || !showTerminalDrawer || terminalDrawerMode != .agent,
      sidebarVisible: $sidebarVisible,
      forkPrefill: $forkPrefill,
      onGitStatsTap: {
        if GitWorktreeManager.shared.isGitRepo(agent.workingFolder) {
          if let pane = agentManager.paneIndex(for: agent.id) {
            agentManager.focusPane(pane)
          }
          toggleChangesPanel(folder: agent.workingFolder)
        }
      },
      onPaneTap: {
        if let pane = agentManager.paneIndex(for: agent.id) {
          agentManager.focusPane(pane)
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

  private func isTerminalVisible(_ agent: Agent) -> Bool {
    agentManager.activeAgentIds.contains(agent.id) && terminalDrawerMode == .agent
  }

  private func terminalRect(for agent: Agent, in size: CGSize, visible: Bool) -> CGRect {
    if visible {
      return paneRect(for: agent.id, in: size)
    }
    if isTerminalAreaCollapsed {
      return .zero
    }
    return lastPaneRects[agent.id] ?? CGRect(origin: .zero, size: size)
  }

  private var emptyStateView: some View {
    VStack(spacing: 16) {
      Image(nsImage: NSApplication.shared.applicationIconImage)
        .resizable()
        .frame(width: 128, height: 128)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

      VStack(spacing: 0) {
        Text("Welcome to Skwad!")
          .font(.system(size: 36, weight: .semibold))
          .foregroundColor(.primary)

        Text(agentManager.attachedWorkspaces.isEmpty
             ? "Start by creating your first workspace"
             : "Add an agent to your workspace")
          .font(.title)
          .foregroundColor(.secondary)
      }

      SplitButton("New Agent") {
        showNewAgentSheet = true
      } popover: {
        BenchDropdownView(
          onNewAgent: {
            showNewAgentSheet = true
          },
          onDeploy: { benchAgent in
            agentManager.deployBenchAgent(benchAgent)
          }
        )
        .environment(agentManager)
      }
      .frame(width: 240)
      .padding(.vertical, 32)

      VStack(spacing: 12) {
        Text("Install Skwad MCP Server to enable agent‑to‑agent communication")
          .font(.title2)
          .foregroundColor(.secondary)

        MCPCommandView(
          serverURL: settings.mcpServerURL,
          fontSize: .title3,
          backgroundColor: Color.black.opacity(0.08),
          iconSize: 20
        )
        .frame(maxWidth: 820)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(settings.effectiveBackgroundColor)
  }

  @ViewBuilder
  private func splitModeOverlays(in geo: GeometryProxy) -> some View {
    ForEach(0..<agentManager.layoutMode.paneCount, id: \.self) { pane in
      if pane != agentManager.focusedPaneIndex {
        let rect = computePaneRect(pane, in: geo.size)
        Rectangle()
          .fill(Color.black.opacity(Theme.unfocusedOverlayOpacity))
          .frame(width: rect.width, height: rect.height)
          .offset(x: rect.minX, y: rect.minY)
          .allowsHitTesting(false)
      }
    }

    if agentManager.layoutMode == .splitVertical || agentManager.layoutMode == .splitHorizontal {
      let isVertical = agentManager.layoutMode == .splitVertical
      let pos = isVertical ? geo.size.width * agentManager.splitRatio : geo.size.height * agentManager.splitRatio
      let dividerWidth: CGFloat = 12
      SplitDividerView(
        isVertical: isVertical,
        onDrag: { delta in
          if dragStartRatio == nil {
            dragStartRatio = agentManager.splitRatio
          }
          let totalSize = isVertical ? geo.size.width : geo.size.height
          let startPos = totalSize * dragStartRatio!
          let newRatio = (startPos + delta) / totalSize
          agentManager.splitRatio = max(0.25, min(0.75, newRatio))
        },
        onDragEnd: {
          dragStartRatio = nil
          for id in agentManager.activeAgentIds {
            agentManager.notifyTerminalResize(for: id)
          }
        }
      )
      .frame(
        width: isVertical ? dividerWidth : geo.size.width,
        height: isVertical ? geo.size.height : dividerWidth
      )
      .offset(
        x: isVertical ? pos - dividerWidth / 2 : 0,
        y: isVertical ? 0 : pos - dividerWidth / 2
      )
    } else if agentManager.layoutMode == .threePane || agentManager.layoutMode == .gridFourPane {
      let dividerWidth: CGFloat = 12
      let vertPos = geo.size.width * agentManager.splitRatio
      let horizPos = geo.size.height * agentManager.splitRatioSecondary
      let isThreePane = agentManager.layoutMode == .threePane

      SplitDividerView(
        isVertical: true,
        onDrag: { delta in
          if dragStartRatio == nil {
            dragStartRatio = agentManager.splitRatio
          }
          let startPos = geo.size.width * dragStartRatio!
          let newRatio = (startPos + delta) / geo.size.width
          agentManager.splitRatio = max(0.25, min(0.75, newRatio))
        },
        onDragEnd: {
          dragStartRatio = nil
          for id in agentManager.activeAgentIds {
            agentManager.notifyTerminalResize(for: id)
          }
        }
      )
      .frame(width: dividerWidth, height: geo.size.height)
      .offset(x: vertPos - dividerWidth / 2)

      SplitDividerView(
        isVertical: false,
        onDrag: { delta in
          if dragStartRatioSecondary == nil {
            dragStartRatioSecondary = agentManager.splitRatioSecondary
          }
          let startPos = geo.size.height * dragStartRatioSecondary!
          let newRatio = (startPos + delta) / geo.size.height
          agentManager.splitRatioSecondary = max(0.25, min(0.75, newRatio))
        },
        onDragEnd: {
          dragStartRatioSecondary = nil
          for id in agentManager.activeAgentIds {
            agentManager.notifyTerminalResize(for: id)
          }
        }
      )
      .frame(width: isThreePane ? geo.size.width - vertPos : geo.size.width, height: dividerWidth)
      .offset(x: isThreePane ? vertPos : 0, y: horizPos - dividerWidth / 2)
    }
  }

  @ViewBuilder
  private var gitPanel: some View {
    if showGitPanel, let folder = gitPanelFolder {
      GitPanelView(
        folder: folder,
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

  // MARK: - Dashboard

  @ViewBuilder
  private var dashboardOverlay: some View {
    if agentManager.showGlobalDashboard {
      DashboardView(forkPrefill: $forkPrefill, workspaceId: nil)
    } else if agentManager.showDashboard {
      DashboardView(forkPrefill: $forkPrefill, workspaceId: agentManager.currentWorkspaceId)
    }
  }

  // MARK: - Split Pane Layout Helpers

  /// Compute the rect for an agent based on its pane assignment
  private func paneRect(for agentId: UUID, in size: CGSize) -> CGRect {
    if agentManager.layoutMode == .single {
      return CGRect(origin: .zero, size: size)
    }
    let pane = agentManager.paneIndex(for: agentId) ?? 0
    return computePaneRect(pane, in: size)
  }

  /// Compute rect for a pane index given layout mode and split ratio
  static func computePaneRect(pane: Int, layoutMode: LayoutMode, splitRatio: CGFloat, splitRatioSecondary: CGFloat, in size: CGSize) -> CGRect {
    switch layoutMode {
    case .single:
      return CGRect(origin: .zero, size: size)
    case .splitVertical:  // left | right
      let w0 = size.width * splitRatio
      let w1 = size.width - w0
      return pane == 0
        ? CGRect(x: 0, y: 0, width: w0, height: size.height)
        : CGRect(x: w0, y: 0, width: w1, height: size.height)
    case .splitHorizontal:  // top / bottom
      let h0 = size.height * splitRatio
      let h1 = size.height - h0
      return pane == 0
        ? CGRect(x: 0, y: 0, width: size.width, height: h0)
        : CGRect(x: 0, y: h0, width: size.width, height: h1)
    case .threePane:  // left half full-height | right top / right bottom
      let w0 = size.width * splitRatio
      let w1 = size.width - w0
      let h0 = size.height * splitRatioSecondary
      let h1 = size.height - h0
      switch pane {
      case 0: return CGRect(x: 0, y: 0, width: w0, height: size.height)  // left (full height)
      case 1: return CGRect(x: w0, y: 0, width: w1, height: h0)          // top-right
      case 2: return CGRect(x: w0, y: h0, width: w1, height: h1)         // bottom-right
      default: return CGRect(origin: .zero, size: size)
      }
    case .gridFourPane:  // 4-pane grid (primary = vertical, secondary = horizontal)
      let w0 = size.width * splitRatio
      let w1 = size.width - w0
      let h0 = size.height * splitRatioSecondary
      let h1 = size.height - h0
      switch pane {
      case 0: return CGRect(x: 0, y: 0, width: w0, height: h0)        // top-left
      case 1: return CGRect(x: w0, y: 0, width: w1, height: h0)       // top-right
      case 2: return CGRect(x: 0, y: h0, width: w0, height: h1)       // bottom-left
      case 3: return CGRect(x: w0, y: h0, width: w1, height: h1)      // bottom-right
      default: return CGRect(origin: .zero, size: size)
      }
    }
  }

  private func computePaneRect(_ pane: Int, in size: CGSize) -> CGRect {
    Self.computePaneRect(
      pane: pane,
      layoutMode: agentManager.layoutMode,
      splitRatio: agentManager.splitRatio,
      splitRatioSecondary: agentManager.splitRatioSecondary,
      in: size
    )
  }
  // MARK: - Voice Input

  @ViewBuilder
  private var voiceOverlay: some View {
    ZStack {
      Color.black.opacity(0.4)
        .ignoresSafeArea()
        .onTapGesture {
          dismissVoiceOverlay()
        }

      VStack(spacing: 20) {
        // Header with close button
        HStack(spacing: 16) {
          Image(systemName: voiceManager.isListening ? "mic.fill" : "mic")
            .font(.system(size: 32))
            .foregroundColor(voiceManager.isListening ? .red : .secondary)
            .symbolEffect(.pulse, isActive: voiceManager.isListening)

          VStack(alignment: .leading, spacing: 6) {
            Text(voiceManager.isListening ? "Listening..." : "Voice Input")
              .font(.title2.bold())

            if let error = voiceManager.error {
              Text(error)
                .font(.body)
                .foregroundColor(.red)
                .lineLimit(2)
            } else {
              Text("Release key to stop • Escape to cancel")
                .font(.body)
                .foregroundColor(.secondary)
            }
          }

          Spacer()

          Button {
            dismissVoiceOverlay()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.title)
              .foregroundColor(.secondary)
          }
          .buttonStyle(.plain)
          .keyboardShortcut(.escape, modifiers: [])
        }

        // Audio waveform visualization
        if voiceManager.isListening {
          AudioWaveformView(samples: voiceManager.waveformSamples)
            .frame(height: 32)
        }

        // Transcribed text
        if !voiceManager.transcribedText.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            Text("Transcription:")
              .font(.body)
              .foregroundColor(.secondary)

            Text(voiceManager.transcribedText)
              .font(.title3)
              .padding(14)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Color.black.opacity(0.2))
              .cornerRadius(8)
          }

          // Action buttons (only if not auto-insert)
          if !settings.voiceAutoInsert && !voiceManager.isListening {
            HStack {
              Button("Cancel") {
                dismissVoiceOverlay()
              }
              .font(.body)

              Spacer()

              Button("Insert") {
                insertVoiceText()
              }
              .font(.body)
              .keyboardShortcut(.return, modifiers: [])
              .buttonStyle(.borderedProminent)
            }
          }
        }
      }
      .padding(24)
      .frame(width: 480)
      .background(settings.effectiveBackgroundColor)
      .cornerRadius(12)
      .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    }
    .onKeyPress(.escape) {
      dismissVoiceOverlay()
      return .handled
    }
  }

  private func handleVoiceKeyStateChange(isDown: Bool) {
    guard settings.voiceEnabled else { return }

    if isDown {
      // Key pressed - start recording
      showVoiceOverlay = true
      Task {
        await voiceManager.startListening()
      }
    } else {
      // Key released - only inject if overlay wasn't cancelled
      guard showVoiceOverlay else { return }

      let finalText = voiceManager.transcribedText
      voiceManager.stopListening()

      // Always insert text if we have it
      if !finalText.isEmpty {
        voiceManager.injectText(finalText, into: agentManager, submit: settings.voiceAutoInsert)
      }
      dismissVoiceOverlay()
    }
  }

  private func insertVoiceText() {
    guard !voiceManager.transcribedText.isEmpty else { return }
    voiceManager.injectText(voiceManager.transcribedText, into: agentManager, submit: settings.voiceAutoInsert)
    dismissVoiceOverlay()
  }

  private func dismissVoiceOverlay() {
    voiceManager.stopListening()
    voiceManager.transcribedText = ""
    voiceManager.error = nil
    showVoiceOverlay = false
  }

  private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
    guard let agentId = agentManager.activeAgentId else { return false }

    for provider in providers {
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
          guard let data = item as? Data,
                let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

          DispatchQueue.main.async {
            var contextPaths = contextPathsByAgent[agentId] ?? []
            if !contextPaths.contains(url.path) {
              contextPaths.append(url.path)
              contextPathsByAgent[agentId] = contextPaths
            }
          }
        }
        return true
      }
    }
    return false
  }

  private var layoutToggleButton: some View {
    Menu {
      Button {
        agentManager.layoutMode = .single
        if agentManager.activeAgentIds.count > 1 {
          agentManager.activeAgentIds = [agentManager.activeAgentIds[agentManager.focusedPaneIndex]]
        }
      } label: {
        Label("Single Pane", systemImage: "square")
      }
      
      Button {
        agentManager.layoutMode = .splitVertical
        let workspaceAgents = agentManager.currentWorkspaceAgents
        if agentManager.activeAgentIds.count == 1, workspaceAgents.count >= 2 {
          let currentId = agentManager.activeAgentIds[0]
          let otherAgent = workspaceAgents.first { $0.id != currentId }
          if let otherId = otherAgent?.id {
            agentManager.activeAgentIds = [currentId, otherId]
          }
        } else if agentManager.activeAgentIds.count > 2 {
          agentManager.activeAgentIds = Array(agentManager.activeAgentIds.prefix(2))
        }
      } label: {
        Label("Split Vertical", systemImage: "square.split.2x1")
      }

      Button {
        agentManager.layoutMode = .splitHorizontal
        let workspaceAgents = agentManager.currentWorkspaceAgents
        if agentManager.activeAgentIds.count == 1, workspaceAgents.count >= 2 {
          let currentId = agentManager.activeAgentIds[0]
          let otherAgent = workspaceAgents.first { $0.id != currentId }
          if let otherId = otherAgent?.id {
            agentManager.activeAgentIds = [currentId, otherId]
          }
        } else if agentManager.activeAgentIds.count > 2 {
          agentManager.activeAgentIds = Array(agentManager.activeAgentIds.prefix(2))
        }
      } label: {
        Label("Split Horizontal", systemImage: "square.split.1x2")
      }

      if agentManager.currentWorkspaceAgents.count >= 3 {
        Button {
          agentManager.layoutMode = .threePane
          let workspaceAgents = agentManager.currentWorkspaceAgents
          if agentManager.activeAgentIds.count < 3 {
            var newIds = agentManager.activeAgentIds
            let availableAgents = workspaceAgents.filter { !newIds.contains($0.id) }
            for agent in availableAgents.prefix(3 - newIds.count) {
              newIds.append(agent.id)
            }
            agentManager.activeAgentIds = newIds
          } else if agentManager.activeAgentIds.count > 3 {
            agentManager.activeAgentIds = Array(agentManager.activeAgentIds.prefix(3))
          }
        } label: {
          Label("3-Pane Split", systemImage: "rectangle.split.3x1")
        }

        Button {
          agentManager.layoutMode = .gridFourPane
          let workspaceAgents = agentManager.currentWorkspaceAgents
          if agentManager.activeAgentIds.count < 3 {
            // Fill up to 4 agents (or however many we have)
            var newIds = agentManager.activeAgentIds
            let availableAgents = workspaceAgents.filter { !newIds.contains($0.id) }
            for agent in availableAgents.prefix(4 - newIds.count) {
              newIds.append(agent.id)
            }
            agentManager.activeAgentIds = newIds
          }
        } label: {
          Label("4-Pane Split", systemImage: "square.grid.2x2")
        }
      }
    } label: {
      Image(systemName: "menubar.rectangle")
        .font(.system(size: 16, weight: .medium))
        .foregroundColor(Theme.secondaryText)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .help("Layout options")
  }

}

#Preview {
  @Previewable @State var showNewAgentSheet = false
  @Previewable @State var toggleGitPanel = false
  @Previewable @State var toggleSidebar = false
  @Previewable @State var toggleTerminal = false
  @Previewable @State var toggleFileFinder = false
  @Previewable @State var forkPrefill: AgentPrefill? = nil

  ContentView(
    showNewAgentSheet: $showNewAgentSheet,
    toggleGitPanel: $toggleGitPanel,
    toggleSidebar: $toggleSidebar,
    toggleTerminal: $toggleTerminal,
    toggleFileFinder: $toggleFileFinder,
    forkPrefill: $forkPrefill
  )
    .environment(AgentManager())
}

// MARK: - Split Pane Preview

private struct SplitPanePreview: View {
  @State private var manager = previewSplitManager()
  @State private var focusedPane = 0

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .topLeading) {
        ForEach(0..<2) { pane in
          let rect = computeRect(pane, in: geo.size)
          let agent = manager.agents[pane]
          let isFocused = pane == focusedPane

          VStack(spacing: 0) {
            AgentFullHeader(agent: agent, isFocused: isFocused, onGitStatsTap: {}, onPaneTap: {
              focusedPane = pane
            })
            // Placeholder terminal body
            Rectangle()
              .fill(pane == 0 ? Color.blue.opacity(0.08) : Color.green.opacity(0.08))
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .overlay(
                Text("Pane \(pane + 1) — \(agent.name)")
                  .font(.title3)
                  .foregroundColor(.secondary)
              )
          }
          .frame(width: rect.width, height: rect.height)
          .offset(x: rect.minX, y: rect.minY)
        }

        // Dim unfocused pane
        let unfocusedRect = computeRect(1 - focusedPane, in: geo.size)
        Rectangle()
          .fill(Color.black.opacity(Theme.unfocusedOverlayOpacity))
          .frame(width: unfocusedRect.width, height: unfocusedRect.height)
          .offset(x: unfocusedRect.minX, y: unfocusedRect.minY)
          .allowsHitTesting(false)

        // Divider
        let pos = geo.size.width * manager.splitRatio
        Rectangle()
          .fill(Color.clear)
          .frame(width: 6, height: geo.size.height)
          .overlay(
            Rectangle()
              .fill(Color.primary.opacity(0.15))
              .frame(width: 1, height: geo.size.height)
          )
          .offset(x: pos - 3)
      }
    }
    .environment(manager)
    .frame(width: 900, height: 600)
  }

  private func computeRect(_ pane: Int, in size: CGSize) -> CGRect {
    let w0 = size.width * manager.splitRatio
    return pane == 0
      ? CGRect(x: 0, y: 0, width: w0, height: size.height)
      : CGRect(x: w0, y: 0, width: size.width - w0, height: size.height)
  }
}

@MainActor private func previewSplitManager() -> AgentManager {
  var a1 = Agent(name: "skwad", avatar: "🐱", folder: "/Users/nbonamy/src/skwad")
  a1.state = .running
  a1.terminalTitle = "Editing ContentView.swift"
  a1.gitStats = .init(insertions: 42, deletions: 7, files: 3)

  var a2 = Agent(name: "witsy", avatar: "🤖", folder: "/Users/nbonamy/src/witsy")
  a2.state = .idle
  a2.gitStats = .init(insertions: 0, deletions: 0, files: 0)

  let m = AgentManager()
  m.agents = [a1, a2]
  m.activeAgentIds = [a1.id, a2.id]
  m.layoutMode = .splitVertical
  return m
}

#Preview("Split Pane") {
  SplitPanePreview()
}

// MARK: - Audio Waveform Visualization (Dictation style)

struct AudioWaveformView: View {
  let samples: [Float]
  private let barCount = 64
  private let barWidth: CGFloat = 2
  private let spacing: CGFloat = 1.5

  var body: some View {
    TimelineView(.animation(minimumInterval: 1/60)) { _ in
      Canvas { context, size in
        let totalWidth = CGFloat(barCount) * (barWidth + spacing) - spacing
        let startX = (size.width - totalWidth) / 2
        let midY = size.height / 2
        let maxHeight = size.height * 0.9

        for i in 0..<barCount {
          // Map bar index to sample index
          let sampleIndex = samples.count > 0 ? i * samples.count / barCount : 0
          let sample = sampleIndex < samples.count ? samples[sampleIndex] : 0

          // Minimum bar height of 2 for visibility
          let height = max(2, CGFloat(sample) * maxHeight)

          let x = startX + CGFloat(i) * (barWidth + spacing)
          let rect = CGRect(
            x: x,
            y: midY - height / 2,
            width: barWidth,
            height: height
          )

          context.fill(
            Path(roundedRect: rect, cornerRadius: 1),
            with: .color(.white.opacity(0.85))
          )
        }
      }
    }
  }
}
