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
        var suppressAssistantTurn = false

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  json["isMeta"] as? Bool != true,
                  let type = json["type"] as? String,
                  let rawMessage = json["message"] as? [String: Any] else {
                continue
            }

            let timestamp = ConversationTimestampParser.parse(json["timestamp"] as? String) ?? .distantPast

            switch type {
            case "user":
                // Tool results also arrive as user lines — they carry no text parts and are skipped.
                guard let text = Self.messageText(from: rawMessage) else { continue }
                guard TitleUtils.isValidTitle(text) else {
                    // Internal prompt (registration, inbox check…): hide it and the whole reply turn
                    suppressAssistantTurn = true
                    continue
                }
                suppressAssistantTurn = false
                if let last = messages.last, last.role == .user, last.text == text { continue }
                messages.append(AgentConversationMessage(role: .user, text: text, timestamp: timestamp))

            case "assistant":
                guard !suppressAssistantTurn else { continue }
                messages.append(contentsOf: Self.assistantMessages(from: rawMessage, timestamp: timestamp, last: messages.last))

            default:
                continue
            }
        }

        return messages
    }

    /// Expand one assistant transcript line into timeline messages: thinking, tool calls, and text.
    static func assistantMessages(
        from message: [String: Any],
        timestamp: Date,
        last: AgentConversationMessage?
    ) -> [AgentConversationMessage] {
        var result: [AgentConversationMessage] = []

        func appendUnlessDuplicate(_ candidate: AgentConversationMessage) {
            let previous = result.last ?? last
            if let previous,
               previous.role == candidate.role,
               previous.kind == candidate.kind,
               previous.toolName == candidate.toolName,
               previous.text == candidate.text {
                return
            }
            result.append(candidate)
        }

        if let plain = message["content"] as? String {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                appendUnlessDuplicate(AgentConversationMessage(role: .assistant, text: trimmed, timestamp: timestamp))
            }
            return result
        }

        guard let parts = message["content"] as? [[String: Any]] else { return result }

        for part in parts {
            switch part["type"] as? String {
            case "text":
                let text = (part["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                appendUnlessDuplicate(AgentConversationMessage(role: .assistant, text: text, timestamp: timestamp))

            case "thinking":
                let text = (part["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                appendUnlessDuplicate(AgentConversationMessage(role: .assistant, kind: .thinking, text: text, timestamp: timestamp))

            case "tool_use":
                guard let name = part["name"] as? String, !name.isEmpty else { continue }
                let input = part["input"] as? [String: Any] ?? [:]
                appendUnlessDuplicate(
                    AgentConversationMessage(
                        role: .assistant,
                        kind: .toolUse,
                        text: ToolUseFormatter.detail(toolName: name, input: input),
                        toolName: name,
                        timestamp: timestamp
                    )
                )

            default:
                continue
            }
        }

        return result
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
