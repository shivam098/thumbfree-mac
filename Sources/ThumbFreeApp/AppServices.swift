import Foundation

/// A page of ThumbFree's window, which comes in phase 4; until then "Open ThumbFree" says what's where.
public enum AppPage: Sendable {
    case home
    case history
    case settings
    case help
}

/// Everything the menu bar (and the window and the guide, in phase 4) works with, made once by the app and with fakes
/// by tests (thumbfree-windows `AppServices`). The dictation host gets what it needs from here too: `history`,
/// `samples`, `notifier`, `practice` and `models`.
public final class AppServices: @unchecked Sendable {
    public let settings: SettingsStore
    public let history: HistoryStore
    public let samples: SampleStore
    public let models: ModelDownloads
    public let state: DictationState
    public let environment: AppEnvironment
    public let appVersion: String

    /// The guide's practice boxes, which take dictation directly.
    public let practice = PracticeHost()

    private let lock = NSLock()
    private var currentNotifier: Notifier?
    private var pausing: (Bool) -> Void = { _ in }
    private var opening: (AppPage) -> Void = { _ in }

    public init(
        settings: SettingsStore,
        history: HistoryStore,
        samples: SampleStore,
        models: ModelDownloads,
        state: DictationState,
        environment: AppEnvironment,
        appVersion: String
    ) {
        self.settings = settings
        self.history = history
        self.samples = samples
        self.models = models
        self.state = state
        self.environment = environment
        self.appVersion = appVersion
    }

    /// Notifications in Notification Center; nil until the app has made them (and in tests that don't need them).
    public var notifier: Notifier? {
        get { lock.withLock { currentNotifier } }
        set { lock.withLock { currentNotifier = newValue } }
    }

    /// Pauses or resumes the dictation key.
    public var setPaused: (Bool) -> Void {
        get { lock.withLock { pausing } }
        set { lock.withLock { pausing = newValue } }
    }

    /// Opens a page of the window (phase 4).
    public var openPage: (AppPage) -> Void {
        get { lock.withLock { opening } }
        set { lock.withLock { opening = newValue } }
    }

    public var current: AppSettings { settings.current }
}
