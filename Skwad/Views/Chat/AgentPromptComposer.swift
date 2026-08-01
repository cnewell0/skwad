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

    @State private var prompt = ""
    @State private var deliveryError: String?
    @FocusState private var isPromptFocused: Bool

    private var projectName: String {
        URL(fileURLWithPath: agent.workingFolder).lastPathComponent
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
        onEditAgent: (() -> Void)? = nil
    ) {
        self.agent = agent
        self.contextPaths = contextPaths
        self.onAddContext = onAddContext
        self.onRemoveContext = onRemoveContext
        self.onContextsSent = onContextsSent
        self.onSend = onSend
        self.onEditAgent = onEditAgent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            contextBar

            if !contextPaths.isEmpty {
                contextChips
            }

            HStack(alignment: .bottom, spacing: 12) {
                Button(action: onAddContext) {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Add context")
                .accessibilityLabel("Add context")

                TextField("Message \(agent.name)", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...8)
                    .font(.system(size: 15))
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

            Spacer()

            Text(agent.state.rawValue)
                .foregroundStyle(agent.state.color)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var agentChips: some View {
        HStack(spacing: 14) {
            Label(projectName, systemImage: "folder")
            Label(agent.agentType, systemImage: "cpu")

            if let model = agent.metadata["model"], !model.isEmpty {
                Label(model, systemImage: "sparkles")
            }
        }
        .contentShape(Rectangle())
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
