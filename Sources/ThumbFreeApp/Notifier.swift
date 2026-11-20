import Foundation

/// Where ThumbFree's notifications appear: Notification Center (`UserNotificationSurface`), faked in tests
/// (thumbfree-windows `INotificationSurface`).
public protocol NotificationSurface: AnyObject {
    /// Runs when the person clicks a notification (or its Copy button), with the tag it was shown with.
    var onClicked: ((String?) -> Void)? { get set }

    func show(_ title: String, _ text: String, warning: Bool, tag: String?)

    /// Takes all of ThumbFree's notifications off the screen and out of Notification Center, as Windows' Hide does.
    func hide()

    /// Waits, `timeout` at most, until the notifications shown so far have reached Notification Center (before
    /// ThumbFree quits).
    func waitForDelivery(timeout: TimeInterval)
}

extension NotificationSurface {
    public func waitForDelivery(timeout: TimeInterval) {}
}

/// "Never speak into the void, never lose a dictation" (PLAN 3.6), as thumbfree-windows `Notifier` does it. The
/// dictation host calls these from any thread: text that couldn't be typed is kept (and never typed anywhere else)
/// until the person copies it from the notification or the menu bar, and a microphone that sends only silence is
/// reported until sound comes back. Windows reports a click only for the notification shown last, so while a
/// dictation is kept a click on any notification copies it; Notification Center says which was clicked, but the rule
/// stays, so both apps behave alike.
public final class Notifier: @unchecked Sendable {
    public static let untypedTag = "untyped"
    public static let silentTag = "silent"

    private let surface: NotificationSurface
    private let state: DictationState
    private let copy: (String) -> Void
    private let queue: DispatchQueue?
    private let lock = NSRecursiveLock()
    private var shown: String?
    private var untyped: String?

    /// The microphone warning was left up because taking it back would also take the kept dictation's notification.
    private var warningLeft = false

    /// - Parameters:
    ///   - copy: Puts text on the pasteboard.
    ///   - queue: Where the notifications are shown (the app passes the main queue); nil shows them on the calling
    ///     thread, as C# does without a UI thread.
    public init(
        surface: NotificationSurface, state: DictationState, copy: @escaping (String) -> Void, queue: DispatchQueue?
    ) {
        self.surface = surface
        self.state = state
        self.copy = copy
        self.queue = queue
        surface.onClicked = { [weak self] tag in
            guard let self else { return }
            if tag == Self.untypedTag || self.untypedText != nil {
                self.copyUntyped()
            }
        }
    }

    /// The latest dictation that couldn't be typed, until it's copied (the menu bar offers it too).
    public var untypedText: String? { lock.withLock { untyped } }

    /// A dictation couldn't be typed: the text box closed before the text was ready, or the app didn't take it. The
    /// text stays here and in a notification; clicking the notification copies it.
    /// - Parameter reason: One sentence; by default "The text box closed before your text was ready."
    public func showUntyped(_ text: String, reason: String? = nil) {
        post {
            self.untyped = text
            let why = reason ?? "The text box closed before your text was ready."
            self.show("Your dictation is safe", "\(why) Click to copy it.", warning: true, tag: Self.untypedTag)
        }
    }

    /// The microphone sends exact silence (a call or another app took it). Shown until `clearMicrophoneSilent`.
    public func showMicrophoneSilent() {
        post {
            if !self.state.microphoneSilent {
                self.state.setMicrophoneSilent(true)
                self.warningLeft = false
                self.show(
                    "ThumbFree can't hear you", "No sound from the microphone. Is another app or a call using it?",
                    warning: true, tag: Self.silentTag)
            }
        }
    }

    /// Sound came back (or the dictation ended): the warning goes, from the screen and Notification Center. While a
    /// dictation is kept it stays, since taking it back takes back all of ThumbFree's notifications (as on Windows),
    /// the kept one's too; it goes when the dictation is copied.
    public func clearMicrophoneSilent() {
        post {
            guard self.state.microphoneSilent else { return }
            self.state.setMicrophoneSilent(false)
            if self.untyped != nil {
                self.warningLeft = true
            } else if self.shown == Self.silentTag {
                self.surface.hide()
                self.shown = nil
            }
        }
    }

    /// The microphone stopped mid-dictation: what was said so far is being written.
    public func showInterrupted() {
        post {
            self.show(
                "Dictation stopped", "Another app took the microphone. What you said so far is being written.",
                warning: true, tag: nil)
        }
    }

    /// An example for the first-run guide, so people see where these appear (only when they ask).
    public func showExample() {
        post {
            self.show(
                "This is how ThumbFree tells you",
                "If the microphone goes quiet or your words can't be typed, you'll see it here.",
                warning: false, tag: nil)
        }
    }

    /// ThumbFree is quitting with dictations that weren't typed: they're in the menu bar's recent dictations, or, where
    /// History doesn't have them, on the pasteboard (the Mac's own: Windows types one or loses it). ThumbFree's other
    /// notifications go first: clicking one once ThumbFree has gone would copy nothing.
    public func showKeptAtQuit(onPasteboard: Bool) {
        post {
            self.surface.hide()
            self.show(
                "Your dictation is safe",
                onPasteboard
                    ? "ThumbFree quit with a dictation that wasn't typed, so it's on the pasteboard: paste it with ⌘V."
                    : "ThumbFree quit with a dictation that wasn't typed. It's in the menu bar's recent dictations.",
                warning: true, tag: nil)
        }
    }

    /// Waits, `timeout` at most, until the notifications shown so far are in Notification Center.
    public func waitForDelivery(timeout: TimeInterval) {
        surface.waitForDelivery(timeout: timeout)
    }

    /// Copies `untypedText` (from the notification or the menu bar). False when there's nothing to copy.
    @discardableResult
    public func copyUntyped() -> Bool {
        lock.withLock {
            guard let text = untyped else { return false }
            copy(text)
            untyped = nil
            if warningLeft && !state.microphoneSilent {
                surface.hide()
            }

            warningLeft = false
            show("Copied", "Paste your dictation with ⌘V.", warning: false, tag: nil)
            return true
        }
    }

    private func show(_ title: String, _ text: String, warning: Bool, tag: String?) {
        shown = tag
        surface.show(title, text, warning: warning, tag: tag)
    }

    private func post(_ action: @escaping () -> Void) {
        let locked = { [lock] in lock.withLock(action) }
        if let queue, !(queue === DispatchQueue.main && Thread.isMainThread) {
            queue.async { locked() }
        } else {
            locked()
        }
    }
}
