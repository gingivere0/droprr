import Foundation
import UserNotifications

/// Local notifications for received items; banners show even while the app is in front,
/// and clicking one opens the item.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Called on the main queue with the file or link a clicked notification refers to.
    var onOpen: (URL) -> Void = { _ in }

    func requestPermission() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ item: ReceivedItem, from source: String? = nil) {
        let content = UNMutableNotificationContent()
        let suffix = source.map { " from \($0)" } ?? ""
        switch item.kind {
        case .file(let url):
            content.title = "File received\(suffix)"
            content.userInfo = ["open": url.absoluteString]
        case .text:
            content.title = "Text copied\(suffix)"
        case .url(let url):
            content.title = "Link copied\(suffix)"
            content.userInfo = ["open": url.absoluteString]
        }
        content.body = item.title
        content.sound = .default
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let string = response.notification.request.content.userInfo["open"] as? String, let url = URL(string: string) {
            DispatchQueue.main.async { self.onOpen(url) }
        }
        completionHandler()
    }
}
