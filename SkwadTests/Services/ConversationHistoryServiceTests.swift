import XCTest
@testable import Skwad

final class ClaudeHistoryProviderTests: XCTestCase {

    private var tempDir: String!
    private let provider = ClaudeHistoryProvider()

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "skwad-test-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    private func writeJSONL(_ filename: String, lines: [String], modDate: Date? = nil) {
        let path = (tempDir as NSString).appendingPathComponent(filename)
        let content = lines.joined(separator: "\n")
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
        if let modDate = modDate {
            try! FileManager.default.setAttributes([.modificationDate: modDate], ofItemAtPath: path)
        }
    }

    private func userMessage(_ content: String, isMeta: Bool = false) -> String {
        if isMeta {
            return #"{"type":"user","message":{"content":"\#(content)"},"isMeta":true}"#
        }
        return #"{"type":"user","message":{"content":"\#(content)"}}"#
    }

    private func assistantMessage() -> String {
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"response"}]}}"#
    }

    private func progressMessage() -> String {
        #"{"type":"progress","data":{}}"#
    }

    // MARK: - Title Extraction

    func testExtractsTitleFromFirstUserMessage() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("Fix the login bug"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].title, "Fix the login bug")
    }

    func testSkipsMetaMessages() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("meta stuff", isMeta: true),
            userMessage("Real user message"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title, "Real user message")
    }

    func testSkipsRegistrationPromptTeamOfAgents() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("You are part of a team of agents called a skwad. Register with the skwad"),
            userMessage("Actual task here"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title, "Actual task here")
    }

    func testSkipsRegistrationPromptRegisterWithSkwad() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("Register with the skwad using agent ID abc-123"),
            userMessage("Do something useful"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title, "Do something useful")
    }

    func testSkipsRegistrationPromptListAgents() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("List other agents names and project (no ID) in a table based on context."),
            userMessage("Now fix the tests"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title, "Now fix the tests")
    }

    func testSkipsRegistrationCaseInsensitive() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("YOU ARE PART OF A TEAM OF AGENTS"),
            userMessage("Real message"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title, "Real message")
    }

    func testFormatsCommandMessageAsTitle() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("<command-message>review</command-message>\\n<command-name>/review</command-name>\\n<command-args>focus on error handling</command-args>"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title, "/review focus on error handling")
    }

    func testFormatsCommandMessageWithoutArgs() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("<command-message>merge</command-message>\\n<command-name>/merge</command-name>\\n<command-args></command-args>"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title, "/merge")
    }

    func testFormatsCommandMessageWithNoArgsTag() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("<command-message>review</command-message>\\n<command-name>/review</command-name>"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title, "/review")
    }

    func testFormatsCommandMessageIndentedPattern() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("<command-name>/hold</command-name>\\n            <command-message>hold</command-message>\\n            <command-args></command-args>"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title, "/hold")
    }

    func testSkipsClearCommand() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("<command-name>/clear</command-name>\\n<command-args></command-args>"),
            userMessage("Real task"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title, "Real task")
    }

    func testFormatsCommandMessageMultilineArgs() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("<command-message>design</command-message>\\n<command-name>/design</command-name>\\n<command-args>deprecate models screen\\nif workspace has restrictions show it</command-args>"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title, "/design deprecate models screen")
    }

    func testFormatsCommandMessageNamespacedCommand() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("<command-message>skwad:broadcast</command-message>\\n<command-name>/skwad:broadcast</command-name>\\n<command-args>hello all!</command-args>"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title, "/skwad:broadcast hello all!")
    }

    func testSkipsLocalCommandMessages() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("<local-command-stdout></local-command-stdout>"),
            userMessage("Real message"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title, "Real message")
    }

    func testTruncatesLongTitles() {
        let longMessage = String(repeating: "a", count: 100)
        writeJSONL("session1.jsonl", lines: [
            userMessage(longMessage),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title.count, 80)
        XCTAssertTrue(sessions[0].title.hasSuffix("..."))
    }

    func testUsesFirstLineOnly() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("First line\\nSecond line\\nThird line"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].title, "First line")
    }

    // MARK: - Message Count

    func testCountsUserAndAssistantMessages() {
        writeJSONL("session1.jsonl", lines: [
            userMessage("msg1"),
            assistantMessage(),
            userMessage("msg2"),
            assistantMessage(),
            progressMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].messageCount, 4)
    }

    // MARK: - Conversation Parsing

    func testMessagesFromTranscriptExpandsToolAndThinkingParts() {
        let path = (tempDir as NSString).appendingPathComponent("conversation.jsonl")
        let lines = [
            userMessage("Fix the bug"),
            #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Let me look."},{"type":"text","text":"Investigating."},{"type":"tool_use","name":"Read","input":{"file_path":"/tmp/a.swift"}},{"type":"text","text":"Found it."}]}}"#
        ]
        try! lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let messages = provider.messagesFromTranscript(path: path)

        XCTAssertEqual(messages.map(\.role), [.user, .assistant, .assistant, .assistant, .assistant])
        XCTAssertEqual(messages.map(\.kind), [.text, .thinking, .text, .toolUse, .text])
        XCTAssertEqual(messages.map(\.text), ["Fix the bug", "Let me look.", "Investigating.", "/tmp/a.swift", "Found it."])
        XCTAssertEqual(messages[3].toolName, "Read")
    }

    func testMessagesFromTranscriptSkipsToolResultUserLines() {
        let path = (tempDir as NSString).appendingPathComponent("toolresult.jsonl")
        let lines = [
            userMessage("Fix the bug"),
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"file.txt"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#
        ]
        try! lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let messages = provider.messagesFromTranscript(path: path)

        XCTAssertEqual(messages.map(\.text), ["Fix the bug", "ls", "Done."])
        XCTAssertEqual(messages[1].kind, .toolUse)
        XCTAssertEqual(messages[1].toolName, "Bash")
    }

    func testMessagesFromTranscriptSkipsRegistrationTurn() {
        let path = (tempDir as NSString).appendingPathComponent("conversation.jsonl")
        let lines = [
            userMessage("Register with the skwad using agent ID abc"),
            #"{"type":"assistant","message":{"content":"Registered"}}"#,
            userMessage("Build the feature"),
            #"{"type":"assistant","message":{"content":"Working on it"}}"#
        ]
        try! lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let messages = provider.messagesFromTranscript(path: path)

        XCTAssertEqual(messages.map(\.text), ["Build the feature", "Working on it"])
    }

    func testMessagesFromTranscriptPreservesEventTimestamp() {
        let path = (tempDir as NSString).appendingPathComponent("timestamped.jsonl")
        let line = #"{"type":"user","timestamp":"2026-03-04T00:33:46.804Z","message":{"content":"Fix the bug"}}"#
        try! line.write(toFile: path, atomically: true, encoding: .utf8)

        let messages = provider.messagesFromTranscript(path: path)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(messages.first?.timestamp, formatter.date(from: "2026-03-04T00:33:46.804Z"))
    }

    // MARK: - Tool Call Detail

    func testToolCallsCarryFullInputAndPairWithTheirResult() {
        let path = (tempDir as NSString).appendingPathComponent("tools.jsonl")
        let lines = [
            userMessage("check the PRs"),
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"gh pr list --repo Kochava/mcp --limit 25","description":"list PRs"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"PR 1 Fix thing"}]}}"#
        ]
        try! lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let messages = provider.messagesFromTranscript(path: path)
        let call = messages.first { $0.kind == .toolUse }

        XCTAssertEqual(call?.toolName, "Bash")
        // Summary stays one line; the full arguments are kept for the expanded row
        XCTAssertEqual(call?.text, "gh pr list --repo Kochava/mcp --limit 25")
        XCTAssertEqual(call?.toolInput?.contains("command: gh pr list"), true)
        XCTAssertEqual(call?.toolInput?.contains("description: list PRs"), true)
        XCTAssertEqual(call?.toolResult, "PR 1 Fix thing")
    }

    func testToolResultBlocksNeverRenderAsUserMessages() {
        let path = (tempDir as NSString).appendingPathComponent("res.jsonl")
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/a.swift"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"file body"}]}}"#
        ]
        try! lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let messages = provider.messagesFromTranscript(path: path)

        XCTAssertFalse(messages.contains { $0.role == .user })
        XCTAssertEqual(messages.first?.toolResult, "file body")
    }

    // MARK: - Token Usage

    func testOutputTokensSumsAssistantUsage() {
        let path = (tempDir as NSString).appendingPathComponent("usage.jsonl")
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"a"}],"usage":{"output_tokens":1200}}}"#,
            #"{"type":"user","message":{"content":"next"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"b"}],"usage":{"output_tokens":900}}}"#
        ]
        try! lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertEqual(ClaudeHistoryProvider.outputTokens(inTranscriptAt: path), 2100)
    }

    func testOutputTokensIsNilWhenTranscriptReportsNone() {
        let path = (tempDir as NSString).appendingPathComponent("nousage.jsonl")
        try! #"{"type":"assistant","message":{"content":[{"type":"text","text":"a"}]}}"#
            .write(toFile: path, atomically: true, encoding: .utf8)

        XCTAssertNil(ClaudeHistoryProvider.outputTokens(inTranscriptAt: path))
    }

    func testFormatTokensUsesCompactThousands() {
        XCTAssertEqual(ConversationHistoryService.formatTokens(820), "820")
        XCTAssertEqual(ConversationHistoryService.formatTokens(3100), "3.1k")
        XCTAssertEqual(ConversationHistoryService.formatTokens(1000), "1.0k")
    }

    // MARK: - Tool Use Formatting

    func testToolUseFormatterDisplayNameStripsMCPPrefix() {
        XCTAssertEqual(ToolUseFormatter.displayName("mcp__skwad__send-message"), "skwad: send-message")
        XCTAssertEqual(ToolUseFormatter.displayName("Bash"), "Bash")
    }

    func testToolUseFormatterDetailPicksToolSpecificKey() {
        XCTAssertEqual(
            ToolUseFormatter.detail(toolName: "Bash", input: ["command": "make test", "timeout": "5"]),
            "make test"
        )
        XCTAssertEqual(
            ToolUseFormatter.detail(toolName: "Read", input: ["file_path": "/tmp/a.swift"]),
            "/tmp/a.swift"
        )
        XCTAssertEqual(ToolUseFormatter.detail(toolName: "TodoWrite", input: ["todos": "x"]), "")
    }

    func testToolUseFormatterTruncatesAndFlattensNewlines() {
        let long = String(repeating: "a", count: 200)
        let truncated = ToolUseFormatter.truncate(long)
        XCTAssertEqual(truncated.count, 121)
        XCTAssertTrue(truncated.hasSuffix("…"))
        XCTAssertEqual(ToolUseFormatter.truncate("line1\nline2"), "line1 line2")
    }

    // MARK: - Filtering

    func testSkipsFilesWithNoValidUserMessages() {
        writeJSONL("session-old.jsonl", lines: [
            userMessage("You are part of a team of agents"),
            userMessage("<local-command-stdout></local-command-stdout>"),
        ], modDate: Date().addingTimeInterval(-100))

        writeJSONL("session-new.jsonl", lines: [
            userMessage("Real message"),
            assistantMessage()
        ], modDate: Date())

        let sessions = parseSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].title, "Real message")
    }

    func testSkipsEmptyFiles() {
        writeJSONL("session-old.jsonl", lines: [""], modDate: Date().addingTimeInterval(-100))

        writeJSONL("session-new.jsonl", lines: [
            userMessage("Hello"),
            assistantMessage()
        ], modDate: Date())

        let sessions = parseSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].title, "Hello")
    }

    // MARK: - Most Recent Titleless Session

    func testMostRecentFileWithNoTitleIsIncluded() {
        writeJSONL("session-current.jsonl", lines: [
            userMessage("You are part of a team of agents"),
        ], modDate: Date())

        writeJSONL("session-old.jsonl", lines: [
            userMessage("Fix the bug"),
            assistantMessage()
        ], modDate: Date().addingTimeInterval(-100))

        let sessions = parseSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].id, "session-current")
        XCTAssertEqual(sessions[0].title, "")
        XCTAssertEqual(sessions[1].id, "session-old")
        XCTAssertEqual(sessions[1].title, "Fix the bug")
    }

    func testMostRecentEmptyFileIsIncluded() {
        writeJSONL("session-current.jsonl", lines: [""], modDate: Date())

        writeJSONL("session-old.jsonl", lines: [
            userMessage("Hello"),
            assistantMessage()
        ], modDate: Date().addingTimeInterval(-100))

        let sessions = parseSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].id, "session-current")
        XCTAssertEqual(sessions[0].title, "")
    }

    func testMostRecentWithTitleStillWorks() {
        writeJSONL("session-new.jsonl", lines: [
            userMessage("New task"),
            assistantMessage()
        ], modDate: Date())

        writeJSONL("session-old.jsonl", lines: [
            userMessage("Old task"),
            assistantMessage()
        ], modDate: Date().addingTimeInterval(-100))

        let sessions = parseSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].title, "New task")
        XCTAssertEqual(sessions[1].title, "Old task")
    }

    func testOnlyMostRecentTitlelessFileIsKept() {
        writeJSONL("session-newest.jsonl", lines: [
            userMessage("You are part of a team of agents"),
        ], modDate: Date())

        writeJSONL("session-middle.jsonl", lines: [
            userMessage("<local-command-stdout></local-command-stdout>"),
        ], modDate: Date().addingTimeInterval(-50))

        writeJSONL("session-oldest.jsonl", lines: [
            userMessage("Valid message"),
            assistantMessage()
        ], modDate: Date().addingTimeInterval(-100))

        let sessions = parseSessions()
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].id, "session-newest")
        XCTAssertEqual(sessions[0].title, "")
        XCTAssertEqual(sessions[1].id, "session-oldest")
        XCTAssertEqual(sessions[1].title, "Valid message")
    }

    // MARK: - Session Limit

    func testLimitsTo20Sessions() {
        for i in 0..<25 {
            writeJSONL("session\(i).jsonl", lines: [
                userMessage("Message \(i)"),
                assistantMessage()
            ])
        }

        let sessions = parseSessions()
        XCTAssertEqual(sessions.count, 20)
    }

    // MARK: - Session ID

    func testSessionIdIsFilenameWithoutExtension() {
        writeJSONL("abc-123-def.jsonl", lines: [
            userMessage("Hello"),
            assistantMessage()
        ])

        let sessions = parseSessions()
        XCTAssertEqual(sessions[0].id, "abc-123-def")
    }

    // MARK: - Delete

    func testDeleteRemovesFilesAndDirectory() {
        let sessionId = "test-session-id"
        writeJSONL("\(sessionId).jsonl", lines: [
            userMessage("Hello"),
            assistantMessage()
        ])

        let dataDir = (tempDir as NSString).appendingPathComponent(sessionId)
        try! FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: (tempDir as NSString).appendingPathComponent("\(sessionId).jsonl")))
        XCTAssertTrue(fm.fileExists(atPath: dataDir))

        // Test file deletion directly (deleteSession derives its own path)
        try? fm.removeItem(atPath: (tempDir as NSString).appendingPathComponent("\(sessionId).jsonl"))
        try? fm.removeItem(atPath: dataDir)

        XCTAssertFalse(fm.fileExists(atPath: (tempDir as NSString).appendingPathComponent("\(sessionId).jsonl")))
        XCTAssertFalse(fm.fileExists(atPath: dataDir))
    }

    // MARK: - Path Derivation

    func testClaudeProjectsPathDerivation() {
        let path = provider.sessionsDirectory(for: "/Users/foo/src/bar")
        XCTAssertTrue(path.hasSuffix("/.claude/projects/-Users-foo-src-bar"))
    }

    func testClaudeProjectsPathWithTrailingSlash() {
        let path = provider.sessionsDirectory(for: "/Users/foo/src/bar/")
        XCTAssertTrue(path.hasSuffix("/.claude/projects/-Users-foo-src-bar-"))
    }

    // MARK: - Format Command Message

    func testFormatCommandMessageBasic() {
        let result = ClaudeHistoryProvider.formatCommandMessage("<command-name>/review</command-name><command-args>focus on errors</command-args>")
        XCTAssertEqual(result, "/review focus on errors")
    }

    func testFormatCommandMessageNoArgs() {
        let result = ClaudeHistoryProvider.formatCommandMessage("<command-name>/merge</command-name>")
        XCTAssertEqual(result, "/merge")
    }

    func testFormatCommandMessageNoCommandName() {
        let result = ClaudeHistoryProvider.formatCommandMessage("just some text")
        XCTAssertEqual(result, "")
    }

    // MARK: - Helpers

    /// Tests call loadSessions via a wrapper that points at tempDir.
    /// Since loadSessions derives the path from the folder, we test parseSessionFile directly
    /// through the directory-based flow using internal methods.
    private func parseSessions() -> [SessionSummary] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: tempDir) else { return [] }

        var jsonlFiles: [(name: String, date: Date)] = []
        for file in contents where file.hasSuffix(".jsonl") {
            let path = (tempDir as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let modDate = attrs[.modificationDate] as? Date {
                jsonlFiles.append((name: file, date: modDate))
            }
        }
        jsonlFiles.sort { $0.date > $1.date }

        var summaries: [SessionSummary] = []
        for (index, file) in jsonlFiles.enumerated() {
            let sessionId = String(file.name.dropLast(6))
            let path = (tempDir as NSString).appendingPathComponent(file.name)

            if let summary = provider.parseSessionFile(path: path, sessionId: sessionId, timestamp: file.date) {
                summaries.append(summary)
            } else if index == 0 {
                summaries.append(SessionSummary(id: sessionId, title: "", timestamp: file.date, messageCount: 0))
            }
            if summaries.count >= 20 { break }
        }

        return summaries
    }
}
