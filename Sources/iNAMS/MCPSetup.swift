import Foundation

enum MCPSetupError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        if case .message(let msg) = self { return msg }
        return nil
    }
}

/// One-click MCP configuration for local agent clients. Each install gets a
/// freshly-minted Workspace-bound key (caller's responsibility) — never the
/// app's Admin key.
enum MCPSetup {
    // MARK: - Claude Code

    /// Shells out to `claude mcp add` (user scope) — no config-file surgery.
    static func setupClaudeCode(mcpURL: URL, apiKey: String) throws {
        guard commandExists("claude") else {
            throw MCPSetupError.message("Claude Code CLI not found. Install it first: https://claude.com/claude-code")
        }
        // Remove a stale entry first so re-running setup rotates the key
        // instead of failing on "already exists". Ignore its exit status.
        _ = try? runShell("claude mcp remove --scope user nams")
        let command = """
        claude mcp add --transport http --scope user \
          --header 'Authorization: Bearer \(apiKey)' \
          nams '\(mcpURL.absoluteString)'
        """
        let result = try runShell(command)
        guard result.status == 0 else {
            throw MCPSetupError.message("claude mcp add failed: \(result.output)")
        }
    }

    // MARK: - Claude Desktop

    /// Claude Desktop's config only speaks stdio servers, so the remote NAMS
    /// server goes through the `npx mcp-remote` shim. The existing config is
    /// backed up with a timestamp suffix before the rewrite.
    /// Returns the backup path (nil when no config existed).
    @discardableResult
    static func setupClaudeDesktop(
        mcpURL: URL,
        apiKey: String,
        configPath: URL? = nil,
        now: Date = Date()
    ) throws -> String? {
        guard commandExists("npx") else {
            throw MCPSetupError.message("npx (Node.js) not found - Claude Desktop needs the mcp-remote shim. Install Node first: https://nodejs.org")
        }
        let url = configPath ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claude/claude_desktop_config.json")

        var config: [String: Any] = [:]
        var backupPath: String?
        if let data = try? Data(contentsOf: url) {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPSetupError.message("Existing claude_desktop_config.json is not valid JSON - not touching it.")
            }
            config = parsed
            let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingPathExtension().appendingPathExtension("backup-\(stamp).json")
            try data.write(to: backup)
            backupPath = backup.path
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        }

        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers["nams"] = [
            "command": "npx",
            "args": [
                "-y", "mcp-remote", mcpURL.absoluteString,
                "--header", "Authorization: Bearer \(apiKey)",
            ],
        ]
        config["mcpServers"] = servers

        let data = try JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: .atomic)
        return backupPath
    }

    // MARK: - Shell plumbing

    /// Login-shell invocation so the user's PATH (homebrew, nvm, ...) applies;
    /// a GUI app's default PATH would miss both `claude` and `npx`.
    private static func runShell(_ command: String) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func commandExists(_ name: String) -> Bool {
        (try? runShell("command -v \(name)"))?.status == 0
    }
}
