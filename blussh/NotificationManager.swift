import Foundation
import UserNotifications

final class NotificationManager {
    private var authorized = false

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.authorized = granted
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
}
