import Foundation

struct CopilotHistoryProvider: ConversationHistoryProvider {

    private static let basePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.copilot/session-state"
    }()

    func loadSessions(for folder: String) -> [SessionSummary] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: Self.basePath) else { return [] }

        var summaries: [SessionSummary] = []

        for entry in entries {
            let sessionDir = (Self.basePath as NSString).appendingPathComponent(entry)
            let workspacePath = (sessionDir as NSString).appendingPathComponent("workspace.yaml")

            guard let yaml = parseWorkspaceYaml(path: workspacePath) else { continue }
            guard yaml.cwd == folder else { continue }

            let title = resolveTitle(yaml.summary, sessionDir: sessionDir)
            summaries.append(SessionSummary(
                id: entry,
                title: title,
                timestamp: yaml.updatedAt,
                messageCount: 0
            ))
        }

        summaries.sort { $0.timestamp > $1.timestamp }
        return Array(summaries.prefix(20))
    }

    func deleteSession(id: String, folder: String) {
        let sessionDir = (Self.basePath as NSString).appendingPathComponent(id)
        try? FileManager.default.removeItem(atPath: sessionDir)
    }

    func loadMessages(sessionId: String, folder: String, metadata: [String: String]) -> [AgentConversationMessage] {
        let path = metadata["transcript_path"]
            ?? (Self.basePath as NSString)
                .appendingPathComponent(sessionId)
                .appending("/events.jsonl")
        return messagesFromEvents(path: path)
    }

    // MARK: - Workspace YAML Parsing

    struct WorkspaceInfo {
        let cwd: String
        let summary: String
        let updatedAt: Date
    }

    /// Simple line-based YAML parser for workspace.yaml (flat key: value format)
    func parseWorkspaceYaml(path: String) -> WorkspaceInfo? {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        var fields: [String: String] = [:]
        for line in content.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }

        guard let cwd = fields["cwd"] else { return nil }
        let summary = fields["summary"] ?? ""
        let updatedAt = ConversationTimestampParser.parse(fields["updated_at"]) ?? Date.distantPast

        return WorkspaceInfo(cwd: cwd, summary: summary, updatedAt: updatedAt)
    }

    // MARK: - Title Resolution

    private func resolveTitle(_ summary: String, sessionDir: String) -> String {
        if TitleUtils.isValidTitle(summary) {
            return TitleUtils.truncate(summary)
        }

        // Fall back to parsing events.jsonl for first real user message
        let eventsPath = (sessionDir as NSString).appendingPathComponent("events.jsonl")
        return titleFromEvents(path: eventsPath) ?? ""
    }

    /// Parse events.jsonl to find the first real user message
    func titleFromEvents(path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String, type == "user.message",
                  let eventData = json["data"] as? [String: Any],
                  let message = eventData["content"] as? String else {
                continue
            }

            if !TitleUtils.isValidTitle(message) { continue }

            return TitleUtils.extractTitle(message)
        }

        return nil
    }

    func messagesFromEvents(path: String) -> [AgentConversationMessage] {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var messages: [AgentConversationMessage] = []
        var suppressNextAssistant = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  let eventData = json["data"] as? [String: Any],
                  let rawText = eventData["content"] as? String else {
                continue
            }

            let role: AgentConversationMessage.Role
            switch type {
            case "user.message": role = .user
            case "assistant.message": role = .assistant
            default: continue
            }

            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if role == .user && !TitleUtils.isValidTitle(text) {
                suppressNextAssistant = true
                continue
            }
            if role == .assistant && suppressNextAssistant {
                suppressNextAssistant = false
                continue
            }
            suppressNextAssistant = false

            if let last = messages.last, last.role == role, last.text == text { continue }
            let timestamp = ConversationTimestampParser.parse(json["timestamp"] as? String) ?? .distantPast
            messages.append(AgentConversationMessage(role: role, text: text, timestamp: timestamp))
        }

        return messages
    }
}
