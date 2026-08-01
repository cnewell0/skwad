import Foundation

struct SyntaxToken: Equatable, Sendable {
    enum Kind: Sendable {
        case comment
        case string
        case number
        case keyword
        case type
        case function
        case property
        case tag
        case heading
    }

    let range: NSRange
    let kind: Kind
}
