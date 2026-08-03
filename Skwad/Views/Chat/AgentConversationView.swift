import SwiftUI
import AppKit
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
    let onSelectModel: ((String?) -> Void)?
    let onInterrupt: (() -> Void)?
    let onCyclePermission: (() -> Void)?

    @MainActor
    init(
        agent: Agent,
        store: AgentConversationStore? = nil,
        contextPaths: [String] = [],
        onAddContext: @escaping () -> Void = {},
        onRemoveContext: @escaping (String) -> Void = { _ in },
        onContextsSent: @escaping () -> Void = {},
        onSend: @escaping (String) -> Bool,
        onEditAgent: (() -> Void)? = nil,
        onSelectModel: ((String?) -> Void)? = nil,
        onInterrupt: (() -> Void)? = nil,
        onCyclePermission: (() -> Void)? = nil
    ) {
        self.agent = agent
        self.store = store ?? .shared
        self.contextPaths = contextPaths
        self.onAddContext = onAddContext
        self.onRemoveContext = onRemoveContext
        self.onContextsSent = onContextsSent
        self.onSend = onSend
        self.onEditAgent = onEditAgent
        self.onSelectModel = onSelectModel
        self.onInterrupt = onInterrupt
        self.onCyclePermission = onCyclePermission
    }

    /// Text pushed into the composer by a starter card
    @State private var draft: String?

    private var messages: [AgentConversationMessage] {
        store.messages(for: agent.id)
    }

    /// Spinner only when the agent is actually running. A pending prompt alone shows
    /// its own "Waiting for agent" caption — claiming "working" there would be a lie.
    private var showsLiveActivity: Bool {
        agent.state == .running
    }

    /// "12s" / "1m 46s" — Codex-style elapsed time for the current turn.
    static func liveElapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        guard total >= 60 else { return "\(total)s" }
        return "\(total / 60)m \(total % 60)s"
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
        // Claude sets the terminal title from the session's first prompt, which for a
        // Skwad agent is the registration prompt — reporting that as the live activity
        // made every turn claim to be "List agents and register with skwad".
        if !terminalTitle.isEmpty, TitleUtils.isValidTitle(terminalTitle) {
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
                            AgentLiveActivityView(agent: agent, lastMessage: messages.last, onInterrupt: onInterrupt)
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
                onEditAgent: onEditAgent,
                onSelectModel: onSelectModel,
                onCyclePermission: onCyclePermission,
                draft: $draft
            )
                .frame(maxWidth: 820)
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.42))
        .task(id: "\(agent.id.uuidString):\(agent.sessionId ?? ""):\(shouldPollTranscript)") {
            await ConversationHistoryService.shared.refreshConversation(for: agent)
            guard ConversationHistoryService.shared.supportsHistory(agentType: agent.agentType) else { return }

            guard shouldPollTranscript else {
                // The Stop hook can land before the transcript is flushed, so the final
                // answer would otherwise never be read once polling stops.
                for delay in [0.4, 1.2, 3.0] {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    await ConversationHistoryService.shared.refreshConversation(for: agent)
                }
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

            if !agent.isShell {
                starterSuggestions
                    .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(.vertical, 40)
    }

    /// Starter prompts for an empty conversation. They fill the composer rather than
    /// sending immediately so the task can be edited before it goes out.
    private var starterSuggestions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ForEach(ConversationStarter.all) { starter in
                    StarterCard(starter: starter) { draft = starter.prompt }
                }
            }
            VStack(spacing: 10) {
                ForEach(ConversationStarter.all) { starter in
                    StarterCard(starter: starter) { draft = starter.prompt }
                }
            }
        }
    }
}

/// One-tap task starters shown on an empty conversation.
struct ConversationStarter: Identifiable {
    let id: String
    let icon: String
    let title: String
    let prompt: String

    static let all: [ConversationStarter] = [
        .init(
            id: "explore",
            icon: "binoculars",
            title: "Explore and\nunderstand code",
            prompt: "Explore this codebase and explain how it is structured — the main components and how they fit together."
        ),
        .init(
            id: "build",
            icon: "hammer",
            title: "Build a new\nfeature or tool",
            prompt: "Build a new feature: "
        ),
        .init(
            id: "review",
            icon: "checkmark.seal",
            title: "Review code and\nsuggest changes",
            prompt: "Review the uncommitted changes in this repo and suggest improvements."
        ),
        .init(
            id: "fix",
            icon: "ladybug",
            title: "Fix issues\nand failures",
            prompt: "Find and fix failing tests or bugs in this repo. Run the test suite first to see what is broken."
        ),
    ]
}

private struct StarterCard: View {
    let starter: ConversationStarter
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: starter.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                Text(starter.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 132, alignment: .topLeading)
            .padding(12)
            .background(
                Color.primary.opacity(isHovering ? 0.09 : 0.05),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(starter.title.replacingOccurrences(of: "\n", with: " "))
    }
}

private extension MarkdownUI.Theme {
    /// GitHub's theme paints an opaque page background behind body text, which shows
    /// up as a dark slab inside the chat bubble. Everything else about it is right.
    static var skwadChat: MarkdownUI.Theme {
        MarkdownUI.Theme.gitHub
            .text {
                BackgroundColor(nil)
            }
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

                    switch message.delivery {
                    case .pending:
                        Label("Waiting for agent", systemImage: "clock")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    case .undelivered:
                        Label("Not delivered — open Terminal to check", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    case .confirmed:
                        EmptyView()
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
                        .markdownTheme(.skwadChat)
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

/// Compact tool-call row that expands to the exact arguments and the output.
private struct ToolUseRowView: View {
    let message: AgentConversationMessage
    @State private var isExpanded = false

    private var name: String {
        ToolUseFormatter.displayName(message.toolName ?? "Tool")
    }

    private var canExpand: Bool {
        message.toolInput != nil || message.toolResult != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard canExpand else { return }
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
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

                    if canExpand {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.quaternary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let input = message.toolInput {
                        detailSection("Called with", text: input, isOutput: false)
                    }
                    if let result = message.toolResult {
                        detailSection("Output", text: result, isOutput: true)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tool \(name): \(message.text)")
    }

    @ViewBuilder
    private func detailSection(_ title: String, text: String, isOutput: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.quaternary)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
                .help("Copy")
                .accessibilityLabel("Copy \(title)")
            }

            ScrollView(.vertical) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isOutput ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// Slim Codex-style activity line. Describes what the agent is doing right now,
/// derived from the streamed timeline — never the agent's stale self-reported status.
private struct AgentLiveActivityView: View {
    let agent: Agent
    let lastMessage: AgentConversationMessage?
    let onInterrupt: (() -> Void)?

    private var label: String {
        AgentConversationView.liveActivityLabel(lastMessage: lastMessage, terminalTitle: agent.terminalTitle)
    }

    var body: some View {
        // 15fps is plenty for a shimmer; .animation redraws at display rate and kept
        // the whole conversation re-laying-out for every running agent.
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { context in
            let elapsed = context.date.timeIntervalSince(agent.lastStatusChange)
            HStack(spacing: 8) {
                ShimmeringText(text: label, date: context.date)

                Text(AgentConversationView.liveElapsedText(elapsed))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.tertiary)

                if let tokens = ConversationHistoryService.shared.outputTokens[agent.id], tokens > 0 {
                    Text("↓ \(ConversationHistoryService.formatTokens(tokens)) tokens")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.quaternary)
                }

                if let onInterrupt {
                    Button("Stop", action: onInterrupt)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .help("Interrupt the agent (Escape)")
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.name): \(label)")
    }
}

/// Text with a highlight sweeping across it — the "the agent is thinking" cue
/// Codex and Conductor both use, which reads as alive without a spinning widget.
private struct ShimmeringText: View {
    let text: String
    let date: Date

    private static let sweepSeconds: Double = 1.8

    var body: some View {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: Self.sweepSeconds) / Self.sweepSeconds
        // Sweep runs past both edges so the highlight enters and exits cleanly
        let center = phase * 1.6 - 0.3

        Text(text)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(
                LinearGradient(
                    stops: [
                        .init(color: .secondary, location: max(0, min(1, center - 0.25))),
                        .init(color: .primary, location: max(0, min(1, center))),
                        .init(color: .secondary, location: max(0, min(1, center + 0.25))),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }
}
