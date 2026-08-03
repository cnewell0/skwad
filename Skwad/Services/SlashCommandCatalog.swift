import Foundation

/// A slash command the agent's own CLI understands.
struct SlashCommand: Identifiable, Equatable, Sendable {
    /// Command without the leading slash, e.g. "usage"
    let name: String
    let summary: String
    /// True when the command draws its own panel in the agent's terminal instead of
    /// producing a chat message. Sending one of these opens the agent session so the
    /// output is actually visible.
    var showsInTerminal: Bool = true
    /// True when Skwad answers the command itself, in the chat, without involving
    /// the agent at all.
    var handledBySkwad: Bool = false

    var id: String { name }
    var display: String { "/\(name)" }
}

/// Slash commands offered in the composer.
///
/// Claude only: Skwad forwards the typed text verbatim, so suggesting a command
/// another CLI doesn't have would just produce an "unknown command" reply.
enum SlashCommandCatalog {
    static func commands(for agentType: String) -> [SlashCommand] {
        agentType == "claude" ? claude : []
    }

    /// Commands matching what has been typed so far, or nil when the text isn't a
    /// slash command being composed. Returns nil once an argument is being typed so
    /// the list doesn't sit over the composer while you write the rest.
    static func suggestions(for text: String, agentType: String) -> [SlashCommand]? {
        guard text.hasPrefix("/") else { return nil }
        let typed = String(text.dropFirst())
        guard !typed.contains(" ") else { return nil }

        let all = commands(for: agentType)
        guard !all.isEmpty else { return nil }
        guard !typed.isEmpty else { return all }

        let lowered = typed.lowercased()
        let matches = all.filter { $0.name.lowercased().hasPrefix(lowered) }
        return matches.isEmpty ? nil : matches
    }

    /// Text to put in the composer when a command is chosen. Every Claude command
    /// runs bare — /model on its own opens the picker — so nothing is appended; a
    /// trailing space used to strand the previous command in front of the next one.
    static func completion(for command: SlashCommand) -> String {
        command.display
    }

    /// The command Skwad handles itself, if this text is one.
    static func locallyHandled(_ text: String, agentType: String) -> SlashCommand? {
        let name = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .dropFirst()
            .prefix { $0 != " " }
        guard let command = commands(for: agentType).first(where: { $0.name == String(name) }),
              command.handledBySkwad else { return nil }
        return command
    }

    /// Whether sending this text should reveal the agent session.
    static func rendersInTerminal(_ text: String, agentType: String) -> Bool {
        let name = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .dropFirst()
            .prefix { $0 != " " }
        return commands(for: agentType).first { $0.name == String(name) }?.showsInTerminal ?? false
    }

    private static let claude: [SlashCommand] = [
        .init(name: "usage", summary: "Token usage for this session", showsInTerminal: false, handledBySkwad: true),
        .init(name: "cost", summary: "Cost of this session"),
        .init(name: "context", summary: "What is taking up the context window", showsInTerminal: false, handledBySkwad: true),
        .init(name: "compact", summary: "Summarize the conversation to free context", showsInTerminal: false),
        .init(name: "clear", summary: "Start a fresh conversation"),
        // Bare /model opens a picker inside the agent's TUI that the chat cannot see.
        // Skwad has its own model list, so it answers this itself.
        .init(name: "model", summary: "Switch model", showsInTerminal: false, handledBySkwad: true),
        .init(name: "permissions", summary: "Review and edit tool permissions"),
        .init(name: "status", summary: "Model, folder, permissions and connection", showsInTerminal: false, handledBySkwad: true),
        .init(name: "memory", summary: "Edit CLAUDE.md memory files"),
        .init(name: "init", summary: "Write a CLAUDE.md for this repo", showsInTerminal: false),
        .init(name: "review", summary: "Review a pull request", showsInTerminal: false),
        .init(name: "agents", summary: "Manage subagents"),
        .init(name: "mcp", summary: "Manage MCP servers"),
        .init(name: "export", summary: "Export this conversation"),
        .init(name: "doctor", summary: "Diagnose the installation"),
        .init(name: "help", summary: "List every command"),
    ]
}
