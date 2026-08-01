import Foundation

enum WorkspaceFileError: Error, Equatable, LocalizedError {
    case outsideWorkspace
    case notRegularFile
    case notUTF8Text
    case fileTooLarge(maximumBytes: Int)
    case fileNotFound

    var errorDescription: String? {
        switch self {
        case .outsideWorkspace:
            "The selected file is outside this workspace."
        case .notRegularFile:
            "The selected item is not a regular file."
        case .notUTF8Text:
            "This file is not editable UTF-8 text."
        case .fileTooLarge(let maximumBytes):
            "This file is larger than the \(maximumBytes)-byte editing limit."
        case .fileNotFound:
            "The selected file no longer exists."
        }
    }
}
