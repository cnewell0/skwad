import XCTest
@testable import Skwad

final class CodexHistoryProviderTests: XCTestCase {

    private var tempDir: String!
    private let provider = CodexHistoryProvider()

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "skwad-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Rollout JSONL Parsing

    func testTitleFromRolloutExtractsFirstUserMessage() {
        let path = writeRollout("test.jsonl", lines: [
            codexUserMessage("Fix the login bug"),
            codexAgentMessage("I'll fix it"),
        ])

        let title = provider.titleFromRollout(path: path)
        XCTAssertEqual(title, "Fix the login bug")
    }

    func testTitleFromRolloutSkipsRegistrationPrompt() {
        let path = writeRollout("test.jsonl", lines: [
            codexUserMessage("You are part of a team of agents called a skwad. Register with the skwad"),
            codexUserMessage("Now fix the tests"),
        ])

        let title = provider.titleFromRollout(path: path)
        XCTAssertEqual(title, "Now fix the tests")
    }

    func testTitleFromRolloutSkipsRegistrationCaseInsensitive() {
        let path = writeRollout("test.jsonl", lines: [
            codexUserMessage("REGISTER WITH THE SKWAD using agent ID abc"),
            codexUserMessage("Real task"),
        ])

        let title = provider.titleFromRollout(path: path)
        XCTAssertEqual(title, "Real task")
    }

    func testTitleFromRolloutReturnsNilForRegistrationOnly() {
        let path = writeRollout("test.jsonl", lines: [
            codexUserMessage("You are part of a team of agents called a skwad"),
        ])

        let title = provider.titleFromRollout(path: path)
        XCTAssertNil(title)
    }

    func testTitleFromRolloutTruncatesLongTitles() {
        let longMessage = String(repeating: "a", count: 100)
        let path = writeRollout("test.jsonl", lines: [
            codexUserMessage(longMessage),
        ])

        let title = provider.titleFromRollout(path: path)
        XCTAssertEqual(title?.count, 80)
        XCTAssertTrue(title?.hasSuffix("...") ?? false)
    }

    func testTitleFromRolloutReturnsNilForEmptyFile() {
        let path = writeRollout("test.jsonl", lines: [""])
        let title = provider.titleFromRollout(path: path)
        XCTAssertNil(title)
    }

    func testTitleFromRolloutReturnsNilForMissingFile() {
        let title = provider.titleFromRollout(path: "/nonexistent/path.jsonl")
        XCTAssertNil(title)
    }

    func testTitleFromRolloutSkipsNonUserMessages() {
        let path = writeRollout("test.jsonl", lines: [
            #"{"timestamp":"2026-03-04T00:33:46.803Z","type":"session_meta","payload":{"id":"abc"}}"#,
            codexAgentMessage("I'm an agent"),
            codexUserMessage("Real user message"),
        ])

        let title = provider.titleFromRollout(path: path)
        XCTAssertEqual(title, "Real user message")
    }

    // MARK: - Conversation Parsing

    func testMessagesFromRolloutReturnsUserAndAssistantMessagesInOrder() {
        let path = writeRollout("messages.jsonl", lines: [
            codexUserMessage("Fix the login bug"),
            codexAgentMessage("I found the issue."),
            codexUserMessage("Please add a regression test"),
            codexAgentMessage("Done — the test passes.")
        ])

        let messages = provider.messagesFromRollout(path: path)

        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .user, .assistant])
        XCTAssertEqual(
            messages.map(\.text),
            ["Fix the login bug", "I found the issue.", "Please add a regression test", "Done — the test passes."]
        )
    }

    func testMessagesFromRolloutSkipsRegistrationAndNonConversationEvents() {
        let path = writeRollout("messages.jsonl", lines: [
            #"{"timestamp":"2026-03-04T00:33:46.803Z","type":"session_meta","payload":{"id":"abc"}}"#,
            codexUserMessage("Register with the skwad using agent ID abc"),
            codexAgentMessage("Registered"),
            codexUserMessage("Real task"),
            codexAgentMessage("Real answer")
        ])

        let messages = provider.messagesFromRollout(path: path)

        XCTAssertEqual(messages.map(\.text), ["Real task", "Real answer"])
    }

    func testMessagesFromRolloutParsesResponseItemMessageContent() {
        let path = writeRollout("response-items.jsonl", lines: [
            #"{"timestamp":"2026-03-04T00:33:46.804Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Review this diff"}]}}"#,
            #"{"timestamp":"2026-03-04T00:33:52.509Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I found one issue."}]}}"#
        ])

        let messages = provider.messagesFromRollout(path: path)

        XCTAssertEqual(messages.map(\.text), ["Review this diff", "I found one issue."])
    }

    // MARK: - Helpers

    private func codexUserMessage(_ message: String) -> String {
        #"{"timestamp":"2026-03-04T00:33:46.804Z","type":"event_msg","payload":{"type":"user_message","message":"\#(message)"}}"#
    }

    private func codexAgentMessage(_ message: String) -> String {
        #"{"timestamp":"2026-03-04T00:33:52.509Z","type":"event_msg","payload":{"type":"agent_message","message":"\#(message)"}}"#
    }

    @discardableResult
    private func writeRollout(_ filename: String, lines: [String]) -> String {
        let path = (tempDir as NSString).appendingPathComponent(filename)
        let content = lines.joined(separator: "\n")
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}
