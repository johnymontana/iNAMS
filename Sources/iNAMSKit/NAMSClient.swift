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

/// Hand-written client for the NAMS REST surface (see docs/PLAN.md for why
/// this is not generated). All calls authenticate with the Bearer token from
/// `tokenProvider` — normally the app's self-provisioned Admin API key out of
/// the Keychain — except where a per-call override is passed (used during
/// onboarding, when the key to use was just issued and isn't stored yet).
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

    /// Exchange an Auth0 access token (plus optional ID token, revalidated
    /// server-side against Auth0's JWKS) for short-lived per-workspace JWTs.
    public func exchange(auth0AccessToken: String, idToken: String?) async throws -> ExchangeResponse {
        var body: [String: String] = ["access_token": auth0AccessToken]
        if let idToken { body["id_token"] = idToken }
        return try await send(
            ExchangeResponse.self, base: config.authBase, method: "POST",
            path: "/v1/auth/exchange", body: body, authenticated: false
        )
    }

    /// Mint an API key. Requires a user token or an Admin key; pass
    /// `bearerOverride` when bootstrapping with a just-exchanged JWT.
    public func createAPIKey(
        label: String,
        category: String,
        workspaceID: String? = nil,
        bearerOverride: String? = nil
    ) async throws -> CreatedAPIKey {
        var body: [String: String] = ["label": label, "category": category]
        if let workspaceID { body["workspaceId"] = workspaceID }
        return try await send(
            CreatedAPIKey.self, base: config.authBase, method: "POST",
            path: "/v1/auth/api-keys", body: body, bearerOverride: bearerOverride
        )
    }

    /// Rotate the app's own key before its 90-day expiry.
    public func rotateAPIKey(id: String) async throws -> CreatedAPIKey {
        try await send(
            CreatedAPIKey.self, base: config.authBase, method: "POST",
            path: "/v1/auth/api-keys/\(id)/rotate", body: Empty()
        )
    }

    // MARK: - Workspaces

    public func listWorkspaces() async throws -> [Workspace] {
        try await send(
            WorkspaceListResponse.self, base: config.apiBase, method: "GET",
            path: "/v1/users/me/workspaces"
        ).workspaces
    }

    /// Database mode + sandbox liveness/expiry. Requires workspace:admin —
    /// the reason the app holds an Admin key. The backend does a live
    /// sandbox-v2 lookup per call, so poll sparingly (the app uses 30 min).
    public func databaseConfig(workspaceID: String) async throws -> DatabaseConfig {
        try await send(
            DatabaseConfig.self, base: config.apiBase, method: "GET",
            path: "/v1/workspace/database", workspaceID: workspaceID
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
            path: "/v1/conversations", workspaceID: workspaceID, body: body
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
            path: "/v1/conversations/\(conversationID)/messages", workspaceID: workspaceID,
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
            path: "/v1/messages/search", workspaceID: workspaceID, body: body
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
            path: "/v1/entities/search", workspaceID: workspaceID, body: body
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
