import Foundation

struct WorkspaceFileService: Sendable {
    let rootURL: URL
    let maximumFileSize: Int

    init(rootURL: URL, maximumFileSize: Int = 2 * 1024 * 1024) {
        self.rootURL = rootURL.standardizedFileURL
        self.maximumFileSize = maximumFileSize
    }

    func read(relativePath: String) throws -> String {
        let fileURL = try validatedURL(relativePath: relativePath)
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])

        guard values.isRegularFile == true else {
            throw WorkspaceFileError.notRegularFile
        }
        if let size = values.fileSize, size > maximumFileSize {
            throw WorkspaceFileError.fileTooLarge(maximumBytes: maximumFileSize)
        }

        let data = try Data(contentsOf: fileURL)
        guard data.count <= maximumFileSize else {
            throw WorkspaceFileError.fileTooLarge(maximumBytes: maximumFileSize)
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw WorkspaceFileError.notUTF8Text
        }
        return content
    }

    func write(_ content: String, relativePath: String) throws {
        let fileURL = try validatedURL(relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw WorkspaceFileError.fileNotFound
        }
        guard let data = content.data(using: .utf8) else {
            throw WorkspaceFileError.notUTF8Text
        }
        guard data.count <= maximumFileSize else {
            throw WorkspaceFileError.fileTooLarge(maximumBytes: maximumFileSize)
        }
        try data.write(to: fileURL, options: .atomic)
    }

    private func validatedURL(relativePath: String) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !(trimmed as NSString).isAbsolutePath else {
            throw WorkspaceFileError.outsideWorkspace
        }

        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let candidate = canonicalRoot.appending(path: trimmed).standardizedFileURL
        guard Self.contains(candidate, inside: canonicalRoot) else {
            throw WorkspaceFileError.outsideWorkspace
        }

        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard Self.contains(resolvedCandidate, inside: canonicalRoot) else {
            throw WorkspaceFileError.outsideWorkspace
        }
        return resolvedCandidate
    }

    private static func contains(_ candidate: URL, inside root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }
}
