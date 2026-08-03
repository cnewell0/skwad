import Foundation
import Observation

@Observable
@MainActor
final class AgentConversationStore {
    static let shared = AgentConversationStore()

    private var messagesByAgent: [UUID: [AgentConversationMessage]] = [:]

    func messages(for agentId: UUID) -> [AgentConversationMessage] {
        messagesByAgent[agentId] ?? []
    }

    func append(
        role: AgentConversationMessage.Role,
        kind: AgentConversationMessage.Kind = .text,
        text: String,
        choices: [String] = [],
        for agentId: UUID,
        delivery: AgentConversationMessage.Delivery = .confirmed,
        timestamp: Date = .now
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var messages = messagesByAgent[agentId] ?? []
        if delivery == .confirmed,
           let pendingIndex = messages.firstIndex(where: {
               $0.role == role && $0.text == trimmed && $0.delivery == .pending
           }) {
            let pending = messages[pendingIndex]
            messages[pendingIndex] = AgentConversationMessage(
                id: pending.id,
                role: pending.role,
                kind: pending.kind,
                text: pending.text,
                toolName: pending.toolName,
                toolInput: pending.toolInput,
                toolUseId: pending.toolUseId,
                toolResult: pending.toolResult,
                timestamp: pending.timestamp,
                delivery: .confirmed
            )
            messagesByAgent[agentId] = messages
            return
        }

        if let last = messages.last,
           last.role == role,
           last.text == trimmed {
            if last.delivery == .confirmed, delivery == .confirmed {
                return
            }
        }

        messages.append(
            AgentConversationMessage(
                role: role,
                kind: kind,
                text: trimmed,
                choices: choices,
                timestamp: timestamp,
                delivery: delivery
            )
        )
        messagesByAgent[agentId] = messages
    }

    func replaceHistory(_ history: [AgentConversationMessage], for agentId: UUID) {
        let existingMessages = messagesByAgent[agentId] ?? []
        let existingConfirmed = existingMessages.filter { $0.delivery == .confirmed }
        let confirmedHistory = history.enumerated().map { index, message in
            let existing = index < existingConfirmed.count ? existingConfirmed[index] : nil
            let stableId: UUID
            if let existing,
               existing.role == message.role,
               existing.kind == message.kind,
               existing.text == message.text,
               existing.toolName == message.toolName,
               existing.timestamp == message.timestamp {
                stableId = existing.id
            } else {
                stableId = message.id
            }

            return AgentConversationMessage(
                id: stableId,
                role: message.role,
                kind: message.kind,
                text: message.text,
                toolName: message.toolName,
                toolInput: message.toolInput,
                toolUseId: message.toolUseId,
                toolResult: message.toolResult,
                timestamp: message.timestamp,
                delivery: .confirmed
            )
        }
        // Reports Skwad produced itself (e.g. /usage) exist in no transcript, so a
        // refresh would otherwise wipe them a second after they appeared.
        let localReports = existingMessages.filter { $0.kind == .report || $0.kind == .choice }

        let pending = existingMessages.filter { message in
            guard message.delivery == .pending else { return false }
            return !confirmedHistory.contains { confirmed in
                Self.deduplicationKey(confirmed) == Self.deduplicationKey(message) &&
                confirmed.timestamp >= message.timestamp
            }
        }
        let transcriptReports = Set(confirmedHistory.filter { $0.kind == .report }.map(\.text))
        let keptReports = localReports.filter { !transcriptReports.contains($0.text) }
        // Order stays history, then local reports, then anything still in flight —
        // sorting by timestamp moved pending prompts out of last place.
        messagesByAgent[agentId] = confirmedHistory + keptReports + pending
    }

    /// Whether a specific user prompt is still awaiting delivery confirmation
    func hasPendingUserPrompt(_ text: String, for agentId: UUID) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return messages(for: agentId).contains {
            $0.role == .user && $0.delivery == .pending && $0.text == trimmed
        }
    }

    /// Mark a prompt the agent never picked up, so the chat stops implying it will.
    func markUndelivered(_ text: String, for agentId: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var messages = messagesByAgent[agentId],
              let index = messages.firstIndex(where: {
                  $0.role == .user && $0.delivery == .pending && $0.text == trimmed
              }) else { return }
        let pending = messages[index]
        messages[index] = AgentConversationMessage(
            id: pending.id,
            role: pending.role,
            kind: pending.kind,
            text: pending.text,
            toolName: pending.toolName,
            toolInput: pending.toolInput,
            toolUseId: pending.toolUseId,
            toolResult: pending.toolResult,
            timestamp: pending.timestamp,
            delivery: .undelivered
        )
        messagesByAgent[agentId] = messages
    }

    func clear(for agentId: UUID) {
        messagesByAgent.removeValue(forKey: agentId)
    }

    func clearAll() {
        messagesByAgent.removeAll()
    }

    private static func deduplicationKey(_ message: AgentConversationMessage) -> String {
        "\(message.role.rawValue):\(message.kind.rawValue):\(message.toolName ?? ""):\(message.text)"
    }
}
