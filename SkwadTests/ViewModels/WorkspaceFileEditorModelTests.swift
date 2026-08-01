import XCTest
@testable import Skwad

@MainActor
final class WorkspaceFileEditorModelTests: XCTestCase {
    private var rootURL: URL!
    private var model: WorkspaceFileEditorModel!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "skwad-editor-model-tests-")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        model = WorkspaceFileEditorModel(service: WorkspaceFileService(rootURL: rootURL))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func testSelectLoadsWorkspaceFileForEditing() throws {
        let fileURL = rootURL.appending(path: "Sources/App.swift")
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)

        model.select(relativePath: "Sources/App.swift")

        XCTAssertEqual(model.relativePath, "Sources/App.swift")
        XCTAssertEqual(model.text, "let value = 1\n")
        XCTAssertFalse(model.hasUnsavedChanges)
        XCTAssertNil(model.errorMessage)
    }

    func testChangingTextMarksEditorDirtyAndSavePersists() throws {
        let fileURL = rootURL.appending(path: "README.md")
        try "old\n".write(to: fileURL, atomically: true, encoding: .utf8)
        model.select(relativePath: "README.md")

        model.text = "new\n"
        XCTAssertTrue(model.hasUnsavedChanges)

        XCTAssertTrue(model.save())
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "new\n")
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testSelectionFailureDoesNotExposeOutsideWorkspaceContent() {
        model.select(relativePath: "../secret.txt")

        XCTAssertNil(model.relativePath)
        XCTAssertEqual(model.text, "")
        XCTAssertNotNil(model.errorMessage)
    }

    func testReloadDiscardsUnsavedBuffer() throws {
        let fileURL = rootURL.appending(path: "notes.txt")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)
        model.select(relativePath: "notes.txt")
        model.text = "draft"

        model.reload()

        XCTAssertEqual(model.text, "original")
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testSelectingAnotherFileRequiresExplicitDiscardWhenBufferIsDirty() throws {
        try "first".write(to: rootURL.appending(path: "first.txt"), atomically: true, encoding: .utf8)
        try "second".write(to: rootURL.appending(path: "second.txt"), atomically: true, encoding: .utf8)
        model.select(relativePath: "first.txt")
        model.text = "unsaved"

        XCTAssertFalse(model.select(relativePath: "second.txt"))
        XCTAssertEqual(model.relativePath, "first.txt")
        XCTAssertEqual(model.text, "unsaved")

        XCTAssertTrue(model.select(relativePath: "second.txt", discardingUnsavedChanges: true))
        XCTAssertEqual(model.relativePath, "second.txt")
        XCTAssertEqual(model.text, "second")
    }

    func testReloadIfCleanFollowsAgentEditsOnDisk() throws {
        let fileURL = rootURL.appending(path: "live.swift")
        try "v1".write(to: fileURL, atomically: true, encoding: .utf8)
        model.select(relativePath: "live.swift")

        try "v2".write(to: fileURL, atomically: true, encoding: .utf8)
        model.reloadIfClean()

        XCTAssertEqual(model.text, "v2")
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testReloadIfCleanNeverClobbersUnsavedEdits() throws {
        let fileURL = rootURL.appending(path: "live.swift")
        try "v1".write(to: fileURL, atomically: true, encoding: .utf8)
        model.select(relativePath: "live.swift")
        model.text = "user draft"

        try "v2".write(to: fileURL, atomically: true, encoding: .utf8)
        model.reloadIfClean()

        XCTAssertEqual(model.text, "user draft")
        XCTAssertTrue(model.hasUnsavedChanges)
    }

    func testSaveRefusesToOverwriteAgentChangeMadeAfterFileWasOpened() throws {
        let fileURL = rootURL.appending(path: "shared.swift")
        try "original".write(to: fileURL, atomically: true, encoding: .utf8)
        model.select(relativePath: "shared.swift")
        model.text = "user draft"
        try "agent update".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertFalse(model.save())
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "agent update")
        XCTAssertEqual(model.text, "user draft")
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertNotNil(model.errorMessage)
    }
}
