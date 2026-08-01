import Foundation

enum CodeLanguage: String, CaseIterable, Sendable {
    case swift
    case objectiveC
    case c
    case cpp
    case cSharp
    case typescript
    case javascript
    case json
    case python
    case go
    case rust
    case java
    case kotlin
    case ruby
    case php
    case shell
    case html
    case xml
    case css
    case markdown
    case yaml
    case toml
    case sql
    case dockerfile
    case makefile
    case plainText

    init(path: String) {
        let url = URL(fileURLWithPath: path)
        let filename = url.lastPathComponent.lowercased()

        switch filename {
        case "dockerfile", "containerfile": self = .dockerfile
        case "makefile", "gnumakefile": self = .makefile
        case ".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".profile": self = .shell
        default:
            self = Self.languageByExtension[url.pathExtension.lowercased()] ?? .plainText
        }
    }

    var displayName: String {
        switch self {
        case .swift: "Swift"
        case .objectiveC: "Objective-C"
        case .c: "C"
        case .cpp: "C++"
        case .cSharp: "C#"
        case .typescript: "TypeScript"
        case .javascript: "JavaScript"
        case .json: "JSON"
        case .python: "Python"
        case .go: "Go"
        case .rust: "Rust"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .ruby: "Ruby"
        case .php: "PHP"
        case .shell: "Shell"
        case .html: "HTML"
        case .xml: "XML"
        case .css: "CSS"
        case .markdown: "Markdown"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .sql: "SQL"
        case .dockerfile: "Dockerfile"
        case .makefile: "Makefile"
        case .plainText: "Plain text"
        }
    }

    var iconName: String {
        switch self {
        case .json, .yaml, .toml: "curlybraces"
        case .markdown: "text.document"
        case .html, .xml: "chevron.left.forwardslash.chevron.right"
        case .dockerfile: "shippingbox"
        case .makefile, .shell: "terminal"
        case .plainText: "doc.plaintext"
        default: "chevron.left.forwardslash.chevron.right"
        }
    }

    private static let languageByExtension: [String: CodeLanguage] = [
        "swift": .swift,
        "m": .objectiveC,
        "mm": .objectiveC,
        "h": .c,
        "c": .c,
        "cc": .cpp,
        "cpp": .cpp,
        "cxx": .cpp,
        "hpp": .cpp,
        "cs": .cSharp,
        "ts": .typescript,
        "tsx": .typescript,
        "mts": .typescript,
        "cts": .typescript,
        "js": .javascript,
        "jsx": .javascript,
        "mjs": .javascript,
        "cjs": .javascript,
        "json": .json,
        "jsonc": .json,
        "py": .python,
        "pyw": .python,
        "go": .go,
        "rs": .rust,
        "java": .java,
        "kt": .kotlin,
        "kts": .kotlin,
        "rb": .ruby,
        "php": .php,
        "sh": .shell,
        "bash": .shell,
        "zsh": .shell,
        "fish": .shell,
        "html": .html,
        "htm": .html,
        "vue": .html,
        "svelte": .html,
        "xml": .xml,
        "svg": .xml,
        "plist": .xml,
        "css": .css,
        "scss": .css,
        "sass": .css,
        "less": .css,
        "md": .markdown,
        "mdx": .markdown,
        "markdown": .markdown,
        "yaml": .yaml,
        "yml": .yaml,
        "toml": .toml,
        "sql": .sql,
    ]
}
