import AppKit
import Combine
import iNAMSKit

/// Central app services + observable UI state. Everything here is MainActor;
/// the durable queue and HTTP client it owns are concurrency-safe themselves.
@MainActor
final class AppState: ObservableObject {
    let keychain = KeychainStore()
    let config = NAMSConfig.resolved()
    let client: NAMSClient
    let queue: CaptureQueue?
    private let auth = AuthController()

    @Published var isSignedIn: Bool
    @Published var workspaces: [Workspace] = []
    @Published var selectedWorkspaceID: String? {
        didSet { UserDefaults.standard.set(selectedWorkspaceID, forKey: "SelectedWorkspaceID") }
    }
    @Published var pendingCount = 0
    @Published var sandboxExpiresAt: Date?
    @Published var sandboxActive: Bool?
    @Published var lastError: String?

    private var pollTimer: Timer?
    private var drainTimer: Timer?

    init() {
        let keychain = self.keychain
        client = NAMSClient(config: config) {
            keychain.get(account: KeychainStore.apiKeyAccount)
        }
        queue = try? CaptureQueue(directory: CaptureQueue.defaultDirectory())
        isSignedIn = keychain.get(account: KeychainStore.apiKeyAccount) != nil
        selectedWorkspaceID = UserDefaults.standard.string(forKey: "SelectedWorkspaceID")
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    func start() {
        Notifier.requestAuthorization()
        Task { await refreshStatus() }
        Task { await refreshPendingCount(); await drainNow() }

        // Status poll: 30 min. GET /v1/workspace/database does a live
        // owner-authenticated sandbox-v2 lookup per call - poll sparingly;
        // the expiry countdown ticks locally off the cached date.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.refreshStatus() }
        }
        // Queue drain: cheap no-op when empty.
        drainTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor [weak self] in await self?.drainNow() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        drainTimer?.invalidate()
    }

    // MARK: - Capture

    /// Always succeeds instantly into the durable local queue; delivery is
    /// the drain's job. This is the hotkey's "never lose a note" promise.
    func capture(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let workspaceID = selectedWorkspaceID else {
            lastError = "No workspace selected - sign in first"
            return
        }
        guard let queue else {
            lastError = "Capture queue unavailable"
            return
        }
        do {
            try await queue.enqueue(text: trimmed, workspaceID: workspaceID)
        } catch {
            lastError = "Failed to persist capture: \(error.localizedDescription)"
            return
        }
        await refreshPendingCount()
        Task { await drainNow() }
    }

    func drainNow() async {
        guard let queue, await queue.pendingCount > 0 else { return }
        let client = self.client
        let summary = await queue.drain { [weak self] capture in
            guard let self else { return .transient("shutting down") }
            do {
                let convID = try await self.quickCaptureConversationID(workspaceID: capture.workspaceID)
                _ = try await client.addMessage(
                    conversationID: convID, workspaceID: capture.workspaceID,
                    role: "user", content: capture.text
                )
                return .delivered
            } catch let error as NAMSError {
                let reason = String(describing: error)
                return error.isTransient ? .transient(reason) : .permanent(reason)
            } catch {
                return .transient(error.localizedDescription)
            }
        }
        if summary.permanentFailures > 0 {
            Notifier.notifyNow(
                id: "capture-failed",
                title: "Some captures could not be saved to NAMS",
                body: "\(summary.permanentFailures) note(s) hit a permanent error (revoked key or missing workspace). They are kept locally - see the menu."
            )
        }
        await refreshPendingCount()
    }

    private func refreshPendingCount() async {
        guard let queue else { return }
        pendingCount = await queue.pendingCount
    }

    /// Quick captures all land in one idempotently-created conversation per
    /// workspace so the observation/reflection pipeline gets message density.
    /// The id is remembered locally; if the mapping is lost a fresh
    /// conversation is created (old notes stay searchable).
    private func quickCaptureConversationID(workspaceID: String) async throws -> String {
        let key = "QuickCaptureConversationIDs"
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        if let existing = map[workspaceID] { return existing }
        let created = try await client.createConversation(
            workspaceID: workspaceID,
            metadata: ["source": "inams", "kind": "quick-capture"]
        )
        map[workspaceID] = created.id
        UserDefaults.standard.set(map, forKey: key)
        return created.id
    }

    // MARK: - Search

    struct SearchResults {
        var messages: [MessageHit] = []
        var entities: [EntityHit] = []
        var searchType = ""
    }

    func search(_ query: String) async -> SearchResults {
        guard let workspaceID = selectedWorkspaceID, !query.isEmpty else { return SearchResults() }
        var results = SearchResults()
        async let messages = try? client.searchMessages(query: query, workspaceID: workspaceID, limit: 10)
        async let entities = try? client.searchEntities(query: query, workspaceID: workspaceID, limit: 10)
        if let m = await messages {
            results.messages = m.messages
            results.searchType = m.searchType
        }
        if let e = await entities {
            results.entities = e.entities
            if results.searchType.isEmpty { results.searchType = e.searchType }
        }
        return results
    }

    // MARK: - Status

    func refreshStatus() async {
        guard isSignedIn else { return }
        do {
            workspaces = try await client.listWorkspaces()
            if selectedWorkspaceID == nil || !workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
                selectedWorkspaceID = workspaces.first?.id
            }
            lastError = nil
        } catch let error as NAMSError where error == .unauthorized {
            // Key revoked or past its 90-day expiry - surface re-auth.
            isSignedIn = false
            lastError = "Session expired - sign in again"
            return
        } catch {
            lastError = "Status refresh failed: \(error)"
            return
        }

        guard let workspaceID = selectedWorkspaceID else { return }
        do {
            let db = try await client.databaseConfig(workspaceID: workspaceID)
            sandboxActive = db.sandboxActive
            sandboxExpiresAt = db.sandboxExpiresAt
            if let expiry = db.sandboxExpiresAt {
                Notifier.scheduleSandboxWarnings(
                    expiry: expiry,
                    workspaceName: selectedWorkspace?.name ?? workspaceID
                )
            }
            if db.sandboxActive == false {
                notifyDeprovisionOnce(workspaceID: workspaceID)
            }
        } catch {
            // Expiry is fetched live server-side; transient failure just means
            // "couldn't tell this tick" - keep the last known value.
        }
    }

    private func notifyDeprovisionOnce(workspaceID: String) {
        let key = "DeprovisionNotified"
        var notified = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !notified.contains(workspaceID) else { return }
        notified.append(workspaceID)
        UserDefaults.standard.set(notified, forKey: key)
        Notifier.notifyNow(
            id: "deprovisioned-\(workspaceID)",
            title: "NAMS workspace database is gone",
            body: "The sandbox for “\(selectedWorkspace?.name ?? workspaceID)” is no longer active. Re-provision it from the dashboard."
        )
    }

    // MARK: - Auth

    func signIn() async {
        do {
            try await auth.signIn(client: client, keychain: keychain)
            isSignedIn = true
            lastError = nil
            await refreshStatus()
        } catch {
            lastError = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    func signOut() {
        try? keychain.delete(account: KeychainStore.apiKeyAccount)
        try? keychain.delete(account: KeychainStore.apiKeyIDAccount)
        isSignedIn = false
        workspaces = []
        sandboxExpiresAt = nil
        sandboxActive = nil
    }

    // MARK: - MCP setup

    enum MCPTarget: String {
        case claudeCode = "Claude Code"
        case claudeDesktop = "Claude Desktop"
    }

    /// Mints a fresh Workspace-bound key (data-plane scopes only - never the
    /// app's Admin key) and writes it into the chosen client's config.
    func setupMCP(_ target: MCPTarget) async throws -> String {
        guard let workspaceID = selectedWorkspaceID else {
            throw MCPSetupError.message("No workspace selected")
        }
        let host = Host.current().localizedName ?? "Mac"
        let created = try await client.createAPIKey(
            label: "MCP – \(target.rawValue) – \(host)",
            category: "workspace",
            workspaceID: workspaceID
        )
        switch target {
        case .claudeCode:
            try MCPSetup.setupClaudeCode(mcpURL: config.mcpBase, apiKey: created.key)
            return "Added the “nams” MCP server to Claude Code (user scope) with a fresh workspace-bound key."
        case .claudeDesktop:
            let backup = try MCPSetup.setupClaudeDesktop(mcpURL: config.mcpBase, apiKey: created.key)
            return "Added “nams” to Claude Desktop via mcp-remote. Backup of the previous config: \(backup ?? "none (new file)"). Restart Claude Desktop to pick it up."
        }
    }
}
