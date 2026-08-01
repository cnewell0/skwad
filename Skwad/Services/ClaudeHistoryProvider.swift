import Foundation

struct ClaudeHistoryProvider: ConversationHistoryProvider {

    func loadSessions(for folder: String) -> [SessionSummary] {
        let directory = sessionsDirectory(for: folder)
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory),
              let contents = try? fm.contentsOfDirectory(atPath: directory) else {
            return []
        }

        var jsonlFiles: [(name: String, date: Date)] = []
        for file in contents where file.hasSuffix(".jsonl") {
            let path = (directory as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let modDate = attrs[.modificationDate] as? Date {
                jsonlFiles.append((name: file, date: modDate))
            }
        }
        jsonlFiles.sort { $0.date > $1.date }

        let maxSessions = 20
        var summaries: [SessionSummary] = []
        for (index, file) in jsonlFiles.enumerated() {
            let sessionId = String(file.name.dropLast(6)) // remove .jsonl
            let path = (directory as NSString).appendingPathComponent(file.name)

            if let summary = parseSessionFile(path: path, sessionId: sessionId, timestamp: file.date) {
                summaries.append(summary)
            } else if index == 0 {
                summaries.append(SessionSummary(id: sessionId, title: "", timestamp: file.date, messageCount: 0))
            }
            if summaries.count >= maxSessions { break }
        }

        return summaries
    }

    func deleteSession(id: String, folder: String) {
        let directory = sessionsDirectory(for: folder)
        let fm = FileManager.default
        let jsonlPath = (directory as NSString).appendingPathComponent("\(id).jsonl")
        try? fm.removeItem(atPath: jsonlPath)
        let dataPath = (directory as NSString).appendingPathComponent(id)
        try? fm.removeItem(atPath: dataPath)
    }

    func loadMessages(sessionId: String, folder: String, metadata: [String: String]) -> [AgentConversationMessage] {
        let path = metadata["transcript_path"]
            ?? (sessionsDirectory(for: folder) as NSString).appendingPathComponent("\(sessionId).jsonl")
        return messagesFromTranscript(path: path)
    }

    // MARK: - Internal

    /// Derive the Claude projects path for a given folder
    /// e.g. /Users/foo/src/bar → ~/.claude/projects/-Users-foo-src-bar
    func sessionsDirectory(for folder: String) -> String {
        let dashPath = folder.replacingOccurrences(of: "/", with: "-")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/projects/\(dashPath)"
    }

    func parseSessionFile(path: String, sessionId: String, timestamp: Date) -> SessionSummary? {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = content.components(separatedBy: "\n")
        var title: String?
        var messageCount = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else {
                continue
            }

            if type == "user" || type == "assistant" {
                messageCount += 1
            }

            if title == nil && type == "user" {
                if json["isMeta"] as? Bool == true { continue }

                guard let message = json["message"] as? [String: Any],
                      let messageContent = message["content"] as? String else {
                    continue
                }

                let cleaned: String
                if messageContent.contains("<command-name>") {
                    cleaned = Self.formatCommandMessage(messageContent)
                    if cleaned.isEmpty { continue }
                } else {
                    cleaned = messageContent
                }

                if !TitleUtils.isValidTitle(cleaned) { continue }

                title = TitleUtils.extractTitle(cleaned)
            }
        }

        guard let title = title, messageCount > 0 else { return nil }

        return SessionSummary(
            id: sessionId,
            title: title,
            timestamp: timestamp,
            messageCount: messageCount
        )
    }

    /// Format a command message like "<command-name>/review</command-name>...<command-args>text</command-args>"
    /// into "/review text"
    static func formatCommandMessage(_ content: String) -> String {
        guard let nameStart = content.range(of: "<command-name>"),
              let nameEnd = content.range(of: "</command-name>") else {
            return ""
        }
        let commandName = String(content[nameStart.upperBound..<nameEnd.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var args = ""
        if let argsStart = content.range(of: "<command-args>"),
           let argsEnd = content.range(of: "</command-args>") {
            args = String(content[argsStart.upperBound..<argsEnd.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if args.isEmpty {
            return commandName
        }
        return "\(commandName) \(args)"
    }

    func messagesFromTranscript(path: String) -> [AgentConversationMessage] {
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
                  json["isMeta"] as? Bool != true,
                  let type = json["type"] as? String,
                  let rawMessage = json["message"] as? [String: Any],
                  let text = Self.messageText(from: rawMessage) else {
                continue
            }

            let role: AgentConversationMessage.Role
            switch type {
            case "user": role = .user
            case "assistant": role = .assistant
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

            if let last = messages.last, last.role == role, last.text == text {
                continue
            }
            messages.append(AgentConversationMessage(role: role, text: text))
        }

        return messages
    }

    private static func messageText(from message: [String: Any]) -> String? {
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let parts = message["content"] as? [[String: Any]] else { return nil }
        let text = parts.compactMap { part -> String? in
            guard part["type"] as? String == "text" else { return nil }
            return part["text"] as? String
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
