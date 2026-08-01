import Foundation
import XCTest
@testable import Skwad

final class SyntaxHighlighterTests: XCTestCase {
    func testHighlightsSwiftStructureWithoutTokenizingInsideCommentsOrStrings() {
        let source = "let title = \"class\" // return value"
        let tokens = SyntaxHighlighter.tokens(in: source, language: .swift)

        XCTAssertEqual(texts(for: .keyword, in: tokens, source: source), ["let"])
        XCTAssertEqual(texts(for: .string, in: tokens, source: source), ["\"class\""])
        XCTAssertEqual(texts(for: .comment, in: tokens, source: source), ["// return value"])
    }

    func testHighlightsJSONKeysSeparatelyFromValues() {
        let source = "{\"enabled\": true, \"label\": \"Skwad\", \"count\": 12}"
        let tokens = SyntaxHighlighter.tokens(in: source, language: .json)

        XCTAssertEqual(texts(for: .property, in: tokens, source: source), ["\"enabled\"", "\"label\"", "\"count\""])
        XCTAssertEqual(texts(for: .keyword, in: tokens, source: source), ["true"])
        XCTAssertEqual(texts(for: .string, in: tokens, source: source), ["\"Skwad\""])
        XCTAssertEqual(texts(for: .number, in: tokens, source: source), ["12"])
    }

    func testHighlightsTypeScriptKeywordsFunctionsAndTypes() {
        let source = "export async function loadAgent(id: string): Promise<Agent> { return id }"
        let tokens = SyntaxHighlighter.tokens(in: source, language: .typescript)

        XCTAssertEqual(texts(for: .function, in: tokens, source: source), ["loadAgent"])
        XCTAssertTrue(texts(for: .keyword, in: tokens, source: source).contains("export"))
        XCTAssertTrue(texts(for: .keyword, in: tokens, source: source).contains("async"))
        XCTAssertTrue(texts(for: .type, in: tokens, source: source).contains("Promise"))
        XCTAssertTrue(texts(for: .type, in: tokens, source: source).contains("Agent"))
    }

    func testPlainTextProducesNoSyntaxTokens() {
        XCTAssertTrue(SyntaxHighlighter.tokens(in: "ordinary notes", language: .plainText).isEmpty)
    }

    func testEditorSelectionIsClampedAfterExternalTextReplacement() {
        let ranges = [
            NSValue(range: NSRange(location: 3, length: 8)),
            NSValue(range: NSRange(location: 50, length: 2)),
        ]

        let clamped = CodeEditorView.clampedSelectionRanges(ranges, textLength: 5)

        XCTAssertEqual(clamped.map(\.rangeValue), [
            NSRange(location: 3, length: 2),
            NSRange(location: 5, length: 0),
        ])
    }

    private func texts(
        for kind: SyntaxToken.Kind,
        in tokens: [SyntaxToken],
        source: String
    ) -> [String] {
        let source = source as NSString
        return tokens
            .filter { $0.kind == kind }
            .map { source.substring(with: $0.range) }
    }
}
