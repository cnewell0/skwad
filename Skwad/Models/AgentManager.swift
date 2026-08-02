import Foundation
import SwiftUI
import Observation

enum LayoutMode: String, Codable {
    case single
    case splitVertical   // left | right
    case splitHorizontal // top / bottom
    case threePane       // left half full-height | right top / right bottom
    case gridFourPane    // 4-pane grid (up to 4 agents)

    var paneCount: Int {
        switch self {
        case .single: return 1
        case .splitVertical, .splitHorizontal: return 2
        case .threePane: return 3
        case .gridFourPane: return 4
        }
    }
}

// Weak wrapper for terminal references to avoid retain cycles
private class WeakTerminalRef {
    weak var terminal: GhosttyTerminalView?
    init(_ terminal: GhosttyTerminalView) {
        self.terminal = terminal
    }
}

@Observable
@MainActor
final class AgentManager {
    // All agents across all workspaces
    var agents: [Agent] = []

    /// Callback to open a detached workspace window (set by SkwadApp)
    var openDetachedWindow: ((UUID) -> Void)?

    /// Maps NSWindow to workspace ID for detached windows (for Cmd+W routing)
    var detachedWindowMap: [ObjectIdentifier: UUID] = [:]

    // Global dashboard state (persisted via AppSettings)
    var showGlobalDashboard: Bool {
        get { settings.showGlobalDashboard }
        set { settings.showGlobalDashboard = newValue }
    }

    // Workspaces
    var workspaces: [Workspace] = []
    var currentWorkspaceId: UUID?


    private let settings = AppSettings.shared

    // Terminal references for each agent (keyed by agent ID)
    // Uses weak references to avoid retain cycles with SwiftUI view lifecycle
    private var terminals: [UUID: WeakTerminalRef] = [:]

    // Controllers for each agent (keyed by agent ID)
    private var controllers: [UUID: TerminalSessionController] = [:]

    // Tracks last notified message ID per agent (for deduplication)
    private var lastNotifiedMessageId: [UUID: UUID] = [:]

    // Serial queue for git stats refresh to avoid thundering herd at startup
    private let gitStatsQueue = DispatchQueue(label: "AgentManager.gitStats", qos: .utility)

    init() {
        guard !AppRuntime.isToolingLaunch else { return }
        if settings.restoreLayoutOnLaunch {
            agents = settings.loadSavedAgents()
            workspaces = settings.loadWorkspaces()

            // Migration: if we have agents but no workspaces, create default "Skwad" workspace
            if !agents.isEmpty && workspaces.isEmpty {
                let defaultWorkspace = Workspace.createDefault(withAgentIds: agents.map { $0.id })
                workspaces = [defaultWorkspace]
                currentWorkspaceId = defaultWorkspace.id
                saveWorkspaces()
            } else if let savedCurrentId = settings.currentWorkspaceId,
                      workspaces.contains(where: { $0.id == savedCurrentId }) {
                currentWorkspaceId = savedCurrentId
            } else {
                currentWorkspaceId = workspaces.first?.id
            }

            // Restore companion layout for the active agent
            if let activeId = activeAgentIds.first {
                applyCompanionLayout(for: activeId)
            }
        }
    }

    // MARK: - Window → Agent Mapping

    /// Returns the focused agent for a given window.
    /// For the main window, uses currentWorkspace. For detached windows, uses the mapped workspace.
    func focusedAgent(for window: NSWindow?) -> Agent? {
        guard let window else { return nil }
        let windowId = ObjectIdentifier(window)
        if let workspaceId = detachedWindowMap[windowId],
           let workspace = workspaces.first(where: { $0.id == workspaceId }) {
            let focusedIndex = workspace.focusedPaneIndex
            guard focusedIndex < workspace.activeAgentIds.count else {
                guard let firstId = workspace.activeAgentIds.first else { return nil }
                return agents.first { $0.id == firstId }
            }
            let agentId = workspace.activeAgentIds[focusedIndex]
            return agents.first { $0.id == agentId }
        }
        // Default: main window — use activeAgentId
        guard let id = activeAgentId else { return nil }
        return agents.first { $0.id == id }
    }

    // MARK: - Attached / Detached Workspaces

    /// Workspaces visible in the main window (excludes detached)
    var attachedWorkspaces: [Workspace] {
        workspaces.filter { !$0.isDetachedFromMain }
    }

    /// Workspaces detached to their own windows
    var detachedWorkspaces: [Workspace] {
        workspaces.filter { $0.isDetachedFromMain }
    }

    // MARK: - Current Workspace

    var currentWorkspace: Workspace? {
        get {
            guard let id = currentWorkspaceId else { return nil }
            return workspaces.first { $0.id == id }
        }
        set {
            guard let workspace = newValue,
                  let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
            workspaces[index] = workspace
            saveWorkspaces()
        }
    }

    /// Agents in the current workspace
    var currentWorkspaceAgents: [Agent] {
        guard let workspace = currentWorkspace else { return [] }
        return workspace.agentIds.compactMap { id in agents.first { $0.id == id } }
    }

    // MARK: - Layout (workspace-scoped)

    var layoutMode: LayoutMode {
        get { currentWorkspace?.layoutMode ?? .single }
        set { updateCurrentWorkspace { $0.layoutMode = newValue } }
    }

    var activeAgentIds: [UUID] {
        get { currentWorkspace?.activeAgentIds ?? [] }
        set { updateCurrentWorkspace { $0.activeAgentIds = newValue } }
    }

    var focusedPaneIndex: Int {
        get { currentWorkspace?.focusedPaneIndex ?? 0 }
        set { updateCurrentWorkspace { $0.focusedPaneIndex = newValue } }
    }

    var splitRatio: CGFloat {
        get { currentWorkspace?.splitRatio ?? 0.5 }
        set { updateCurrentWorkspace { $0.splitRatio = newValue } }
    }

    var splitRatioSecondary: CGFloat {
        get { currentWorkspace?.effectiveSplitRatioSecondary ?? 0.5 }
        set { updateCurrentWorkspace { $0.splitRatioSecondary = newValue } }
    }

    var showDashboard: Bool {
        get { currentWorkspace?.isDashboardVisible ?? false }
        set { updateCurrentWorkspace { $0.isDashboardVisible = newValue } }
    }

    private func updateCurrentWorkspace(_ update: (inout Workspace) -> Void) {
        guard let id = currentWorkspaceId,
              var workspace = workspaces.first(where: { $0.id == id }),
              let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        update(&workspace)
        workspaces[index] = workspace
        // Note: Don't save on every layout change for performance
        // Layout is saved when switching workspaces or on explicit save
    }

    // MARK: - Workspace CRUD

    func addWorkspace(name: String, color: WorkspaceColor = .blue) -> Workspace {
        let workspace = Workspace(name: name, colorHex: color.rawValue)
        workspaces.append(workspace)
        currentWorkspaceId = workspace.id
        settings.currentWorkspaceId = workspace.id
        saveWorkspaces()
        return workspace
    }

    func removeWorkspace(_ workspace: Workspace) {
        // Close all agents in this workspace
        let agentsToRemove = workspace.agentIds.compactMap { id in agents.first { $0.id == id } }
        for agent in agentsToRemove {
            removeAgentFromAllWorkspaces(agent)
        }

        workspaces.removeAll { $0.id == workspace.id }

        // If this was the current workspace, switch to another or clear
        if currentWorkspaceId == workspace.id {
            currentWorkspaceId = workspaces.first?.id
            settings.currentWorkspaceId = currentWorkspaceId
        }

        saveWorkspaces()
    }

    func updateWorkspace(id: UUID, name: String, colorHex: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        workspaces[index].name = name
        workspaces[index].colorHex = colorHex
        saveWorkspaces()
    }

    func switchToWorkspace(_ workspaceId: UUID) {
        guard workspaces.contains(where: { $0.id == workspaceId }) else { return }
        // Save current workspace layout before switching
        saveWorkspaces()
        currentWorkspaceId = workspaceId
        settings.currentWorkspaceId = workspaceId

        // Auto-select first agent if none is active
        if activeAgentIds.isEmpty, let firstAgent = currentWorkspaceAgents.first {
            layoutMode = .single
            activeAgentIds = [firstAgent.id]
        }
    }

    func switchToWorkspaceAtIndex(_ index: Int) {
        guard index >= 0, index < workspaces.count else { return }
        switchToWorkspace(workspaces[index].id)
    }

    func cycleWorkspace() {
        let attached = attachedWorkspaces
        if showGlobalDashboard {
            // Command Center → first attached workspace
            showGlobalDashboard = false
            showDashboard = false
            if let first = attached.first {
                switchToWorkspace(first.id)
            }
        } else if let currentId = currentWorkspaceId,
                  let currentIndex = attached.firstIndex(where: { $0.id == currentId }) {
            let nextIndex = currentIndex + 1
            if nextIndex < attached.count {
                // Current workspace → next attached workspace
                switchToWorkspace(attached[nextIndex].id)
            } else {
                // Last attached workspace → Command Center
                showGlobalDashboard = true
                showDashboard = false
            }
        } else {
            // Fallback: go to Command Center
            showGlobalDashboard = true
            showDashboard = false
        }
    }

    func moveWorkspace(from source: IndexSet, to destination: Int) {
        workspaces.move(fromOffsets: source, toOffset: destination)
        saveWorkspaces()
    }

    /// Returns the "worst" status across all agents in a workspace (input > running > idle)
    func workspaceStatus(_ workspace: Workspace) -> AgentState? {
        let statuses = workspace.agentIds.compactMap { agentId in
            agents.first { $0.id == agentId }?.state
        }
        if statuses.contains(.input) { return .input }
        if statuses.contains(.running) { return .running }
        return nil
    }

    // MARK: - Detach / Reattach

    /// Whether detach needs confirmation (agents will be restarted)
    func detachNeedsConfirmation(_ workspace: Workspace) -> Bool {
        !settings.suppressDetachWarning && !workspace.agentIds.isEmpty
    }

    /// Detach a workspace to its own window — restarts all agents
    func detachWorkspace(_ workspace: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index].isDetachedFromMain = true

        // Restart all agents in the workspace (terminal recreation)
        for agentId in workspace.agentIds {
            if let agentIndex = agents.firstIndex(where: { $0.id == agentId }) {
                removeController(for: agentId)
                unregisterTerminal(for: agentId)
                agents[agentIndex].restartToken = UUID()
                agents[agentIndex].state = .idle
                agents[agentIndex].isRegistered = false
                agents[agentIndex].terminalTitle = ""
            }
        }

        // Switch main window to next attached workspace
        if currentWorkspaceId == workspace.id {
            currentWorkspaceId = attachedWorkspaces.first?.id
            settings.currentWorkspaceId = currentWorkspaceId
        }

        saveWorkspaces()

        // Open the detached window
        openDetachedWindow?(workspace.id)
    }

    /// Reattach a detached workspace back to the main window — restarts all agents
    func reattachWorkspace(_ workspace: Workspace) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[index].isDetachedFromMain = false

        // Restart all agents in the workspace (terminal recreation)
        for agentId in workspace.agentIds {
            if let agentIndex = agents.firstIndex(where: { $0.id == agentId }) {
                removeController(for: agentId)
                unregisterTerminal(for: agentId)
                agents[agentIndex].restartToken = UUID()
                agents[agentIndex].state = .idle
                agents[agentIndex].isRegistered = false
                agents[agentIndex].terminalTitle = ""
            }
        }

        // Switch main window to the reattached workspace
        currentWorkspaceId = workspace.id
        settings.currentWorkspaceId = workspace.id

        saveWorkspaces()
    }

    private func saveWorkspaces() {
        // Test hosts share the app's UserDefaults — never let test fixtures
        // (Agent0, Test workspaces…) leak into the user's real saved state.
        guard !AppRuntime.isRunningTests else { return }
        settings.saveWorkspaces(workspaces)
    }

    /// Create default "Skwad" workspace when first agent is added and no workspaces exist
    private func ensureWorkspaceExists() -> UUID {
        if let currentId = currentWorkspaceId {
            return currentId
        }

        // No workspace exists, create default "Skwad" workspace
        let workspace = Workspace.createDefault()
        workspaces = [workspace]
        currentWorkspaceId = workspace.id
        settings.currentWorkspaceId = workspace.id
        saveWorkspaces()
        return workspace.id
    }

    // MARK: - Derived state

    /// The agent in the focused pane (used for git panel, voice, keyboard shortcuts)
    var activeAgentId: UUID? {
        guard focusedPaneIndex < activeAgentIds.count else { return activeAgentIds.first }
        return activeAgentIds[focusedPaneIndex]
    }

    /// The agent currently shown in single mode / pane 0 (kept for convenience)
    var selectedAgentId: UUID? {
        activeAgentIds.first
    }

    var selectedAgent: Agent? {
        guard let id = selectedAgentId else { return nil }
        return agents.first { $0.id == id }
    }

    /// Get companions for an agent
    func companions(of agentId: UUID) -> [Agent] {
        agents.filter { $0.createdBy == agentId && $0.isCompanion }
    }

    /// Whether an agent should appear selected in the sidebar (itself or one of its companions is active)
    func isAgentActive(_ agentId: UUID) -> Bool {
        agentId == activeAgentId ||
        companions(of: agentId).contains { $0.id == activeAgentId }
    }

    /// Which pane index an agent occupies, or nil if not in any pane
    func paneIndex(for agentId: UUID) -> Int? {
        activeAgentIds.firstIndex(of: agentId)
    }

    // MARK: - Controller Management

    /// Create a controller for an agent
    func createController(for agent: Agent) -> TerminalSessionController {
        // Shell: no tracking. Hook agents (claude): .all with longer idle timeout. Others: .all.
        let tracking: ActivityTracking
        let idleTimeout: TimeInterval
        if agent.isShell {
            tracking = .none
            idleTimeout = TimingConstants.idleTimeout
        } else if TerminalCommandBuilder.usesActivityHooks(agentType: agent.agentType) {
            tracking = .all
            idleTimeout = TimingConstants.hookFallbackIdleTimeout
            // Set running so UI shows "Working" while agent boots up
            // Skip for resumed sessions — agent stays idle until user sends input
            if agent.resumeSessionId == nil, let index = agents.firstIndex(where: { $0.id == agent.id }) {
                agents[index].state = .running
            }
        } else {
            tracking = .all
            idleTimeout = TimingConstants.idleTimeout
        }
        let controller = TerminalSessionController(
            agentId: agent.id,
            folder: agent.folder,
            agentType: agent.agentType,
            shellCommand: agent.shellCommand,
            persona: settings.persona(for: agent.personaId),
            resumeSessionId: agent.resumeSessionId,
            forkSession: agent.forkSession,
            model: agent.model,
            activityTracking: tracking,
            idleTimeout: idleTimeout,
            onStatusChange: { [weak self] status, source in
                self?.updateStatus(for: agent.id, status: status, source: source)
            },
            onTitleChange: { [weak self] title in
                self?.updateTitle(for: agent.id, title: title)
            },
            onCheckMessages: { [weak self] in
                self?.checkForUnreadMessages(for: agent.id)
            }
        )

        // Restored shell agents defer their command to avoid startup congestion
        if agent.isPendingStart {
            controller.onDeferredStart = { [weak self] ctrl in
                self?.enqueueShellStart(ctrl, isCompanion: agent.isCompanion)
            }
        }

        controllers[agent.id] = controller
        return controller
    }

    /// Get existing controller for an agent
    func getController(for agentId: UUID) -> TerminalSessionController? {
        controllers[agentId]
    }

    /// Remove controller for an agent
    func removeController(for agentId: UUID) {
        controllers[agentId]?.dispose()
        controllers.removeValue(forKey: agentId)
        removeDrawerShell(for: agentId)
    }

    /// Terminate all agents - called on app quit
    func terminateAll() {
        print("[skwad] Terminating all agents")
        for controller in controllers.values {
            controller.dispose()
        }
        controllers.removeAll()
        for controller in drawerShells.values {
            controller.dispose()
        }
        drawerShells.removeAll()
        terminals.removeAll()
        print("[skwad] All agents terminated")
    }

    // MARK: - Drawer Shell Terminals

    /// Lightweight work shells shown in the terminal drawer (one per agent, lazily created).
    /// Not agents: no sidebar presence, no status tracking, no MCP registration.
    private(set) var drawerShells: [UUID: TerminalSessionController] = [:]

    /// Whether a drawer shell already exists for an agent (does not create one)
    func hasDrawerShell(for agentId: UUID) -> Bool {
        drawerShells[agentId] != nil
    }

    /// Get or create the drawer work shell for an agent.
    /// The shell opens in the agent's working folder with a larger font.
    @discardableResult
    func drawerShellController(for agent: Agent) -> TerminalSessionController {
        if let existing = drawerShells[agent.id] {
            return existing
        }
        let controller = TerminalSessionController(
            agentId: UUID(),  // distinct pane id so it never collides with the agent's session
            folder: agent.workingFolder,
            agentType: "shell",
            fontSize: settings.drawerTerminalFontSize,
            activityTracking: .none,
            onStatusChange: { _, _ in }
        )
        drawerShells[agent.id] = controller
        return controller
    }

    /// Dispose the drawer shell for an agent (terminates the shell process)
    func removeDrawerShell(for agentId: UUID) {
        drawerShells[agentId]?.dispose()
        drawerShells.removeValue(forKey: agentId)
    }

    /// Notify an agent's drawer shell to resize
    func notifyDrawerShellResize(for agentId: UUID) {
        drawerShells[agentId]?.notifyResize()
    }

    // MARK: - Deferred Shell Startup

    /// Pending shell controllers waiting to be started, ordered by priority
    /// (main shells first, companion shells second)
    private var shellStartQueue: [TerminalSessionController] = []
    private var shellStartTask: Task<Void, Never>?

    /// Enqueue a shell agent's command for staggered execution
    private func enqueueShellStart(_ controller: TerminalSessionController, isCompanion: Bool) {
        // Show a waiting banner in the terminal
        // Prefix with space to prevent shell history pollution
        let banner = [
            " clear",
            "printf '\\n'",
            "printf '          \\e[2m╭─────────────────────────────╮\\e[0m\\n'",
            "printf '          \\e[2m│                             │\\e[0m\\n'",
            "printf '          \\e[2m│     \\e[0m\\e[1;97m⏳ Starting soon...\\e[0m\\e[2m     │\\e[0m\\n'",
            "printf '          \\e[2m│                             │\\e[0m\\n'",
            "printf '          \\e[2m╰─────────────────────────────╯\\e[0m\\n'",
            "printf '\\n'",
            "printf '\\n'",
            "printf '\\n'"
        ].joined(separator: " && ")
        controller.sendCommand(banner)

        if isCompanion {
            shellStartQueue.append(controller)
        } else {
            // Main shells go before companions
            let firstCompanionIndex = shellStartQueue.firstIndex { ctrl in
                agents.first { $0.id == ctrl.agentId }?.isCompanion == true
            } ?? shellStartQueue.endIndex
            shellStartQueue.insert(controller, at: firstCompanionIndex)
        }
        drainShellStartQueue()
    }

    /// Process the queue: wait for initial delay, then send one command at a time with stagger
    private func drainShellStartQueue() {
        guard shellStartTask == nil, !shellStartQueue.isEmpty else { return }
        shellStartTask = Task { [weak self] in
            // Initial delay to let non-shell agents settle
            try? await Task.sleep(for: .seconds(TimingConstants.shellStartInitialDelay))

            while let self, !self.shellStartQueue.isEmpty {
                let controller = self.shellStartQueue.removeFirst()

                // Clear pending state
                if let index = self.agents.firstIndex(where: { $0.id == controller.agentId }) {
                    self.agents[index].isPendingStart = false
                }

                let command = controller.buildDeferredCommand()
                if !command.isEmpty {
                    controller.sendCommand(command)
                }
                try? await Task.sleep(for: .seconds(TimingConstants.shellStartStaggerDelay))
            }
            self?.shellStartTask = nil
        }
    }

    // MARK: - Terminal Management (for forceRefresh on resize)

    func registerTerminal(_ terminal: GhosttyTerminalView, for agentId: UUID) {
        terminals[agentId] = WeakTerminalRef(terminal)
    }

    func unregisterTerminal(for agentId: UUID) {
        terminals.removeValue(forKey: agentId)
    }

    func getTerminal(for agentId: UUID) -> GhosttyTerminalView? {
        terminals[agentId]?.terminal
    }

    // MARK: - Text Injection (delegates to controller)

    /// Send text to an agent's terminal WITHOUT return
    func sendText(_ text: String, for agentId: UUID) {
        controllers[agentId]?.sendText(text)
    }

    /// Send return key to an agent's terminal
    func sendReturn(for agentId: UUID) {
        controllers[agentId]?.sendReturn()
    }

    /// Send escape (dismiss autocomplete) then return key to an agent's terminal
    func submitReturn(for agentId: UUID) {
        controllers[agentId]?.submitReturn()
    }

    /// Inject text into an agent's terminal followed by return
    func injectText(_ text: String, for agentId: UUID) {
        controllers[agentId]?.injectText(text)
    }

    /// Submit a user-authored prompt to an agent and mirror it into the chat timeline.
    /// Unlike MCP injection, explicit user prompts are never suppressed by input protection.
    @discardableResult
    func sendPrompt(_ text: String, for agentId: UUID) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let controller = controllers[agentId] else { return false }

        // Only agents with a readable transcript can ever confirm a prompt. A shell
        // just runs the text, so marking it pending would leave "Waiting for agent"
        // on screen forever.
        let expectsReply = agents.first(where: { $0.id == agentId })
            .map { ConversationHistoryService.shared.supportsHistory(agentType: $0.agentType) } ?? false

        AgentConversationStore.shared.append(
            role: .user,
            text: trimmed,
            for: agentId,
            delivery: expectsReply ? .pending : .confirmed
        )
        controller.sendCommand(trimmed)
        if expectsReply {
            schedulePromptDeliveryRetry(trimmed, for: agentId)
        }
        return true
    }

    /// The Return that submits an injected prompt occasionally doesn't land and the text
    /// sits in the agent's composer forever. For hook-based agents, a successful submit
    /// fires UserPromptSubmit (state → running + pending prompt confirmed). If neither
    /// happened shortly after sending, nudge Return once more.
    private func schedulePromptDeliveryRetry(_ text: String, for agentId: UUID) {
        guard let agent = agents.first(where: { $0.id == agentId }),
              TerminalCommandBuilder.usesActivityHooks(agentType: agent.agentType) else { return }

        AsyncDelay.dispatch(after: TimingConstants.promptDeliveryRetryDelay) { [weak self] in
            guard let self,
                  let agent = self.agents.first(where: { $0.id == agentId }),
                  agent.state == .idle,  // .running = delivered; .input = a prompt is up, don't answer it
                  AgentConversationStore.shared.hasPendingUserPrompt(text, for: agentId) else { return }
            self.controllers[agentId]?.submitReturn()
        }
    }

    /// Switch an agent's model. Applies immediately via the CLI's own `/model` command
    /// when it has one — restarting would throw away the conversation. Otherwise the
    /// choice is stored and takes effect the next time the agent starts.
    /// - Returns: true if the change is live now, false if it needs a restart.
    @discardableResult
    func setModel(_ model: String?, for agentId: UUID) -> Bool {
        guard let index = agents.firstIndex(where: { $0.id == agentId }),
              agents[index].model != model else { return false }

        agents[index].model = model
        saveAgents()

        guard let model,
              let command = TerminalCommandBuilder.runtimeModelCommand(
                  agentType: agents[index].agentType,
                  model: model
              ) else {
            return false
        }
        // Explicit user action — bypass the typing guard that protects injections
        controllers[agentId]?.sendCommand(command)
        return true
    }

    /// Interrupt whatever the agent is doing (the TUI equivalent of pressing Escape).
    func interruptAgent(_ agentId: UUID) {
        controllers[agentId]?.sendEscape()
    }

    /// Cycle the agent's permission mode (Shift-Tab in the agent's own TUI).
    func cyclePermissionMode(for agentId: UUID) {
        guard let agent = agents.first(where: { $0.id == agentId }),
              TerminalCommandBuilder.supportsPermissionCycling(agentType: agent.agentType) else { return }
        controllers[agentId]?.cyclePermissionMode()
    }

    /// Check for unread MCP messages and notify the agent if there are new ones
    private func checkForUnreadMessages(for agentId: UUID) {
        guard settings.mcpServerEnabled else { return }
        guard let agent = agents.first(where: { $0.id == agentId }), !agent.isShell else { return }

        Task {
            let latestMessageId = await AgentCoordinator.shared.getLatestUnreadMessageId(for: agentId.uuidString)

            guard let messageId = latestMessageId else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }

                // Deduplicate notifications
                guard self.lastNotifiedMessageId[agentId] != messageId else { return }
                self.lastNotifiedMessageId[agentId] = messageId

                self.injectText(AgentPrompts.checkInbox, for: agentId)
            }
        }
    }

    /// Notify terminal to resize (e.g., when git panel toggles)
    func notifyTerminalResize(for agentId: UUID) {
        controllers[agentId]?.notifyResize()
    }

    // MARK: - Registration State

    /// Inject the registration prompt into an agent's terminal
    func registerAgent(_ agent: Agent) {
        let text = TerminalCommandBuilder.registrationPrompt(agentId: agent.id)
        injectText(text, for: agent.id)
    }

    func setRegistered(for agentId: UUID, registered: Bool) {
        if let index = agents.firstIndex(where: { $0.id == agentId }) {
            agents[index].isRegistered = registered
        }
    }

    func isRegistered(agentId: UUID) -> Bool {
        agents.first { $0.id == agentId }?.isRegistered ?? false
    }

    func setSessionId(for agentId: UUID, sessionId: String) {
        if let index = agents.firstIndex(where: { $0.id == agentId }) {
            agents[index].sessionId = sessionId
        }
    }

    func updateMetadata(for agentId: UUID, metadata: [String: String]) {
        if let index = agents.firstIndex(where: { $0.id == agentId }) {
            agents[index].metadata.merge(metadata) { _, new in new }
        }
    }

    func setAgentStatusText(for agentId: UUID, status: String) {
        if let index = agents.firstIndex(where: { $0.id == agentId }) {
            agents[index].statusText = status
        }
    }

    // MARK: - Agent CRUD

    @discardableResult
    func addAgent(
        folder: String,
        name: String? = nil,
        avatar: String? = nil,
        agentType: String = "claude",
        createdBy: UUID? = nil,
        isCompanion: Bool = false,
        insertAfterId: UUID? = nil,
        shellCommand: String? = nil,
        resumeSessionId: String? = nil,
        forkSession: Bool = false,
        personaId: UUID? = nil,
        model: String? = nil,
        targetWorkspaceId: UUID? = nil
    ) -> UUID? {
        var agent = Agent(folder: folder, avatar: avatar, agentType: agentType, createdBy: createdBy, isCompanion: isCompanion, shellCommand: shellCommand, personaId: personaId, model: model)
        agent.resumeSessionId = resumeSessionId
        agent.forkSession = forkSession
        if let name = name {
            agent.name = name
        }

        // Add to master agent list
        if let insertAfterId = insertAfterId,
           let index = agents.firstIndex(where: { $0.id == insertAfterId }) {
            let insertIndex = agents.index(after: index)
            agents.insert(agent, at: insertIndex)
        } else {
            agents.append(agent)
        }

        // Determine target workspace: source agent, explicit destination, then current workspace.
        let workspaceId: UUID
        if let sourceId = createdBy ?? insertAfterId,
           let sourceWorkspace = workspaces.first(where: { $0.agentIds.contains(sourceId) }) {
            workspaceId = sourceWorkspace.id
        } else if let targetWorkspaceId,
                  workspaces.contains(where: { $0.id == targetWorkspaceId }) {
            workspaceId = targetWorkspaceId
        } else {
            workspaceId = ensureWorkspaceExists()
        }

        // Add agent to target workspace
        if let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            if let insertAfterId = insertAfterId,
               let insertAfterIndex = workspaces[index].agentIds.firstIndex(of: insertAfterId) {
                workspaces[index].agentIds.insert(agent.id, at: insertAfterIndex + 1)
            } else {
                workspaces[index].agentIds.append(agent.id)
            }

            // Set as active if no active agents
            if workspaces[index].activeAgentIds.isEmpty {
                workspaces[index].activeAgentIds = [agent.id]
            }
        }

        saveAgents()
        saveWorkspaces()

        return agent.id
    }

    @discardableResult
    func deployBenchAgent(_ benchAgent: BenchAgent) -> UUID? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: benchAgent.folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            AppSettings.shared.removeFromBench(benchAgent)
            return nil
        }
        return addAgent(
            folder: benchAgent.folder,
            name: benchAgent.name,
            avatar: benchAgent.avatar,
            agentType: benchAgent.agentType,
            shellCommand: benchAgent.shellCommand,
            personaId: benchAgent.personaId
        )
    }

    func removeAgent(_ agent: Agent) {
        // Close companions first (if this agent owns any)
        let companions = companions(of: agent.id)
        for companion in companions {
            removeAgent(companion)
        }

        // Unregister from MCP if registered
        if agent.isRegistered {
            Task {
                await AgentCoordinator.shared.unregisterAgent(agentId: agent.id.uuidString)
            }
        }

        removeController(for: agent.id)
        unregisterTerminal(for: agent.id)
        lastNotifiedMessageId.removeValue(forKey: agent.id)

        // Remove from the owning workspace, including detached workspaces that are
        // not the main window's current selection.
        if let workspaceIndex = workspaces.firstIndex(where: { $0.agentIds.contains(agent.id) }) {
            var workspace = workspaces[workspaceIndex]
            removeAgent(agent.id, from: &workspace)
            workspaces[workspaceIndex] = workspace
        }

        // Remove from master list
        agents.removeAll { $0.id == agent.id }

        saveAgents()
        saveWorkspaces()
    }

    private func removeAgent(_ agentId: UUID, from workspace: inout Workspace) {
        let wasActive = workspace.activeAgentIds.contains(agentId)
        workspace.agentIds.removeAll { $0 == agentId }
        workspace.activeAgentIds.removeAll { $0 == agentId }

        guard wasActive else {
            if workspace.layoutMode == .single,
               workspace.activeAgentIds.first.map({ workspace.agentIds.contains($0) }) != true {
                workspace.activeAgentIds = workspace.agentIds.first.map { [$0] } ?? []
                workspace.focusedPaneIndex = 0
            }
            return
        }

        if (workspace.layoutMode == .gridFourPane || workspace.layoutMode == .threePane),
           workspace.activeAgentIds.count >= 2 {
            workspace.layoutMode = workspace.activeAgentIds.count == 3 ? .threePane : .splitVertical
            workspace.focusedPaneIndex = min(
                workspace.focusedPaneIndex,
                workspace.activeAgentIds.count - 1
            )
            return
        }

        let survivingId = workspace.activeAgentIds.first(where: { workspace.agentIds.contains($0) })
            ?? workspace.agentIds.first
        workspace.activeAgentIds = survivingId.map { [$0] } ?? []
        workspace.layoutMode = .single
        workspace.focusedPaneIndex = 0
    }

    /// Remove agent from all workspaces and master list (used when closing a workspace)
    private func removeAgentFromAllWorkspaces(_ agent: Agent) {
        // Unregister from MCP if registered
        if agent.isRegistered {
            Task {
                await AgentCoordinator.shared.unregisterAgent(agentId: agent.id.uuidString)
            }
        }

        removeController(for: agent.id)
        unregisterTerminal(for: agent.id)

        // Remove from all workspaces
        for i in workspaces.indices {
            workspaces[i].agentIds.removeAll { $0 == agent.id }
            workspaces[i].activeAgentIds.removeAll { $0 == agent.id }
        }

        // Remove from master list
        agents.removeAll { $0.id == agent.id }
        saveAgents()
    }

    func duplicateAgent(_ agent: Agent) {
        addAgent(
            folder: agent.folder,
            name: agent.name + " (copy)",
            avatar: agent.avatar,
            agentType: agent.agentType,
            insertAfterId: agent.id,
            personaId: agent.personaId
        )
    }

    func createShellCompanion(for agent: Agent) {
        guard !agent.isCompanion else { return }
        guard let newId = addAgent(
            folder: agent.folder,
            name: "Shell",
            agentType: "shell",
            createdBy: agent.id,
            isCompanion: true,
            insertAfterId: agent.id
        ) else { return }
        enterSplitWithNewAgent(newAgentId: newId, creatorId: agent.id)
    }

    /// Duplicate companions of sourceAgent onto newAgent, optionally at a new folder
    func duplicateCompanions(from sourceAgentId: UUID, to newAgentId: UUID, newFolder: String?) {
        for companion in companions(of: sourceAgentId) {
            let folder = (newFolder != nil && companion.folder == agents.first(where: { $0.id == sourceAgentId })?.folder)
                ? newFolder! : companion.folder
            addAgent(
                folder: folder,
                name: companion.name,
                avatar: companion.avatar,
                agentType: companion.agentType,
                createdBy: newAgentId,
                isCompanion: true,
                insertAfterId: newAgentId,
                shellCommand: companion.shellCommand,
                personaId: companion.personaId
            )
        }
    }

    func resumeSession(_ agent: Agent, sessionId: String) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[index].resumeSessionId = sessionId
        agents[index].forkSession = false
        agents[index].sessionId = sessionId
        startAgent(agents[index])
    }

    func restartAgent(_ agent: Agent) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[index].sessionId = nil
        agents[index].resumeSessionId = nil
        agents[index].forkSession = false
        startAgent(agents[index])
    }

    /// Tear down existing terminal and trigger recreation via restartToken
    private func startAgent(_ agent: Agent) {
        guard let index = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        removeController(for: agent.id)
        unregisterTerminal(for: agent.id)
        agents[index].restartToken = UUID()
        agents[index].state = .idle
        agents[index].isRegistered = false
        agents[index].terminalTitle = ""
    }

    func updateAgent(id: UUID, name: String, avatar: String, folder: String? = nil, agentType: String? = nil, personaId: UUID? = nil, personaChanged: Bool = false, model: String? = nil, modelChanged: Bool = false, relocateCompanions: Bool = false) {
        guard let index = agents.firstIndex(where: { $0.id == id }) else { return }
        let oldFolder = agents[index].folder
        var needsRestart = false
        agents[index].name = name
        agents[index].avatar = avatar

        if let agentType = agentType, agentType != agents[index].agentType {
            agents[index].agentType = agentType
            needsRestart = true
        }

        if personaChanged {
            agents[index].personaId = personaId
            needsRestart = true
        }

        if modelChanged {
            agents[index].model = model
            needsRestart = true
        }

        if let folder = folder, folder != oldFolder {
            agents[index].folder = folder
            needsRestart = true

            if relocateCompanions {
                for companion in companions(of: id) {
                    guard companion.folder == oldFolder else { continue }
                    if let ci = agents.firstIndex(where: { $0.id == companion.id }) {
                        agents[ci].folder = folder
                        restartAgent(agents[ci])
                    }
                }
            }
        }

        if needsRestart {
            restartAgent(agents[index])
        }

        saveAgents()
    }

    func moveAgent(from source: IndexSet, to destination: Int) {
        // Move within current workspace's agent list
        guard let workspaceId = currentWorkspaceId,
              let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        workspaces[index].agentIds.move(fromOffsets: source, toOffset: destination)
        saveWorkspaces()
    }

    func moveAgentToWorkspace(_ agent: Agent, to targetWorkspaceId: UUID) {
        guard let sourceIndex = workspaces.firstIndex(where: { $0.agentIds.contains(agent.id) }),
              workspaces[sourceIndex].id != targetWorkspaceId,
              let targetIndex = workspaces.firstIndex(where: { $0.id == targetWorkspaceId }) else { return }

        // Remove from source workspace
        workspaces[sourceIndex].agentIds.removeAll { $0 == agent.id }
        workspaces[sourceIndex].activeAgentIds.removeAll { $0 == agent.id }

        // Add to target workspace
        workspaces[targetIndex].agentIds.append(agent.id)

        // Update selection in source workspace if needed
        let sourceAgents = workspaces[sourceIndex].agentIds
        if workspaces[sourceIndex].activeAgentIds.isEmpty && !sourceAgents.isEmpty {
            workspaces[sourceIndex].activeAgentIds = [sourceAgents[0]]
        }

        saveWorkspaces()
    }

    private func saveAgents() {
        // See saveWorkspaces() — keep test fixtures out of real UserDefaults
        guard !AppRuntime.isRunningTests else { return }
        settings.saveAgents(agents)
    }

    func updateStatus(for agentId: UUID, status: AgentState, source: ActivitySource = .terminal) {
        if let index = agents.firstIndex(where: { $0.id == agentId }) {
            guard agents[index].state != status else { return }
            let previousState = agents[index].state
            agents[index].state = status
            agents[index].lastStatusChange = Date()
            if source == .hook {
                controllers[agentId]?.cancelInputProtection()
            }
            if status == .input {
                controllers[agentId]?.status = .input
            }
            if status == .idle && !agents[index].isShell {
                refreshGitStats(for: agentId)
                // A finished turn is the signal you were waiting for while working elsewhere
                if previousState == .running {
                    NotificationService.shared.notifyFinished(
                        agent: agents[index],
                        summary: Self.completionSummary(for: agentId)
                    )
                }
            }
        }
    }

    /// First line of the agent's closing message, for the finished notification.
    static func completionSummary(for agentId: UUID) -> String? {
        guard let last = AgentConversationStore.shared.messages(for: agentId).last,
              last.role == .assistant, last.kind == .text else { return nil }
        let firstLine = last.text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        guard let firstLine, !firstLine.isEmpty else { return nil }
        return ToolUseFormatter.truncate(firstLine, limit: 140)
    }

    /// Agents shown in the sidebar for the current workspace, in display order.
    /// Command-N jumps to the Nth of these.
    var currentWorkspaceSidebarAgents: [Agent] {
        currentWorkspaceAgents.filter { !$0.isCompanion }
    }

    /// Select the Nth sidebar agent (1-based) in the current workspace.
    @discardableResult
    func selectAgent(atSidebarIndex index: Int) -> Bool {
        let list = currentWorkspaceSidebarAgents
        guard index >= 1, index <= list.count else { return false }
        selectAgent(list[index - 1].id)
        return true
    }

    func updateTitle(for agentId: UUID, title: String) {
        // Strip leading spinner/status indicators (⠂, ⠐, ✳, ●, etc.)
        var cleanTitle = title
        while let first = cleanTitle.unicodeScalars.first,
              !first.isASCII || first == " " {
            cleanTitle = String(cleanTitle.dropFirst())
        }
        cleanTitle = cleanTitle.trimmingCharacters(in: .whitespaces)

        if let index = agents.firstIndex(where: { $0.id == agentId }) {
            // Output means it started, whatever the startup queue thinks — otherwise a
            // shell that missed its queue slot shows "Starting..." forever.
            if agents[index].isPendingStart {
                agents[index].isPendingStart = false
            }
            guard agents[index].terminalTitle != cleanTitle else { return }
            agents[index].terminalTitle = cleanTitle
        }
    }

    // MARK: - Layout / Split Pane

    /// Apply the correct layout for an agent and its companions
    func applyCompanionLayout(for agentId: UUID) {
        updateCurrentWorkspace { workspace in
            applyCompanionLayout(for: agentId, to: &workspace)
        }
    }

    func enterSplit(_ mode: LayoutMode) {
        let workspaceAgents = currentWorkspaceAgents
        guard workspaceAgents.count >= 2 else { return }
        guard let currentId = activeAgentIds.first,
              let currentIndex = workspaceAgents.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % workspaceAgents.count
        activeAgentIds = [currentId, workspaceAgents[nextIndex].id]
        layoutMode = mode
        focusedPaneIndex = 0
    }

    private func exitSplit(selecting id: UUID? = nil) {
        let workspaceAgents = currentWorkspaceAgents
        let keepId = id ?? (focusedPaneIndex < activeAgentIds.count ? activeAgentIds[focusedPaneIndex] : nil)
        activeAgentIds = keepId.map { [$0] } ?? (workspaceAgents.first.map { [$0.id] } ?? [])
        layoutMode = .single
        focusedPaneIndex = 0
    }

    /// Enters split view showing the creator agent and a newly created agent
    /// Called when an agent creates a companion agent
    func enterSplitWithNewAgent(newAgentId: UUID, creatorId: UUID) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.agentIds.contains(creatorId) }) else {
            return
        }
        var workspace = workspaces[workspaceIndex]

        // Find which pane the creator is in (if any)
        let creatorPane = workspace.activeAgentIds.firstIndex(of: creatorId)

        switch workspace.layoutMode {
        case .single:
            // Single → Dual vertical: creator left (0), new agent right (1)
            workspace.activeAgentIds = [creatorId, newAgentId]
            workspace.layoutMode = .splitVertical
            workspace.focusedPaneIndex = 1  // Focus the new agent

        case .splitVertical, .splitHorizontal:
            // Dual → Three-pane: keep existing 2 agents, add new agent as pane 2
            var newActiveIds = workspace.activeAgentIds
            newActiveIds.append(newAgentId)
            workspace.activeAgentIds = Array(newActiveIds.prefix(3))
            workspace.layoutMode = .threePane
            // Focus the new agent's pane
            if let newPane = workspace.activeAgentIds.firstIndex(of: newAgentId) {
                workspace.focusedPaneIndex = newPane
            }

        case .threePane:
            // Three-pane → Four-pane grid: add new agent as pane 3
            var newActiveIds = workspace.activeAgentIds
            newActiveIds.append(newAgentId)
            workspace.activeAgentIds = Array(newActiveIds.prefix(4))
            workspace.layoutMode = .gridFourPane
            // Focus the new agent's pane
            if let newPane = workspace.activeAgentIds.firstIndex(of: newAgentId) {
                workspace.focusedPaneIndex = newPane
            }

        case .gridFourPane:
            // Four-pane already full: replace a pane (not the creator's)
            // Priority: 4 (index 3) → 3 (index 2) → 2 (index 1) → 1 (index 0)
            let replacementOrder = [3, 2, 1, 0]
            var replacedPane: Int? = nil

            for pane in replacementOrder where pane < workspace.activeAgentIds.count {
                if pane != creatorPane {
                    workspace.activeAgentIds[pane] = newAgentId
                    replacedPane = pane
                    break
                }
            }

            // Edge case: creator is in all considered panes (shouldn't happen, but fallback)
            if replacedPane == nil, workspace.activeAgentIds.count > 3 {
                workspace.activeAgentIds[3] = newAgentId
                replacedPane = 3
            }

            workspace.focusedPaneIndex = replacedPane ?? 3
        }
        workspaces[workspaceIndex] = workspace
    }

    func focusPane(_ index: Int) {
        guard let workspaceId = currentWorkspaceId else { return }
        focusPane(index, in: workspaceId)
    }

    /// Focuses a pane in a specific workspace without retargeting the main window.
    func focusPane(_ index: Int, in workspaceId: UUID) {
        guard index >= 0,
              let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceId }),
              workspaces[workspaceIndex].layoutMode != .single,
              index < workspaces[workspaceIndex].activeAgentIds.count else { return }
        workspaces[workspaceIndex].focusedPaneIndex = index
    }

    /// Switch to the workspace containing the given agent and bring the window to front.
    func switchToAgent(_ agent: Agent) {
        if let workspace = workspaces.first(where: { $0.agentIds.contains(agent.id) }) {
            switchToWorkspace(workspace.id)
        }
        selectAgent(agent.id)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }

    func selectAgent(_ agentId: UUID, skipCompanionLayout: Bool = false) {
        guard let workspaceId = currentWorkspaceId else { return }
        selectAgent(agentId, in: workspaceId, skipCompanionLayout: skipCompanionLayout)
    }

    /// Selects an agent in a specific workspace without changing the main window's workspace.
    func selectAgent(_ agentId: UUID, in workspaceId: UUID, skipCompanionLayout: Bool = false) {
        guard let workspaceIndex = workspaces.firstIndex(where: { $0.id == workspaceId }),
              workspaces[workspaceIndex].agentIds.contains(agentId) else { return }
        var workspace = workspaces[workspaceIndex]
        selectAgent(agentId, in: &workspace, skipCompanionLayout: skipCompanionLayout)
        workspaces[workspaceIndex] = workspace
    }

    private func selectAgent(
        _ agentId: UUID,
        in workspace: inout Workspace,
        skipCompanionLayout: Bool
    ) {
        // Rule 1: Agent has companions and pane 0 is focused → companion layout
        if !skipCompanionLayout,
           hasCompanions(of: agentId),
           workspace.focusedPaneIndex == 0 {
            applyCompanionLayout(for: agentId, to: &workspace)
            return
        }

        // Rule 2: Currently selected agent (pane 0) has companions → collapse to single
        if let currentId = workspace.activeAgentIds.first,
           hasCompanions(of: currentId) {
            workspace.activeAgentIds = [agentId]
            workspace.layoutMode = .single
            workspace.focusedPaneIndex = 0
            return
        }

        // Rule 3: Agent already in a pane → just focus it
        if let pane = workspace.activeAgentIds.firstIndex(of: agentId) {
            workspace.focusedPaneIndex = pane
            return
        }

        // Rule 4: Place in focused pane
        if workspace.layoutMode == .single || workspace.activeAgentIds.isEmpty {
            workspace.activeAgentIds = [agentId]
            workspace.focusedPaneIndex = 0
        } else {
            let pane = min(max(workspace.focusedPaneIndex, 0), workspace.activeAgentIds.count - 1)
            workspace.activeAgentIds[pane] = agentId
            workspace.focusedPaneIndex = pane
        }
    }

    private func applyCompanionLayout(for agentId: UUID, to workspace: inout Workspace) {
        let companionIds = companions(of: agentId).prefix(3).map(\.id)
        workspace.activeAgentIds = [agentId] + companionIds
        switch companionIds.count {
        case 0: workspace.layoutMode = .single
        case 1: workspace.layoutMode = .splitVertical
        case 2: workspace.layoutMode = .threePane
        default: workspace.layoutMode = .gridFourPane
        }
        workspace.focusedPaneIndex = 0
    }

    private func hasCompanions(of agentId: UUID) -> Bool {
        !companions(of: agentId).isEmpty
    }

    // MARK: - Agent Navigation

    func selectNextAgent() {
        // Cycle through sidebar items (non-companion agents)
        let navigableAgents = currentWorkspaceAgents.filter { !$0.isCompanion }
        guard !navigableAgents.isEmpty else { return }
        guard let currentIndex = navigableAgents.firstIndex(where: { $0.id == activeAgentId }) else {
            selectAgent(navigableAgents[0].id)
            return
        }
        let nextIndex = (currentIndex + 1) % navigableAgents.count
        selectAgent(navigableAgents[nextIndex].id)
    }

    func selectPreviousAgent() {
        // Cycle through sidebar items (non-companion agents)
        let navigableAgents = currentWorkspaceAgents.filter { !$0.isCompanion }
        guard !navigableAgents.isEmpty else { return }
        guard let currentIndex = navigableAgents.firstIndex(where: { $0.id == activeAgentId }) else {
            if let lastAgent = navigableAgents.last {
                selectAgent(lastAgent.id)
            }
            return
        }
        let previousIndex = (currentIndex - 1 + navigableAgents.count) % navigableAgents.count
        selectAgent(navigableAgents[previousIndex].id)
    }

    func selectAgentAtIndex(_ index: Int) {
        let navigableAgents = currentWorkspaceAgents.filter { !$0.isCompanion }
        guard index >= 0 && index < navigableAgents.count else { return }
        let agentId = navigableAgents[index].id

        if layoutMode != .single {
            // If agent is already in a pane, focus that pane
            if let pane = paneIndex(for: agentId) {
                focusedPaneIndex = pane
            } else {
                selectAgent(agentId)
            }
        } else {
            activeAgentIds = [agentId]
        }
    }

    // MARK: - Git Stats

    func refreshGitStats(forFolder folder: String) {
        guard let agent = agents.first(where: { $0.folder == folder }) else { return }
        refreshGitStats(for: agent.id)
    }

    private func refreshGitStats(for agentId: UUID) {
        guard let agent = agents.first(where: { $0.id == agentId }) else { return }

        guard GitWorktreeManager.shared.isGitRepo(agent.folder) else {
            if let index = agents.firstIndex(where: { $0.id == agentId }) {
                agents[index].gitStats = nil
            }
            return
        }

        let folder = agent.folder
        gitStatsQueue.async { [weak self] in
            let repo = GitRepository(path: folder)
            let stats = repo.combinedDiffStats()

            DispatchQueue.main.async {
                guard let self,
                      let index = self.agents.firstIndex(where: { $0.id == agentId }) else { return }
                self.agents[index].gitStats = stats
            }
        }
    }

    // MARK: - Markdown Panel

    /// Show the markdown panel for a specific file
    func showMarkdownPanel(filePath: String, maximized: Bool = false, forAgent agentId: UUID) {
        if let index = agents.firstIndex(where: { $0.id == agentId }) {
            agents[index].markdownFilePath = filePath
            agents[index].markdownMaximized = maximized
            // Add to history (remove if already present to move to front)
            agents[index].markdownFileHistory.removeAll { $0 == filePath }
            agents[index].markdownFileHistory.insert(filePath, at: 0)
        }
    }

    /// Close the markdown panel for an agent
    func closeMarkdownPanel(for agentId: UUID) {
        if let index = agents.firstIndex(where: { $0.id == agentId }) {
            agents[index].markdownFilePath = nil
        }
    }

    // MARK: - Mermaid Panel

    /// Show the mermaid panel for an agent with diagram source
    func showMermaidPanel(source: String, title: String?, forAgent agentId: UUID) {
        if let index = agents.firstIndex(where: { $0.id == agentId }) {
            agents[index].mermaidSource = source
            agents[index].mermaidTitle = title
        }
    }

    /// Close the mermaid panel for an agent
    func closeMermaidPanel(for agentId: UUID) {
        if let index = agents.firstIndex(where: { $0.id == agentId }) {
            agents[index].mermaidSource = nil
            agents[index].mermaidTitle = nil
        }
    }
}
