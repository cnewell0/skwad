import SwiftUI

enum ChangesWorkspaceSizing {
    static let defaultPanelWidth: CGFloat = 560
    static let minimumPanelWidth: CGFloat = 440
    static let maximumPanelWidth: CGFloat = 1_200

    static func panelWidth(start: CGFloat, translation: CGFloat) -> CGFloat {
        min(maximumPanelWidth, max(minimumPanelWidth, start - translation))
    }

    static func leadingLength(
        total: CGFloat,
        preferredFraction: CGFloat,
        dividerThickness: CGFloat,
        minimumLeading: CGFloat,
        minimumTrailing: CGFloat
    ) -> CGFloat {
        let available = max(0, total - dividerThickness)
        let required = minimumLeading + minimumTrailing

        guard required > 0 else { return available * preferredFraction.clamped(to: 0...1) }
        guard available >= required else {
            return available * (minimumLeading / required)
        }

        let preferred = available * preferredFraction.clamped(to: 0...1)
        return min(available - minimumTrailing, max(minimumLeading, preferred))
    }

    static func fraction(
        forLeadingLength leadingLength: CGFloat,
        total: CGFloat,
        dividerThickness: CGFloat
    ) -> CGFloat {
        let available = max(0, total - dividerThickness)
        guard available > 0 else { return 0.5 }
        return (leadingLength / available).clamped(to: 0...1)
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(limits.upperBound, max(limits.lowerBound, self))
    }
}

/// Sliding panel showing git status and diffs for the current agent's folder
struct GitPanelView: View {
    private enum PanelMode: String, CaseIterable, Identifiable {
        case review = "Review"
        case edit = "Edit"

        var id: String { rawValue }
    }

    private enum DetailLayout {
        case sideBySide
        case stacked
        case detailOnly

        var iconName: String {
            switch self {
            case .sideBySide: "rectangle.split.2x1"
            case .stacked: "rectangle.split.1x2"
            case .detailOnly: "rectangle"
            }
        }
    }

    private enum DetailSplitAxis {
        case horizontal
        case vertical

        var accessibilityLabel: String {
            switch self {
            case .horizontal: "Resize file list width"
            case .vertical: "Resize file list height"
            }
        }
    }

    let folder: String
    let onUnsavedChangesChange: (Bool) -> Void
    let onClose: () -> Void

    @Environment(AgentManager.self) var agentManager
    @ObservedObject private var settings = AppSettings.shared
    @State private var viewModel: GitPanelViewModel?
    @State private var editorModel: WorkspaceFileEditorModel?
    @State private var panelWidth: CGFloat = ChangesWorkspaceSizing.defaultPanelWidth
    @State private var panelDragStartWidth: CGFloat?
    @State private var isResizeHandleHovered = false
    @State private var sideFileListFraction: CGFloat = 0.4
    @State private var stackedFileListFraction: CGFloat = 0.36
    @State private var detailDragStartLeading: CGFloat?
    @State private var isDetailResizeHandleHovered = false
    @State private var showCommitSheet = false
    @State private var mode: PanelMode = .review
    @State private var detailLayout: DetailLayout = .sideBySide
    @State private var pendingFileSelection: (file: FileStatus, staged: Bool)?
    @State private var pendingMode: PanelMode?
    @State private var pendingClose = false
    @State private var showDiscardEditorAlert = false
    @State private var listSource: FileListSource = .changes
    @State private var fileFilter = ""
    @State private var searchService = FileSearchService()

    init(
        folder: String,
        onUnsavedChangesChange: @escaping (Bool) -> Void = { _ in },
        onClose: @escaping () -> Void
    ) {
        self.folder = folder
        self.onUnsavedChangesChange = onUnsavedChangesChange
        self.onClose = onClose
    }

    private var backgroundColor: Color {
        settings.effectiveBackgroundColor
    }

    var body: some View {
        HStack(spacing: 0) {
            resizeHandle

            VStack(spacing: 0) {
                header

                Divider()
                    .background(Color.primary.opacity(0.2))

                if let vm = viewModel {
                    contentView(vm)
                }
            }
            .frame(width: panelWidth)
        }
        .background(backgroundColor)
        .onAppear {
            let vm = GitPanelViewModel(folder: folder) { [weak agentManager] in
                agentManager?.refreshGitStats(forFolder: folder)
            }
            viewModel = vm
            editorModel = WorkspaceFileEditorModel(
                service: WorkspaceFileService(rootURL: URL(fileURLWithPath: folder))
            )
            vm.onAppear()
        }
        .onDisappear {
            viewModel?.onDisappear()
            onUnsavedChangesChange(false)
        }
        .sheet(isPresented: $showCommitSheet) {
            CommitSheet(folder: folder) {
                viewModel?.refresh()
            }
        }
        .onChange(of: mode) { _, newMode in
            guard newMode == .edit,
                  let path = viewModel?.selectedFile?.path else { return }
            requestEditorSelection(path)
        }
        .onChange(of: viewModel?.refreshRevision ?? 0) { _, _ in
            // Agent (or anything else) touched the worktree — refresh the live editor
            editorModel?.reloadIfClean()
        }
        .onChange(of: editorModel?.hasUnsavedChanges ?? false) { _, isDirty in
            onUnsavedChangesChange(isDirty)
        }
        .alert("Discard unsaved edits?", isPresented: $showDiscardEditorAlert) {
            Button("Cancel", role: .cancel) {
                pendingFileSelection = nil
                pendingMode = nil
                pendingClose = false
            }
            Button("Discard", role: .destructive) {
                if let pendingFileSelection {
                    editorModel?.select(
                        relativePath: pendingFileSelection.file.path,
                        discardingUnsavedChanges: true
                    )
                    viewModel?.selectFile(
                        pendingFileSelection.file,
                        staged: pendingFileSelection.staged
                    )
                } else if let pendingMode {
                    editorModel?.reload()
                    mode = pendingMode
                } else if pendingClose {
                    editorModel?.reload()
                    onUnsavedChangesChange(false)
                    onClose()
                }
                self.pendingFileSelection = nil
                self.pendingMode = nil
                self.pendingClose = false
            }
        } message: {
            Text("The current file has edits that have not been saved to the worktree.")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func contentView(_ vm: GitPanelViewModel) -> some View {
        if vm.isLoading {
            loadingView
        } else if let error = vm.errorMessage {
            errorView(error)
        } else if let status = vm.status {
            if status.isClean {
                cleanView
            } else {
                changesWorkspace(status: status, viewModel: vm)
            }
        }
    }

    @ViewBuilder
    private func changesWorkspace(status: RepositoryStatus, viewModel: GitPanelViewModel) -> some View {
        switch detailLayout {
        case .sideBySide:
            GeometryReader { geometry in
                let dividerThickness: CGFloat = 10
                let leadingLength = ChangesWorkspaceSizing.leadingLength(
                    total: geometry.size.width,
                    preferredFraction: sideFileListFraction,
                    dividerThickness: dividerThickness,
                    minimumLeading: 210,
                    minimumTrailing: 300
                )

                HStack(spacing: 0) {
                    fileListView(status: status, viewModel: viewModel)
                        .frame(width: leadingLength)

                    detailResizeHandle(
                        axis: .horizontal,
                        currentLeadingLength: leadingLength,
                        totalLength: geometry.size.width,
                        dividerThickness: dividerThickness,
                        fraction: $sideFileListFraction,
                        resetFraction: 0.4
                    )

                    detailView(viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .stacked:
            GeometryReader { geometry in
                let dividerThickness: CGFloat = 10
                let leadingLength = ChangesWorkspaceSizing.leadingLength(
                    total: geometry.size.height,
                    preferredFraction: stackedFileListFraction,
                    dividerThickness: dividerThickness,
                    minimumLeading: 150,
                    minimumTrailing: 240
                )

                VStack(spacing: 0) {
                    fileListView(status: status, viewModel: viewModel)
                        .frame(height: leadingLength)

                    detailResizeHandle(
                        axis: .vertical,
                        currentLeadingLength: leadingLength,
                        totalLength: geometry.size.height,
                        dividerThickness: dividerThickness,
                        fraction: $stackedFileListFraction,
                        resetFraction: 0.36
                    )

                    detailView(viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        case .detailOnly:
            detailView(viewModel)
        }
    }

    @ViewBuilder
    private func detailView(_ viewModel: GitPanelViewModel) -> some View {
        if mode == .review {
            diffDetailView(viewModel: viewModel)
        } else {
            editorDetailView
        }
    }

    // MARK: - Resize Handle

    private var resizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(isResizeHandleHovered ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07))

            Capsule()
                .fill(isResizeHandleHovered ? Color.accentColor : Color.secondary.opacity(0.45))
                .frame(width: 3, height: 42)
        }
            .frame(width: 12)
            .contentShape(Rectangle())
            .gesture(
                // Global coordinate space: the handle moves with the panel edge,
                // so local translation would fight the drag and jitter.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if panelDragStartWidth == nil {
                            panelDragStartWidth = panelWidth
                        }
                        panelWidth = ChangesWorkspaceSizing.panelWidth(
                            start: panelDragStartWidth ?? panelWidth,
                            translation: value.translation.width
                        )
                    }
                    .onEnded { _ in panelDragStartWidth = nil }
            )
            .onTapGesture(count: 2) {
                panelWidth = ChangesWorkspaceSizing.defaultPanelWidth
            }
            .onHover { hovering in
                isResizeHandleHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Resize Changes panel")
            .accessibilityValue("\(Int(panelWidth)) points wide")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    panelWidth = ChangesWorkspaceSizing.panelWidth(start: panelWidth, translation: -40)
                case .decrement:
                    panelWidth = ChangesWorkspaceSizing.panelWidth(start: panelWidth, translation: 40)
                @unknown default:
                    break
                }
            }
    }

    private func detailResizeHandle(
        axis: DetailSplitAxis,
        currentLeadingLength: CGFloat,
        totalLength: CGFloat,
        dividerThickness: CGFloat,
        fraction: Binding<CGFloat>,
        resetFraction: CGFloat
    ) -> some View {
        ZStack {
            Rectangle()
                .fill(isDetailResizeHandleHovered ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07))

            Capsule()
                .fill(isDetailResizeHandleHovered ? Color.accentColor : Color.secondary.opacity(0.45))
                .frame(
                    width: axis == .horizontal ? 3 : 42,
                    height: axis == .horizontal ? 42 : 3
                )
        }
        .frame(
            width: axis == .horizontal ? dividerThickness : nil,
            height: axis == .vertical ? dividerThickness : nil
        )
        .frame(
            maxWidth: axis == .vertical ? .infinity : nil,
            maxHeight: axis == .horizontal ? .infinity : nil
        )
        .contentShape(Rectangle())
        .gesture(
            // Global coordinate space: the divider moves as the fraction changes,
            // so local translation would fight the drag and jitter.
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if detailDragStartLeading == nil {
                        detailDragStartLeading = currentLeadingLength
                    }
                    let translation = axis == .horizontal
                        ? value.translation.width
                        : value.translation.height
                    fraction.wrappedValue = ChangesWorkspaceSizing.fraction(
                        forLeadingLength: (detailDragStartLeading ?? currentLeadingLength) + translation,
                        total: totalLength,
                        dividerThickness: dividerThickness
                    )
                }
                .onEnded { _ in detailDragStartLeading = nil }
        )
        .onTapGesture(count: 2) {
            fraction.wrappedValue = resetFraction
        }
        .onHover { hovering in
            isDetailResizeHandleHovered = hovering
            if hovering {
                (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(axis.accessibilityLabel)
        .accessibilityValue("\(Int(fraction.wrappedValue * 100)) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                fraction.wrappedValue = (fraction.wrappedValue + 0.05).clamped(to: 0...1)
            case .decrement:
                fraction.wrappedValue = (fraction.wrappedValue - 0.05).clamped(to: 0...1)
            @unknown default:
                break
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Changes")
                .font(.headline)
                .foregroundColor(.primary)

                Text(URL(fileURLWithPath: folder).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Picker("Changes mode", selection: Binding(
                get: { mode },
                set: { requestMode($0) }
            )) {
                ForEach(PanelMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            Menu("Change detail layout", systemImage: detailLayout.iconName) {
                Button("Side by side", systemImage: "rectangle.split.2x1") {
                    detailLayout = .sideBySide
                }
                Button("Stacked", systemImage: "rectangle.split.1x2") {
                    detailLayout = .stacked
                }
                Button(mode == .edit ? "Editor only" : "Diff only", systemImage: "rectangle") {
                    detailLayout = .detailOnly
                }
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .help("Change file and detail layout")

            if let status = viewModel?.status, status.hasStaged {
                Button {
                    showCommitSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle")
                        Text("Commit")
                    }
                    .font(.caption)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.8))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Commit staged changes")
            }

            Button {
                viewModel?.refresh()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh")

            Button {
                requestClose()
            } label: {
                Image(systemName: "xmark")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.05))
    }

    // MARK: - States

    private var loadingView: some View {
        VStack {
            ProgressView()
            Text("Loading...")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)
            Text(message)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cleanView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.largeTitle)
                .foregroundColor(.green)
            Text("Working tree clean")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File List

    private func fileListView(status: RepositoryStatus, viewModel: GitPanelViewModel) -> some View {
        VStack(spacing: 0) {
            if let branch = status.branch {
                branchInfoView(branch: branch, status: status)
            }

            listControls

            if listSource == .all {
                WorkspaceFileBrowser(
                    tree: FileTreeIndex(paths: searchService.cachedFiles),
                    filterResults: fileFilter.isEmpty ? nil : searchService.results,
                    changeMarks: Self.changeMarks(for: status),
                    onSelect: { path in openBrowsedFile(path, viewModel: viewModel) }
                )
                .task(id: folder) { await searchService.loadFiles(in: folder) }
                .onChange(of: fileFilter) { _, pattern in
                    Task { await searchService.search(pattern: pattern) }
                }
            } else {
                changesListView(status: status, viewModel: viewModel)
            }
        }
    }

    private var listControls: some View {
        HStack(spacing: 8) {
            Picker("File list", selection: $listSource) {
                ForEach(FileListSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("Filter files", text: $fileFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .accessibilityLabel("Filter files")
                if !fileFilter.isEmpty {
                    Button {
                        fileFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Changed files matching the filter text; empty filter passes everything.
    static func filtered(_ files: [FileStatus], by filter: String) -> [FileStatus] {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return files }
        return files.filter { $0.path.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Status letter and colour for every path that currently has a diff
    static func changeMarks(for status: RepositoryStatus) -> [String: (symbol: String, color: Color)] {
        var marks: [String: (symbol: String, color: Color)] = [:]
        for file in status.stagedFiles { marks[file.path] = (mark(of: file), .green) }
        for file in status.modifiedFiles { marks[file.path] = (mark(of: file), .orange) }
        for file in status.untrackedFiles { marks[file.path] = ("U", .gray) }
        for file in status.conflictedFiles { marks[file.path] = ("!", .red) }
        return marks
    }

    private static func mark(of file: FileStatus) -> String {
        file.stagedStatus?.symbol ?? file.unstagedStatus?.symbol ?? "M"
    }

    /// Open a file picked in the browser: files with a diff behave like the Changes
    /// list; anything else is viewed in the editor.
    private func openBrowsedFile(_ path: String, viewModel: GitPanelViewModel) {
        if let file = viewModel.status?.files.first(where: { $0.path == path }) {
            let staged = file.stagedStatus != nil && file.unstagedStatus == nil
            select(file, staged: staged, viewModel: viewModel)
        } else {
            if mode != .edit { requestMode(.edit) }
            requestEditorSelection(path)
        }
    }

    private func changesListView(status: RepositoryStatus, viewModel: GitPanelViewModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                if !Self.filtered(status.stagedFiles, by: fileFilter).isEmpty {
                    fileSection(
                        title: "Staged Changes",
                        files: Self.filtered(status.stagedFiles, by: fileFilter),
                        isStaged: true,
                        color: .green,
                        viewModel: viewModel
                    )
                }

                if !Self.filtered(status.modifiedFiles, by: fileFilter).isEmpty {
                    fileSection(
                        title: "Changes",
                        files: Self.filtered(status.modifiedFiles, by: fileFilter),
                        isStaged: false,
                        color: .orange,
                        viewModel: viewModel
                    )
                }

                if !Self.filtered(status.untrackedFiles, by: fileFilter).isEmpty {
                    fileSection(
                        title: "Untracked",
                        files: Self.filtered(status.untrackedFiles, by: fileFilter),
                        isStaged: false,
                        color: .gray,
                        viewModel: viewModel
                    )
                }

                if !Self.filtered(status.conflictedFiles, by: fileFilter).isEmpty {
                    fileSection(
                        title: "Conflicts",
                        files: Self.filtered(status.conflictedFiles, by: fileFilter),
                        isStaged: false,
                        color: .red,
                        viewModel: viewModel
                    )
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func branchInfoView(branch: String, status: RepositoryStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundColor(.secondary)

            Text(branch)
                .fontWeight(.medium)
                .foregroundColor(.primary)

            if status.ahead > 0 {
                Text("↑\(status.ahead)")
                    .font(.caption)
                    .foregroundColor(.green)
            }

            if status.behind > 0 {
                Text("↓\(status.behind)")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05))
    }

    private func fileSection(
        title: String,
        files: [FileStatus],
        isStaged: Bool,
        color: Color,
        viewModel: GitPanelViewModel
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Text("(\(files.count))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                if isStaged {
                    Button("Unstage All") {
                        viewModel.unstageAll()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                } else if title == "Changes" {
                    Button("Stage All") {
                        viewModel.stageAll()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ForEach(files) { file in
                FileRowView(
                    file: file,
                    isSelected: viewModel.selectedFile?.path == file.path && viewModel.showStagedDiff == isStaged,
                    color: color,
                    onSelect: {
                        select(file, staged: isStaged, viewModel: viewModel)
                    },
                    onStage: isStaged ? nil : {
                        viewModel.stage([file.path])
                    },
                    onUnstage: isStaged ? {
                        viewModel.unstage([file.path])
                    } : nil,
                    onDiscard: !isStaged && !file.isUntracked && editorModel?.hasUnsavedChanges != true ? {
                        viewModel.discard([file.path])
                    } : nil
                )
            }
        }
    }

    // MARK: - Diff Detail

    private func diffDetailView(viewModel: GitPanelViewModel) -> some View {
        Group {
            if let diff = viewModel.selectedDiff {
                VStack(spacing: 0) {
                    HStack {
                        Text(diff.path)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)
                            .foregroundColor(.primary)

                        Spacer()

                        if diff.additions > 0 {
                            Text("+\(diff.additions)")
                                .foregroundColor(.green)
                                .font(.caption.monospaced())
                        }
                        if diff.deletions > 0 {
                            Text("-\(diff.deletions)")
                                .foregroundColor(.red)
                                .font(.caption.monospaced())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.primary.opacity(0.05))

                    DiffView(diff: diff)
                }
            } else {
                VStack {
                    Image(systemName: "doc.text")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Select a file to view diff")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var editorDetailView: some View {
        if let editorModel, let path = editorModel.relativePath {
            WorkspaceCodeEditorPane(model: editorModel) {
                viewModel?.refresh()
            }
            .id(path)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "pencil.and.outline")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)

                if let error = editorModel?.errorMessage {
                    Text(error)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Select a text file to edit it in this worktree")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func select(_ file: FileStatus, staged: Bool, viewModel: GitPanelViewModel) {
        if mode == .edit,
           editorModel?.hasUnsavedChanges == true,
           editorModel?.relativePath != file.path {
            pendingFileSelection = (file, staged)
            showDiscardEditorAlert = true
            return
        }

        viewModel.selectFile(file, staged: staged)
        if mode == .edit {
            requestEditorSelection(file.path)
        }
    }

    private func requestEditorSelection(_ path: String) {
        guard editorModel?.select(relativePath: path) == false else { return }
        guard editorModel?.hasUnsavedChanges == true,
              editorModel?.relativePath != path else { return }
        if let file = viewModel?.status?.files.first(where: { $0.path == path }) {
            pendingFileSelection = (file, viewModel?.showStagedDiff ?? false)
            showDiscardEditorAlert = true
        }
    }

    private func requestMode(_ requestedMode: PanelMode) {
        guard requestedMode != mode else { return }
        if mode == .edit, editorModel?.hasUnsavedChanges == true {
            pendingMode = requestedMode
            showDiscardEditorAlert = true
        } else {
            mode = requestedMode
        }
    }

    private func requestClose() {
        guard editorModel?.hasUnsavedChanges == true else {
            onClose()
            return
        }
        pendingClose = true
        showDiscardEditorAlert = true
    }
}

// MARK: - File Row

struct FileRowView: View {
    let file: FileStatus
    let isSelected: Bool
    let color: Color
    let onSelect: () -> Void
    let onStage: (() -> Void)?
    let onUnstage: (() -> Void)?
    let onDiscard: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(statusSymbol)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(color)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isHovering {
                HStack(spacing: 4) {
                    if let onStage = onStage {
                        Button {
                            onStage()
                        } label: {
                            Image(systemName: "plus.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Stage")
                    }

                    if let onUnstage = onUnstage {
                        Button {
                            onUnstage()
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Unstage")
                    }

                    if let onDiscard = onDiscard {
                        Button {
                            onDiscard()
                        } label: {
                            Image(systemName: "arrow.uturn.backward.circle")
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Discard changes")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.3) : (isHovering ? Color.primary.opacity(0.1) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            isHovering = hovering
        }
    }

    private var statusSymbol: String {
        if let staged = file.stagedStatus, staged != .untracked {
            return staged.symbol
        }
        if let unstaged = file.unstagedStatus {
            return unstaged.symbol
        }
        return "?"
    }
}

#Preview("FileRow") {
    let staged = FileStatus(path: "Skwad/Views/ContentView.swift", originalPath: nil, stagedStatus: .modified, unstagedStatus: nil)
    let unstaged = FileStatus(path: "Skwad/Models/Agent.swift", originalPath: nil, stagedStatus: nil, unstagedStatus: .modified)
    let untracked = FileStatus(path: "Skwad/Views/NewView.swift", originalPath: nil, stagedStatus: .untracked, unstagedStatus: .untracked)
    let deleted = FileStatus(path: "Skwad/Old/Removed.swift", originalPath: nil, stagedStatus: .deleted, unstagedStatus: nil)

    VStack(spacing: 0) {
        FileRowView(file: staged, isSelected: true, color: .green, onSelect: {}, onStage: nil, onUnstage: {}, onDiscard: nil)
        FileRowView(file: unstaged, isSelected: false, color: .orange, onSelect: {}, onStage: {}, onUnstage: nil, onDiscard: {})
        FileRowView(file: untracked, isSelected: false, color: .gray, onSelect: {}, onStage: {}, onUnstage: nil, onDiscard: nil)
        FileRowView(file: deleted, isSelected: false, color: .green, onSelect: {}, onStage: nil, onUnstage: {}, onDiscard: nil)
    }
    .frame(width: 400)
}
