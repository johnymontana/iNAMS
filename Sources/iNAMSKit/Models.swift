import Foundation

// Codable mirrors of the NAMS REST responses iNAMS consumes. Shapes match the
// Go handlers in project-gaylord (see vendor/openapi.json for the documented
// contract); fields the app never reads are omitted on purpose.

// MARK: - Auth (nams-auth)

/// `POST /v1/auth/api-keys` (201). The raw key is returned exactly once.
public struct CreatedAPIKey: Codable, Sendable, Equatable {
    public let id: String
    public let key: String
    public let label: String
    public let category: String?
    public let workspaceId: String?
}

/// One row of `GET /v1/auth/api-keys` — metadata only, never the raw key.
public struct APIKeyInfo: Codable, Sendable, Equatable {
    public let id: String
    public let label: String?
    public let createdAt: String?
    public let revokedAt: String?
    public let expiresAt: String?
    public let scopes: [String]?
    public let workspaceId: String?

    /// Expiry as a Date. The backend emits RFC3339 with fractional seconds
    /// (Go time.Time through JSON), but accept the plain form too.
    public var expiryDate: Date? {
        guard let expiresAt else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
    }
}

struct APIKeyListResponse: Codable {
    let keys: [APIKeyInfo]
}

/// Raw NAMS keys embed their own ID — `nams_<keyID>_<secret>` — so a pasted
/// key can be matched against the metadata list without an extra endpoint.
/// The keyID length is the backend's to choose; only the shape is assumed.
public enum APIKeyFormat {
    public static func keyID(fromRawKey raw: String) -> String? {
        let prefix = "nams_"
        guard raw.hasPrefix(prefix) else { return nil }
        let rest = raw.dropFirst(prefix.count)
        guard let underscore = rest.firstIndex(of: "_"), rest.startIndex < underscore else { return nil }
        return String(rest[..<underscore])
    }
}

// MARK: - Workspaces (nams-tenants via nams-api proxy)

/// One row of `GET /v1/users/me/workspaces`.
public struct Workspace: Codable, Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    public let name: String?
    public let status: String?
    public let role: String?
    public let dbMode: String?
}

struct WorkspaceListResponse: Codable {
    let workspaces: [Workspace]
}

/// `GET /v1/workspace/database`. In managed mode `connections.rw.expiresAt`
/// carries the sandbox reaping deadline, fetched live by the backend —
/// absent whenever sandbox-v2 was unreachable.
public struct DatabaseConfig: Codable, Sendable, Equatable {
    public let mode: String
    public let connection: ConnectionInfo?
    public let connections: ManagedConnections?
    public let sandboxActive: Bool?

    /// Sandbox expiry as a Date, when the backend could determine it.
    public var sandboxExpiresAt: Date? {
        guard let iso = connections?.rw?.expiresAt else { return nil }
        return ISO8601DateFormatter().date(from: iso)
    }
}

public struct ManagedConnections: Codable, Sendable, Equatable {
    public let rw: ConnectionInfo?
    public let ro: ConnectionInfo?
}

public struct ConnectionInfo: Codable, Sendable, Equatable {
    public let uri: String?
    public let database: String?
    public let username: String?
    public let expiresAt: String?
}

// MARK: - Memory (nams-api)

/// `POST /v1/conversations` (201).
public struct CreatedConversation: Codable, Sendable, Equatable {
    public let id: String
}

/// `POST /v1/conversations/:id/messages` (201).
public struct AddedMessage: Codable, Sendable, Equatable {
    public let id: String
    public let conversationId: String
    public let role: String
    public let content: String
}

/// One hit from `POST /v1/messages/search` (workspace-wide) or
/// `POST /v1/conversations/:id/search` (where conversationId is absent).
public struct MessageHit: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let role: String?
    public let content: String?
    public let tokenCount: Int?
    public let createdAt: String?
    public let conversationId: String?
    public let score: Double?
}

public struct MessageSearchResponse: Codable, Sendable, Equatable {
    public let messages: [MessageHit]
    /// "vector" or "text" — which search strategy the backend used.
    public let searchType: String
}

/// One hit from `POST /v1/entities/search`.
public struct EntityHit: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String?
    public let type: String?
    public let description: String?
    public let score: Double?
}

public struct EntitySearchResponse: Codable, Sendable, Equatable {
    public let entities: [EntityHit]
    public let searchType: String
}
