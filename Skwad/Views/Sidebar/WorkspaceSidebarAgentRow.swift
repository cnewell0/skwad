import SwiftUI

struct WorkspaceSidebarAgentRow: View {
    let agent: Agent
    let isSelected: Bool
    var isCompanion = false
    /// 1-based position in the sidebar; shown as the Command-N hint like Codex does
    var shortcutIndex: Int?

    var body: some View {
        HStack(spacing: 9) {
            if isCompanion {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }

            AvatarView(avatar: agent.avatar, size: isCompanion ? 20 : 24, font: .caption)

            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)

                let detail = agent.headerTitle.isEmpty ? agent.state.rawValue : agent.headerTitle
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if let shortcutIndex, shortcutIndex <= 9 {
                Text("⌘\(shortcutIndex)")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }

            if let stats = agent.gitStats, stats.insertions + stats.deletions > 0 {
                Text("+\(stats.insertions) -\(stats.deletions)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if !agent.isShell {
                Circle()
                    .fill(agent.state.color)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(agent.state.rawValue)
            }
        }
        .padding(.leading, isCompanion ? 13 : 8)
        .padding(.trailing, 8)
        .padding(.vertical, isCompanion ? 5 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Theme.selectionBackground : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
    }
}
