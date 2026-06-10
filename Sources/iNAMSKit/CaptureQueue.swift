import Foundation

/// A note captured via the hotkey, waiting to be delivered to NAMS.
public struct PendingCapture: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let text: String
    public let workspaceID: String
    public let createdAt: Date
    public var attempts: Int
    public var lastError: String?

    public init(id: UUID = UUID(), text: String, workspaceID: String, createdAt: Date, attempts: Int = 0, lastError: String? = nil) {
        self.id = id
        self.text = text
        self.workspaceID = workspaceID
        self.createdAt = createdAt
        self.attempts = attempts
        self.lastError = lastError
    }
}

/// A capture that hit a permanent failure (revoked key, deleted workspace).
/// Kept on disk so the note text is never silently lost.
public struct FailedCapture: Codable, Sendable, Equatable {
    public let capture: PendingCapture
    public let reason: String
    public let failedAt: Date
}

public enum SendOutcome: Sendable {
    case delivered
    /// Worth retrying on the next drain (network down, 5xx, 429).
    case transient(String)
    /// Retrying cannot help (401, 403, workspace gone); dead-letter it.
    case permanent(String)
}

/// Durable local queue backing quick capture: enqueue always succeeds
/// instantly; a background drain delivers with retry. This is the app's
/// trust contract — the hotkey never loses a note.
public actor CaptureQueue {
    public struct DrainSummary: Sendable, Equatable {
        public var delivered = 0
        public var transientFailures = 0
        public var permanentFailures = 0
    }

    private let pendingURL: URL
    private let failedURL: URL
    private var items: [PendingCapture]
    private var failedItems: [FailedCapture]

    /// `directory` is created if missing. Production callers use
    /// `CaptureQueue.defaultDirectory()`; tests pass a temp dir.
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pendingURL = directory.appendingPathComponent("pending-captures.json")
        failedURL = directory.appendingPathComponent("failed-captures.json")
        items = Self.load([PendingCapture].self, from: pendingURL) ?? []
        failedItems = Self.load([FailedCapture].self, from: failedURL) ?? []
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iNAMS", isDirectory: true)
    }

    public var pending: [PendingCapture] { items }
    public var pendingCount: Int { items.count }
    public var failed: [FailedCapture] { failedItems }

    @discardableResult
    public func enqueue(text: String, workspaceID: String, now: Date = Date()) throws -> PendingCapture {
        let capture = PendingCapture(text: text, workspaceID: workspaceID, createdAt: now)
        items.append(capture)
        try persistPending()
        return capture
    }

    /// Attempt delivery of every pending capture, oldest first. Transient
    /// failures stay queued with an incremented attempt count; permanent
    /// failures move to the dead-letter file.
    public func drain(now: Date = Date(), send: @Sendable (PendingCapture) async -> SendOutcome) async -> DrainSummary {
        var summary = DrainSummary()
        var remaining: [PendingCapture] = []
        for var item in items {
            switch await send(item) {
            case .delivered:
                summary.delivered += 1
            case .transient(let reason):
                item.attempts += 1
                item.lastError = reason
                remaining.append(item)
                summary.transientFailures += 1
            case .permanent(let reason):
                failedItems.append(FailedCapture(capture: item, reason: reason, failedAt: now))
                summary.permanentFailures += 1
            }
        }
        items = remaining
        try? persistPending()
        try? persistFailed()
        return summary
    }

    public func clearFailed() throws {
        failedItems = []
        try persistFailed()
    }

    // MARK: - Persistence

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (encoder, decoder)
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? coder().1.decode(T.self, from: data)
    }

    private func persistPending() throws {
        try Self.coder().0.encode(items).write(to: pendingURL, options: .atomic)
    }

    private func persistFailed() throws {
        try Self.coder().0.encode(failedItems).write(to: failedURL, options: .atomic)
    }
}
