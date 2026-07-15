import Foundation
@preconcurrency import UserNotifications

public protocol UsageAlertNotifying: AnyObject {
    @MainActor
    func requestAuthorization() async -> Bool

    @MainActor
    func deliver(_ notification: UsageAlertNotification) async throws
}

@MainActor
public final class LocalUsageAlertNotifier: NSObject, UsageAlertNotifying, UNUserNotificationCenterDelegate {
    public static let shared = LocalUsageAlertNotifier()

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    @MainActor
    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    @MainActor
    public func deliver(_ notification: UsageAlertNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.userInfo = [
            "accountID": notification.accountID,
            "kind": notification.kind.rawValue,
        ]

        let request = UNNotificationRequest(
            identifier: notification.id,
            content: content,
            trigger: nil
        )

        try await center.add(request)
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
