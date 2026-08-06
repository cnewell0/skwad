import Foundation
import Observation

@Observable
@MainActor
final class GitPanelViewModel {

    // MARK: - Published State

    private(set) var status: RepositoryStatus?
    private(set) var selectedFile: FileStatus?
    private(set) var selectedDiff: FileDiff?
    private(set) var showStagedDiff = false
    private(set) var isLoading = true
    private(set) var errorMessage: String?

    /// Work this session already committed. Without it the panel empties out the
    /// moment an agent commits, which reads as "nothing was done here".
    private(set) var committedFiles: [FileStatus] = []

    /// Bumped every time a refresh lands. Observers use this to react to
    /// on-disk changes (e.g. reloading the live editor when the agent edits files).
    private(set) var refreshRevision = 0

    // MARK: - Dependencies

    private let folder: String
    private let repository: GitRepository
    private let onStatsRefresh: () -> Void

    /// Commit this session started on, or nil when the session's start is unknown
    /// (a folder opened outside an agent, or a repo with no commits yet). Resolved on
    /// every refresh because the baseline is captured asynchronously.
    private let sessionBaseCommit: () -> String?

    /// One retry is enough to cover the panel opening before the baseline lands
    private var didRetryForBaseline = false

    private var fileWatcher: GitFileWatcher?

    // MARK: - Initialization

    init(
        folder: String,
        sessionBaseCommit: @escaping () -> String? = { nil },
        onStatsRefresh: @escaping () -> Void
    ) {
        self.folder = folder
        self.repository = GitRepository(path: folder)
        self.sessionBaseCommit = sessionBaseCommit
        self.onStatsRefresh = onStatsRefresh
    }

    // MARK: - Lifecycle

    func onAppear() {
        refresh()
        startWatching()
    }

    func onDisappear() {
        stopWatching()
    }

    // MARK: - File Watching

    private func startWatching() {
        fileWatcher = GitFileWatcher(path: folder) { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        fileWatcher?.start()
    }

    private func stopWatching() {
        fileWatcher?.stop()
        fileWatcher = nil
    }

    // MARK: - Refresh

    func refresh() {
        fileWatcher?.pause()

        if status == nil {
            isLoading = true
        }
        errorMessage = nil

        // Capture repository for use in detached task
        let repo = repository
        let base = sessionBaseCommit()

        Task.detached(priority: .userInitiated) {
            let newStatus = repo.status()
            // Anything still in the working tree is listed by status(); this is only
            // the work that has already been committed out of it.
            let committed = base.map { repo.committedFiles(since: $0) } ?? []
            let stillDirty = Set(newStatus.files.map(\.path))
            let committedOnly = committed.filter { !stillDirty.contains($0.path) }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.status = newStatus
                self.committedFiles = committedOnly
                self.isLoading = false
                self.refreshRevision += 1
                self.onStatsRefresh()

                if let selected = self.selectedFile,
                   !newStatus.files.contains(where: { $0.path == selected.path }),
                   !committedOnly.contains(where: { $0.path == selected.path }) {
                    self.selectedFile = nil
                    self.selectedDiff = nil
                } else if let selected = self.selectedFile,
                          committedOnly.contains(where: { $0.path == selected.path }) {
                    // A committed file has no working-tree diff to re-read
                    self.selectCommittedFile(selected)
                } else if let selected = self.selectedFile {
                    // Re-read the diff so the review pane tracks live edits on disk
                    self.selectFile(selected, staged: self.showStagedDiff)
                }

                AsyncDelay.dispatch(after: TimingConstants.gitFileWatcherResume) { [weak self] in
                    self?.fileWatcher?.resume()
                }

                // Opening the panel is what triggers the first stats refresh, which is
                // what captures the baseline — so the first pass often runs without one.
                if base == nil, !self.didRetryForBaseline {
                    self.didRetryForBaseline = true
                    AsyncDelay.dispatch(after: 0.8) { [weak self] in
                        guard let self, self.sessionBaseCommit() != nil else { return }
                        self.refresh()
                    }
                }
            }
        }
    }

    // MARK: - Selection

    func selectFile(_ file: FileStatus, staged: Bool) {
        selectedFile = file
        showStagedDiff = staged

        // Capture repository for use in detached task
        let repo = repository

        Task.detached(priority: .userInitiated) {
            let diffs = repo.diff(for: file.path, staged: staged)

            await MainActor.run { [weak self] in
                self?.selectedDiff = diffs.first
            }
        }
    }

    /// Show what the session committed to this file, diffed against the commit the
    /// session started on.
    func selectCommittedFile(_ file: FileStatus) {
        selectedFile = file
        showStagedDiff = false

        guard let base = sessionBaseCommit() else {
            selectedDiff = nil
            return
        }
        let repo = repository

        Task.detached(priority: .userInitiated) {
            let diff = repo.committedDiff(for: file.path, since: base)

            await MainActor.run { [weak self] in
                self?.selectedDiff = diff
            }
        }
    }

    // MARK: - Git Operations

    func stage(_ paths: [String]) {
        performGitOperation {
            try self.repository.stage(paths)
        }
    }

    func unstage(_ paths: [String]) {
        performGitOperation {
            try self.repository.unstage(paths)
        }
    }

    func stageAll() {
        performGitOperation {
            try self.repository.stageAll()
        }
    }

    func unstageAll() {
        performGitOperation {
            try self.repository.unstageAll()
        }
    }

    func discard(_ paths: [String]) {
        performGitOperation {
            try self.repository.discardChanges(paths)
        }
    }

    // MARK: - Private Helpers

    private func performGitOperation(_ operation: () throws -> Void) {
        do {
            try operation()
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
