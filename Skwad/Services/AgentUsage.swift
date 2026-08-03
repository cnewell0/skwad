import Foundation

/// Token totals for one model within a session.
struct ModelUsage: Equatable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var total: Int { input + output + cacheRead + cacheWrite }
}

/// What a session has spent, derived from the transcript the agent already writes.
/// Reported natively so `/usage` answers in the chat instead of drawing a panel in
/// the terminal that the chat can never see.
struct AgentUsage: Equatable, Sendable {
    var byModel: [String: ModelUsage] = [:]
    var turns = 0

    var isEmpty: Bool { byModel.isEmpty }

    var combined: ModelUsage {
        byModel.values.reduce(into: ModelUsage()) { total, usage in
            total.input += usage.input
            total.output += usage.output
            total.cacheRead += usage.cacheRead
            total.cacheWrite += usage.cacheWrite
        }
    }

    /// Plain-text report shown in the chat.
    ///
    /// Deliberately reports tokens only. Turning them into money needs a per-model
    /// price table that would silently go stale — `/cost` in the agent session is
    /// the authority on spend.
    func report() -> String {
        guard !isEmpty else { return "No usage recorded for this session yet." }

        func fmt(_ n: Int) -> String {
            n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
        }

        var lines: [String] = []
        lines.append("\(turns) assistant turn\(turns == 1 ? "" : "s")")
        lines.append("")

        for model in byModel.keys.sorted() {
            let usage = byModel[model]!
            lines.append(model)
            lines.append("  in \(fmt(usage.input))   out \(fmt(usage.output))   cache read \(fmt(usage.cacheRead))   cache write \(fmt(usage.cacheWrite))")
        }

        if byModel.count > 1 {
            let all = combined
            lines.append("")
            lines.append("total")
            lines.append("  in \(fmt(all.input))   out \(fmt(all.output))   cache read \(fmt(all.cacheRead))   cache write \(fmt(all.cacheWrite))")
        }

        return lines.joined(separator: "\n")
    }
}
