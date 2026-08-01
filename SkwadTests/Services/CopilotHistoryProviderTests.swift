import XCTest
@testable import Skwad

final class CopilotHistoryProviderTests: XCTestCase {

    private var tempDir: String!
    private let provider = CopilotHistoryProvider()

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "skwad-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    // MARK: - Workspace YAML Parsing

    func testParseWorkspaceYamlExtractsFields() {
        let path = writeYaml("workspace.yaml", content: """
            id: abc-123
            cwd: /Users/foo/src/bar
            summary: Fix the login bug
            created_at: 2026-03-04T01:09:07.089Z
            updated_at: 2026-03-04T01:09:35.484Z
            """)

        let info = provider.parseWorkspaceYaml(path: path)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.cwd, "/Users/foo/src/bar")
        XCTAssertEqual(info?.summary, "Fix the login bug")
    }

    func testParseWorkspaceYamlReturnsNilWithoutCwd() {
        let path = writeYaml("workspace.yaml", content: """
            id: abc-123
            summary: Fix the login bug
            """)

        let info = provider.parseWorkspaceYaml(path: path)
        XCTAssertNil(info)
    }

    func testParseWorkspaceYamlHandlesEmptySummary() {
        let path = writeYaml("workspace.yaml", content: """
            id: abc-123
            cwd: /Users/foo/src/bar
            summary:
            updated_at: 2026-03-04T01:09:35.484Z
            """)

        let info = provider.parseWorkspaceYaml(path: path)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.summary, "")
    }

    func testParseWorkspaceYamlReturnsNilForMissingFile() {
        let info = provider.parseWorkspaceYaml(path: "/nonexistent/workspace.yaml")
        XCTAssertNil(info)
    }

    // MARK: - Events JSONL Parsing

    func testTitleFromEventsExtractsFirstUserMessage() {
        let path = writeEvents("events.jsonl", lines: [
            copilotSessionStart(),
            copilotUserMessage("Fix the login bug"),
            copilotAssistantMessage("I'll fix it"),
        ])

        let title = provider.titleFromEvents(path: path)
        XCTAssertEqual(title, "Fix the login bug")
    }

    func testTitleFromEventsSkipsRegistrationPrompt() {
        let path = writeEvents("events.jsonl", lines: [
            copilotUserMessage("Register with the Skwad crew using your agent ID"),
            copilotUserMessage("Now fix the tests"),
        ])

        let title = provider.titleFromEvents(path: path)
        XCTAssertEqual(title, "Now fix the tests")
    }

    func testTitleFromEventsReturnsNilForRegistrationOnly() {
        let path = writeEvents("events.jsonl", lines: [
            copilotUserMessage("You are part of a team of agents called a skwad"),
        ])

        let title = provider.titleFromEvents(path: path)
        XCTAssertNil(title)
    }

    func testTitleFromEventsTruncatesLongTitles() {
        let longMessage = String(repeating: "a", count: 100)
        let path = writeEvents("events.jsonl", lines: [
            copilotUserMessage(longMessage),
        ])

        let title = provider.titleFromEvents(path: path)
        XCTAssertEqual(title?.count, 80)
        XCTAssertTrue(title?.hasSuffix("...") ?? false)
    }

    func testTitleFromEventsReturnsNilForMissingFile() {
        let title = provider.titleFromEvents(path: "/nonexistent/events.jsonl")
        XCTAssertNil(title)
    }

    func testTitleFromEventsSkipsNonUserMessages() {
        let path = writeEvents("events.jsonl", lines: [
            copilotSessionStart(),
            copilotAssistantMessage("I'm thinking..."),
            copilotUserMessage("Real user message"),
        ])

        let title = provider.titleFromEvents(path: path)
        XCTAssertEqual(title, "Real user message")
    }

    func testMessagesFromEventsReturnsUserAndAssistantConversation() {
        let path = writeEvents("events.jsonl", lines: [
            copilotSessionStart(),
            copilotUserMessage("Register with the Skwad crew using your agent ID"),
            copilotUserMessage("Fix the login bug"),
            copilotAssistantMessage("I fixed the login bug"),
        ])

        let messages = provider.messagesFromEvents(path: path)

        XCTAssertEqual(messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(messages.map(\.text), ["Fix the login bug", "I fixed the login bug"])
    }

    // MARK: - Helpers

    private func copilotUserMessage(_ content: String) -> String {
        #"{"type":"user.message","data":{"content":"\#(content)"},"id":"\#(UUID().uuidString)","timestamp":"2026-03-04T01:09:07.089Z"}"#
    }

    private func copilotAssistantMessage(_ content: String) -> String {
        #"{"type":"assistant.message","data":{"content":"\#(content)"},"id":"\#(UUID().uuidString)","timestamp":"2026-03-04T01:09:19.073Z"}"#
    }

    private func copilotSessionStart() -> String {
        #"{"type":"session.start","data":{"sessionId":"abc-123"},"id":"\#(UUID().uuidString)","timestamp":"2026-03-04T01:09:07.089Z"}"#
    }

    @discardableResult
    private func writeYaml(_ filename: String, content: String) -> String {
        let path = (tempDir as NSString).appendingPathComponent(filename)
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @discardableResult
    private func writeEvents(_ filename: String, lines: [String]) -> String {
        let path = (tempDir as NSString).appendingPathComponent(filename)
        let content = lines.joined(separator: "\n")
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
}
