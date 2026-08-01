import Foundation

enum SyntaxHighlighter {
    static func tokens(in source: String, language: CodeLanguage) -> [SyntaxToken] {
        guard language != .plainText, !source.isEmpty else { return [] }

        let fullRange = NSRange(location: 0, length: source.utf16.count)
        var tokens: [SyntaxToken] = []
        // Tracks claimed character positions so later (lower-priority) patterns can't
        // overlap earlier tokens. Index-set operations are O(log n) — a linear scan
        // over `tokens` per match made large files take seconds to highlight.
        let claimed = NSMutableIndexSet()

        func append(_ pattern: String, as kind: SyntaxToken.Kind, options: NSRegularExpression.Options = []) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in expression.matches(in: source, range: fullRange) {
                let range = match.range
                guard range.location != NSNotFound,
                      range.length > 0,
                      !claimed.intersects(in: range) else {
                    continue
                }
                claimed.add(in: range)
                tokens.append(SyntaxToken(range: range, kind: kind))
            }
        }

        if let commentPattern = commentPattern(for: language) {
            append(commentPattern, as: .comment, options: [.anchorsMatchLines, .dotMatchesLineSeparators])
        }

        if language == .json {
            append(#"\"(?:\\.|[^\"\\])*\"(?=\s*:)"#, as: .property)
        }

        if language == .markdown {
            append(#"^#{1,6}\s+.*$"#, as: .heading, options: .anchorsMatchLines)
        }

        if language == .html || language == .xml {
            append(#"</?[A-Za-z][^>]*>"#, as: .tag)
        }

        append(#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#, as: .string)

        if let keywords = keywords(for: language), !keywords.isEmpty {
            let alternatives = keywords
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            let options: NSRegularExpression.Options = language == .sql || language == .dockerfile
                ? .caseInsensitive
                : []
            append("\\b(?:\(alternatives))\\b", as: .keyword, options: options)
        }

        if supportsNamedTypes(language) {
            append(#"\b[A-Z][A-Za-z0-9_]*\b"#, as: .type)
        }

        if supportsFunctions(language) {
            append(#"\b[A-Za-z_$][A-Za-z0-9_$]*(?=\s*\()"#, as: .function)
        }

        append(#"(?<![A-Za-z0-9_])(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)(?![A-Za-z0-9_])"#, as: .number)

        return tokens.sorted { lhs, rhs in
            if lhs.range.location == rhs.range.location {
                lhs.range.length > rhs.range.length
            } else {
                lhs.range.location < rhs.range.location
            }
        }
    }

    private static func commentPattern(for language: CodeLanguage) -> String? {
        switch language {
        case .swift, .objectiveC, .c, .cpp, .cSharp, .typescript, .javascript,
             .go, .rust, .java, .kotlin, .php, .css, .json:
            #"//[^\n]*|/\*[\s\S]*?\*/"#
        case .python, .ruby, .shell, .yaml, .toml, .makefile, .dockerfile:
            #"#[^\n]*"#
        case .sql:
            #"--[^\n]*|/\*[\s\S]*?\*/"#
        case .html, .xml, .markdown:
            #"<!--[\s\S]*?-->"#
        case .plainText:
            nil
        }
    }

    private static func keywords(for language: CodeLanguage) -> [String]? {
        switch language {
        case .swift:
            ["actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "do", "else", "enum", "extension", "false", "for", "func", "guard", "if", "import", "in", "init", "inout", "is", "let", "nil", "nonisolated", "private", "protocol", "public", "repeat", "return", "self", "some", "static", "struct", "switch", "throw", "throws", "true", "try", "var", "where", "while"]
        case .typescript, .javascript:
            ["as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "private", "protected", "public", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "with", "yield"]
        case .json:
            ["true", "false", "null"]
        case .python:
            ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
        case .go:
            ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"]
        case .rust:
            ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
        case .objectiveC, .c, .cpp, .cSharp, .java, .kotlin:
            ["abstract", "auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "false", "final", "finally", "float", "for", "if", "implements", "import", "in", "int", "interface", "internal", "long", "namespace", "new", "nil", "null", "override", "package", "private", "protected", "public", "return", "short", "signed", "static", "struct", "super", "switch", "this", "throw", "throws", "true", "try", "typedef", "unsigned", "using", "var", "virtual", "void", "volatile", "when", "while"]
        case .ruby:
            ["alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield"]
        case .php:
            ["abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "endfor", "endforeach", "endif", "endswitch", "endwhile", "extends", "false", "final", "finally", "fn", "for", "foreach", "function", "global", "if", "implements", "include", "instanceof", "interface", "isset", "namespace", "new", "null", "private", "protected", "public", "require", "return", "static", "switch", "throw", "trait", "true", "try", "use", "var", "while", "yield"]
        case .sql:
            ["add", "alter", "and", "as", "asc", "between", "by", "case", "column", "constraint", "create", "database", "default", "delete", "desc", "distinct", "drop", "else", "end", "exists", "foreign", "from", "full", "group", "having", "in", "index", "inner", "insert", "into", "is", "join", "key", "left", "like", "limit", "not", "null", "on", "or", "order", "outer", "primary", "references", "right", "select", "set", "table", "then", "union", "unique", "update", "values", "view", "when", "where"]
        case .yaml, .toml:
            ["true", "false", "null", "yes", "no"]
        case .dockerfile:
            ["add", "arg", "cmd", "copy", "entrypoint", "env", "expose", "from", "healthcheck", "label", "maintainer", "onbuild", "run", "shell", "stopsignal", "user", "volume", "workdir"]
        case .shell:
            ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "return", "then", "while"]
        case .html, .xml, .css, .markdown, .makefile, .plainText:
            nil
        }
    }

    private static func supportsNamedTypes(_ language: CodeLanguage) -> Bool {
        switch language {
        case .swift, .objectiveC, .c, .cpp, .cSharp, .typescript, .javascript,
             .go, .rust, .java, .kotlin:
            true
        default:
            false
        }
    }

    private static func supportsFunctions(_ language: CodeLanguage) -> Bool {
        switch language {
        case .json, .html, .xml, .css, .markdown, .yaml, .toml, .dockerfile,
             .makefile, .plainText:
            false
        default:
            true
        }
    }
}
