import SwiftUI

/// The primary text-first control for directing an agent.
/// The agent's live terminal remains available in the terminal drawer.
struct AgentPromptComposer: View {
    let agent: Agent
    let contextPaths: [String]
    let onAddContext: () -> Void
    let onRemoveContext: (String) -> Void
    let onContextsSent: () -> Void
    let onSend: (String) -> Bool
    let onEditAgent: (() -> Void)?
    let onSelectModel: ((String?) -> Void)?
    let onCyclePermission: (() -> Void)?
    /// Called when the thing being sent only draws in the agent's own terminal
    let onRevealAgentTerminal: (() -> Void)?
    @Binding var draft: String?

    @State private var prompt = ""
    @State private var slashSelection = 0
    @State private var dismissedSlashPalette = false
    @State private var deliveryError: String?
    @FocusState private var isPromptFocused: Bool

    private var projectName: String {
        URL(fileURLWithPath: agent.workingFolder).lastPathComponent
    }

    /// Show what you picked. Reporting the session's current model instead made a
    /// deliberate choice look ignored; whether it has taken effect is conveyed by
    /// `modelPendingRestart` instead.
    private var displayModel: String? {
        if let configured = agent.model, !configured.isEmpty {
            let known = TerminalCommandBuilder.selectableModels(for: agent.agentType)
            return known.first { $0.id == configured }?.label ?? configured
        }
        let reported = agent.metadata["model"]
        return (reported?.isEmpty == false) ? reported : nil
    }

    /// True when a chosen model has not reached the running session. The runtime
    /// switch can be refused (older CLI, unknown alias), and silently showing the
    /// new name would be a lie — a restart applies it for certain.
    private var modelPendingRestart: Bool {
        guard let chosen = agent.model, !chosen.isEmpty else { return false }
        guard let reported = agent.metadata["model"], !reported.isEmpty else { return false }
        return !reported.lowercased().contains(chosen.lowercased())
    }

    /// Commands to offer for what is currently typed, or nil when the palette
    /// shouldn't be showing.
    private var slashSuggestions: [SlashCommand]? {
        guard !dismissedSlashPalette else { return nil }
        return SlashCommandCatalog.suggestions(for: prompt, agentType: agent.agentType)
    }

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        agent: Agent,
        contextPaths: [String] = [],
        onAddContext: @escaping () -> Void = {},
        onRemoveContext: @escaping (String) -> Void = { _ in },
        onContextsSent: @escaping () -> Void = {},
        onSend: @escaping (String) -> Bool,
        onEditAgent: (() -> Void)? = nil,
        onSelectModel: ((String?) -> Void)? = nil,
        onCyclePermission: (() -> Void)? = nil,
        onRevealAgentTerminal: (() -> Void)? = nil,
        draft: Binding<String?> = .constant(nil)
    ) {
        self.agent = agent
        self.contextPaths = contextPaths
        self.onAddContext = onAddContext
        self.onRemoveContext = onRemoveContext
        self.onContextsSent = onContextsSent
        self.onSend = onSend
        self.onEditAgent = onEditAgent
        self.onSelectModel = onSelectModel
        self.onCyclePermission = onCyclePermission
        self.onRevealAgentTerminal = onRevealAgentTerminal
        self._draft = draft
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let suggestions = slashSuggestions {
                slashPalette(suggestions)
            }

            composerBody
        }
        .onChange(of: prompt) { _, newValue in
            // A fresh "/" should always offer the list again
            if !newValue.hasPrefix("/") { dismissedSlashPalette = false }
            slashSelection = 0
        }
    }

    private var composerBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            contextBar

            if !contextPaths.isEmpty {
                contextChips
            }

            HStack(alignment: .center, spacing: 12) {
                Button(action: onAddContext) {
                    // Match the send button's metrics so the two ends of the row balance
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Add context")
                .accessibilityLabel("Add context")

                TextField("Message \(agent.name)", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .font(.system(size: 15))
                    .frame(minHeight: 30)
                    .focused($isPromptFocused)
                    .onSubmit(send)
                    .accessibilityLabel("Agent prompt")

                Button(action: send) {
                    Label("Send", systemImage: "arrow.up")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canSend ? Color.black : Color.secondary)
                        .frame(width: 30, height: 30)
                        .background(canSend ? Color.white : Color.white.opacity(0.22), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send prompt (Command-Return)")
                .accessibilityLabel("Send prompt")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if let deliveryError {
                Text(deliveryError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .onChange(of: agent.id) {
            prompt = ""
            deliveryError = nil
            isPromptFocused = true
        }
        .onChange(of: draft) { _, newDraft in
            guard let newDraft else { return }
            // Focus first while the field is still empty: focusing a populated field
            // selects all of it, so the next keystroke would wipe the starter text.
            isPromptFocused = true
            DispatchQueue.main.async {
                prompt = newDraft
                draft = nil
            }
        }
        .onKeyPress(.tab, phases: .down) { press in
            if press.modifiers.contains(.shift), let onCyclePermission {
                onCyclePermission()
                return .handled
            }
            guard let suggestions = slashSuggestions, !suggestions.isEmpty else { return .ignored }
            apply(suggestions[min(slashSelection, suggestions.count - 1)])
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard let suggestions = slashSuggestions, !suggestions.isEmpty else { return .ignored }
            slashSelection = (slashSelection + 1) % suggestions.count
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard let suggestions = slashSuggestions, !suggestions.isEmpty else { return .ignored }
            slashSelection = (slashSelection - 1 + suggestions.count) % suggestions.count
            return .handled
        }
        .onKeyPress(.escape) {
            guard slashSuggestions != nil else { return .ignored }
            dismissedSlashPalette = true
            return .handled
        }
    }

    private func slashPalette(_ suggestions: [SlashCommand]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, command in
                Button {
                    apply(command)
                } label: {
                    HStack(spacing: 10) {
                        Text(command.display)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .frame(width: 108, alignment: .leading)

                        Text(command.summary)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        index == min(slashSelection, suggestions.count - 1)
                            ? Color.accentColor.opacity(0.18)
                            : Color.clear
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(command.display): \(command.summary)")
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.98))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    /// Put the chosen command in the composer without sending, so an argument can
    /// still be typed if you want one.
    private func apply(_ command: SlashCommand) {
        prompt = SlashCommandCatalog.completion(for: command)
        dismissedSlashPalette = true
        isPromptFocused = true
    }

    private var contextBar: some View {
        HStack(spacing: 14) {
            if let onEditAgent {
                Button(action: onEditAgent) {
                    agentChips
                }
                .buttonStyle(.plain)
                .font(.caption)
                .controlSize(.small)
                .help("Edit agent (folder, type, options)")
                .accessibilityLabel("Edit agent settings")
            } else {
                agentChips
            }

            modelChip

            accessChip

            Spacer()

            connectionIndicator

            Text(agent.state.rawValue)
                .foregroundStyle(agent.state.color)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    /// What the agent may do without asking. Elevated access is called out in orange —
    /// an agent that can act unattended is something you should never have to go
    /// digging through Settings to discover.
    /// The mode you chose, falling back to what the session reports and then to the
    /// launch flags. Your choice wins the label so picking one visibly does something.
    private var accessLevel: TerminalCommandBuilder.AccessLevel {
        TerminalCommandBuilder.accessLevel(forConfiguredMode: agent.permissionMode)
            ?? TerminalCommandBuilder.accessLevel(fromReportedMode: agent.metadata["permission_mode"])
            ?? TerminalCommandBuilder.accessLevel(
                agentType: agent.agentType,
                options: AppSettings.shared.getOptions(for: agent.agentType)
            )
    }

    /// Whether this agent can talk back through Skwad at all. A shell runs commands
    /// but has no session to connect, so it gets no indicator.
    private var showsConnection: Bool {
        !agent.isShell && AppSettings.shared.mcpServerEnabled
    }

    @ViewBuilder
    private var connectionIndicator: some View {
        if showsConnection {
            let connected = agent.isRegistered
            HStack(spacing: 5) {
                Circle()
                    .fill(connected ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(connected ? "Connected" : "Connecting…")
            }
            .foregroundStyle(.secondary)
            .help(connected
                  ? "Registered with Skwad — messages and status are live"
                  : "Waiting for the agent to register with Skwad")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(connected ? "Agent connected" : "Agent connecting")
        }
    }

    /// The mode the running session last reported, which is the only ground truth.
    private var reportedLevel: TerminalCommandBuilder.AccessLevel? {
        TerminalCommandBuilder.accessLevel(fromReportedMode: agent.metadata["permission_mode"])
    }

    /// True when we have asked for a mode the agent has not yet confirmed. Cycling is
    /// a keystroke into a TUI, so it can miss — this is how you can tell.
    private var permissionUnconfirmed: Bool {
        guard let chosen = agent.permissionMode, let reported = reportedLevel else { return false }
        return TerminalCommandBuilder.accessLevel(forConfiguredMode: chosen) != reported
    }

    @ViewBuilder
    private var accessChip: some View {
        if !agent.isShell {
            let level = accessLevel
            let canCycle = !TerminalCommandBuilder.selectablePermissionModes(for: agent.agentType).isEmpty

            if canCycle, let onCyclePermission {
                Button(action: onCyclePermission) {
                    HStack(spacing: 4) {
                        Image(systemName: level.iconName)
                        Text(level.rawValue)
                        if permissionUnconfirmed {
                            Image(systemName: "questionmark.circle")
                                .font(.system(size: 9, weight: .bold))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(permissionUnconfirmed
                                     ? Color.orange
                                     : (level.isElevated ? Color.orange : Color.secondary))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption)
                .controlSize(.small)
                .help(permissionUnconfirmed
                      ? "Asked for \(level.rawValue); the session last reported \(reportedLevel?.rawValue ?? "another mode"). It confirms on the agent's next turn."
                      : "\(level.rawValue) — click or press Shift-Tab to cycle")
                .accessibilityLabel(permissionUnconfirmed
                                    ? "Permission mode \(level.rawValue), not yet confirmed by the agent"
                                    : "Permission mode: \(level.rawValue). Activate to cycle.")
            } else {
                Label(level.rawValue, systemImage: level.iconName)
                    .foregroundStyle(level.isElevated ? Color.orange : Color.secondary)
                    .help(level.rawValue)
            }
        }
    }

    private var agentChips: some View {
        HStack(spacing: 14) {
            Label(projectName, systemImage: "folder")
            Label(agent.agentType, systemImage: "cpu")
        }
        .contentShape(Rectangle())
    }

    /// Model is switched straight from the composer — going through Edit Agent for
    /// something you change this often is too many clicks.
    @ViewBuilder
    private var modelChip: some View {
        let models = TerminalCommandBuilder.selectableModels(for: agent.agentType)
        if !models.isEmpty, let onSelectModel {
            Menu {
                Button { onSelectModel(nil) } label: {
                    Label("Default", systemImage: agent.model == nil ? "checkmark" : "")
                }
                Divider()
                ForEach(models, id: \.id) { model in
                    Button { onSelectModel(model.id) } label: {
                        Label(model.label, systemImage: agent.model == model.id ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                    Text(displayModel ?? "Model")
                    if modelPendingRestart {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 8, weight: .bold))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(modelPendingRestart ? Color.orange : Color.secondary)
                .font(.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .font(.caption)
            .controlSize(.small)
            .help(modelPendingRestart
                  ? "The session is still on \(agent.metadata["model"] ?? "its previous model"). Restart the agent to apply your choice."
                  : "Switch model")
            .accessibilityLabel("Switch model")
        } else if let model = displayModel {
            Label(model, systemImage: "sparkles")
        }
    }

    private var contextChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 7) {
                ForEach(contextPaths, id: \.self) { path in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                        Text(path)
                            .lineLimit(1)
                        Button {
                            onRemoveContext(path)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(path)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }

    private func send() {
        // Return on an open palette runs the highlighted command rather than sending
        // the half-typed text — "/us" would otherwise go out verbatim.
        var outgoing = prompt
        if let suggestions = slashSuggestions, !suggestions.isEmpty {
            let chosen = suggestions[min(slashSelection, suggestions.count - 1)]
            outgoing = SlashCommandCatalog.completion(for: chosen)
            prompt = outgoing
            dismissedSlashPalette = true
        }

        let text = outgoing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if onSend(Self.message(prompt: text, contextPaths: contextPaths)) {
            prompt = ""
            deliveryError = nil
            onContextsSent()
        } else {
            deliveryError = "The agent is still starting. Open the terminal drawer to check its status."
        }
    }

    static func message(prompt: String, contextPaths: [String]) -> String {
        guard !contextPaths.isEmpty else { return prompt }
        let files = contextPaths.map { "- \($0)" }.joined(separator: "\n")
        return "\(prompt)\n\nContext files:\n\(files)"
    }
}
