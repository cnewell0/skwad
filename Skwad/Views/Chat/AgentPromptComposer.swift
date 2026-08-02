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
    @Binding var draft: String?

    @State private var prompt = ""
    @State private var deliveryError: String?
    @FocusState private var isPromptFocused: Bool

    private var projectName: String {
        URL(fileURLWithPath: agent.workingFolder).lastPathComponent
    }

    /// Prefer the model the running session reports; fall back to the configured
    /// override so the chip isn't blank before the first hook arrives.
    private var displayModel: String? {
        if let reported = agent.metadata["model"], !reported.isEmpty {
            return reported
        }
        guard let configured = agent.model, !configured.isEmpty else { return nil }
        let known = TerminalCommandBuilder.selectableModels(for: agent.agentType)
        return known.first { $0.id == configured }?.label ?? configured
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
        self._draft = draft
    }

    var body: some View {
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
            guard press.modifiers.contains(.shift), let onCyclePermission else { return .ignored }
            onCyclePermission()
            return .handled
        }
    }

    private var contextBar: some View {
        HStack(spacing: 14) {
            if let onEditAgent {
                Button(action: onEditAgent) {
                    agentChips
                }
                .buttonStyle(.plain)
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
    /// Live mode if the agent reported one, otherwise what it was launched with.
    private var accessLevel: TerminalCommandBuilder.AccessLevel {
        TerminalCommandBuilder.accessLevel(fromReportedMode: agent.metadata["permission_mode"])
            ?? TerminalCommandBuilder.accessLevel(
                agentType: agent.agentType,
                options: AppSettings.shared.getOptions(for: agent.agentType)
            )
    }

    @ViewBuilder
    private var accessChip: some View {
        if !agent.isShell {
            let level = accessLevel
            let label = Label(level.rawValue, systemImage: level.iconName)
                .foregroundStyle(level.isElevated ? Color.orange : Color.secondary)

            if let onCyclePermission {
                Button(action: onCyclePermission) {
                    label.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(level.rawValue) — click or press Shift-Tab to cycle")
                .accessibilityLabel("Permission mode: \(level.rawValue). Activate to cycle.")
            } else {
                label.help(level.rawValue)
            }
        }
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
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch model")
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
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
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
