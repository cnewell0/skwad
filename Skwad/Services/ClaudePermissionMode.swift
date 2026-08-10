import Foundation

/// Claude's permission modes, named the way Claude names them.
///
/// Skwad used to invent its own words for these ("Auto", "Manual", "Bypass") and its
/// own cycle order, and both drifted from what the session actually reported — the chip
/// would read "Auto" while the footer read "manual mode on". These are transcribed from
/// the table the CLI builds its own footer from (claude 2.1.223), where the footer text
/// is the indicator followed by " on":
///
/// ```
/// default:           indicator "manual mode"
/// plan:              indicator "plan mode"
/// acceptEdits:       indicator "accept edits"
/// auto:              indicator "auto mode"
/// bypassPermissions: indicator "bypass permissions"
/// dontAsk:           indicator "don't ask"
/// ```
///
/// `auto` and `acceptEdits` are separate modes, not two spellings of one — treating
/// them as the same is why a session in auto mode could never be labelled correctly.
struct ClaudePermissionMode: Identifiable, Equatable, Sendable {
    /// The `--permission-mode` value and what hooks report
    let id: String
    /// What Claude calls the mode in its footer, without the trailing " on"
    let indicator: String
    let iconName: String
    /// Whether the agent can act without asking — called out in orange
    let isElevated: Bool

    /// Exactly what Claude prints: "manual mode on", "accept edits on", …
    var footerLabel: String { "\(indicator) on" }

    // MARK: - The table

    static let manual = ClaudePermissionMode(
        id: "default", indicator: "manual mode", iconName: "lock", isElevated: false
    )
    static let acceptEdits = ClaudePermissionMode(
        id: "acceptEdits", indicator: "accept edits", iconName: "pencil", isElevated: false
    )
    static let plan = ClaudePermissionMode(
        id: "plan", indicator: "plan mode", iconName: "list.bullet.clipboard", isElevated: false
    )
    static let auto = ClaudePermissionMode(
        id: "auto", indicator: "auto mode", iconName: "bolt.fill", isElevated: true
    )
    static let bypassPermissions = ClaudePermissionMode(
        id: "bypassPermissions", indicator: "bypass permissions",
        iconName: "exclamationmark.triangle.fill", isElevated: true
    )
    static let dontAsk = ClaudePermissionMode(
        id: "dontAsk", indicator: "don't ask",
        iconName: "exclamationmark.triangle.fill", isElevated: true
    )

    /// Every mode Claude can report, so a session in one of the dangerous modes is
    /// still labelled truthfully even though it cannot be picked.
    static let all: [ClaudePermissionMode] = [
        manual, acceptEdits, plan, auto, bypassPermissions, dontAsk,
    ]

    /// How many non-empty lines from the bottom count as the footer. Claude prints the
    /// banner on the last line, with the input box just above it.
    static let footerLineCount = 6

    /// The modes offered in the chip, in Claude's own cycle order
    /// (`default → acceptEdits → plan → bypass? → auto? → default`).
    static let selectable: [ClaudePermissionMode] = [manual, acceptEdits, plan, auto]

    static func mode(id: String?) -> ClaudePermissionMode? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// Hints Claude prints alongside the banner. A line has to carry one of these to
    /// count as the footer — without that, an agent discussing modes in its own output
    /// (or reading this file) was read as the session's state.
    static let footerMarkers = [
        "shift+tab to cycle", "shift-tab to cycle", "? for shortcuts",
        "esc to interrupt", "for agents", "\u{23F5}\u{23F5}", "\u{25B6}\u{25B6}",
    ]

    /// Whether a line looks like Claude's status footer rather than ordinary output
    static func isFooterLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return footerMarkers.contains { lowered.contains($0) }
    }

    /// The mode a captured screen says the session is in.
    ///
    /// Read from the footer only, working up from the bottom, and longest indicator
    /// first so no mode can be swallowed by a shorter one.
    static func mode(fromScreen screen: String) -> ClaudePermissionMode? {
        let byLength = all.sorted { $0.indicator.count > $1.indicator.count }
        let lines = screen
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(footerLineCount)

        for line in lines.reversed() where isFooterLine(line) {
            let lowered = line.lowercased()
            if let mode = byLength.first(where: { lowered.contains($0.footerLabel) }) {
                return mode
            }
        }
        return nil
    }
}
