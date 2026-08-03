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
        Self.parseTranscript(path: path).messages
    }

    /// Single pass over the transcript. The conversation view polls this every second
    /// while an agent runs, so reading and JSON-decoding the file twice (once for
    /// messages, once for token usage) doubled the cost of every tick.
    static func parseTranscript(path: String) -> (messages: [AgentConversationMessage], outputTokens: Int?, usage: AgentUsage) {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return ([], nil, AgentUsage())
        }

        var messages: [AgentConversationMessage] = []
        var suppressAssistantTurn = false
        var totalOutputTokens = 0
        var usage = AgentUsage()
        // tool_use_id -> what the tool returned, recorded on the following user line
        var toolResults: [String: String] = [:]

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
                // Tool results arrive as user lines: keep the payload, skip the row.
                for (toolUseId, output) in Self.toolResults(in: rawMessage) {
                    toolResults[toolUseId] = output
                }
                guard let raw = Self.messageText(from: rawMessage) else { continue }

                // A command that prints has its output recorded here. It is the
                // command's answer, not something the user said, so it renders as a
                // report rather than a prompt.
                if let output = Self.localCommandOutput(in: raw) {
                    messages.append(
                        AgentConversationMessage(
                            role: .assistant,
                            kind: .report,
                            text: output,
                            timestamp: timestamp
                        )
                    )
                    continue
                }

                // Claude records slash commands as an XML block; show the command the
                // user actually typed rather than the markup.
                let text = raw.contains("<command-name>")
                    ? Self.formatCommandMessage(raw)
                    : raw
                guard !text.isEmpty else { continue }
                guard TitleUtils.isValidTitle(text) else {
                    // Internal prompt (registration, inbox check…): hide it and the whole reply turn
                    suppressAssistantTurn = true
                    continue
                }
                suppressAssistantTurn = false
                if let last = messages.last, last.role == .user, last.text == text { continue }
                messages.append(AgentConversationMessage(role: .user, text: text, timestamp: timestamp))

            case "assistant":
                if let turnUsage = rawMessage["usage"] as? [String: Any] {
                    let out = (turnUsage["output_tokens"] as? Int) ?? 0
                    totalOutputTokens += out
                    let model = (rawMessage["model"] as? String) ?? "unknown"
                    var entry = usage.byModel[model] ?? ModelUsage()
                    entry.input += (turnUsage["input_tokens"] as? Int) ?? 0
                    entry.output += out
                    entry.cacheRead += (turnUsage["cache_read_input_tokens"] as? Int) ?? 0
                    entry.cacheWrite += (turnUsage["cache_creation_input_tokens"] as? Int) ?? 0
                    usage.byModel[model] = entry
                    usage.turns += 1
                    // The newest turn's input is what the window currently holds
                    let contextNow = ((turnUsage["input_tokens"] as? Int) ?? 0)
                        + ((turnUsage["cache_read_input_tokens"] as? Int) ?? 0)
                        + ((turnUsage["cache_creation_input_tokens"] as? Int) ?? 0)
                    if contextNow > 0 { usage.latestContextTokens = contextNow }
                }
                guard !suppressAssistantTurn else { continue }
                messages.append(contentsOf: Self.assistantMessages(from: rawMessage, timestamp: timestamp, last: messages.last))

            default:
                continue
            }
        }

        // Pair each call with its result now that the whole file has been read
        let paired = messages.map { message -> AgentConversationMessage in
            guard message.kind == .toolUse,
                  let toolUseId = message.toolUseId,
                  let result = toolResults[toolUseId] else { return message }
            return AgentConversationMessage(
                id: message.id,
                role: message.role,
                kind: message.kind,
                text: message.text,
                toolName: message.toolName,
                toolInput: message.toolInput,
                toolUseId: message.toolUseId,
                toolResult: result,
                timestamp: message.timestamp,
                delivery: message.delivery
            )
        }

        return (paired, totalOutputTokens > 0 ? totalOutputTokens : nil, usage)
    }

    /// Output of a slash command that prints, with terminal colour codes removed.
    static func localCommandOutput(in content: String) -> String? {
        guard let start = content.range(of: "<local-command-stdout>"),
              let end = content.range(of: "</local-command-stdout>") else { return nil }
        let body = String(content[start.upperBound..<end.lowerBound])
        let stripped = body.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    /// tool_result blocks carried on a user line, keyed by the call they answer.
    static func toolResults(in message: [String: Any]) -> [String: String] {
        guard let parts = message["content"] as? [[String: Any]] else { return [:] }
        var results: [String: String] = [:]
        for part in parts where part["type"] as? String == "tool_result" {
            guard let toolUseId = part["tool_use_id"] as? String else { continue }
            let text: String
            if let string = part["content"] as? String {
                text = string
            } else if let blocks = part["content"] as? [[String: Any]] {
                text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                continue
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Cap the retained output; transcripts can hold megabytes per call
            results[toolUseId] = trimmed.count > 8000
                ? String(trimmed.prefix(8000)) + "\n… output truncated"
                : trimmed
        }
        return results
    }

    /// Total output tokens across the transcript's assistant turns.
    /// Prefer `parseTranscript` — this re-reads the file and exists for tests.
    static func outputTokens(inTranscriptAt path: String) -> Int? {
        parseTranscript(path: path).outputTokens
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
                        toolInput: ToolUseFormatter.fullInput(input),
                        toolUseId: part["id"] as? String,
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
