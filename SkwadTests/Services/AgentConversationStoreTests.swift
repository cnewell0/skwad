import XCTest
@testable import Skwad

@MainActor
final class AgentConversationStoreTests: XCTestCase {
    func testAppendStoresTrimmedMessageForAgent() {
        let store = AgentConversationStore()
        let agentId = UUID()

        store.append(role: .user, text: "  Fix the tests  ", for: agentId)

        XCTAssertEqual(store.messages(for: agentId).map(\.text), ["Fix the tests"])
        XCTAssertEqual(store.messages(for: agentId).map(\.role), [.user])
    }

    func testAppendRejectsWhitespaceOnlyMessage() {
        let store = AgentConversationStore()
        let agentId = UUID()

        store.append(role: .assistant, text: " \n\t ", for: agentId)

        XCTAssertTrue(store.messages(for: agentId).isEmpty)
    }

    func testConsecutiveDuplicateMessageIsStoredOnlyOnce() {
        let store = AgentConversationStore()
        let agentId = UUID()

        store.append(role: .assistant, text: "Done.", for: agentId)
        store.append(role: .assistant, text: "Done.", for: agentId)

        XCTAssertEqual(store.messages(for: agentId).count, 1)
    }

    func testConfirmedDuplicatePromotesPendingMessage() {
        let store = AgentConversationStore()
        let agentId = UUID()
        store.append(role: .user, text: "Continue", for: agentId, delivery: .pending)

        store.append(role: .user, text: "Continue", for: agentId, delivery: .confirmed)

        XCTAssertEqual(store.messages(for: agentId).count, 1)
        XCTAssertEqual(store.messages(for: agentId).first?.delivery, .confirmed)
    }

    func testSameTextFromDifferentRolesIsNotDeduplicated() {
        let store = AgentConversationStore()
        let agentId = UUID()

        store.append(role: .user, text: "Continue", for: agentId)
        store.append(role: .assistant, text: "Continue", for: agentId)

        XCTAssertEqual(store.messages(for: agentId).map(\.role), [.user, .assistant])
    }

    func testReplaceHistoryPreservesPendingLocalPromptNotYetInTranscript() {
        let store = AgentConversationStore()
        let agentId = UUID()
        store.append(role: .user, text: "Pending prompt", for: agentId, delivery: .pending)

        let history = [
            AgentConversationMessage(role: .user, text: "Earlier prompt"),
            AgentConversationMessage(role: .assistant, text: "Earlier answer")
        ]
        store.replaceHistory(history, for: agentId)

        XCTAssertEqual(
            store.messages(for: agentId).map(\.text),
            ["Earlier prompt", "Earlier answer", "Pending prompt"]
        )
    }

    func testReplaceHistoryRemovesPendingDuplicateOnceTranscriptContainsIt() {
        let store = AgentConversationStore()
        let agentId = UUID()
        store.append(role: .user, text: "Fix the tests", for: agentId, delivery: .pending)

        store.replaceHistory(
            [AgentConversationMessage(role: .user, text: "Fix the tests")],
            for: agentId
        )

        XCTAssertEqual(store.messages(for: agentId).count, 1)
        XCTAssertEqual(store.messages(for: agentId).first?.delivery, .confirmed)
    }

    func testMessagesAreIsolatedByAgent() {
        let store = AgentConversationStore()
        let first = UUID()
        let second = UUID()

        store.append(role: .user, text: "First", for: first)
        store.append(role: .assistant, text: "Second", for: second)

        XCTAssertEqual(store.messages(for: first).map(\.text), ["First"])
        XCTAssertEqual(store.messages(for: second).map(\.text), ["Second"])
    }
}
