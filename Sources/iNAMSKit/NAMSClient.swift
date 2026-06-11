import Foundation

public enum NAMSError: Error, Equatable {
    /// 401 — the stored key was revoked or hit its 90-day expiry; re-auth needed.
    case unauthorized
    /// 403 — the key lacks a required scope or violates a workspace binding.
    case forbidden
    /// 429 — back off and retry.
    case rateLimited
    case server(status: Int, message: String)
    case client(status: Int, message: String)
    case invalidResponse

    /// Whether a retry can plausibly succeed without user intervention.
    /// Drives the capture queue's transient/permanent split.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .server:
            return true
        case .unauthorized, .forbidden, .client, .invalidResponse:
            return false
        }
    }
}

/// Without this conformance, surfacing a NAMSError via `localizedDescription`
/// yields the bridged-NSError junk ("iNAMSKit.NAMSError error 0.") and
/// swallows the message payload.
extension NAMSError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "NAMS rejected the credentials (401)."
        case .forbidden:
            return "The API key lacks the required permissions (403)."
        case .rateLimited:
            return "NAMS is rate limiting requests (429) - try again shortly."
        case .server(let status, let message):
            // Status 0 wraps a transport-level failure; the message is the
            // underlying URLError text and stands on its own.
            return status == 0 ? message : "NAMS server error (\(status)): \(message)"
        case .client(let status, let message):
            return "NAMS request failed (\(status)): \(message)"
        case .invalidResponse:
            return "NAMS returned a response the app could not decode."
        }
    }
}

/// Hand-written client for the NAMS REST surface (see docs/PLAN.md for why
/// this is not generated). All calls authenticate with the Bearer token from
/// `tokenProvider` — normally the user's pasted Admin API key out of the
/// Keychain — except where a per-call override is passed (used to validate
/// a freshly pasted key before it is stored).
public final class NAMSClient: Sendable {
    public let config: NAMSConfig
    private let session: URLSession
    private let tokenProvider: @Sendable () -> String?

    public init(
        config: NAMSConfig,
        session: URLSession = .shared,
        tokenProvider: @escaping @Sendable () -> String?
    ) {
        self.config = config
        self.session = session
        self.tokenProvider = tokenProvider
    }

    // MARK: - Auth (nams-auth)

    /// Mint an API key. Requires the stored Admin key (used by MCP setup to
    /// issue workspace-bound keys).
    public func createAPIKey(
        label: String,
        category: String,
        workspaceID: String? = nil
    ) async throws -> CreatedAPIKey {
        var body: [String: String] = ["label": label, "category": category]
        if let workspaceID { body["workspaceId"] = workspaceID }
        return try await send(
            CreatedAPIKey.self, base: config.authBase, method: "POST",
            path: "/auth/api-keys", body: body
        )
    }

    /// List the caller's API keys (metadata only). The endpoint admits user
    /// tokens and Admin keys but 403s workspace-bound keys, so one call with
    /// `bearerOverride` set to a pasted key proves it is both valid and
    /// admin-category — and returns its expiry — before anything is stored.
    public func listAPIKeys(bearerOverride: String? = nil) async throws -> [APIKeyInfo] {
        try await send(
            APIKeyListResponse.self, base: config.authBase, method: "GET",
            path: "/auth/api-keys", bearerOverride: bearerOverride
        ).keys
    }

    // MARK: - Workspaces

    public func listWorkspaces() async throws -> [Workspace] {
        try await send(
            WorkspaceListResponse.self, base: config.apiBase, method: "GET",
            path: "/users/me/workspaces"
        ).workspaces
    }

    /// Database mode + sandbox liveness/expiry. Requires workspace:admin —
    /// the reason the app holds an Admin key. The backend does a live
    /// sandbox-v2 lookup per call, so poll sparingly (the app uses 30 min).
    public func databaseConfig(workspaceID: String) async throws -> DatabaseConfig {
        try await send(
            DatabaseConfig.self, base: config.apiBase, method: "GET",
            path: "/workspace/database", workspaceID: workspaceID
        )
    }

    // MARK: - Memory

    public func createConversation(
        workspaceID: String,
        userID: String? = nil,
        metadata: [String: String]? = nil
    ) async throws -> CreatedConversation {
        var body: [String: AnyJSON] = [:]
        if let userID { body["userId"] = .string(userID) }
        if let metadata { body["metadata"] = .object(metadata.mapValues(AnyJSON.string)) }
        return try await send(
            CreatedConversation.self, base: config.apiBase, method: "POST",
            path: "/conversations", workspaceID: workspaceID, body: body
        )
    }

    public func addMessage(
        conversationID: String,
        workspaceID: String,
        role: String,
        content: String
    ) async throws -> AddedMessage {
        try await send(
            AddedMessage.self, base: config.apiBase, method: "POST",
            path: "/conversations/\(conversationID)/messages", workspaceID: workspaceID,
            body: ["role": role, "content": content]
        )
    }

    /// Workspace-wide hybrid message search (`POST /v1/messages/search`).
    public func searchMessages(
        query: String,
        workspaceID: String,
        limit: Int? = nil
    ) async throws -> MessageSearchResponse {
        var body: [String: AnyJSON] = ["query": .string(query)]
        if let limit { body["limit"] = .int(limit) }
        return try await send(
            MessageSearchResponse.self, base: config.apiBase, method: "POST",
            path: "/messages/search", workspaceID: workspaceID, body: body
        )
    }

    public func searchEntities(
        query: String,
        workspaceID: String,
        type: String? = nil,
        limit: Int? = nil
    ) async throws -> EntitySearchResponse {
        var body: [String: AnyJSON] = ["query": .string(query)]
        if let type { body["type"] = .string(type) }
        if let limit { body["limit"] = .int(limit) }
        return try await send(
            EntitySearchResponse.self, base: config.apiBase, method: "POST",
            path: "/entities/search", workspaceID: workspaceID, body: body
        )
    }

    // MARK: - Plumbing

    private struct Empty: Encodable {}

    private func send<T: Decodable, B: Encodable>(
        _ type: T.Type,
        base: URL,
        method: String,
        path: String,
        workspaceID: String? = nil,
        body: B? = nil as Empty?,
        bearerOverride: String? = nil,
        authenticated: Bool = true
    ) async throws -> T {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        if authenticated {
            guard let token = bearerOverride ?? tokenProvider() else {
                throw NAMSError.unauthorized
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        // The app's Admin key is account-wide (no workspace binding), so the
        // target workspace must travel in the header on data-plane calls.
        if let workspaceID {
            request.setValue(workspaceID, forHTTPHeaderField: "X-Workspace-Id")
        }
        if let body, method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NAMSError.server(status: 0, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NAMSError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw NAMSError.invalidResponse
            }
        case 401:
            throw NAMSError.unauthorized
        case 403:
            throw NAMSError.forbidden
        case 429:
            throw NAMSError.rateLimited
        case 400..<500:
            throw NAMSError.client(status: http.statusCode, message: Self.errorMessage(from: data))
        default:
            throw NAMSError.server(status: http.statusCode, message: Self.errorMessage(from: data))
        }
    }

    private static func errorMessage(from data: Data) -> String {
        struct ErrorBody: Decodable { let error: String? }
        if let body = try? JSONDecoder().decode(ErrorBody.self, from: data), let msg = body.error {
            return msg
        }
        return String(data: data.prefix(200), encoding: .utf8) ?? ""
    }
}

/// Minimal JSON value for heterogeneous request bodies (string + int fields).
public enum AnyJSON: Encodable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case object([String: AnyJSON])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
