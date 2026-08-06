import Foundation

/// High-level git repository operations
class GitRepository {
    let path: String
    private let cli = GitCLI.shared

    init(path: String) {
        self.path = path
    }

    // MARK: - Status

    /// Get full repository status
    func status() -> RepositoryStatus {
        let result = cli.run(["status", "--porcelain=v2", "--branch"], in: path)

        guard case .success(let output) = result else {
            return RepositoryStatus(branch: nil, upstream: nil, ahead: 0, behind: 0, files: [])
        }

        return GitOutputParser.parseStatus(output)
    }

    /// Check if working tree is clean
    func isClean() -> Bool {
        let result = cli.run(["status", "--porcelain"], in: path)
        guard case .success(let output) = result else { return false }
        return output.isEmpty
    }

    // MARK: - Diff

    /// Get diff for files (all or specific file)
    /// - Parameters:
    ///   - file: Specific file path, or nil for all files
    ///   - staged: If true, show staged changes; if false, show unstaged
    func diff(for file: String? = nil, staged: Bool = false) -> [FileDiff] {
        var args = ["diff", "--no-color"]
        if staged {
            args.append("--staged")
        }
        if let file = file {
            args.append("--")
            args.append(file)
        }

        let result = cli.run(args, in: path)
        guard case .success(let output) = result, !output.isEmpty else {
            return []
        }

        return GitOutputParser.parseDiff(output)
    }

    /// Get combined diff statistics (unstaged + staged) in minimal git calls
    func combinedDiffStats() -> GitLineStats {
        // One call for unstaged, one for staged
        let unstagedResult = cli.run(["diff", "--numstat"], in: path)
        let stagedResult = cli.run(["diff", "--staged", "--numstat"], in: path)

        var insertions = 0, deletions = 0
        // A file that is both staged and modified must count once, not twice
        var changedPaths = Set<String>()

        for result in [unstagedResult, stagedResult] {
            guard case .success(let output) = result else { continue }
            for entry in GitOutputParser.parseNumstatEntries(output) {
                insertions += entry.insertions
                deletions += entry.deletions
                changedPaths.insert(entry.path)
            }
        }
        var files = changedPaths.count

        // Untracked files: count lines directly instead of spawning git per file
        let untrackedFiles = status().untrackedFiles
        for file in untrackedFiles {
            let fullPath = (path as NSString).appendingPathComponent(file.path)
            if let data = FileManager.default.contents(atPath: fullPath),
               let content = String(data: data, encoding: .utf8) {
                let lineCount = content.isEmpty ? 0 : content.components(separatedBy: "\n").count
                insertions += lineCount
                files += 1
            } else {
                // Binary or unreadable file — just count it
                files += 1
            }
        }

        return GitLineStats(insertions: insertions, deletions: deletions, files: files)
    }

    // MARK: - Staging

    /// Stage files for commit
    func stage(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let args = ["add"] + paths
        let result = cli.run(args, in: path)
        if case .failure(let error) = result {
            throw error
        }
    }

    /// Unstage files (remove from index but keep changes)
    func unstage(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let args = ["restore", "--staged"] + paths
        let result = cli.run(args, in: path)
        if case .failure(let error) = result {
            throw error
        }
    }

    /// Stage all changes
    func stageAll() throws {
        let result = cli.run(["add", "-A"], in: path)
        if case .failure(let error) = result {
            throw error
        }
    }

    /// Unstage all files
    func unstageAll() throws {
        let result = cli.run(["reset", "HEAD"], in: path)
        if case .failure(let error) = result {
            throw error
        }
    }

    /// Discard changes in working directory for specific files
    func discardChanges(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let args = ["restore"] + paths
        let result = cli.run(args, in: path)
        if case .failure(let error) = result {
            throw error
        }
    }

    // MARK: - Commit

    /// Create a commit with the given message
    func commit(message: String) throws {
        let result = cli.run(["commit", "-m", message], in: path)
        if case .failure(let error) = result {
            throw error
        }
    }

    // MARK: - Branch Info

    /// Get current branch name
    func currentBranch() -> String? {
        let result = cli.run(["branch", "--show-current"], in: path)
        guard case .success(let output) = result, !output.isEmpty else {
            return nil
        }
        return output
    }

    /// Check if there are unpushed commits
    func hasUnpushedCommits() -> Bool {
        let result = cli.run(["log", "@{u}..", "--oneline"], in: path)
        guard case .success(let output) = result else {
            return false
        }
        return !output.isEmpty
    }

    /// Get ahead/behind count relative to upstream
    func aheadBehind() -> (ahead: Int, behind: Int) {
        let result = cli.run(["rev-list", "--left-right", "--count", "@{u}...HEAD"], in: path)
        guard case .success(let output) = result else {
            return (0, 0)
        }

        let parts = output.split(separator: "\t")
        guard parts.count == 2,
              let behind = Int(parts[0]),
              let ahead = Int(parts[1]) else {
            return (0, 0)
        }

        return (ahead, behind)
    }

    // MARK: - Session History

    /// The commit the working tree is sitting on, recorded when a session starts so
    /// its work can still be shown after it has been committed and pushed.
    func headCommit() -> String? {
        let result = cli.run(["rev-parse", "HEAD"], in: path)
        guard case .success(let output) = result, !output.isEmpty else { return nil }
        return output
    }

    /// Files the session changed and then committed.
    ///
    /// Only committed work: anything still in the working tree is already listed by
    /// `status()`, and showing it twice would be worse than not showing it at all.
    /// An unknown base (rebased away, or a fresh repo with no commits) yields nothing
    /// rather than an error — the panel falls back to the working tree.
    func committedFiles(since base: String) -> [FileStatus] {
        guard !base.isEmpty else { return [] }
        let result = cli.run(["diff", "--name-status", "\(base)..HEAD"], in: path)
        guard case .success(let output) = result, !output.isEmpty else { return [] }
        return GitOutputParser.parseNameStatus(output)
    }

    /// Diff of one file across everything the session committed
    func committedDiff(for file: String, since base: String) -> FileDiff? {
        guard !base.isEmpty else { return nil }
        let result = cli.run(["diff", "--no-color", "\(base)..HEAD", "--", file], in: path)
        guard case .success(let output) = result, !output.isEmpty else { return nil }
        return GitOutputParser.parseDiff(output).first
    }

    /// Line counts for everything the session committed, for the sidebar totals
    func committedStats(since base: String) -> GitLineStats {
        guard !base.isEmpty else { return GitLineStats(insertions: 0, deletions: 0, files: 0) }
        let result = cli.run(["diff", "--numstat", "\(base)..HEAD"], in: path)
        guard case .success(let output) = result else {
            return GitLineStats(insertions: 0, deletions: 0, files: 0)
        }
        var insertions = 0, deletions = 0, files = 0
        for entry in GitOutputParser.parseNumstatEntries(output) {
            insertions += entry.insertions
            deletions += entry.deletions
            files += 1
        }
        return GitLineStats(insertions: insertions, deletions: deletions, files: files)
    }
}

