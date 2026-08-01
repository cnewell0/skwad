import SwiftUI
import MarkdownUI

/// A text-first view over the active agent session. The terminal remains alive in
/// ContentView and can be opened when direct shell interaction is needed.
struct AgentConversationView: View {
    let agent: Agent
    let store: AgentConversationStore
    let contextPaths: [String]
    let onAddContext: () -> Void
    let onRemoveContext: (String) -> Void
    let onContextsSent: () -> Void
    let onSend: (String) -> Bool
    let onEditAgent: (() -> Void)?

    @MainActor
    init(
        agent: Agent,
        store: AgentConversationStore? = nil,
        contextPaths: [String] = [],
        onAddContext: @escaping () -> Void = {},
        onRemoveContext: @escaping (String) -> Void = { _ in },
        onContextsSent: @escaping () -> Void = {},
        onSend: @escaping (String) -> Bool,
        onEditAgent: (() -> Void)? = nil
    ) {
        self.agent = agent
        self.store = store ?? .shared
        self.contextPaths = contextPaths
        self.onAddContext = onAddContext
        self.onRemoveContext = onRemoveContext
        self.onContextsSent = onContextsSent
        self.onSend = onSend
        self.onEditAgent = onEditAgent
    }

    private var messages: [AgentConversationMessage] {
        store.messages(for: agent.id)
    }

    /// Spinner only when the agent is actually running. A pending prompt alone shows
    /// its own "Waiting for agent" caption — claiming "working" there would be a lie.
    private var showsLiveActivity: Bool {
        agent.state == .running
    }

    /// What the running agent is doing right now, derived from the streamed timeline.
    static func liveActivityLabel(lastMessage: AgentConversationMessage?, terminalTitle: String) -> String {
        if let lastMessage, lastMessage.role == .assistant {
            switch lastMessage.kind {
            case .toolUse:
                if let toolName = lastMessage.toolName {
                    return "Running \(ToolUseFormatter.displayName(toolName))…"
                }
                return "Running a tool…"
            case .thinking:
                return "Thinking…"
            case .text:
                break
            }
        }
        if !terminalTitle.isEmpty {
            return terminalTitle
        }
        return "Working…"
    }

    /// Keep polling the transcript while running or while a prompt awaits confirmation.
    private var shouldPollTranscript: Bool {
        showsLiveActivity || messages.contains { $0.delivery == .pending }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(messages) { message in
                                AgentConversationMessageView(message: message)
                                    .id(message.id)
                            }
                        }

                        if showsLiveActivity {
                            AgentLiveActivityView(agent: agent, lastMessage: messages.last)
                                .id("live-agent-activity")
                        }
                    }
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.top, 32)
                    .padding(.bottom, 24)
                }
                .onChange(of: messages.last?.id) { _, messageId in
                    guard let messageId else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(messageId, anchor: .bottom)
                    }
                }
                .onChange(of: showsLiveActivity) { _, isActive in
                    guard isActive else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("live-agent-activity", anchor: .bottom)
                    }
                }
            }

            AgentPromptComposer(
                agent: agent,
                contextPaths: contextPaths,
                onAddContext: onAddContext,
                onRemoveContext: onRemoveContext,
                onContextsSent: onContextsSent,
                onSend: onSend,
                onEditAgent: onEditAgent
            )
                .frame(maxWidth: 820)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.42))
        .task(id: "\(agent.id.uuidString):\(agent.sessionId ?? ""):\(shouldPollTranscript)") {
            await ConversationHistoryService.shared.refreshConversation(for: agent)
            guard shouldPollTranscript,
                  ConversationHistoryService.shared.supportsHistory(agentType: agent.agentType) else {
                return
            }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await ConversationHistoryService.shared.refreshConversation(for: agent)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            AvatarView(avatar: agent.avatar, size: 54, font: .title)

            Text("What should we build with \(agent.name)?")
                .font(.system(size: 26, weight: .semibold))

            Text("Send a task here. Open Terminal when you need the live agent session.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(.vertical, 40)
    }
}

private struct AgentConversationMessageView: View {
    let message: AgentConversationMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 72)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(message.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if message.delivery == .pending {
                        Label("Waiting for agent", systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

        case .assistant:
            switch message.kind {
            case .thinking:
                ThinkingRowView(message: message)

            case .toolUse:
                ToolUseRowView(message: message)

            case .text:
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    }
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Markdown(message.text)
                        .markdownTheme(.gitHub)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        case .system:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

/// Collapsed-by-default reasoning row: one dim line, click to expand the full thought.
private struct ThinkingRowView: View {
    let message: AgentConversationMessage
    @State private var isExpanded = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "brain")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)

                if isExpanded {
                    Text(message.text)
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(message.text)
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.quaternary)
                    .padding(.top, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Thinking: \(message.text)")
    }
}

/// Compact tool-call row: icon, tool name, one-line detail — mirrors the terminal transcript.
private struct ToolUseRowView: View {
    let message: AgentConversationMessage

    private var name: String {
        ToolUseFormatter.displayName(message.toolName ?? "Tool")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ToolUseFormatter.iconName(message.toolName ?? ""))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tool \(name): \(message.text)")
    }
}

/// Slim Codex-style activity line. Describes what the agent is doing right now,
/// derived from the streamed timeline — never the agent's stale self-reported status.
private struct AgentLiveActivityView: View {
    let agent: Agent
    let lastMessage: AgentConversationMessage?

    private var label: String {
        AgentConversationView.liveActivityLabel(lastMessage: lastMessage, terminalTitle: agent.terminalTitle)
    }

    var body: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)

            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.name): \(label)")
    }
}
