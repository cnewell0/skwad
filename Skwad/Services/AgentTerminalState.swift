import Foundation

/// State the agent prints about itself, read off its terminal.
///
/// Skwad used to predict these — assume a Shift-Tab landed on the next mode, assume
/// `/model x` was accepted — and the prediction drifted from reality without anything
/// noticing. The agent states both plainly in its own footer, so that is the source
/// of truth and the UI reports it rather than guessing.
enum AgentTerminalState {

    /// Permission mode from the footer, e.g. "plan mode on (shift+tab to cycle)".
    ///
    /// Absence of a banner means the default (asks before acting), which is why an
    /// unmatched screen returns `.ask` rather than nil.
    static func permissionMode(fromScreen screen: String) -> String? {
        // Banners first, matched against Claude's own table. The footer does not
        // always carry the "shift+tab to cycle" hint (e.g. "manual mode on · ? for
        // shortcuts"), so gating on it made the read-back silently fail and left a
        // stale chip.
        if let mode = ClaudePermissionMode.mode(fromScreen: screen) { return mode.id }

        let lowered = screen
            .components(separatedBy: "\n")
            .filter { ClaudePermissionMode.isFooterLine($0) }
            .suffix(ClaudePermissionMode.footerLineCount)
            .joined(separator: "\n")
            .lowercased()
        // Older builds worded bypass differently
        if lowered.contains("bypassing permissions") { return ClaudePermissionMode.bypassPermissions.id }
        // The cycle hint with no banner is how older builds show the default
        if lowered.contains("shift+tab to cycle") || lowered.contains("shift-tab to cycle") {
            return ClaudePermissionMode.manual.id
        }
        return nil
    }

    /// What the agent said in response to a model change, if it said anything.
    ///
    /// Claude answers "Set model to X" when it takes, and "Kept model as X" when it
    /// does not — the second is the case Skwad was reporting as success.
    static func modelChangeOutcome(fromScreen screen: String) -> ModelChangeOutcome? {
        for line in screen.components(separatedBy: "\n").reversed() {
            // Found anywhere in the line: the agent prefixes it with tree glyphs
            if let range = line.range(of: "Kept model as ") {
                return .refused(stillOn: cleaned(String(line[range.upperBound...])))
            }
            if let range = line.range(of: "Set model to ") {
                return .changed(to: cleaned(String(line[range.upperBound...])))
            }
        }
        return nil
    }

    enum ModelChangeOutcome: Equatable, Sendable {
        case changed(to: String)
        case refused(stillOn: String)
    }

    /// Trim the trailing prose Claude appends after the model name
    private static func cleaned(_ name: String) -> String {
        var value = name
        for suffix in [" and saved as your default for new sessions"] {
            if let trimmed = value.range(of: suffix) {
                value = String(value[value.startIndex..<trimmed.lowerBound])
            }
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " .\t"))
    }
}
