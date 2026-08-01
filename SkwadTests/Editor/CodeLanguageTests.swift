import XCTest
@testable import Skwad

final class CodeLanguageTests: XCTestCase {
    func testDetectsLanguagesFromCommonSourceExtensions() {
        XCTAssertEqual(CodeLanguage(path: "Sources/App.swift"), .swift)
        XCTAssertEqual(CodeLanguage(path: "src/components/Panel.tsx"), .typescript)
        XCTAssertEqual(CodeLanguage(path: "src/index.mjs"), .javascript)
        XCTAssertEqual(CodeLanguage(path: "cmd/server/main.go"), .go)
        XCTAssertEqual(CodeLanguage(path: "scripts/release.py"), .python)
        XCTAssertEqual(CodeLanguage(path: "locales/en.JSON"), .json)
    }

    func testDetectsLanguagesFromExtensionlessToolingFiles() {
        XCTAssertEqual(CodeLanguage(path: "Dockerfile"), .dockerfile)
        XCTAssertEqual(CodeLanguage(path: "Makefile"), .makefile)
        XCTAssertEqual(CodeLanguage(path: ".zshrc"), .shell)
    }

    func testFallsBackToPlainTextForUnknownFiles() {
        XCTAssertEqual(CodeLanguage(path: "notes/custom.data"), .plainText)
    }
}
