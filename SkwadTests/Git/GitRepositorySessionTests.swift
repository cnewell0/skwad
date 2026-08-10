import XCTest
@testable import Skwad

/// Drives a real repository. The bug these cover — an agent's work disappearing from
/// the Changes panel the moment it committed and pushed — only exists in the
/// interaction with git itself, so a mocked git would not have caught it.
final class GitRepositorySessionTests: XCTestCase {

    private var root: String!
    private var repo: GitRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = NSTemporaryDirectory() + "skwad-session-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        repo = GitRepository(path: root)

        try git("init", "-b", "main")
        try write("README.md", "start\n")
        try commitAll("first")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        // Never depend on the machine's git identity or hooks
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
        ]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")): \(output)")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ name: String, _ contents: String) throws {
        try contents.write(
            toFile: (root as NSString).appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    private func commitAll(_ message: String) throws {
        try git("add", "-A")
        try git("commit", "-m", message)
    }

    // MARK: - Tests

    func testHeadCommitIsTheCommitTheSessionStartsOn() throws {
        let head = repo.headCommit()
        XCTAssertEqual(head, try git("rev-parse", "HEAD"))
    }

    /// The reported bug: agent commits and pushes, panel says "Working tree clean"
    func testCommittedWorkIsStillListedAfterTheWorkingTreeIsClean() throws {
        let base = try XCTUnwrap(repo.headCommit())

        try write("feature.swift", "let a = 1\n")
        try commitAll("agent work")

        XCTAssertTrue(repo.isClean(), "the working tree is clean once the agent commits")
        XCTAssertEqual(repo.committedFiles(since: base).map(\.path), ["feature.swift"])
    }

    func testCommittedWorkSurvivesSeveralCommits() throws {
        let base = try XCTUnwrap(repo.headCommit())

        try write("one.swift", "1\n")
        try commitAll("first change")
        try write("two.swift", "2\n")
        try commitAll("second change")

        XCTAssertEqual(
            Set(repo.committedFiles(since: base).map(\.path)),
            ["one.swift", "two.swift"]
        )
    }

    /// Work done before the session started belongs to whoever did it, not the agent
    func testWorkFromBeforeTheSessionIsNotClaimed() throws {
        try write("earlier.swift", "old\n")
        try commitAll("someone else's commit")

        let base = try XCTUnwrap(repo.headCommit())
        try write("mine.swift", "new\n")
        try commitAll("agent work")

        XCTAssertEqual(repo.committedFiles(since: base).map(\.path), ["mine.swift"])
    }

    func testCommittedDiffShowsTheLinesTheSessionCommitted() throws {
        let base = try XCTUnwrap(repo.headCommit())
        try write("README.md", "start\nadded by the agent\n")
        try commitAll("agent work")

        let diff = try XCTUnwrap(repo.committedDiff(for: "README.md", since: base))
        XCTAssertEqual(diff.path, "README.md")
        XCTAssertTrue(
            diff.hunks.flatMap(\.lines).contains { $0.content.contains("added by the agent") },
            "the added line should be in the diff"
        )
    }

    func testCommittedStatsCountTheSessionsCommits() throws {
        let base = try XCTUnwrap(repo.headCommit())
        try write("feature.swift", "a\nb\nc\n")
        try commitAll("agent work")

        let stats = repo.committedStats(since: base)
        XCTAssertEqual(stats.insertions, 3)
        XCTAssertEqual(stats.deletions, 0)
        XCTAssertEqual(stats.files, 1)
    }

    func testRenamesReportTheNewPath() throws {
        let base = try XCTUnwrap(repo.headCommit())
        try git("mv", "README.md", "GUIDE.md")
        try commitAll("rename")

        let file = try XCTUnwrap(repo.committedFiles(since: base).first)
        XCTAssertEqual(file.path, "GUIDE.md")
        XCTAssertEqual(file.originalPath, "README.md")
    }

    // MARK: - Worktree start point

    /// The durable base: a worktree remembers where it was cut from, so its work is
    /// still shown after the app is relaunched and after the branch is pushed.
    func testWorktreeRemembersWhereItStarted() throws {
        let start = try XCTUnwrap(repo.headCommit())
        let worktree = root + "-wt"
        try git("worktree", "add", "-b", "feature", worktree)
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        let wt = GitRepository(path: worktree)

        // The agent does its work and commits it
        try "changed\n".write(
            toFile: (worktree as NSString).appendingPathComponent("README.md"),
            atomically: true, encoding: .utf8
        )
        let commit = Process()
        commit.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        commit.arguments = ["git", "-C", worktree, "commit", "-am", "agent work"]
        commit.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
        ]) { _, new in new }
        commit.standardOutput = Pipe()
        commit.standardError = Pipe()
        try commit.run()
        commit.waitUntilExit()
        XCTAssertEqual(commit.terminationStatus, 0)

        XCTAssertEqual(wt.worktreeStartCommit(), start, "the worktree was cut from HEAD")
        XCTAssertTrue(wt.isClean(), "committed, so nothing is left in the working tree")
        // Which is the whole point: the work is still listed
        XCTAssertEqual(
            wt.committedFiles(since: try XCTUnwrap(wt.worktreeStartCommit())).map(\.path),
            ["README.md"]
        )
    }

    /// In a normal checkout the oldest reflog entry is the clone; diffing against it
    /// would show the entire history of the repository, so it reports nothing.
    func testPlainCheckoutHasNoWorktreeStart() {
        XCTAssertNil(repo.worktreeStartCommit())
    }

    /// A base that no longer exists (rebased away) must not throw or hang the panel
    func testUnknownBaseYieldsNothing() {
        XCTAssertTrue(repo.committedFiles(since: "0000000000000000000000000000000000000000").isEmpty)
        XCTAssertNil(repo.committedDiff(for: "README.md", since: "not-a-commit"))
        XCTAssertEqual(repo.committedStats(since: "").files, 0)
        XCTAssertTrue(repo.committedFiles(since: "").isEmpty)
    }
}
