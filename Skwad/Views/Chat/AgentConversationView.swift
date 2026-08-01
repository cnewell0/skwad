import SwiftUI

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

    init(
        agent: Agent,
        store: AgentConversationStore = .shared,
        contextPaths: [String] = [],
        onAddContext: @escaping () -> Void = {},
        onRemoveContext: @escaping (String) -> Void = { _ in },
        onContextsSent: @escaping () -> Void = {},
        onSend: @escaping (String) -> Bool
    ) {
        self.agent = agent
        self.store = store
        self.contextPaths = contextPaths
        self.onAddContext = onAddContext
        self.onRemoveContext = onRemoveContext
        self.onContextsSent = onContextsSent
        self.onSend = onSend
    }

    private var messages: [AgentConversationMessage] {
        store.messages(for: agent.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if messages.isEmpty {
                            emptyState
                        } else {
                            ForEach(messages) { message in
                                AgentConversationMessageView(message: message)
                                    .id(message.id)
                            }
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
            }

            AgentPromptComposer(
                agent: agent,
                contextPaths: contextPaths,
                onAddContext: onAddContext,
                onRemoveContext: onRemoveContext,
                onContextsSent: onContextsSent,
                onSend: onSend
            )
                .frame(maxWidth: 820)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.42))
        .task(id: "\(agent.id.uuidString):\(agent.sessionId ?? "")") {
            await ConversationHistoryService.shared.refreshConversation(for: agent)
            guard agent.agentType == "gemini" || agent.agentType == "copilot" else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
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
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                }
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Text(message.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
