import Foundation
import UserNotifications

/// Local notifications for received items; banners show even while the app is in front.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ item: ReceivedItem) {
        let content = UNMutableNotificationContent()
        switch item.kind {
        case .file: content.title = "File received"
        case .text: content.title = "Text received and copied"
        case .url: content.title = "Link received and copied"
        }
        content.body = item.title
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
