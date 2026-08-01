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
        text: String,
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
                text: pending.text,
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
                text: trimmed,
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
               existing.text == message.text,
               existing.timestamp == message.timestamp {
                stableId = existing.id
            } else {
                stableId = message.id
            }

            return AgentConversationMessage(
                id: stableId,
                role: message.role,
                text: message.text,
                timestamp: message.timestamp,
                delivery: .confirmed
            )
        }
        let pending = existingMessages.filter { message in
            guard message.delivery == .pending else { return false }
            return !confirmedHistory.contains { confirmed in
                Self.deduplicationKey(confirmed) == Self.deduplicationKey(message) &&
                confirmed.timestamp >= message.timestamp
            }
        }
        messagesByAgent[agentId] = confirmedHistory + pending
    }

    func clear(for agentId: UUID) {
        messagesByAgent.removeValue(forKey: agentId)
    }

    func clearAll() {
        messagesByAgent.removeAll()
    }

    private static func deduplicationKey(_ message: AgentConversationMessage) -> String {
        "\(message.role.rawValue):\(message.text)"
    }
}
