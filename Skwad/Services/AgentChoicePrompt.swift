import Foundation

/// A numbered question the agent is waiting on, lifted off the terminal screen.
///
/// Several commands stop and ask before acting — `/model` warns that switching
/// re-reads the conversation, `/clear` confirms, permission requests list options.
/// The answer only exists as a keystroke in the agent's own TUI, so without this the
/// chat looks like the command simply hung.
struct AgentChoicePrompt: Equatable, Sendable {
    let question: String
    /// Option labels in order; index 0 answers with "1"
    let options: [String]

    /// Find the last numbered prompt on a captured screen, if it is still open.
    static func parse(screen: String) -> AgentChoicePrompt? {
        let lines = screen.components(separatedBy: "\n")

        // Options look like "1. Yes, switch to Haiku 4.5", optionally with a caret
        var options: [(number: Int, label: String, line: Int)] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t❯>›"))
            guard let dot = trimmed.firstIndex(of: "."),
                  let number = Int(trimmed[trimmed.startIndex..<dot]),
                  number >= 1, number <= 9 else { continue }
            let label = trimmed[trimmed.index(after: dot)...]
                .trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            options.append((number, label, index))
        }

        // Keep the final consecutive run, so an older prompt higher up is ignored
        guard let last = options.last else { return nil }
        var run: [(number: Int, label: String, line: Int)] = [last]
        var expected = last.number - 1
        for candidate in options.dropLast().reversed() {
            guard candidate.number == expected else { break }
            run.insert(candidate, at: 0)
            expected -= 1
        }
        guard run.count >= 2, run.first?.number == 1 else { return nil }

        // The question is the nearest non-empty line above the first option
        var question = ""
        var cursor = run[0].line - 1
        while cursor >= 0 {
            let candidate = lines[cursor].trimmingCharacters(in: .whitespaces)
            if !candidate.isEmpty, !candidate.allSatisfy({ $0 == "─" || $0 == "-" || $0 == "═" }) {
                question = candidate
                break
            }
            cursor -= 1
        }
        guard !question.isEmpty else { return nil }

        return AgentChoicePrompt(question: question, options: run.map(\.label))
    }
}
