import SwiftUI

/// Which files the Changes panel lists: only those with a diff, or the whole repo.
enum FileListSource: String, CaseIterable, Identifiable {
    case changes
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .changes: "Changes"
        case .all: "All files"
        }
    }
}

/// Lazy directory tree over a flat list of repo-relative paths.
///
/// Children are computed per directory on demand, so a 50k-file repo costs one sort
/// up front and nothing for directories that never get expanded.
struct FileTreeIndex {
    struct Entry: Identifiable, Equatable {
        let name: String
        /// Repo-relative path of the entry
        let path: String
        let isDirectory: Bool

        var id: String { path }
    }

    private let sortedPaths: [String]

    init(paths: [String]) {
        self.sortedPaths = paths.sorted()
    }

    var isEmpty: Bool { sortedPaths.isEmpty }

    /// Entries directly inside a directory ("" is the root). Directories first,
    /// each group alphabetical.
    func entries(in directory: String) -> [Entry] {
        let prefix = directory.isEmpty ? "" : directory + "/"
        var directories = Set<String>()
        var files: [String] = []

        for path in sortedPaths {
            guard path.hasPrefix(prefix), path.count > prefix.count else { continue }
            let remainder = path.dropFirst(prefix.count)
            if let slash = remainder.firstIndex(of: "/") {
                directories.insert(String(remainder[remainder.startIndex..<slash]))
            } else {
                files.append(String(remainder))
            }
        }

        return directories.sorted().map {
            Entry(name: $0, path: prefix + $0, isDirectory: true)
        } + files.map {
            Entry(name: $0, path: prefix + $0, isDirectory: false)
        }
    }
}

/// VS Code-style file browser for the Changes panel: the whole repo as a lazy tree,
/// a fuzzy filter above it, and diffed files marked with their status.
struct WorkspaceFileBrowser: View {
    let tree: FileTreeIndex
    let filterResults: [FileResult]?
    /// Status letter + colour for paths that currently have a diff
    let changeMarks: [String: (symbol: String, color: Color)]
    /// The file currently open in the detail pane, so the list shows where you are
    let selectedPath: String?
    let onSelect: (String) -> Void

    @State private var expanded: Set<String> = []

    /// Whether a row is the file open in the detail pane. Folders are never selected:
    /// clicking one expands it rather than opening anything.
    static func isSelected(path: String, selectedPath: String?, isDirectory: Bool) -> Bool {
        guard !isDirectory, let selectedPath, !selectedPath.isEmpty else { return false }
        return path == selectedPath
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let filterResults {
                    if filterResults.isEmpty {
                        Text("No files match")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    ForEach(filterResults) { result in
                        row(path: result.relativePath, name: result.relativePath, indent: 0, isDirectory: false)
                    }
                } else {
                    levelView(directory: "", indent: 0)
                }
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func levelView(directory: String, indent: Int) -> some View {
        ForEach(tree.entries(in: directory)) { entry in
            if entry.isDirectory {
                row(path: entry.path, name: entry.name, indent: indent, isDirectory: true)
                if expanded.contains(entry.path) {
                    AnyView(levelView(directory: entry.path, indent: indent + 1))
                }
            } else {
                row(path: entry.path, name: entry.name, indent: indent, isDirectory: false)
            }
        }
    }

    private func row(path: String, name: String, indent: Int, isDirectory: Bool) -> some View {
        let isSelected = Self.isSelected(path: path, selectedPath: selectedPath, isDirectory: isDirectory)
        return Button {
            if isDirectory {
                if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
            } else {
                onSelect(path)
            }
        } label: {
            HStack(spacing: 6) {
                if isDirectory {
                    Image(systemName: expanded.contains(path) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Spacer().frame(width: 10)
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if let mark = changeMarks[path] {
                    Text(mark.symbol)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(mark.color)
                }
            }
            .padding(.leading, CGFloat(12 + indent * 14))
            .padding(.trailing, 12)
            .padding(.vertical, 4)
            .background(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
                        }
                        .padding(.horizontal, 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDirectory ? "Folder \(name)" : "Open \(name)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
