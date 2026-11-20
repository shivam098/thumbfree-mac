import Foundation
import UserNotifications

/// ThumbFree's notifications in Notification Center (UNUserNotificationCenter), for `Notifier`. Clicking one, or the
/// Copy button of "Your dictation is safe", is reported on the main thread. Permission is asked the first time a
/// dictation starts (`requestPermission`), never at launch; until it's given, notifications aren't shown, and the pill
/// and the menu bar still say what happened. Only an app bundle has Notification Center: `isAvailable`.
public final class UserNotificationSurface: NSObject, NotificationSurface, UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    static let copyAction = "copy"
    static let untypedCategory = "untyped"

    private let center: UNUserNotificationCenter
    private let lock = NSLock()
    private let clicked = Handler<String?>()
    private var lastIdentifier: String?
    private var asked = false

    /// Notification Center exists only for an app bundle with an identifier: not for a bare binary (`swift run`).
    public static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Only when `isAvailable`.
    public override init() {
        center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
        let copy = UNNotificationAction(identifier: Self.copyAction, title: "Copy", options: [])
        let untyped = UNNotificationCategory(
            identifier: Self.untypedCategory, actions: [copy], intentIdentifiers: [], options: [])
        center.setNotificationCategories([untyped])
    }

    public var onClicked: ((String?) -> Void)? {
        get { clicked.handler }
        set { clicked.handler = newValue }
    }

    /// Asks for permission to show notifications, once, if macOS hasn't asked yet.
    public func requestPermission() {
        let first: Bool = lock.withLock {
            defer { asked = true }
            return !asked
        }

        guard first else { return }
        let center = self.center
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                Log.info(granted ? "notifications allowed" : "notifications not allowed")
            }
        }
    }

    public func show(_ title: String, _ text: String, warning: Bool, tag: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = text
        if let tag {
            content.userInfo = ["tag": tag]
            if tag == Notifier.untypedTag {
                content.categoryIdentifier = Self.untypedCategory
            }
        }

        let identifier = UUID().uuidString
        lock.withLock { lastIdentifier = identifier }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
            if let error {
                Log.warn("notification not shown: \(Log.kind(of: error))")
            }
        }
    }

    public func hide() {
        guard let identifier = lock.withLock({ lastIdentifier }) else { return }
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// Shown even while ThumbFree is the active app.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let action = response.actionIdentifier
        if action == UNNotificationDefaultActionIdentifier || action == Self.copyAction {
            let tag = response.notification.request.content.userInfo["tag"] as? String
            let clicked = self.clicked
            DispatchQueue.main.async { clicked(tag) }
        }

        completionHandler()
    }
}
