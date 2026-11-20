import Foundation

/// Where practice text goes, for smart formatting: the same three facts as ThumbFreeCore's layout context
/// (thumbfree-windows `PracticeField`).
public struct PracticeField: Equatable, Sendable {
    /// The box takes line breaks (lists and emails need them).
    public var multiLine: Bool

    /// The dictation starts the text (needed for email layout).
    public var atStart: Bool

    /// An email body: a greeting or a sign-off alone is enough for email layout.
    public var email: Bool

    public init(multiLine: Bool, atStart: Bool, email: Bool) {
        self.multiLine = multiLine
        self.atStart = atStart
        self.email = email
    }
}

/// A practice box in the first-run guide (phase 4) that takes dictation itself (thumbfree-windows `IPracticeTarget`).
public protocol PracticeTarget: AnyObject {
    var field: PracticeField { get }

    /// The words so far while speaking; nil clears them. Any thread.
    func showLive(_ text: String?)

    /// The finished dictation after the formatter. The box lays it out itself. Any thread.
    func insert(_ text: String)
}

/// ThumbFree never types into its own windows, so the guide's practice boxes are reached through this hook
/// (thumbfree-windows `PracticeHost`): when a dictation starts, the host reads `active`, and if a practice box has the
/// keyboard focus the dictation goes to it and to nothing else, even if the focus moves meanwhile.
public final class PracticeHost: @unchecked Sendable {
    private let lock = NSLock()
    private var target: PracticeTarget?
    private let changed = Handler<Void>()

    public init() {}

    /// The practice box with the keyboard focus in the guide, or nil. Any thread.
    public var active: PracticeTarget? { lock.withLock { target } }

    /// Runs on the thread that changed `active` (the main thread).
    public var onActiveChanged: (() -> Void)? {
        get { changed.handler.map { handler in { handler(()) } } }
        set { changed.handler = newValue.map { handler in { _ in handler() } } }
    }

    public func setActive(_ active: PracticeTarget?) {
        let changes: Bool = lock.withLock {
            guard target !== active else { return false }
            target = active
            return true
        }

        if changes {
            changed(())
        }
    }
}
