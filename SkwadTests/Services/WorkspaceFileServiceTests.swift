import XCTest
@testable import Skwad

final class WorkspaceFileServiceTests: XCTestCase {
    private var rootURL: URL!
    private var service: WorkspaceFileService!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "skwad-file-service-tests-")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        service = WorkspaceFileService(rootURL: rootURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func testReadReturnsUTF8TextInsideWorkspace() throws {
        let fileURL = rootURL.appending(path: "Sources/App.swift")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "let value = 1\n".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(try service.read(relativePath: "Sources/App.swift"), "let value = 1\n")
    }

    func testWriteAtomicallyUpdatesFileInsideWorkspace() throws {
        let fileURL = rootURL.appending(path: "README.md")
        try "old".write(to: fileURL, atomically: true, encoding: .utf8)

        try service.write("new\n", relativePath: "README.md")

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "new\n")
    }

    func testReadRejectsParentDirectoryTraversal() {
        XCTAssertThrowsError(try service.read(relativePath: "../secret.txt")) { error in
            XCTAssertEqual(error as? WorkspaceFileError, .outsideWorkspace)
        }
    }

    func testWriteRejectsAbsolutePath() {
        XCTAssertThrowsError(try service.write("no", relativePath: "/tmp/outside.txt")) { error in
            XCTAssertEqual(error as? WorkspaceFileError, .outsideWorkspace)
        }
    }

    func testReadRejectsSymlinkThatEscapesWorkspace() throws {
        let outsideURL = FileManager.default.temporaryDirectory
            .appending(path: "skwad-outside-\(UUID().uuidString)")
        try "secret".write(to: outsideURL, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: outsideURL) }

        let linkURL = rootURL.appending(path: "escaped.txt")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)

        XCTAssertThrowsError(try service.read(relativePath: "escaped.txt")) { error in
            XCTAssertEqual(error as? WorkspaceFileError, .outsideWorkspace)
        }
    }

    func testReadRejectsNonUTF8File() throws {
        let fileURL = rootURL.appending(path: "binary.dat")
        try Data([0xFF, 0xFE, 0x00]).write(to: fileURL)

        XCTAssertThrowsError(try service.read(relativePath: "binary.dat")) { error in
            XCTAssertEqual(error as? WorkspaceFileError, .notUTF8Text)
        }
    }

    func testReadRejectsFileAboveEditingLimit() throws {
        service = WorkspaceFileService(rootURL: rootURL, maximumFileSize: 4)
        let fileURL = rootURL.appending(path: "large.txt")
        try "12345".write(to: fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try service.read(relativePath: "large.txt")) { error in
            XCTAssertEqual(error as? WorkspaceFileError, .fileTooLarge(maximumBytes: 4))
        }
    }
}
