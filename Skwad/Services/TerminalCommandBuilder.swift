import Foundation

/// Builds shell commands for agent initialization
///
/// See `doc/agent-cli-arguments.md` for CLI argument reference across agents.
///
/// This service centralizes all command construction logic that was previously
/// duplicated across multiple view components (GhosttyHostView, TerminalHostView).
struct TerminalCommandBuilder {
  
  /// Builds the full agent command with MCP tool filtering arguments
  ///
  /// - Parameters:
  ///   - agentType: The type of agent (claude, codex, etc.)
  ///   - settings: The app settings containing user-configured options
  ///   - agentId: The agent's UUID for inline registration (optional)
  ///   - shellCommand: Optional command to run for shell agent type
  /// - Returns: The complete agent command with all arguments
  static func buildAgentCommand(for agentType: String, settings: AppSettings, agentId: UUID? = nil, shellCommand: String? = nil, resumeSessionId: String? = nil, forkSession: Bool = false, persona: Persona? = nil, model: String? = nil) -> String {
    // Shell type: return custom command or empty
    if agentType == "shell" {
      return shellCommand ?? ""
    }
    
    let cmd = settings.getCommand(for: agentType)
    let userOpts = settings.getOptions(for: agentType)
    
    guard !cmd.isEmpty else { return "" }
    
    var fullCommand = cmd
    
    // Add resume/fork session arguments
    if let sessionId = resumeSessionId, canResumeConversation(agentType: agentType) {
      switch agentType {
      case "codex":
        // Codex uses subcommands: `codex resume <id>` or `codex fork <id>`
        if forkSession && canForkConversation(agentType: agentType) {
          fullCommand += " fork \(sessionId)"
        } else {
          fullCommand += " resume \(sessionId)"
        }
      default:
        // Claude and others use flags: `--resume <id> [--fork-session]`
        fullCommand += " --resume \(sessionId)"
        if forkSession && canForkConversation(agentType: agentType) {
          fullCommand += " --fork-session"
        }
      }
    }
    
    fullCommand += modelArgument(for: agentType, model: model)

    // Add user-provided options first (e.g., --settings)
    if !userOpts.isEmpty {
      fullCommand += " \(userOpts)"
    }
    
    // Add MCP-specific arguments if MCP is enabled
    if settings.mcpServerEnabled {
      fullCommand += getMCPArguments(for: agentType, mcpURL: settings.mcpServerURL)
      
      // Add inline registration for supported agents
      if let agentId = agentId {
        fullCommand += getInlineRegistrationArguments(for: agentType, agentId: agentId, isResume: resumeSessionId != nil, persona: persona)
      }
    }
    
    return fullCommand
  }
  
  // MARK: - Shell Escaping
  
  /// Escape a string for safe embedding inside double-quoted shell arguments.
  /// Handles: backslash, double quote, dollar sign, backtick, and exclamation mark.
  static func shellEscape(_ string: String) -> String {
    var result = string
    result = result.replacingOccurrences(of: "\\", with: "\\\\")
    result = result.replacingOccurrences(of: "\"", with: "\\\"")
    result = result.replacingOccurrences(of: "$", with: "\\$")
    result = result.replacingOccurrences(of: "`", with: "\\`")
    result = result.replacingOccurrences(of: "!", with: "\\!")
    return result
  }
  
  /// Build the persona prompt from a Persona.
  static func personaPrompt(from persona: Persona?) -> String? {
    guard let persona, !persona.instructions.isEmpty else { return nil }
    return "You are asked to impersonate \(persona.name) based on the following instructions: \(persona.instructions)"
  }
  
  // MARK: - Registration Prompt Strings
  
  /// The user prompt sent to Claude on first launch to trigger the agent list table.
  static let registrationUserPrompt = AgentPrompts.registrationUserPrompt
  
  /// Public accessor for re-registration from AgentManager context menu
  static func registrationPrompt(agentId: UUID) -> String {
    AgentPrompts.registrationPrompt(agentId: agentId)
  }
  
  private static func registrationSystemPrompt(agentId: UUID) -> String {
    AgentPrompts.skwadInstructions(agentId: agentId)
  }
  
  // MARK: - Inline Registration
  
  /// Check if an agent type supports forking a conversation (--resume + --fork-session)
  static func canForkConversation(agentType: String) -> Bool {
    switch agentType {
    case "claude", "codex":
      return true
    default:
      return false
    }
  }
  
  /// Check if an agent type supports resuming a conversation
  static func canResumeConversation(agentType: String) -> Bool {
    switch agentType {
    case "claude", "codex", "gemini", "copilot":
      return true
    default:
      return false
    }
  }
  
  /// Check if an agent type uses hook-based activity detection (via plugin)
  /// When true, terminal-level activity tracking is disabled
  static func usesActivityHooks(agentType: String) -> Bool {
    switch agentType {
    case "claude", "codex":
      return true
    default:
      return false
    }
  }
  
  /// Models selectable per agent, keyed by agent type. Empty means the CLI has no
  /// `--model` flag we can drive, so the picker is hidden for that agent type.
  /// Values are passed verbatim to the CLI.
  static func selectableModels(for agentType: String) -> [(id: String, label: String)] {
    switch agentType {
    case "claude":
      return [
        ("fable", "Fable 5"),
        ("opus", "Opus 5"),
        ("sonnet", "Sonnet 5"),
        ("haiku", "Haiku 4.5"),
      ]
    case "codex":
      return [
        ("gpt-5-codex", "GPT-5 Codex"),
        ("o3", "o3"),
      ]
    case "gemini":
      return [
        ("gemini-2.5-pro", "Gemini 2.5 Pro"),
        ("gemini-2.5-flash", "Gemini 2.5 Flash"),
      ]
    default:
      return []
    }
  }

  static func supportsModelSelection(agentType: String) -> Bool {
    !selectableModels(for: agentType).isEmpty
  }

  /// Slash command that switches model mid-session, or nil when the agent can only
  /// take a model at launch. Switching live keeps the conversation intact.
  static func runtimeModelCommand(agentType: String, model: String) -> String? {
    switch agentType {
    case "claude", "codex":
      return "/model \(model)"
    default:
      return nil
    }
  }

  /// The `--model` argument for an agent, or "" when unset/unsupported.
  static func modelArgument(for agentType: String, model: String?) -> String {
    guard let model, !model.isEmpty, supportsModelSelection(agentType: agentType) else { return "" }
    switch agentType {
    case "codex":
      return " -m \(model)"
    default:
      return " --model \(model)"
    }
  }

  /// How much the agent is allowed to do without asking, derived from the flags it
  /// was actually launched with. Surfaced in the composer so the answer is never a
  /// guess about what a background agent might do.
  enum AccessLevel: String {
    case full = "Full access"
    case autoEdit = "Auto-edit"
    case plan = "Plan mode"
    case ask = "Asks first"

    var isElevated: Bool { self == .full }

    var iconName: String {
      switch self {
      case .full: "exclamationmark.triangle.fill"
      case .autoEdit: "pencil"
      case .plan: "list.bullet.clipboard"
      case .ask: "lock"
      }
    }
  }

  /// The mode the agent reports it is actually in. Claude can be switched at runtime
  /// with Shift-Tab, so the launch flags alone go stale.
  static func accessLevel(fromReportedMode mode: String?) -> AccessLevel? {
    switch mode {
    case "bypassPermissions": return .full
    case "acceptEdits": return .autoEdit
    case "plan": return .plan
    case "default": return .ask
    default: return nil
    }
  }

  /// Whether the agent can cycle permission modes from the keyboard (Shift-Tab).
  static func supportsPermissionCycling(agentType: String) -> Bool {
    agentType == "claude"
  }

  static func accessLevel(agentType: String, options: String) -> AccessLevel {
    let opts = options.lowercased()
    switch agentType {
    case "claude":
      if opts.contains("--dangerously-skip-permissions") { return .full }
      if opts.contains("acceptedits") || opts.contains("accept-edits") { return .autoEdit }
      if opts.contains("bypasspermissions") { return .full }
      return .ask
    case "codex":
      if opts.contains("--dangerously-bypass-approvals-and-sandbox") { return .full }
      if opts.contains("--full-auto") { return .autoEdit }
      if opts.contains("never") && opts.contains("approval") { return .full }
      return .ask
    case "gemini", "copilot", "opencode":
      if opts.contains("--yolo") || opts.contains("--allow-all-tools") { return .full }
      return .ask
    default:
      return .ask
    }
  }

  /// Whether submitting text to this agent needs an Escape first.
  ///
  /// Escape dismisses the autocomplete popup in TUI agents like Claude Code, which
  /// would otherwise swallow the Return. A plain shell has no such popup, and in zsh
  /// an Escape starts a meta sequence — the following Return is then consumed instead
  /// of accepting the line, leaving the command stranded at the prompt.
  static func needsEscapeBeforeSubmit(agentType: String) -> Bool {
    agentType != "shell"
  }

  /// Check if an agent type supports system prompt injection
  static func supportsSystemPrompt(agentType: String) -> Bool {
    switch agentType {
    case "claude", "codex":
      return true
    default:
      return false
    }
  }
  
  /// Check if an agent type supports inline registration via command-line arguments
  /// Shell returns true to skip registration prompts entirely
  static func supportsInlineRegistration(agentType: String) -> Bool {
    switch agentType {
    case "claude", "codex", "opencode", "gemini", "copilot", "shell":
      return true
    default:
      return false
    }
  }
  
  /// Get inline registration arguments for supported agents
  /// See `doc/agent-cli-arguments.md` for CLI argument reference
  private static func getInlineRegistrationArguments(for agentType: String, agentId: UUID, isResume: Bool = false, persona: Persona? = nil) -> String {
    switch agentType {
    case "claude":
      // Claude: registration is handled by hooks, just inject system prompt
      var systemPrompt = registrationSystemPrompt(agentId: agentId)
      if let personaPrompt = personaPrompt(from: persona) {
        systemPrompt += " " + shellEscape(personaPrompt)
      }
      // Skip user prompt on resume/fork — the agent already has conversation context
      if isResume {
        return #" --append-system-prompt "\#(systemPrompt)""#
      }
      return #" --append-system-prompt "\#(systemPrompt)" "\#(registrationUserPrompt)""#
      
    case "codex":
      // Codex: system prompt via -c developer_instructions, user prompt as last argument
      var systemPrompt = registrationSystemPrompt(agentId: agentId)
      if let personaPrompt = personaPrompt(from: persona) {
        systemPrompt += " " + shellEscape(personaPrompt)
      }
      if isResume {
        return #" -c 'developer_instructions="\#(systemPrompt)"'"#
      }
      return #" -c 'developer_instructions="\#(systemPrompt)"' "\#(registrationUserPrompt)""#
      
    case "opencode":
      // OpenCode: no system prompt support — skip registration on resume
      if isResume { return "" }
      let userPromptOC = registrationPrompt(agentId: agentId)
      return #" --prompt "\#(userPromptOC)""#
      
    case "gemini":
      // Gemini CLI: no system prompt support — skip registration on resume
      if isResume { return "" }
      let userPromptG = registrationPrompt(agentId: agentId)
      return #" --prompt-interactive "\#(userPromptG)""#
      
    case "copilot":
      // GitHub Copilot: no system prompt support — skip registration on resume
      if isResume { return "" }
      let userPromptCP = registrationPrompt(agentId: agentId)
      return #" --interactive "\#(userPromptCP)""#
      
    default:
      return ""
    }
  }
  
  /// Get MCP-specific arguments for each agent type
  private static func getMCPArguments(for agentType: String, mcpURL: String) -> String {
    switch agentType {
    case "claude":
      let mcpConfig = #"--mcp-config '{"mcpServers":{"skwad":{"type":"http","url":"\#(mcpURL)"}}}'"#
      var args = " \(mcpConfig) --allowed-tools 'mcp__skwad__*'"
      // Add plugin directory for hook-based activity detection
      if let pluginPath = resolvePluginPath(for: agentType) {
        args += " --plugin-dir \"\(pluginPath)\""
      }
      return args
      
    case "codex":
      // Inject notify hook via -c flag for activity detection
      var args = ""
      if let pluginPath = resolvePluginPath(for: agentType) {
        let notifyScript = "\(pluginPath)/scripts/notify.sh"
        args += #" -c 'notify=["bash","\#(notifyScript)"]'"#
      }
      return args
      
    case "gemini":
      return " --allowed-mcp-server-names skwad"
      
    case "copilot":
      // Configure the MCP server and allow all Skwad tools
      let mcpConfig = #"--additional-mcp-config '{"mcpServers":{"skwad":{"type":"http","url":"\#(mcpURL)","tools":["*"]}}}'"#
      let allowedTools = [
        "skwad(register-agent)",
        "skwad(list-agents)",
        "skwad(send-message)",
        "skwad(check-messages)",
        "skwad(broadcast-message)"
      ].map { "--allow-tool '\($0)'" }.joined(separator: " ")
      return " \(mcpConfig) \(allowedTools)"
      
    default:
      return ""
    }
  }
  
  /// Builds the initialization command that navigates to the folder,
  /// clears the screen, and launches the agent.
  ///
  /// The command is prefixed with a space to prevent shell history pollution
  /// (requires HISTCONTROL=ignorespace in bash or equivalent in other shells).
  ///
  /// - Parameters:
  ///   - folder: The working directory for the agent
  ///   - agentCommand: The full agent command to execute
  /// - Returns: The complete shell command string
  static func buildInitializationCommand(
    folder: String,
    agentCommand: String,
    agentId: UUID? = nil,
    hookServerURL: String? = nil
  ) -> String {
    // Prefix with space to prevent shell history
    // Note: zsh ignores by default, bash requires HISTCONTROL=ignorespace
    if agentCommand.isEmpty {
      // Shell mode: just cd and clear, no agent command
      return " cd '\(folder)' && clear"
    }
    // Inject the active app's endpoint so hooks work when multiple Skwad builds use different ports.
    let hookURLPrefix = hookServerURL.map { "SKWAD_URL=\($0) " } ?? ""
    let agentIdPrefix = agentId.map { "SKWAD_AGENT_ID=\($0.uuidString) " } ?? ""
    let envPrefix = hookURLPrefix + agentIdPrefix
    return " cd '\(folder)' && clear && \(envPrefix)\(agentCommand)"
  }
  
  /// Resolves the plugin directory path for a given agent type.
  /// In release builds, the plugin is bundled inside the app.
  /// In dev builds (Xcode), fall back to the source tree.
  private static func resolvePluginPath(for agentType: String) -> String? {
    let subpath = "plugin/\(agentType)"
    // Try app bundle first (release / archived builds)
    if let bundled = Bundle.main.url(forResource: subpath, withExtension: nil)?.path,
       FileManager.default.fileExists(atPath: bundled) {
      return bundled
    }
    // Dev fallback: derive source root from this file's compile-time path
    let sourceFile = #filePath
    let sourceDir = (sourceFile as NSString).deletingLastPathComponent  // .../Skwad/Services
    let projectRoot = ((sourceDir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    let devPath = (projectRoot as NSString).appendingPathComponent(subpath)
    if FileManager.default.fileExists(atPath: devPath) {
      return devPath
    }
    return nil
  }
  
  /// Gets the default shell executable path
  static func getDefaultShell() -> String {
    return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
  }
}
