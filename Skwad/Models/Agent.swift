import Foundation
import SwiftUI
import AppKit

enum AgentState: String, Codable {
    case idle = "Idle"
    case running = "Working"
    case input = "Awaiting input"
    case error = "Error"

    var color: Color {
        switch self {
        case .idle: return .green
        case .running: return .orange
        case .input: return .red
        case .error: return .red
        }
    }
}

struct GitLineStats: Hashable, Codable {
    let insertions: Int
    let deletions: Int
    let files: Int
}

struct Agent: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var avatar: String?  // Either emoji or "data:image/png;base64,..."
    var folder: String
    var agentType: String  // Agent type ID (claude, codex, custom1, etc.)
    var createdBy: UUID?  // Agent ID that created this agent (nil if created by user)
    var isCompanion: Bool = false  // If true, this agent is a companion of the createdBy agent
    var shellCommand: String?  // Command to run for shell agent type
    var personaId: UUID?  // Optional persona to apply to system prompt
    var model: String?  // Optional model override passed to the agent CLI (nil = CLI default)
    var permissionMode: String?  // Optional --permission-mode passed at launch (nil = CLI default)

    // Runtime state (not persisted)

    /// Internal state machine state (idle/running/input/error), driven by terminal activity and hooks
    var state: AgentState = .idle
    /// Human-readable status text explicitly set by the agent via the `set-status` MCP tool (e.g. "Implementing auth module").
    /// Distinct from `state` (automatic state machine) and `terminalTitle` (terminal escape sequence).
    var statusText: String = ""
    var isRegistered: Bool = false  // Set true when agent calls register-agent with MCP
    var isPendingStart: Bool = false  // Shell agents waiting in the startup queue
    /// Raw terminal title from escape sequences. Use `displayTitle` for display (currently an alias).
    var terminalTitle: String = ""
    var restartToken: UUID = UUID()  // Changes on restart to force terminal recreation
    var gitStats: GitLineStats? = nil
    /// Worktree state when this session started. Everything shown as "changed" is
    /// measured against this, so a repo that was already dirty doesn't get counted
    /// as the agent's work.
    var baselineGitStats: GitLineStats? = nil
    /// Commit the session started on. Once the agent commits and pushes, the working
    /// tree is clean and its work would vanish from the Changes panel — this is what
    /// that work is still diffed against.
    var sessionBaseCommit: String? = nil
    /// Checkout the baseline above was taken in. An agent that moves into a worktree
    /// mid-session is measuring against a different repository, so both are retaken.
    var sessionBaseFolder: String? = nil
    /// Line counts for what the session has already committed
    var committedGitStats: GitLineStats? = nil
    var sessionId: String? = nil  // Set during register-agent, used by hooks for activity detection
    var resumeSessionId: String? = nil  // Session ID to resume/fork (transient, used once at launch)
    var forkSession: Bool = false  // If true, fork instead of resume (transient)
    var markdownFilePath: String? = nil  // Markdown file being previewed (set by MCP tool)
    var markdownMaximized: Bool = false  // Whether the markdown panel should be maximized
    var markdownFileHistory: [String] = []  // History of markdown files shown (most recent first)
    var mermaidSource: String? = nil  // Mermaid diagram source text (set by MCP tool)
    var mermaidTitle: String? = nil  // Optional title for the mermaid diagram
    var metadata: [String: String] = [:]  // Hook-populated metadata (transcript_path, cwd, model, etc.)
    var lastStatusChange: Date = Date()  // When status last changed (runtime only, for dashboard sorting)

    /// Actual working directory: hook-reported cwd if it differs from folder (e.g. worktree), otherwise folder.
    ///
    /// A cwd nested inside the folder is normally just the agent cd'ing around its own
    /// repo and is ignored — but a nested git worktree (Skwad puts them under
    /// .claude/worktrees/) is a separate checkout, and Changes must follow it or it
    /// shows the main checkout's unrelated dirt instead of the agent's work.
    var workingFolder: String {
        let folderWithSlash = folder.hasSuffix("/") ? folder : folder + "/"
        guard let cwd = metadata["cwd"], cwd != folder else { return folder }
        if cwd.hasPrefix(folderWithSlash), !Self.isRepositoryRoot(cwd) {
            return folder
        }
        return cwd
    }

    /// True when the path is itself a repo or worktree root. In a worktree, .git is a
    /// file pointing at the parent repo; in a normal checkout it is a directory —
    /// fileExists covers both.
    static func isRepositoryRoot(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    // Only persist these fields
    enum CodingKeys: String, CodingKey {
        case id, name, avatar, folder, agentType, createdBy, isCompanion, shellCommand, personaId, model, permissionMode
    }

    // Custom decoding to handle migration from old format without isCompanion/createdBy
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        folder = try container.decode(String.self, forKey: .folder)
        agentType = try container.decodeIfPresent(String.self, forKey: .agentType) ?? "claude"
        createdBy = try container.decodeIfPresent(UUID.self, forKey: .createdBy)
        isCompanion = try container.decodeIfPresent(Bool.self, forKey: .isCompanion) ?? false
        shellCommand = try container.decodeIfPresent(String.self, forKey: .shellCommand)
        personaId = try container.decodeIfPresent(UUID.self, forKey: .personaId)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
    }

    init(id: UUID = UUID(), name: String, avatar: String? = nil, folder: String, agentType: String = "claude", createdBy: UUID? = nil, isCompanion: Bool = false, shellCommand: String? = nil, personaId: UUID? = nil, model: String? = nil, permissionMode: String? = nil) {
        self.id = id
        self.name = name
        self.avatar = avatar
        self.folder = folder
        self.agentType = agentType
        self.createdBy = createdBy
        self.isCompanion = isCompanion
        self.shellCommand = shellCommand
        self.personaId = personaId
        self.model = model
        self.permissionMode = permissionMode
    }

    /// Create agent from folder path, deriving name from last path component
    init(folder: String, avatar: String? = nil, agentType: String = "claude", createdBy: UUID? = nil, isCompanion: Bool = false, shellCommand: String? = nil, personaId: UUID? = nil, model: String? = nil, permissionMode: String? = nil) {
        self.id = UUID()
        self.folder = folder
        self.avatar = avatar
        self.agentType = agentType
        self.createdBy = createdBy
        self.isCompanion = isCompanion
        self.shellCommand = shellCommand
        self.personaId = personaId
        self.model = model
        self.permissionMode = permissionMode
        self.name = URL(fileURLWithPath: folder).lastPathComponent
    }

    /// Prefill for forking this agent
    func forkPrefill() -> AgentPrefill {
        AgentPrefill(
            name: name + " (fork)",
            avatar: avatar,
            folder: folder,
            agentType: agentType,
            insertAfterId: id,
            sessionId: sessionId,
            personaId: personaId
        )
    }

    /// Prefill for creating a new companion of this agent
    func companionPrefill() -> AgentPrefill {
        AgentPrefill(
            name: "",
            avatar: nil,
            folder: folder,
            agentType: "shell",
            insertAfterId: id,
            createdBy: id,
            isCompanion: true
        )
    }

    /// Changes this session is responsible for: current worktree state minus whatever
    /// was already uncommitted when the session started, plus anything it has since
    /// committed. Committing used to make the session's own numbers drop back to zero.
    var sessionGitStats: GitLineStats? {
        guard gitStats != nil || committedGitStats != nil else { return nil }
        let current = gitStats ?? GitLineStats(insertions: 0, deletions: 0, files: 0)
        let committed = committedGitStats ?? GitLineStats(insertions: 0, deletions: 0, files: 0)
        guard let baseline = baselineGitStats else {
            return GitLineStats(
                insertions: current.insertions + committed.insertions,
                deletions: current.deletions + committed.deletions,
                files: current.files + committed.files
            )
        }
        return GitLineStats(
            insertions: max(0, current.insertions - baseline.insertions) + committed.insertions,
            deletions: max(0, current.deletions - baseline.deletions) + committed.deletions,
            files: max(0, current.files - baseline.files) + committed.files
        )
    }

    /// Whether this is a plain shell agent (no AI)
    var isShell: Bool {
        agentType == "shell"
    }

    /// Terminal title (cleaned on update in AgentManager)
    var displayTitle: String {
        terminalTitle
    }

    /// Title for the terminal header: prefers agent-set status text over terminal title
    var headerTitle: String {
        statusText.isEmpty ? terminalTitle : statusText
    }

    /// Check if avatar is an image (base64 encoded)
    var isImageAvatar: Bool {
        avatar?.hasPrefix("data:image") ?? false
    }

    /// Get emoji avatar string (returns default if image or nil)
    var emojiAvatar: String {
        if let avatar = avatar, !avatar.hasPrefix("data:") {
            return avatar
        }
        return "🤖"
    }

    /// Get NSImage from base64 avatar data
    var avatarImage: NSImage? {
        guard let avatar = avatar,
              avatar.hasPrefix("data:image"),
              let commaIndex = avatar.firstIndex(of: ",") else {
            return nil
        }
        let base64String = String(avatar[avatar.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: base64String) else {
            return nil
        }
        return NSImage(data: data)
    }
}
