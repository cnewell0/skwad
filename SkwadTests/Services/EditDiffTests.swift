import XCTest
@testable import Skwad

final class EditDiffTests: XCTestCase {

    // MARK: - Diffing

    /// The case from the screenshot: one line swapped for another inside context
    func testShowsChangedLinesAndKeepsTheRestAsContext() {
        let old = """
        if (event === 'chat_updated') {
            store.saveHistoryDebounced()
        }
        """
        let new = """
        if (event === 'chat_updated') {
            store.saveChatDebounced(session.chat, sessionWorkspaceId, 'personas')
        }
        """

        let lines = EditDiff.lines(old: old, new: new)

        XCTAssertEqual(lines.map(\.kind), [.context, .deletion, .addition, .context])
        XCTAssertEqual(lines[1].content, "    store.saveHistoryDebounced()")
        XCTAssertEqual(
            lines[2].content,
            "    store.saveChatDebounced(session.chat, sessionWorkspaceId, 'personas')"
        )
    }

    /// An untouched line between two changes must not be reported as changed
    func testUnchangedLinesBetweenEditsStayContext() {
        let old = "a\nkeep\nb"
        let new = "A\nkeep\nB"

        let lines = EditDiff.lines(old: old, new: new)

        let context = lines.filter { $0.kind == .context }
        XCTAssertEqual(context.map(\.content), ["keep"])
        XCTAssertEqual(EditDiff.stats(lines).added, 2)
        XCTAssertEqual(EditDiff.stats(lines).removed, 2)
    }

    func testPureAdditionHasNothingOnTheLeft() {
        let lines = EditDiff.lines(old: "one\ntwo", new: "one\nmiddle\ntwo")

        XCTAssertEqual(lines.map(\.kind), [.context, .addition, .context])
        XCTAssertEqual(EditDiff.stats(lines) == (added: 1, removed: 0), true)
    }

    func testAWholeNewFileIsAllAdditions() {
        let lines = EditDiff.lines(old: "", new: "let a = 1\nlet b = 2\n")

        XCTAssertEqual(lines.map(\.kind), [.addition, .addition])
        XCTAssertEqual(EditDiff.stats(lines).removed, 0)
    }

    /// A trailing newline ends the last line; it does not add an empty one
    func testTrailingNewlineDoesNotBecomeALine() {
        XCTAssertEqual(EditDiff.splitLines("a\nb\n"), ["a", "b"])
        XCTAssertEqual(EditDiff.splitLines(""), [])
        XCTAssertEqual(EditDiff.splitLines("\n"), [""])
    }

    /// Beyond the matching limit the edit is shown as a rewrite rather than hanging
    /// on a quadratic table
    func testVeryLargeEditsFallBackToWholesaleReplacement() {
        let limit = EditDiff.maximumLinesForLineMatching
        let old = (0..<(limit + 10)).map(String.init).joined(separator: "\n")
        let new = (0..<(limit + 10)).map { String($0 * 2) }.joined(separator: "\n")

        let lines = EditDiff.lines(old: old, new: new)

        XCTAssertEqual(lines.filter { $0.kind == .deletion }.count, limit + 10)
        XCTAssertEqual(lines.filter { $0.kind == .addition }.count, limit + 10)
        XCTAssertTrue(lines.allSatisfy { $0.kind != .context })
    }

    // MARK: - Line numbers

    func testNumbersLinesFromWhereTheEditSitsInTheFile() {
        let lines = EditDiff.lines(old: "b\nc", new: "b\nC", startLine: 10)

        XCTAssertEqual(lines[0].oldLineNumber, 10)   // context "b"
        XCTAssertEqual(lines[0].newLineNumber, 10)
        XCTAssertEqual(lines[1].oldLineNumber, 11)   // removed "c"
        XCTAssertNil(lines[1].newLineNumber)
        XCTAssertEqual(lines[2].newLineNumber, 11)   // added "C"
        XCTAssertNil(lines[2].oldLineNumber)
    }

    func testWithoutAKnownStartTheGutterStaysEmpty() {
        let lines = EditDiff.lines(old: "a", new: "b")

        XCTAssertTrue(lines.allSatisfy { $0.oldLineNumber == nil && $0.newLineNumber == nil })
    }

    func testFindsTheLineTheEditStartsOn() {
        let contents = "one\ntwo\nthree\nfour\n"

        XCTAssertEqual(EditDiff.startLine(of: "three", in: contents), 3)
        XCTAssertEqual(EditDiff.startLine(of: "two\nthree", in: contents), 2)
        XCTAssertEqual(EditDiff.startLine(of: "one", in: contents), 1)
    }

    /// A wrong line number is worse than none, so ambiguity yields nothing
    func testAmbiguousOrMissingTextIsNotNumbered() {
        let contents = "dup\nother\ndup\n"

        XCTAssertNil(EditDiff.startLine(of: "dup", in: contents), "two matches: unknowable")
        XCTAssertNil(EditDiff.startLine(of: "absent", in: contents))
        XCTAssertNil(EditDiff.startLine(of: "", in: contents))
    }

    func testReadsTheLineNumberFromARealFile() throws {
        let path = NSTemporaryDirectory() + "skwad-diff-\(UUID().uuidString).txt"
        try "alpha\nbeta\ngamma\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertEqual(EditDiff.startLine(of: "gamma", inFileAt: path), 3)
        XCTAssertNil(EditDiff.startLine(of: "gamma", inFileAt: path + "-missing"))
    }

    // MARK: - Building a whole call's diffs

    /// What the chat actually renders: every edit in the call, numbered off disk
    func testBuildsANumberedDiffPerEdit() throws {
        let path = NSTemporaryDirectory() + "skwad-build-\(UUID().uuidString).swift"
        try "header\nlet a = 1\nfooter\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let diffs = EditDiff.build([
            ToolEdit(filePath: path, oldString: "let a = 1", newString: "let a = 2"),
            // Text that is not in the file cannot be numbered, but still diffs
            ToolEdit(filePath: path, oldString: "gone", newString: "replaced"),
        ])

        XCTAssertEqual(diffs.count, 2)
        XCTAssertEqual(diffs[0].map(\.kind), [.deletion, .addition])
        XCTAssertEqual(diffs[0][0].oldLineNumber, 2, "the edit sits on line 2 of the file")
        XCTAssertEqual(diffs[0][1].newLineNumber, 2)
        XCTAssertNil(diffs[1][0].oldLineNumber, "absent text must not be given a number")
    }

    func testBuildingNothingYieldsNothing() {
        XCTAssertTrue(EditDiff.build([]).isEmpty)
    }

    // MARK: - Pulling edits off a tool call

    func testReadsAnEditToolsBeforeAndAfter() {
        let edits = ToolUseFormatter.edits(toolName: "Edit", input: [
            "file_path": "/tmp/a.swift",
            "old_string": "let a = 1",
            "new_string": "let a = 2",
        ])

        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0].filePath, "/tmp/a.swift")
        XCTAssertEqual(edits[0].oldString, "let a = 1")
        XCTAssertFalse(edits[0].isNewFile)
    }

    func testAWriteIsAnEditWithNothingBefore() {
        let edits = ToolUseFormatter.edits(toolName: "Write", input: [
            "file_path": "/tmp/new.swift",
            "content": "let a = 1\n",
        ])

        XCTAssertEqual(edits.count, 1)
        XCTAssertTrue(edits[0].isNewFile)
        XCTAssertEqual(edits[0].newString, "let a = 1\n")
    }

    func testMultiEditCarriesEveryChange() {
        let edits = ToolUseFormatter.edits(toolName: "MultiEdit", input: [
            "file_path": "/tmp/a.swift",
            "edits": [
                ["old_string": "one", "new_string": "1"],
                ["old_string": "two", "new_string": "2"],
            ],
        ])

        XCTAssertEqual(edits.map(\.oldString), ["one", "two"])
        XCTAssertTrue(edits.allSatisfy { $0.filePath == "/tmp/a.swift" })
    }

    func testToolsThatChangeNothingHaveNoDiff() {
        XCTAssertTrue(ToolUseFormatter.edits(
            toolName: "Read", input: ["file_path": "/tmp/a.swift"]
        ).isEmpty)
        XCTAssertTrue(ToolUseFormatter.edits(
            toolName: "Bash", input: ["command": "ls"]
        ).isEmpty)
        // Malformed input must not produce a half-built diff
        XCTAssertTrue(ToolUseFormatter.edits(
            toolName: "Edit", input: ["file_path": "/tmp/a.swift"]
        ).isEmpty)
    }
}
