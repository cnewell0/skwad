import Foundation

struct AgentConversationMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case user
        case assistant
        case system
    }

    enum Kind: String, Equatable, Sendable {
        case text
        case thinking
        case toolUse
    }

    enum Delivery: String, Equatable, Sendable {
        case pending
        case confirmed
    }

    let id: UUID
    let role: Role
    let kind: Kind
    let text: String
    /// Tool name for `.toolUse` messages (e.g. "Bash", "Read")
    let toolName: String?
    let timestamp: Date
    let delivery: Delivery

    init(
        id: UUID = UUID(),
        role: Role,
        kind: Kind = .text,
        text: String,
        toolName: String? = nil,
        timestamp: Date = .now,
        delivery: Delivery = .confirmed
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.timestamp = timestamp
        self.delivery = delivery
    }
}

/// Formats tool_use blocks into compact, human-readable rows for the chat timeline.
enum ToolUseFormatter {
    /// Short display name: strips MCP prefixes ("mcp__skwad__send-message" → "skwad: send-message")
    static func displayName(_ toolName: String) -> String {
        if toolName.hasPrefix("mcp__") {
            let parts = toolName.dropFirst(5).components(separatedBy: "__")
            if parts.count >= 2 {
                return "\(parts[0]): \(parts.dropFirst().joined(separator: "__"))"
            }
            return String(toolName.dropFirst(5))
        }
        return toolName
    }

    /// One-line detail summarizing the tool input (command, file path, pattern, …)
    static func detail(toolName: String, input: [String: Any]) -> String {
        let keys: [String]
        switch toolName {
        case "Bash": keys = ["command", "description"]
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit": keys = ["file_path", "notebook_path"]
        case "Glob", "Grep": keys = ["pattern"]
        case "Task": keys = ["description", "prompt"]
        case "WebFetch": keys = ["url"]
        case "WebSearch": keys = ["query"]
        case "Skill": keys = ["skill", "args"]
        case "TodoWrite": return ""  // todo payloads are noisy, the name is enough
        default: keys = ["description", "command", "file_path", "path", "pattern", "query", "url", "prompt", "message", "text", "status"]
        }

        for key in keys {
            if let value = input[key] as? String, !value.isEmpty {
                return truncate(value)
            }
        }
        // Fallback: first short string value, sorted for determinism
        for key in input.keys.sorted() {
            if let value = input[key] as? String, !value.isEmpty {
                return truncate(value)
            }
        }
        return ""
    }

    /// SF Symbol for a tool row
    static func iconName(_ toolName: String) -> String {
        switch toolName {
        case "Bash": "terminal"
        case "Read": "doc.text"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": "pencil"
        case "Glob", "Grep": "magnifyingglass"
        case "Task": "person.2"
        case "WebFetch", "WebSearch": "globe"
        case "Skill": "wand.and.stars"
        case "TodoWrite": "checklist"
        case "AskUserQuestion", "ExitPlanMode": "questionmark.bubble"
        default: toolName.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }

    static func truncate(_ value: String, limit: Int = 120) -> String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }
}

enum ConversationTimestampParser {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        return ISO8601DateFormatter().date(from: value)
    }
}
