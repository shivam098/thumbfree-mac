import Foundation

/// Something failed while ThumbFree was starting, before its menu-bar item existed (thumbfree-windows
/// `StartupGuard`, before the tray icon). With no menu there's no way to see it or quit it, and a hidden copy would
/// keep the next launch from working, so it says what went wrong and quits.
public struct StartupGuard {
    private let logs: String
    private let showError: (String) throws -> Void
    private let quit: () -> Void

    /// - Parameters:
    ///   - logs: The log folder the message points to.
    ///   - showError: Shows the message (an alert); what it throws is logged, and ThumbFree quits all the same.
    public init(logs: String, showError: @escaping (String) throws -> Void, quit: @escaping () -> Void) {
        self.logs = logs
        self.showError = showError
        self.quit = quit
    }

    public static func message(_ error: Error, logs: String) -> String {
        "ThumbFree couldn't start: \(error.localizedDescription)\n\nTry starting it again. If this keeps happening, "
            + "its log has the details: \(logs)"
    }

    /// True when ThumbFree quits because of `error`; false once the menu-bar item exists (the usual handling applies).
    @discardableResult
    public func handle(_ error: Error, menuBarExists: Bool) -> Bool {
        if menuBarExists {
            return false
        }

        do {
            try showError(Self.message(error, logs: logs))
        } catch {
            Log.error("couldn't show the startup error: \(Log.kind(of: error))")
        }

        quit()
        return true
    }
}
