import AppKit
import SwiftmailCore
@preconcurrency import UserNotifications

/// System notifications for new inbox mail and the Dock badge.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let category = "app.swiftmail.message"
    static let archiveAction = "archive"
    static let readAction = "read"
    static let askedKey = "notificationPermissionAsked"

    weak var app: AppModel?
    private var center: UNUserNotificationCenter {
        .current()
    }

    func start() {
        center.delegate = self
        let archive = UNNotificationAction(identifier: Self.archiveAction, title: "Archive")
        let read = UNNotificationAction(identifier: Self.readAction, title: "Mark as Read")
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [archive, read], intentIdentifiers: [])])
    }

    /// Asked the first time an account finishes its inbox sync, not on first launch.
    func requestPermissionIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.askedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ plan: NotificationPlan) {
        switch plan {
        case .none:
            return
        case let .summary(accountID, count):
            let content = UNMutableNotificationContent()
            content.title = "\(count) new messages"
            content.body = app?.account(accountID)?.email ?? ""
            content.sound = .default
            content.userInfo = ["account": accountID]
            center.add(UNNotificationRequest(identifier: "summary-\(UUID().uuidString)", content: content, trigger: nil))
        case let .messages(notifications):
            for notification in notifications {
                let content = UNMutableNotificationContent()
                content.title = notification.title
                content.subtitle = notification.subtitle
                content.body = notification.body
                content.sound = .default
                content.threadIdentifier = notification.threadIdentifier
                content.categoryIdentifier = Self.category
                content.userInfo = ["account": notification.accountID, "thread": notification.threadID]
                center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil))
            }
        }
    }

    /// Read or archived anywhere, including Gmail web: the notification goes away.
    func remove(messageIDs: [String], accountID: String) {
        center.removeDeliveredNotifications(withIdentifiers: messageIDs.map { NotificationPolicy.identifier(accountID: accountID, messageID: $0) })
    }

    func remove(threads: [ThreadSummary.ID]) {
        let wanted = Set(threads.map { NotificationPolicy.threadIdentifier(accountID: $0.accountID, threadID: $0.threadID) })
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { wanted.contains($0.request.content.threadIdentifier) }.map(\.request.identifier)
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// The Dock badge: unread threads in the unified inbox (Primary only when tabs are on).
    func updateBadge(unread: Int) {
        let enabled = UserDefaults.standard.object(forKey: Preferences.dockBadge) as? Bool ?? true
        NSApp.dockTile.badgeLabel = enabled && unread > 0 ? unread.formatted() : nil
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let accountID = info["account"] as? String else { return }
        let threadID = info["thread"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let app = self.app else { return }
            let id = threadID.map { ThreadSummary.ID(accountID: accountID, threadID: $0) }
            switch action {
            case Self.archiveAction:
                if let id {
                    app.perform(.archive, threads: [id], showToast: false)
                }
            case Self.readAction:
                if let id {
                    app.perform(.markRead, threads: [id], showToast: false)
                }
            default:
                app.openThread(id, accountID: accountID)
            }
        }
    }
}
