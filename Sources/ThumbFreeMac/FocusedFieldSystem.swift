import AppKit
import ApplicationServices
import Carbon

extension FocusedField {
    /// The Accessibility API itself, for `Reader`, and NSWorkspace for the app in front. Every Accessibility call
    /// waits at most `timeout` for the app's answer.
    final class SystemAccessibility: Accessibility {
        /// How long one call waits for an app (AXUIElementSetMessagingTimeout on the system-wide element, which sets it
        /// for every call ThumbFree makes). An app that doesn't answer gets no further calls in that read.
        static let timeout: Float = 1

        private let systemWide = AXUIElementCreateSystemWide()

        /// Where apps coming to the front are handled: one at a time, off the main thread.
        private let activationQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            return queue
        }()

        init() {
            _ = AXUIElementSetMessagingTimeout(systemWide, Self.timeout)
        }

        var secureEventInput: Bool { SecureInput.isOn() }

        var frontmostProcess: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

        func observeActivations(_ handler: @escaping @Sendable (pid_t) -> Void) -> AnyObject {
            let center = NSWorkspace.shared.notificationCenter
            let token = center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: activationQueue
            ) { notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    handler(app.processIdentifier)
                }
            }

            return Observation(center, token)
        }

        func focusedElement() throws -> AnyObject? {
            try element(kAXFocusedUIElementAttribute, of: systemWide)
        }

        func string(_ attribute: String, of element: AnyObject) throws -> String? {
            try copy(attribute, of: element) as? String
        }

        func integer(_ attribute: String, of element: AnyObject) throws -> Int? {
            (try copy(attribute, of: element) as? NSNumber)?.intValue
        }

        func range(_ attribute: String, of element: AnyObject) throws -> CFRange? {
            guard let value = try axValue(attribute, of: element, .cfRange) else { return nil }
            var range = CFRange()
            return AXValueGetValue(value, .cfRange, &range) ? range : nil
        }

        func utf16(_ attribute: String, for range: CFRange, of element: AnyObject) throws -> [UInt16]? {
            var range = range
            guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
            var value: CFTypeRef?
            let error = AXUIElementCopyParameterizedAttributeValue(
                Self.ax(element), attribute as CFString, parameter, &value)
            guard try Self.answered(error), let text = value as? NSString else { return nil }
            var units = [UInt16](repeating: 0, count: text.length)
            text.getCharacters(&units, range: NSRange(location: 0, length: text.length))
            return units
        }

        func element(_ attribute: String, of element: AnyObject) throws -> AnyObject? {
            guard let value = try copy(attribute, of: element), CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }

            return value
        }

        func frame(of element: AnyObject) throws -> CGRect? {
            guard let position = try axValue(kAXPositionAttribute, of: element, .cgPoint),
                  let size = try axValue(kAXSizeAttribute, of: element, .cgSize) else { return nil }
            var frame = CGRect.zero
            guard AXValueGetValue(position, .cgPoint, &frame.origin), AXValueGetValue(size, .cgSize, &frame.size) else {
                return nil
            }

            return frame
        }

        func processIdentifier(of element: AnyObject) throws -> pid_t {
            var pid: pid_t = 0
            guard AXUIElementGetPid(Self.ax(element), &pid) == .success else { throw NoAnswer() }
            return pid
        }

        func application(_ processIdentifier: pid_t) -> AnyObject {
            AXUIElementCreateApplication(processIdentifier)
        }

        func setFlag(_ attribute: String, _ value: Bool, of element: AnyObject) -> Bool {
            AXUIElementSetAttributeValue(Self.ax(element), attribute as CFString, NSNumber(value: value)) == .success
        }

        func isSame(_ element: AnyObject, as other: AnyObject) -> Bool {
            CFEqual(element, other)
        }

        /// The bundle identifier and name from NSRunningApplication; Electron apps carry Electron Framework.framework.
        func app(_ processIdentifier: pid_t) -> App {
            let running = NSRunningApplication(processIdentifier: processIdentifier)
            let electron = running?.bundleURL.map {
                let framework = $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
                return FileManager.default.fileExists(atPath: framework.path)
            }

            return App(
                processIdentifier: processIdentifier, bundleIdentifier: running?.bundleIdentifier,
                name: running?.localizedName, isElectron: electron ?? false)
        }

        /// The attribute's value: nil when the element doesn't have it, `NoAnswer` when Accessibility is off for
        /// ThumbFree, the element has gone or the app didn't answer in time.
        private func copy(_ attribute: String, of element: AnyObject) throws -> CFTypeRef? {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(Self.ax(element), attribute as CFString, &value)
            return try Self.answered(error) ? value : nil
        }

        /// True for an answer, false for "the element doesn't have that"; throws when there was no answer.
        private static func answered(_ error: AXError) throws -> Bool {
            switch error {
            case .success:
                return true
            case .noValue, .attributeUnsupported, .parameterizedAttributeUnsupported, .failure, .illegalArgument,
                 .notImplemented:
                return false
            default:
                throw NoAnswer()
            }
        }

        /// A point, size or range attribute: an AXValue of `type`.
        private func axValue(_ attribute: String, of element: AnyObject, _ type: AXValueType) throws -> AXValue? {
            guard let value = try copy(attribute, of: element), CFGetTypeID(value) == AXValueGetTypeID() else {
                return nil
            }

            let axValue = unsafeBitCast(value, to: AXValue.self)
            return AXValueGetType(axValue) == type ? axValue : nil
        }

        private static func ax(_ element: AnyObject) -> AXUIElement {
            precondition(CFGetTypeID(element) == AXUIElementGetTypeID(), "not an AXUIElement")
            return unsafeBitCast(element, to: AXUIElement.self)
        }

        /// Stops the activation observer when it goes.
        private final class Observation {
            private let center: NotificationCenter
            private let token: NSObjectProtocol

            init(_ center: NotificationCenter, _ token: NSObjectProtocol) {
                self.center = center
                self.token = token
            }

            deinit {
                center.removeObserver(token)
            }
        }
    }

    /// IsSecureEventInputEnabled(), asked on the main thread, since CarbonEventsCore.h marks it not thread safe. From
    /// another thread it waits for the main thread's answer, `wait` at most; without one it says yes, so nothing is
    /// typed while that can't be told.
    enum SecureInput {
        static let wait: TimeInterval = 1

        static func isOn() -> Bool {
            if Thread.isMainThread {
                return IsSecureEventInputEnabled()
            }

            let answer = Answer()
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                answer.isOn = IsSecureEventInputEnabled()
                answered.signal()
            }

            return answered.wait(timeout: .now() + wait) == .success ? answer.isOn : true
        }

        /// Written on the main thread before the semaphore is signalled, read after it.
        private final class Answer: @unchecked Sendable {
            var isOn = true
        }
    }
}
