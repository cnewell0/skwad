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

    func testReplaceHistoryKeepsReportsSkwadGeneratedItself() {
        let store = AgentConversationStore()
        let agentId = UUID()
        store.append(role: .user, text: "/usage", for: agentId)
        store.append(role: .assistant, kind: .report, text: "3 assistant turns", for: agentId)

        // A transcript refresh knows nothing about a locally produced report
        store.replaceHistory(
            [AgentConversationMessage(role: .user, text: "/usage")],
            for: agentId
        )

        let kinds = store.messages(for: agentId).map(\.kind)
        XCTAssertTrue(kinds.contains(.report), "the report should survive a refresh")
    }

    func testRepeatedLocalCardsDoNotStackUp() {
        let store = AgentConversationStore()
        let agentId = UUID()
        // Running the same command three times used to leave three identical cards
        for _ in 0..<3 {
            store.append(role: .assistant, kind: .report, text: "7 assistant turns", for: agentId)
            store.replaceHistory([], for: agentId)
        }

        let reports = store.messages(for: agentId).filter { $0.kind == .report }
        XCTAssertEqual(reports.count, 1)
    }

    func testAnsweredQuestionStopsAsking() {
        let store = AgentConversationStore()
        let agentId = UUID()
        store.append(
            role: .assistant,
            kind: .choice,
            text: "Which model should desktop use?",
            choices: ["Opus 5", "Sonnet 5"],
            for: agentId
        )

        store.removeChoicePrompt(matching: "Which model should desktop use?", for: agentId)

        XCTAssertFalse(store.messages(for: agentId).contains { $0.kind == .choice })
    }

    func testACardAlreadyInTheTranscriptIsNotDuplicatedLocally() {
        let store = AgentConversationStore()
        let agentId = UUID()
        store.append(role: .assistant, kind: .report, text: "Set model to Sonnet 5", for: agentId)

        // The agent's own stdout says the same thing; only one card should remain
        store.replaceHistory(
            [AgentConversationMessage(role: .assistant, kind: .report, text: "Set model to Sonnet 5")],
            for: agentId
        )

        XCTAssertEqual(store.messages(for: agentId).filter { $0.kind == .report }.count, 1)
    }
    /// A question read out of the transcript is part of history, so keeping it as a
    /// local card too would show it twice on every refresh.
    func testTranscriptQuestionIsNotListedTwice() {
        let store = AgentConversationStore()
        let agentId = UUID()
        let question = AgentConversationMessage(
            role: .assistant, kind: .choice, text: "How wide?",
            toolUseId: "toolu_1", choices: ["A", "B"]
        )

        store.replaceHistory([question], for: agentId)
        store.replaceHistory([question], for: agentId)

        XCTAssertEqual(store.messages(for: agentId).filter { $0.kind == .choice }.count, 1)
        XCTAssertEqual(store.messages(for: agentId).first?.choices, ["A", "B"])
    }

    /// Answering writes the tool result a moment later, so until then the transcript
    /// still contains the question and must not ask again.
    func testAnsweredQuestionDoesNotComeBack() {
        let store = AgentConversationStore()
        let agentId = UUID()
        let question = AgentConversationMessage(
            role: .assistant, kind: .choice, text: "How wide?",
            toolUseId: "toolu_1", choices: ["A", "B"]
        )
        store.replaceHistory([question], for: agentId)

        store.removeChoicePrompt(matching: "How wide?", for: agentId)
        store.replaceHistory([question], for: agentId)

        XCTAssertFalse(store.messages(for: agentId).contains { $0.kind == .choice })
    }

    /// Once the question leaves the transcript, the same question asked again is new
    func testTheSameQuestionCanBeAskedAgainLater() {
        let store = AgentConversationStore()
        let agentId = UUID()
        let question = AgentConversationMessage(
            role: .assistant, kind: .choice, text: "How wide?",
            toolUseId: "toolu_1", choices: ["A", "B"]
        )
        store.replaceHistory([question], for: agentId)
        store.removeChoicePrompt(matching: "How wide?", for: agentId)

        // The answered call is gone from the transcript...
        store.replaceHistory([], for: agentId)
        // ...so a fresh call with the same wording is a real question again
        store.replaceHistory([question], for: agentId)

        XCTAssertEqual(store.messages(for: agentId).filter { $0.kind == .choice }.count, 1)
    }

}
