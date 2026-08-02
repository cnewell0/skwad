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

    func testConfirmationPromotesOldestMatchingPendingPrompt() {
        let store = AgentConversationStore()
        let agentId = UUID()
        store.append(role: .user, text: "Continue", for: agentId, delivery: .pending)
        store.append(role: .user, text: "Continue", for: agentId, delivery: .pending)

        store.append(role: .user, text: "Continue", for: agentId, delivery: .confirmed)

        XCTAssertEqual(store.messages(for: agentId).map(\.delivery), [.confirmed, .pending])
    }

    func testRepeatedPromptIsNotDroppedAfterEarlierIdenticalPromptWasConfirmed() {
        let store = AgentConversationStore()
        let agentId = UUID()
        store.append(role: .user, text: "Run the tests", for: agentId)

        store.append(role: .user, text: "Run the tests", for: agentId, delivery: .pending)

        XCTAssertEqual(store.messages(for: agentId).count, 2)
        XCTAssertEqual(store.messages(for: agentId).last?.delivery, .pending)
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

    func testReplaceHistoryPreservesIdentityForUnchangedMessages() {
        let store = AgentConversationStore()
        let agentId = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let history = [
            AgentConversationMessage(role: .user, text: "Fix the bug", timestamp: timestamp),
            AgentConversationMessage(role: .assistant, text: "Investigating", timestamp: timestamp)
        ]
        store.replaceHistory(history, for: agentId)
        let initialIDs = store.messages(for: agentId).map(\.id)

        store.replaceHistory(history.map {
            AgentConversationMessage(role: $0.role, text: $0.text, timestamp: $0.timestamp)
        }, for: agentId)

        XCTAssertEqual(store.messages(for: agentId).map(\.id), initialIDs)
    }

    func testReplaceHistoryPreservesRepeatedPromptWhenOnlyOlderOccurrenceIsInTranscript() {
        let store = AgentConversationStore()
        let agentId = UUID()
        let pendingAt = Date(timeIntervalSince1970: 2_000)
        store.append(
            role: .user,
            text: "Run the tests",
            for: agentId,
            delivery: .pending,
            timestamp: pendingAt
        )

        store.replaceHistory(
            [
                AgentConversationMessage(
                    role: .user,
                    text: "Run the tests",
                    timestamp: Date(timeIntervalSince1970: 1_000)
                )
            ],
            for: agentId
        )

        XCTAssertEqual(store.messages(for: agentId).count, 2)
        XCTAssertEqual(store.messages(for: agentId).last?.delivery, .pending)
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

    func testReplaceHistoryPreservesToolDetailSoRowsStayExpandable() {
        let store = AgentConversationStore()
        let agentId = UUID()
        let call = AgentConversationMessage(
            role: .assistant,
            kind: .toolUse,
            text: "gh pr list",
            toolName: "Bash",
            toolInput: "command: gh pr list --limit 25",
            toolUseId: "t1",
            toolResult: "310 Feat/stackadapt"
        )

        store.replaceHistory([call], for: agentId)

        let stored = store.messages(for: agentId).first
        XCTAssertEqual(stored?.toolInput, "command: gh pr list --limit 25")
        XCTAssertEqual(stored?.toolResult, "310 Feat/stackadapt")
        XCTAssertEqual(stored?.toolUseId, "t1")
    }
}
