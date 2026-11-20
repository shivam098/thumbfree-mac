import AppKit
import AVFoundation
import Network
import ServiceManagement
import ThumbFreeMac
import UserNotifications

/// Whether ThumbFree may use the microphone (thumbfree-windows `MicrophoneAccess`).
public enum MicrophoneAccess: Sendable {
    case allowed
    /// macOS hasn't asked yet: it asks the first time ThumbFree listens.
    case notAsked
    /// Not allowed: only System Settings › Privacy & Security › Microphone changes it.
    case denied
    case noMicrophone
}

/// A yes/no question: `confirm` is the button that does it ("Delete", "Download").
public struct Confirmation: Equatable, Sendable {
    public var title: String
    public var message: String
    public var confirm: String
    public var cancel: String
    public var danger: Bool

    public init(title: String, message: String, confirm: String, cancel: String = "Cancel", danger: Bool = false) {
        self.title = title
        self.message = message
        self.confirm = confirm
        self.cancel = cancel
        self.danger = danger
    }
}

/// What the menu bar (and the window and the guide, in phase 4) ask of macOS (thumbfree-windows `IAppEnvironment`).
/// Tests use a fake, so they never touch the pasteboard, the login items or the screen. Use it from the main thread,
/// except `notificationsEnabled`, which the dictation host asks on its own thread.
public protocol AppEnvironment: AnyObject {
    /// "Start at login" (SMAppService: ThumbFree starts in the menu bar).
    var startsAtLogin: Bool { get set }

    /// This Mac's physical memory.
    var totalMemoryBytes: Int64 { get }

    func copyText(_ text: String)

    /// Opens a web page, a System Settings pane, a file or a folder.
    func open(_ url: URL)

    /// Opens Finder with `path` selected.
    func showInFinder(_ path: String)

    /// macOS says the connection costs data: a phone's hotspot, or Low Data Mode.
    func isMeteredConnection() -> Bool

    func checkMicrophone() -> MicrophoneAccess

    /// Notifications are allowed for ThumbFree.
    func notificationsEnabled() -> Bool

    func confirm(_ question: Confirmation) -> Bool

    /// Asks where to save a file; nil when cancelled.
    func askSavePath(title: String, fileName: String) -> String?
}

/// The real `AppEnvironment`.
public final class MacEnvironment: AppEnvironment, @unchecked Sendable {
    private let permissions: Permissions

    public init(permissions: Permissions = Permissions()) {
        self.permissions = permissions
    }

    /// Registered as a login item. One that waits for approval in System Settings › General › Login Items counts as
    /// off until it's approved; turning it on opens that pane then.
    public var startsAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                    if SMAppService.mainApp.status == .requiresApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                } else {
                    try SMAppService.mainApp.unregister()
                }

                Log.info(newValue ? "starts at login" : "doesn't start at login")
            } catch {
                Log.warn("couldn't change start at login: \(Log.kind(of: error))")
            }
        }
    }

    public var totalMemoryBytes: Int64 { Int64(clamping: ProcessInfo.processInfo.physicalMemory) }

    /// For this Mac only: Universal Clipboard doesn't offer your dictations to your other devices (as Windows keeps
    /// them from the cloud clipboard).
    public func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        if !pasteboard.setString(text, forType: .string) {
            Log.warn("couldn't copy to the pasteboard")
        }
    }

    public func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            Log.warn("couldn't open \(url.scheme ?? "a link")")
        }
    }

    public func showInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Asks the network stack once, waiting a second at most (unknown counts as not metered).
    public func isMeteredConnection() -> Bool {
        let monitor = NWPathMonitor()
        let metered = LockedValue(false)
        let answered = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            metered.value = path.isExpensive || path.isConstrained
            answered.signal()
        }

        monitor.start(queue: DispatchQueue.global(qos: .utility))
        _ = answered.wait(timeout: .now() + 1)
        monitor.cancel()
        return metered.value
    }

    public func checkMicrophone() -> MicrophoneAccess {
        switch permissions.status(.microphone) {
        case .granted:
            return AVCaptureDevice.default(for: .audio) == nil ? .noMicrophone : .allowed
        case .notDetermined:
            return .notAsked
        case .denied:
            return .denied
        }
    }

    /// Waits a second at most for Notification Center's answer; true when it can't tell.
    public func notificationsEnabled() -> Bool {
        guard UserNotificationSurface.isAvailable else { return false }
        let enabled = LockedValue(true)
        let answered = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            enabled.value = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            answered.signal()
        }

        _ = answered.wait(timeout: .now() + 1)
        return enabled.value
    }

    /// An alert, with ThumbFree brought to the front for it. Main thread only.
    public func confirm(_ question: Confirmation) -> Bool {
        MainActor.assumeIsolated {
            AppKitHelpers.activate()
            let alert = NSAlert()
            alert.messageText = question.title
            alert.informativeText = question.message
            alert.alertStyle = question.danger ? .critical : .informational
            let button = alert.addButton(withTitle: question.confirm)
            button.hasDestructiveAction = question.danger
            alert.addButton(withTitle: question.cancel)
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    /// A save panel, with ThumbFree brought to the front for it. Main thread only.
    public func askSavePath(title: String, fileName: String) -> String? {
        MainActor.assumeIsolated {
            AppKitHelpers.activate()
            let panel = NSSavePanel()
            panel.title = title
            panel.nameFieldStringValue = fileName
            panel.canCreateDirectories = true
            return panel.runModal() == .OK ? panel.url?.path : nil
        }
    }
}

/// AppKit calls the app layer shares.
@MainActor
enum AppKitHelpers {
    /// Brings ThumbFree to the front, for an alert or a panel (it's a menu-bar app, so it isn't otherwise).
    static func activate() {
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
