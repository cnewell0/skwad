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

    /// The modes offered in the chip, in Claude's own cycle order
    /// (`default → acceptEdits → plan → bypass? → auto? → default`).
    static let selectable: [ClaudePermissionMode] = [manual, acceptEdits, plan, auto]

    static func mode(id: String?) -> ClaudePermissionMode? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    /// The mode a captured screen says the session is in.
    ///
    /// Longest indicator first so no mode can be swallowed by a shorter one, and the
    /// last banner on screen wins — earlier ones are scrollback.
    static func mode(fromScreen screen: String) -> ClaudePermissionMode? {
        let lowered = screen.lowercased()
        let byLength = all.sorted { $0.indicator.count > $1.indicator.count }

        var best: (mode: ClaudePermissionMode, position: String.Index)?
        for mode in byLength {
            guard let range = lowered.range(of: mode.footerLabel, options: .backwards) else {
                continue
            }
            if best == nil || range.lowerBound > best!.position {
                best = (mode, range.lowerBound)
            }
        }
        return best?.mode
    }
}
