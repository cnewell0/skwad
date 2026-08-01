import Foundation

struct AgentConversationMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Equatable, Sendable {
        case user
        case assistant
        case system
    }

    enum Delivery: String, Equatable, Sendable {
        case pending
        case confirmed
    }

    let id: UUID
    let role: Role
    let text: String
    let timestamp: Date
    let delivery: Delivery

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        timestamp: Date = .now,
        delivery: Delivery = .confirmed
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.delivery = delivery
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
