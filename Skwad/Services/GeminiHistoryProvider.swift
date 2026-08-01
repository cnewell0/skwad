import Foundation

struct GeminiHistoryProvider: ConversationHistoryProvider {

    private static let basePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.gemini/tmp"
    }()

    func loadSessions(for folder: String) -> [SessionSummary] {
        guard let projectDir = findProjectDirectory(for: folder) else { return [] }

        let logsPath = (projectDir as NSString).appendingPathComponent("logs.json")
        guard let data = FileManager.default.contents(atPath: logsPath),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        // Group by sessionId, keep the first user message per session
        var sessionMap: [String: (message: String, timestamp: Date)] = [:]
        for entry in entries {
            guard let sessionId = entry["sessionId"] as? String,
                  let type = entry["type"] as? String, type == "user",
                  let message = entry["message"] as? String,
                  let timestampStr = entry["timestamp"] as? String else {
                continue
            }
            // Only keep the first entry per session
            if sessionMap[sessionId] == nil {
                let timestamp = ConversationTimestampParser.parse(timestampStr) ?? Date.distantPast
                sessionMap[sessionId] = (message: message, timestamp: timestamp)
            }
        }

        // Sort by timestamp descending, limit to 20
        let sorted = sessionMap.sorted { $0.value.timestamp > $1.value.timestamp }
        let limited = sorted.prefix(20)

        let chatsDir = (projectDir as NSString).appendingPathComponent("chats")

        return limited.map { (sessionId, info) in
            let title = resolveTitle(info.message, sessionId: sessionId, chatsDir: chatsDir)
            return SessionSummary(id: sessionId, title: title, timestamp: info.timestamp, messageCount: 0)
        }
    }

    func deleteSession(id: String, folder: String) {
        guard let projectDir = findProjectDirectory(for: folder) else { return }

        // Delete matching chat file
        let chatsDir = (projectDir as NSString).appendingPathComponent("chats")
        if let chatFile = findChatFile(sessionId: id, in: chatsDir) {
            try? FileManager.default.removeItem(atPath: chatFile)
        }

        // Remove entry from logs.json
        let logsPath = (projectDir as NSString).appendingPathComponent("logs.json")
        guard let data = FileManager.default.contents(atPath: logsPath),
              var entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        entries.removeAll { ($0["sessionId"] as? String) == id }
        if let updated = try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted]) {
            try? updated.write(to: URL(fileURLWithPath: logsPath))
        }
    }

    func loadMessages(sessionId: String, folder: String, metadata: [String: String]) -> [AgentConversationMessage] {
        if let transcriptPath = metadata["transcript_path"] {
            return messagesFromChatFile(path: transcriptPath)
        }
        guard let projectDir = findProjectDirectory(for: folder) else { return [] }
        let chatsDir = (projectDir as NSString).appendingPathComponent("chats")
        guard let path = findChatFile(sessionId: sessionId, in: chatsDir) else { return [] }
        return messagesFromChatFile(path: path)
    }

    // MARK: - Project Directory Discovery

    /// Find the ~/.gemini/tmp/<name>/ folder whose .project_root matches the given folder
    func findProjectDirectory(for folder: String) -> String? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: Self.basePath) else { return nil }

        for dir in dirs {
            let fullPath = (Self.basePath as NSString).appendingPathComponent(dir)
            let projectRootFile = (fullPath as NSString).appendingPathComponent(".project_root")
            guard let rootData = fm.contents(atPath: projectRootFile),
                  let root = String(data: rootData, encoding: .utf8) else {
                continue
            }
            if root.trimmingCharacters(in: .whitespacesAndNewlines) == folder {
                return fullPath
            }
        }
        return nil
    }

    // MARK: - Title Resolution

    private func resolveTitle(_ logMessage: String, sessionId: String, chatsDir: String) -> String {
        if TitleUtils.isValidTitle(logMessage) {
            return TitleUtils.truncate(logMessage)
        }

        // Fall back to parsing the chat JSON for the first real user message
        if let chatFile = findChatFile(sessionId: sessionId, in: chatsDir) {
            if let title = titleFromChatFile(path: chatFile) {
                return title
            }
        }

        return ""
    }

    /// Parse a Gemini chat JSON file to find the first real user message
    func titleFromChatFile(path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            return nil
        }

        for msg in messages {
            guard let type = msg["type"] as? String, type == "user",
                  let content = msg["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String else {
                continue
            }

            if !TitleUtils.isValidTitle(text) { continue }

            return TitleUtils.extractTitle(text)
        }

        return nil
    }

    func messagesFromChatFile(path: String) -> [AgentConversationMessage] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMessages = json["messages"] as? [[String: Any]] else {
            return []
        }

        var messages: [AgentConversationMessage] = []
        var suppressNextAssistant = false

        for rawMessage in rawMessages {
            guard let type = rawMessage["type"] as? String,
                  let text = messageText(from: rawMessage),
                  !text.isEmpty else { continue }

            let role: AgentConversationMessage.Role
            switch type {
            case "user": role = .user
            case "gemini", "assistant", "model": role = .assistant
            default: continue
            }

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
            let timestamp = ConversationTimestampParser.parse(rawMessage["timestamp"] as? String) ?? .distantPast
            messages.append(AgentConversationMessage(role: role, text: text, timestamp: timestamp))
        }

        return messages
    }

    private func messageText(from message: [String: Any]) -> String? {
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let parts = message["content"] as? [[String: Any]] else { return nil }
        let text = parts.compactMap { $0["text"] as? String }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Find the chat file for a session ID in the chats directory
    /// Files are named like: session-2026-03-04T01-08-8ed8bc14.json (short prefix of session ID)
    private func findChatFile(sessionId: String, in chatsDir: String) -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { return nil }

        // The filename contains a short prefix of the session ID (first 8 chars)
        let shortId = String(sessionId.prefix(8))
        for file in files where file.hasSuffix(".json") && file.contains(shortId) {
            return (chatsDir as NSString).appendingPathComponent(file)
        }
        return nil
    }

}
