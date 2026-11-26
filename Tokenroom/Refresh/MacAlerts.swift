import Foundation
import UserNotifications

enum MacAlerts {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(_ alerts: [UsageAlert]) {
        let center = UNUserNotificationCenter.current()
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = alert.isUrgent ? .default : nil
            content.threadIdentifier = alert.provider
            center.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil))
        }
    }
}
