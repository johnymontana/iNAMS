import XCTest
@testable import iNAMSKit

final class CaptureQueueTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inams-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testEnqueuePersistsAcrossReload() async throws {
        let queue = try CaptureQueue(directory: dir)
        try await queue.enqueue(text: "remember the milk", workspaceID: "ws-1")
        try await queue.enqueue(text: "sandbox expires friday", workspaceID: "ws-1")

        // A fresh instance over the same directory must see both captures —
        // this is the survives-quit/crash guarantee.
        let reloaded = try CaptureQueue(directory: dir)
        let pending = await reloaded.pending
        XCTAssertEqual(pending.map(\.text), ["remember the milk", "sandbox expires friday"])
        XCTAssertEqual(pending.map(\.attempts), [0, 0])
    }

    func testDrainDeliveredRemovesItems() async throws {
        let queue = try CaptureQueue(directory: dir)
        try await queue.enqueue(text: "a", workspaceID: "ws-1")
        try await queue.enqueue(text: "b", workspaceID: "ws-1")

        let summary = await queue.drain { _ in .delivered }
        XCTAssertEqual(summary, .init(delivered: 2, transientFailures: 0, permanentFailures: 0))
        let count = await queue.pendingCount
        XCTAssertEqual(count, 0)

        let reloaded = try CaptureQueue(directory: dir)
        let reloadedCount = await reloaded.pendingCount
        XCTAssertEqual(reloadedCount, 0, "delivery must persist")
    }

    func testDrainTransientKeepsAndIncrementsAttempts() async throws {
        let queue = try CaptureQueue(directory: dir)
        try await queue.enqueue(text: "a", workspaceID: "ws-1")

        var summary = await queue.drain { _ in .transient("connection refused") }
        XCTAssertEqual(summary, .init(delivered: 0, transientFailures: 1, permanentFailures: 0))
        summary = await queue.drain { _ in .transient("connection refused") }
        XCTAssertEqual(summary.transientFailures, 1)

        let pending = await queue.pending
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].attempts, 2)
        XCTAssertEqual(pending[0].lastError, "connection refused")
    }

    func testDrainPermanentMovesToDeadLetter() async throws {
        let queue = try CaptureQueue(directory: dir)
        try await queue.enqueue(text: "orphaned note", workspaceID: "ws-gone")

        let summary = await queue.drain { _ in .permanent("workspace deleted") }
        XCTAssertEqual(summary, .init(delivered: 0, transientFailures: 0, permanentFailures: 1))
        let count = await queue.pendingCount
        XCTAssertEqual(count, 0)

        // Dead-lettered text survives reload — never silently lost.
        let reloaded = try CaptureQueue(directory: dir)
        let failed = await reloaded.failed
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed[0].capture.text, "orphaned note")
        XCTAssertEqual(failed[0].reason, "workspace deleted")
    }

    func testMixedDrainOutcomes() async throws {
        let queue = try CaptureQueue(directory: dir)
        try await queue.enqueue(text: "ok", workspaceID: "ws-1")
        try await queue.enqueue(text: "retry-me", workspaceID: "ws-1")
        try await queue.enqueue(text: "dead", workspaceID: "ws-1")

        let summary = await queue.drain { capture in
            switch capture.text {
            case "ok": return .delivered
            case "retry-me": return .transient("503")
            default: return .permanent("401")
            }
        }
        XCTAssertEqual(summary, .init(delivered: 1, transientFailures: 1, permanentFailures: 1))
        let pending = await queue.pending
        XCTAssertEqual(pending.map(\.text), ["retry-me"])
    }
}
