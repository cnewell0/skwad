import Foundation
import Observation

/// Editing state for one file selected from the active worktree's changes.
/// All filesystem access remains scoped by WorkspaceFileService.
@Observable
@MainActor
final class WorkspaceFileEditorModel {
    private let service: WorkspaceFileService
    private var savedText = ""

    private(set) var relativePath: String?
    var text = ""
    private(set) var errorMessage: String?

    var hasUnsavedChanges: Bool {
        relativePath != nil && text != savedText
    }

    init(service: WorkspaceFileService) {
        self.service = service
    }

    @discardableResult
    func select(relativePath: String, discardingUnsavedChanges: Bool = false) -> Bool {
        if hasUnsavedChanges,
           self.relativePath != relativePath,
           !discardingUnsavedChanges {
            errorMessage = "Save or discard the current edits before opening another file."
            return false
        }
        if hasUnsavedChanges,
           self.relativePath == relativePath,
           !discardingUnsavedChanges {
            return true
        }

        do {
            let loadedText = try service.read(relativePath: relativePath)
            self.relativePath = relativePath
            text = loadedText
            savedText = loadedText
            errorMessage = nil
            return true
        } catch {
            self.relativePath = nil
            text = ""
            savedText = ""
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let relativePath else { return false }
        do {
            try service.write(
                text,
                relativePath: relativePath,
                expectedCurrentContent: savedText
            )
            savedText = text
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func reload() {
        guard let relativePath else { return }
        select(relativePath: relativePath, discardingUnsavedChanges: true)
    }
}
