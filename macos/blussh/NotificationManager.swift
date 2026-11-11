import Foundation
import UserNotifications

final class NotificationManager {
    private var authorized = false

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            self.authorized = granted
            NSLog("blussh notifications: granted=\(granted) error=\(error?.localizedDescription ?? "none")")
        }
    }

    func notify(host: MonitoredHost, isUp: Bool) {
        guard authorized, UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true else { return }

        let content = UNMutableNotificationContent()
        content.title = isUp ? "🟢 \(host.name) is back up" : "🔴 \(host.name) went down"
        content.body = "\(host.origin.groupTitle) · \(host.address)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(host.id)-\(isUp ? "up" : "down")",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Result of an action the user started (T3 pairing, linking). Not gated by the
    /// down/up notifications setting: it's the only feedback once the popover closes.
    /// Callers must never pass a pairing token in `title` or `body`.
    func notifyAction(title: String, body: String, failed: Bool) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if failed { content.sound = .default }
        let request = UNNotificationRequest(identifier: "action-\(UUID().uuidString)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
