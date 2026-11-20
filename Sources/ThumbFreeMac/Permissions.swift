import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics
import Foundation

/// The permissions dictation needs, how macOS has answered, and where to change them in System Settings. The first-run
/// guide explains each one before macOS's own prompt shows (PLAN 3.5, 3.7), so nothing here asks on its own.
public struct Permissions {
    public enum Kind: String, CaseIterable, Sendable {
        /// Hearing you.
        case microphone
        /// Reading the text box (the Accessibility API).
        case accessibility
        /// Sending keys: the ⌘V that types, and the event tap that keeps the Esc that cancels from the app. macOS
        /// checks it apart from `accessibility` (`CGPreflightPostEventAccess`), but System Settings shows both as the
        /// app's Accessibility switch.
        case postEvents
        /// Seeing Fn when the app may not post events (a listen-only event tap).
        case inputMonitoring
    }

    public enum Status: Equatable, Sendable {
        case granted
        /// macOS hasn't asked yet, so asking shows its prompt. Only the microphone tells this apart from `denied`.
        case notDetermined
        /// Not allowed (refused, restricted, or not switched on yet): only System Settings changes it.
        case denied
    }

    /// What Permissions asks macOS; faked in tests.
    public protocol System {
        func microphoneStatus() -> AVAuthorizationStatus
        /// Shows macOS's microphone prompt; `completion` runs on any thread.
        func requestMicrophone(_ completion: @escaping @Sendable (Bool) -> Void)
        /// AXIsProcessTrustedWithOptions. With `prompt`, macOS offers to open System Settings when not trusted.
        func isAccessibilityTrusted(prompt: Bool) -> Bool
        /// CGPreflightPostEventAccess.
        func canPostEvents() -> Bool
        /// CGRequestPostEventAccess: macOS's prompt, which leads to the Accessibility list, the first time.
        func requestPostEvents() -> Bool
        /// CGPreflightListenEventAccess.
        func canListenToEvents() -> Bool
        /// CGRequestListenEventAccess: macOS's Input Monitoring prompt, the first time.
        func requestListenToEvents() -> Bool
        func open(_ url: URL) -> Bool
    }

    private let system: any System

    /// - Parameter system: macOS itself when nil.
    public init(system: (any System)? = nil) {
        self.system = system ?? MacSystem()
    }

    /// How macOS has answered so far. It never shows a prompt.
    public func status(_ kind: Kind) -> Status {
        switch kind {
        case .microphone:
            switch system.microphoneStatus() {
            case .authorized:
                return .granted
            case .notDetermined:
                return .notDetermined
            default:
                return .denied
            }
        case .accessibility:
            return system.isAccessibilityTrusted(prompt: false) ? .granted : .denied
        case .postEvents:
            return system.canPostEvents() ? .granted : .denied
        case .inputMonitoring:
            return system.canListenToEvents() ? .granted : .denied
        }
    }

    /// Asks for `kind` the way macOS allows: its microphone prompt the first time; its Accessibility, event-posting or
    /// Input Monitoring prompt, which leads to System Settings. `completion` gets the status after, on the main
    /// thread. When macOS has already asked, nothing shows: `openSettings` is the way then.
    public func request(_ kind: Kind, completion: @escaping @MainActor @Sendable (Status) -> Void) {
        switch kind {
        case .microphone:
            let current = status(.microphone)
            guard current == .notDetermined else {
                Permissions.finish(current, completion)
                return
            }

            system.requestMicrophone { granted in
                Permissions.finish(granted ? .granted : .denied, completion)
            }
        case .accessibility:
            Permissions.finish(system.isAccessibilityTrusted(prompt: true) ? .granted : .denied, completion)
        case .postEvents:
            let granted = system.canPostEvents() || system.requestPostEvents()
            Permissions.finish(granted ? .granted : .denied, completion)
        case .inputMonitoring:
            let granted = system.canListenToEvents() || system.requestListenToEvents()
            Permissions.finish(granted ? .granted : .denied, completion)
        }
    }

    /// Opens the pane of System Settings where `kind` is switched on. False when it couldn't be opened.
    @discardableResult
    public func openSettings(_ kind: Kind) -> Bool {
        system.open(Permissions.settingsURL(kind))
    }

    /// Privacy & Security, at the list for `kind`.
    public static func settingsURL(_ kind: Kind) -> URL {
        let list: String
        switch kind {
        case .microphone:
            list = "Privacy_Microphone"
        case .accessibility, .postEvents:
            list = "Privacy_Accessibility"
        case .inputMonitoring:
            list = "Privacy_ListenEvent"
        }

        return URL(string: "x-apple.systempreferences:com.apple.preference.security?" + list)!
    }

    private static func finish(_ status: Status, _ completion: @escaping @MainActor @Sendable (Status) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                completion(status)
            }
        }
    }
}

extension Permissions {
    /// The real checks: AVCaptureDevice, the Accessibility API, Core Graphics and NSWorkspace.
    public struct MacSystem: System {
        public init() {}

        public func microphoneStatus() -> AVAuthorizationStatus {
            AVCaptureDevice.authorizationStatus(for: .audio)
        }

        public func requestMicrophone(_ completion: @escaping @Sendable (Bool) -> Void) {
            AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        }

        public func isAccessibilityTrusted(prompt: Bool) -> Bool {
            // The key is kAXTrustedCheckOptionPrompt's value; the constant is a mutable global in Swift.
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
        }

        public func canPostEvents() -> Bool {
            CGPreflightPostEventAccess()
        }

        public func requestPostEvents() -> Bool {
            CGRequestPostEventAccess()
        }

        public func canListenToEvents() -> Bool {
            CGPreflightListenEventAccess()
        }

        public func requestListenToEvents() -> Bool {
            CGRequestListenEventAccess()
        }

        public func open(_ url: URL) -> Bool {
            NSWorkspace.shared.open(url)
        }
    }
}
