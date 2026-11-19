import AppKit
import ApplicationServices
import Carbon

extension FocusedField {
    /// The Accessibility API itself, for `Reader`. Every call waits at most `timeout` for the app's answer.
    final class SystemAccessibility: Accessibility {
        /// How long one call waits for an app (AXUIElementSetMessagingTimeout on the system-wide element, which sets it
        /// for every call ThumbFree makes). An app that doesn't answer gets no further calls in that read.
        static let timeout: Float = 1

        private let systemWide = AXUIElementCreateSystemWide()

        init() {
            _ = AXUIElementSetMessagingTimeout(systemWide, Self.timeout)
        }

        var secureEventInput: Bool { IsSecureEventInputEnabled() }

        func focusedElement() throws -> AnyObject? {
            try element(kAXFocusedUIElementAttribute, of: systemWide)
        }

        func string(_ attribute: String, of element: AnyObject) throws -> String? {
            try copy(attribute, of: element) as? String
        }

        func range(_ attribute: String, of element: AnyObject) throws -> CFRange? {
            guard let value = try axValue(attribute, of: element, .cfRange) else { return nil }
            var range = CFRange()
            return AXValueGetValue(value, .cfRange, &range) ? range : nil
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
            switch AXUIElementCopyAttributeValue(Self.ax(element), attribute as CFString, &value) {
            case .success:
                return value
            case .noValue, .attributeUnsupported, .failure, .illegalArgument, .notImplemented:
                return nil
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
    }
}
