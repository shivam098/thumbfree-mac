import AppKit
import Foundation

/// Whether the other Mac app is running: ThumbFree watches for Jarvis and Jarvis for ThumbFree. Both use Fn, so with
/// both running every dictation would be typed twice, and each app warns (on Windows, ThumbFree warns the same way at
/// launch about Voice Assistant). NSRunningApplication tells at the start; NSWorkspace's list of running apps, watched
/// with key-value observing, keeps it current.
@MainActor
public final class OtherApp {
    /// The bundle identifier watched for.
    public let bundleIdentifier: String

    /// The other app is running now (once `start()` has been called).
    public private(set) var isRunning = false

    /// Runs on the main thread when the other app starts or quits; how things stand at `start()` is in `isRunning`.
    public var onChange: ((Bool) -> Void)?

    private let workspace: any Workspace
    private let ownProcess = ProcessInfo.processInfo.processIdentifier
    private var processes: Set<pid_t> = []
    private var watching = false

    /// - Parameter workspace: NSWorkspace when nil.
    public init(bundleIdentifier: String, workspace: (any Workspace)? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.workspace = workspace ?? SystemWorkspace()
    }

    /// Watches for the other app of the one with `ownBundleIdentifier` (ThumbFree's or Jarvis's); nil for any other.
    public convenience init?(otherThan ownBundleIdentifier: String?, workspace: (any Workspace)? = nil) {
        guard let other = OtherApp.otherBundleIdentifier(of: ownBundleIdentifier) else { return nil }
        self.init(bundleIdentifier: other, workspace: workspace)
    }

    /// Jarvis's bundle identifier for ThumbFree and ThumbFree's for Jarvis; nil for any other app.
    nonisolated public static func otherBundleIdentifier(of bundleIdentifier: String?) -> String? {
        switch bundleIdentifier {
        case .some(ThumbFreeMac.thumbFreeBundleIdentifier):
            return ThumbFreeMac.jarvisBundleIdentifier
        case .some(ThumbFreeMac.jarvisBundleIdentifier):
            return ThumbFreeMac.thumbFreeBundleIdentifier
        default:
            return nil
        }
    }

    /// Starts watching; `isRunning` tells right away whether the other app is running.
    public func start() {
        guard !watching else { return }
        watching = true
        // Watched first, so an app launching while the list is read isn't missed.
        workspace.observe { [weak self] change, bundleIdentifier, processIdentifier in
            self?.update(change, bundleIdentifier, processIdentifier)
        }
        processes = Set(workspace.processes(bundleIdentifier: bundleIdentifier)).subtracting([ownProcess])
        isRunning = !processes.isEmpty
    }

    public func stop() {
        guard watching else { return }
        watching = false
        workspace.stopObserving()
        processes = []
        isRunning = false
    }

    private func update(_ change: Change, _ bundleIdentifier: String?, _ processIdentifier: pid_t) {
        guard watching, bundleIdentifier == self.bundleIdentifier, processIdentifier != ownProcess else { return }
        switch change {
        case .launched:
            processes.insert(processIdentifier)
        case .quit:
            processes.remove(processIdentifier)
        }

        let running = !processes.isEmpty
        guard running != isRunning else { return }
        isRunning = running
        onChange?(running)
    }
}

extension OtherApp {
    public enum Change: Equatable, Sendable {
        case launched
        case quit
    }

    /// What OtherApp needs from NSWorkspace; faked in tests.
    public protocol Workspace: AnyObject {
        /// The process identifiers of the running apps with this bundle identifier.
        func processes(bundleIdentifier: String) -> [pid_t]
        /// Calls `handler` on the main thread with each app that launches or quits (its bundle identifier and process
        /// identifier), until `stopObserving()`.
        func observe(_ handler: @escaping @MainActor @Sendable (OtherApp.Change, String?, pid_t) -> Void)
        func stopObserving()
    }

    /// NSRunningApplication, and NSWorkspace's list of running apps watched with key-value observing. (The workspace's
    /// launch and quit notifications aren't posted for apps with LSUIElement, which ThumbFree and Jarvis both are.)
    public final class SystemWorkspace: Workspace {
        private var observation: NSKeyValueObservation?

        public init() {}

        deinit {
            stopObserving()
        }

        public func processes(bundleIdentifier: String) -> [pid_t] {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .filter { !$0.isTerminated }
                .map(\.processIdentifier)
        }

        public func observe(_ handler: @escaping @MainActor @Sendable (OtherApp.Change, String?, pid_t) -> Void) {
            stopObserving()
            observation = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new]) { _, change in
                let (launched, quit) = SystemWorkspace.difference(
                    old: change.oldValue.map(SystemWorkspace.apps), new: change.newValue.map(SystemWorkspace.apps))
                guard !launched.isEmpty || !quit.isEmpty else { return }
                // The list changes on the main run loop; the handler runs on the main thread in any case.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Launches first, so an app replaced by a new copy in one change never reads as gone.
                        for app in launched {
                            handler(.launched, app.bundleIdentifier, app.processIdentifier)
                        }

                        for app in quit {
                            handler(.quit, app.bundleIdentifier, app.processIdentifier)
                        }
                    }
                }
            }
        }

        public func stopObserving() {
            observation?.invalidate()
            observation = nil
        }

        /// A running app, as far as OtherApp cares.
        struct App: Hashable, Sendable {
            let bundleIdentifier: String?
            let processIdentifier: pid_t
        }

        /// The apps that launched and quit in one change of the list of running apps, from its old and new values. Apps
        /// that launched come as an insertion (only new values), apps that quit as a removal (only old values), and a
        /// whole new list as both.
        static func difference(old: [App]?, new: [App]?) -> (launched: Set<App>, quit: Set<App>) {
            let before = Set(old ?? [])
            let after = Set(new ?? [])
            return (after.subtracting(before), before.subtracting(after))
        }

        private static func apps(_ list: [NSRunningApplication]) -> [App] {
            list.map { app in
                App(bundleIdentifier: app.bundleIdentifier, processIdentifier: app.processIdentifier)
            }
        }
    }
}
