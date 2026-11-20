import Foundation
import ThumbFreeCore
import ThumbFreeMac

/// Activity labels for a dictation, as the pill shows them (thumbfree-windows `DictationLabels`).
public enum DictationLabels {
    /// Recording: the level meter, the words heard so far and how to finish.
    public static let listening = Pill.listening

    /// Recording has stopped and the speech is being turned into text.
    public static let transcribing = Pill.transcribing
}

/// What the menu bar (and the window, in phase 4) shows about dictation right now: paused, listening, transcribing,
/// the microphone gone silent, and the latest problem (thumbfree-windows `DictationState`). The app feeds it from the
/// dictation host's events, on the main thread.
public final class DictationState: @unchecked Sendable {
    private let lock = NSLock()
    private let observers = Observers<Void>()
    private var isPaused = false
    private var currentActivity: String?
    private var silent = false
    private var latestProblem: StatusUpdate?
    private var latestProblemTime = Date.distantPast

    public init() {}

    /// Runs `handler` after any change, on the thread that made it (the main thread).
    @discardableResult
    public func observe(_ handler: @escaping () -> Void) -> ObservationToken {
        observers.add { _ in handler() }
    }

    /// The dictation key is paused (from the menu bar).
    public var paused: Bool { lock.withLock { isPaused } }

    /// `DictationLabels.listening`, `DictationLabels.transcribing`, or another short label; nil while idle.
    public var activity: String? { lock.withLock { currentActivity } }

    /// The microphone sends only silence: a call or another app has it (see `Notifier`).
    public var microphoneSilent: Bool { lock.withLock { silent } }

    /// The latest warning or error, until a dictation works again.
    public var problem: StatusUpdate? { lock.withLock { latestProblem } }

    /// When `problem` happened.
    public var problemTime: Date { lock.withLock { latestProblemTime } }

    public var listening: Bool { activity == DictationLabels.listening }

    public var transcribing: Bool { activity == DictationLabels.transcribing }

    public func setPaused(_ paused: Bool) {
        change { state in
            guard state.isPaused != paused else { return false }
            state.isPaused = paused
            return true
        }
    }

    public func setActivity(_ activity: String?) {
        change { state in
            guard state.currentActivity != activity else { return false }
            state.currentActivity = activity
            return true
        }
    }

    public func setMicrophoneSilent(_ silent: Bool) {
        change { state in
            guard state.silent != silent else { return false }
            state.silent = silent
            return true
        }
    }

    /// A status message from the host: warnings and errors are kept until a later success.
    public func report(_ update: StatusUpdate) {
        change { state in
            switch update.kind {
            case .warning, .error:
                state.latestProblem = update
                state.latestProblemTime = Date()
                return true
            case .success where state.latestProblem != nil:
                state.latestProblem = nil
                return true
            default:
                return false
            }
        }
    }

    /// Makes a change under the lock, then tells the observers if `body` says something changed.
    private func change(_ body: (DictationState) -> Bool) {
        if lock.withLock({ body(self) }) {
            observers.notify(())
        }
    }
}
