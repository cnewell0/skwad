import Foundation

/// One file edit an agent made, taken straight from the tool's own input.
struct ToolEdit: Equatable, Sendable {
    let filePath: String
    let oldString: String
    let newString: String

    /// A file written whole has nothing on the left-hand side
    var isNewFile: Bool { oldString.isEmpty }
}

/// Turns an agent's edit into the red and green lines the agent's own terminal shows.
///
/// The transcript records only the before and after text — no line numbers, no diff —
/// so the diff is computed here, and the numbers are looked up in the file itself
/// rather than guessed.
enum EditDiff {

    /// Above this, the quadratic table is not worth building: the whole edit is shown
    /// as a removal followed by an addition, which is what a wholesale rewrite is.
    static let maximumLinesForLineMatching = 600

    /// Line-by-line diff of an edit.
    /// - Parameter startLine: the file line `old` begins at, when it is known. Numbers
    ///   are omitted entirely rather than invented when it is not.
    static func lines(old: String, new: String, startLine: Int? = nil) -> [DiffLine] {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)

        let operations = diffOperations(oldLines, newLines)

        var result: [DiffLine] = []
        var oldNumber = startLine
        var newNumber = startLine
        for operation in operations {
            switch operation.kind {
            case .context:
                result.append(DiffLine(
                    kind: .context, content: operation.text,
                    oldLineNumber: oldNumber, newLineNumber: newNumber
                ))
                oldNumber = oldNumber.map { $0 + 1 }
                newNumber = newNumber.map { $0 + 1 }
            case .deletion:
                result.append(DiffLine(
                    kind: .deletion, content: operation.text,
                    oldLineNumber: oldNumber, newLineNumber: nil
                ))
                oldNumber = oldNumber.map { $0 + 1 }
            case .addition:
                result.append(DiffLine(
                    kind: .addition, content: operation.text,
                    oldLineNumber: nil, newLineNumber: newNumber
                ))
                newNumber = newNumber.map { $0 + 1 }
            }
        }
        return result
    }

    /// Diffs for a whole tool call, numbered from the files on disk.
    ///
    /// Reads files, so it belongs off the main thread — the view calls it from a task.
    static func build(_ edits: [ToolEdit]) -> [[DiffLine]] {
        edits.map { edit in
            lines(
                old: edit.oldString,
                new: edit.newString,
                startLine: startLine(of: edit.oldString, inFileAt: edit.filePath)
            )
        }
    }

    static func stats(_ lines: [DiffLine]) -> (added: Int, removed: Int) {
        (
            lines.filter { $0.kind == .addition }.count,
            lines.filter { $0.kind == .deletion }.count
        )
    }

    /// The 1-based line `text` starts on in the file as it is now.
    ///
    /// Returns nil when the text is absent (a later edit replaced it) or appears more
    /// than once — either way the true line is unknown, and a wrong number is worse
    /// than none.
    static func startLine(of text: String, inFileAt path: String) -> Int? {
        guard !text.isEmpty,
              let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return startLine(of: text, in: contents)
    }

    static func startLine(of text: String, in contents: String) -> Int? {
        guard !text.isEmpty else { return nil }
        let haystack = splitLines(contents)
        let needle = splitLines(text)
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }

        var found: Int?
        for start in 0...(haystack.count - needle.count) {
            guard Array(haystack[start..<(start + needle.count)]) == needle else { continue }
            if found != nil { return nil }  // ambiguous
            found = start + 1
        }
        return found
    }

    // MARK: - Diff

    private enum OperationKind { case context, deletion, addition }
    private struct Operation { let kind: OperationKind; let text: String }

    /// Longest-common-subsequence diff, so untouched lines inside an edit stay as
    /// context instead of being reported as a delete and an add of the same text.
    private static func diffOperations(_ old: [String], _ new: [String]) -> [Operation] {
        guard old.count <= maximumLinesForLineMatching,
              new.count <= maximumLinesForLineMatching else {
            return old.map { Operation(kind: .deletion, text: $0) }
                + new.map { Operation(kind: .addition, text: $0) }
        }

        // lengths[i][j] = LCS length of old[i...] and new[j...]
        var lengths = [[Int]](
            repeating: [Int](repeating: 0, count: new.count + 1),
            count: old.count + 1
        )
        if !old.isEmpty && !new.isEmpty {
            for i in stride(from: old.count - 1, through: 0, by: -1) {
                for j in stride(from: new.count - 1, through: 0, by: -1) {
                    lengths[i][j] = old[i] == new[j]
                        ? lengths[i + 1][j + 1] + 1
                        : max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }

        var operations: [Operation] = []
        var i = 0, j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                operations.append(Operation(kind: .context, text: old[i]))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                operations.append(Operation(kind: .deletion, text: old[i]))
                i += 1
            } else {
                operations.append(Operation(kind: .addition, text: new[j]))
                j += 1
            }
        }
        while i < old.count {
            operations.append(Operation(kind: .deletion, text: old[i]))
            i += 1
        }
        while j < new.count {
            operations.append(Operation(kind: .addition, text: new[j]))
            j += 1
        }
        return operations
    }

    /// A trailing newline ends the last line rather than starting an empty one
    static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
