import Foundation
import SQLite3

struct CodexHistoryProvider: ConversationHistoryProvider {

    private static let dbPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.codex/state_5.sqlite"
    }()

    func loadSessions(for folder: String) -> [SessionSummary] {
        guard FileManager.default.fileExists(atPath: Self.dbPath) else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(Self.dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let query = """
            SELECT id, rollout_path, title, updated_at
            FROM threads
            WHERE cwd = ?1 AND archived = 0
            ORDER BY updated_at DESC
            LIMIT 20
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (folder as NSString).utf8String, -1, nil)

        var summaries: [SessionSummary] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let rolloutPath = String(cString: sqlite3_column_text(stmt, 1))
            let title = String(cString: sqlite3_column_text(stmt, 2))
            let updatedAt = sqlite3_column_int64(stmt, 3)
            let timestamp = Date(timeIntervalSince1970: Double(updatedAt))

            let resolvedTitle = resolveTitle(title, rolloutPath: rolloutPath)
            summaries.append(SessionSummary(id: id, title: resolvedTitle, timestamp: timestamp, messageCount: 0))
        }

        return summaries
    }

    func deleteSession(id: String, folder: String) {
        // Delete the rollout file if it exists
        if let rolloutPath = rolloutPath(for: id) {
            try? FileManager.default.removeItem(atPath: rolloutPath)
        }

        // Mark as archived in the DB
        guard FileManager.default.fileExists(atPath: Self.dbPath) else { return }
        var db: OpaquePointer?
        guard sqlite3_open(Self.dbPath, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let query = "UPDATE threads SET archived = 1 WHERE id = ?1"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    func loadMessages(sessionId: String, folder: String, metadata: [String: String]) -> [AgentConversationMessage] {
        guard let path = rolloutPath(for: sessionId) else { return [] }
        return messagesFromRollout(path: path)
    }

    // MARK: - Title Resolution

    /// If the DB title is empty or a skwad registration prompt, parse the rollout file for a real title
    private func resolveTitle(_ dbTitle: String, rolloutPath: String) -> String {
        if TitleUtils.isValidTitle(dbTitle) {
            return TitleUtils.truncate(dbTitle)
        }

        // Fall back to parsing the rollout JSONL
        return titleFromRollout(path: rolloutPath) ?? ""
    }

    /// Parse a Codex rollout JSONL file to find the first real user message
    func titleFromRollout(path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  let type = payload["type"] as? String,
                  type == "user_message",
                  let message = payload["message"] as? String else {
                continue
            }

            if !TitleUtils.isValidTitle(message) { continue }

            return TitleUtils.extractTitle(message)
        }

        return nil
    }

    func messagesFromRollout(path: String) -> [AgentConversationMessage] {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var messages: [AgentConversationMessage] = []
        var suppressNextAssistant = false

        for line in content.components(separatedBy: .newlines) {
            guard let parsed = conversationMessage(from: line) else { continue }

            if parsed.role == .user && !TitleUtils.isValidTitle(parsed.text) {
                suppressNextAssistant = true
                continue
            }
            if parsed.role == .assistant && suppressNextAssistant {
                suppressNextAssistant = false
                continue
            }
            suppressNextAssistant = false

            if let last = messages.last,
               last.role == parsed.role,
               last.text == parsed.text {
                continue
            }
            messages.append(parsed)
        }

        return messages
    }

    private func conversationMessage(from line: String) -> AgentConversationMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["payload"] as? [String: Any] else {
            return nil
        }

        if let type = payload["type"] as? String,
           let text = payload["message"] as? String {
            let role: AgentConversationMessage.Role?
            switch type {
            case "user_message": role = .user
            case "agent_message": role = .assistant
            default: role = nil
            }
            if let role {
                return message(role: role, text: text, json: json)
            }
        }

        guard payload["type"] as? String == "message",
              let rawRole = payload["role"] as? String,
              let role = AgentConversationMessage.Role(rawValue: rawRole) else {
            return nil
        }

        let text: String
        if let content = payload["content"] as? String {
            text = content
        } else if let parts = payload["content"] as? [[String: Any]] {
            text = parts.compactMap { part in
                guard let type = part["type"] as? String,
                      type == "input_text" || type == "output_text" else {
                    return nil
                }
                return part["text"] as? String
            }.joined(separator: "\n")
        } else {
            return nil
        }
        return message(role: role, text: text, json: json)
    }

    private func message(
        role: AgentConversationMessage.Role,
        text: String,
        json: [String: Any]
    ) -> AgentConversationMessage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let timestamp = (json["timestamp"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) } ?? .now
        return AgentConversationMessage(role: role, text: trimmed, timestamp: timestamp)
    }

    /// Look up the rollout_path for a thread ID
    private func rolloutPath(for id: String) -> String? {
        guard FileManager.default.fileExists(atPath: Self.dbPath) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(Self.dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let query = "SELECT rollout_path FROM threads WHERE id = ?1"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }
}
