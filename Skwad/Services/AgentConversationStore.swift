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
        if let last = messages.last,
           last.role == role,
           last.text == trimmed {
            if last.delivery == .pending, delivery == .confirmed {
                messages[messages.count - 1] = AgentConversationMessage(
                    id: last.id,
                    role: last.role,
                    text: last.text,
                    timestamp: last.timestamp,
                    delivery: .confirmed
                )
                messagesByAgent[agentId] = messages
            }
            return
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
        let confirmedHistory = history.map { message in
            AgentConversationMessage(
                id: message.id,
                role: message.role,
                text: message.text,
                timestamp: message.timestamp,
                delivery: .confirmed
            )
        }
        let confirmedKeys = Set(confirmedHistory.map(Self.deduplicationKey))
        let pending = (messagesByAgent[agentId] ?? []).filter { message in
            message.delivery == .pending && !confirmedKeys.contains(Self.deduplicationKey(message))
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
