import Foundation
import UserNotifications

/// Local-notification helper. UNUserNotificationCenter requires a real app
/// bundle; under `swift run` (no bundle id) every call degrades to a no-op so
/// development builds don't crash.
enum Notifier {
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Replace any scheduled sandbox warnings with fresh ones at expiry-24h
    /// and expiry-1h. Re-invoked on every status poll, so extensions push the
    /// warnings out automatically.
    static func scheduleSandboxWarnings(expiry: Date, workspaceName: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        let ids = ["sandbox-24h", "sandbox-1h"]
        center.removePendingNotificationRequests(withIdentifiers: ids)

        let warnings: [(String, TimeInterval, String)] = [
            ("sandbox-24h", 24 * 3600, "expires in 24 hours"),
            ("sandbox-1h", 3600, "expires in 1 hour"),
        ]
        for (id, lead, phrase) in warnings {
            let fireDate = expiry.addingTimeInterval(-lead)
            guard fireDate > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = "NAMS sandbox \(phrase)"
            content.body = "The database for “\(workspaceName)” \(phrase.replacingOccurrences(of: "expires", with: "will be reaped")). Export or extend it from the dashboard."
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: fireDate.timeIntervalSinceNow, repeats: false
            )
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    /// The app never rotates a pasted key (the user owns it and may rely on
    /// it elsewhere), so advance warning is the only defense against the
    /// fixed 90-day cutoff. Scheduled once per successful connect.
    static func scheduleKeyExpiryWarnings(expiry: Date) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: keyExpiryIDs)

        let warnings: [(String, TimeInterval, String)] = [
            ("key-expiry-7d", 7 * 24 * 3600, "in 7 days"),
            ("key-expiry-1d", 24 * 3600, "tomorrow"),
        ]
        for (id, lead, phrase) in warnings {
            let fireDate = expiry.addingTimeInterval(-lead)
            guard fireDate > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = "iNAMS API key expires \(phrase)"
            content.body = "Mint a fresh Admin key in the NAMS dashboard and paste it via “Connect to NAMS…” in the menu bar before access stops."
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: fireDate.timeIntervalSinceNow, repeats: false
            )
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    static func cancelKeyExpiryWarnings() {
        guard available else { return }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: keyExpiryIDs)
    }

    private static let keyExpiryIDs = ["key-expiry-7d", "key-expiry-1d"]

    static func notifyNow(id: String, title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }
}
