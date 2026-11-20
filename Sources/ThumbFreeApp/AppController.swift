import AppKit
import ThumbFreeCore
import ThumbFreeMac
import ThumbFreeSpeech

/// ThumbFree for Mac, the app itself (thumbfree-windows App.xaml.cs and App.Ui.cs): one copy at a time, the settings
/// and the stores, the dictation host, the menu bar, the pill, the dictation key and the notifications, wired
/// together on the main thread. `Sources/ThumbFree/main.swift` only calls `run()`.
@MainActor
public final class AppController: NSObject, NSApplicationDelegate {
    /// Runs ThumbFree in the menu bar until it quits.
    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = AppController(paths: .standard)
        app.delegate = controller
        withExtendedLifetime(controller) {
            app.run()
        }
    }

    /// The version from the app's Info.plist, else the core's.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ThumbFreeCore.version
    }

    /// The longest ThumbFree waits, when it quits, for a dictation being finished to be typed.
    static let quitWait: TimeInterval = 10

    private let paths: AppPaths
    private let instance: SingleInstance
    private let permissions = Permissions()
    private var services: AppServices?
    private var host: DictationHost?
    private var menuBar: MenuBar?
    private var pill: Pill.Panel?
    private var keys: HotkeyTap?
    private var notifications: UserNotificationSurface?
    private var otherApp: OtherApp?
    private var reader: FocusedField.Reader?
    private var permissionTimer: Timer?
    private var tokens: [ObservationToken] = []
    private var downloading: Set<String> = []
    private var recording = false
    private var recordingId = 0
    private var paused = false
    private var quitting = false

    /// The tap the permissions allowed when the dictation key's tap was last made: it's made again only when they
    /// change, not every few seconds while macOS refuses it.
    private var tapAllowed: HotkeyTap.Mode?

    init(paths: AppPaths) {
        self.paths = paths
        instance = SingleInstance(path: paths.instanceLock)
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let startup = StartupGuard(
            logs: paths.logs,
            showError: { message in MainActor.assumeIsolated { AppController.showError(message) } },
            quit: { exit(1) })
        do {
            try start()
        } catch {
            Log.error("start failed: \(Log.kind(of: error))")
            if !startup.handle(error, menuBarExists: menuBar != nil) {
                pill?.showStatus(Pill.Status(.error, "Something went wrong: " + error.localizedDescription))
            }
        }
    }

    /// Opening ThumbFree again while it runs (the Finder, Spotlight) opens its menu.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.open()
        return false
    }

    /// Quitting while a dictation is being transcribed or typed: it's typed first, 10 s at most, with the main thread
    /// free, since typing asks it about Secure Input (`DictationHost.finishForQuit`). A recording is cancelled, as on
    /// Windows.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let host, !quitting else { return quitting ? .terminateCancel : .terminateNow }
        if recording {
            endDictation(cancel: true)
        }

        guard host.isBusy else { return .terminateNow }
        quitting = true
        Log.info("quitting once the dictation is typed")
        host.finishForQuit(timeout: Self.quitWait) {
            MainActor.assumeIsolated {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }

        return .terminateLater
    }

    /// Lets History and samples finish writing before the process ends.
    public func applicationWillTerminate(_ notification: Notification) {
        Log.info("exiting")
        permissionTimer?.invalidate()
        keys?.stop()
        otherApp?.stop()
        host?.close()
        _ = services?.history.flush(timeout: 2)
        _ = services?.samples.flush(timeout: 2)
        instance.release()
    }

    private func start() throws {
        try FileManager.default.createDirectory(atPath: paths.data, withIntermediateDirectories: true)
        Log.start(in: paths.logs)
        guard try instance.acquire() else {
            // One copy at a time: two would each rewrite History from their own list.
            Log.info("ThumbFree is already running; showing that copy")
            SingleInstance.showRunningCopy()
            exit(0)
        }

        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        Log.info("starting \(Self.version) on \(architecture), macOS \(system); \(ThumbFreeSpeech.engines)")

        let settings = AppSettings.load(from: paths.settingsFile)
        let store = ModelStore(primaryFolder: paths.modelsFolder, sharedFolders: ModelStore.defaultSharedFolders)
        let services = makeServices(settings, store)
        self.services = services

        let pill = Pill.Panel(keyName: settings.dictationKey.displayName)
        pill.pinned = StateFlags.isSet(paths.pillPinnedFlag)
        pill.setDictationLanguage(
            hinglish: settings.language == .hinglish, accurate: settings.hinglishTier == .accurate)
        self.pill = pill

        let reader = FocusedField.Reader()
        reader.startWaking()
        self.reader = reader
        let desktop = MacDesktop(
            typer: PasteTyper(), reader: reader, insertMethod: Self.setting(services.settings, \.insertMethod))
        let host = DictationHost(
            services, models: StoreSpeechModels(store), post: Self.postToMain, desktop: desktop,
            fields: MacFieldReader(reader), audio: MicrophoneAudio(), sounds: true)
        self.host = host

        menuBar = MenuBar(services: services, actions: menuActions(), permissions: permissions)
        makeNotifier(services)
        wire(host, services)
        installKeys(settings)
        setPaused(StateFlags.isSet(paths.pausedFlag))
        warnIfJarvisRuns()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showRequested(_:)), name: SingleInstance.showNotification, object: nil,
            suspensionBehavior: .deliverImmediately)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissionsMayHaveChanged() }
        }

        host.start()
        warmUpIfNeeded(settings.selectedModel)
        openAtStart(services)
    }

    private func makeServices(_ settings: AppSettings, _ store: ModelStore) -> AppServices {
        let settingsStore = SettingsStore(settings, path: paths.settingsFile)
        let services = AppServices(
            settings: settingsStore,
            history: HistoryStore(
                path: paths.historyFile, enabled: Self.setting(settingsStore, \.keepHistory), changes: .main),
            samples: SampleStore(
                folder: paths.samplesFolder, enabled: Self.setting(settingsStore, \.saveSamples),
                appVersion: Self.version, changes: .main),
            models: ModelDownloads(StoreModelManager(store), changes: .main),
            state: DictationState(),
            environment: MacEnvironment(permissions: permissions),
            appVersion: Self.version)
        services.setPaused = { paused in onMain { [weak self] in self?.setPaused(paused) } }

        // Until the window comes (phase 4), the menu is where a model is downloaded.
        services.openPage = { _ in onMain { [weak self] in self?.menuBar?.open() } }

        // The browsers on this Mac are read now, in the background, so no dictation waits for them.
        Browsers.prepare()
        return services
    }

    /// Runs `action` on the main thread, later: the host's `post`, made off the main actor since the host calls it
    /// from its own threads.
    nonisolated private static func postToMain(_ action: @escaping () -> Void) {
        DispatchQueue.main.async { action() }
    }

    /// A setting as it is now, for the stores and the desktop to read on their own threads.
    nonisolated private static func setting<Value>(
        _ store: SettingsStore, _ key: KeyPath<AppSettings, Value>
    ) -> () -> Value {
        { store.current[keyPath: key] }
    }

    /// Notifications in Notification Center when this is an app bundle; a bare binary (`swift run`) has none, but a
    /// dictation that couldn't be typed is still kept for the menu bar.
    private func makeNotifier(_ services: AppServices) {
        let surface: NotificationSurface
        if UserNotificationSurface.isAvailable {
            let notifications = UserNotificationSurface()
            self.notifications = notifications
            surface = notifications
        } else {
            Log.warn("not an app bundle: no notifications")
            surface = SilentSurface()
        }

        let environment = services.environment
        services.notifier = Notifier(
            surface: surface, state: services.state, copy: { text in environment.copyText(text) }, queue: .main)
    }

    private func menuActions() -> MenuActions {
        MenuActions(
            open: { [weak self] page in self?.showPage(page) },
            pasteLast: { [weak self] in self?.host?.pasteLastTranscript() },
            quit: { NSApp.terminate(nil) },
            paused: { [weak self] in self?.paused ?? false },
            pillPinned: { [weak self] in self?.pill?.pinned ?? false },
            togglePill: { [weak self] in self?.togglePill() })
    }

    /// Feeds the pill, the menu bar and the state from the dictation host and the settings (App.Ui.cs `WireUi`).
    private func wire(_ host: DictationHost, _ services: AppServices) {
        host.onStatus = { [weak self] update in
            MainActor.assumeIsolated {
                services.state.report(update)
                self?.pill?.showStatus(AppController.pillStatus(update))
            }
        }

        host.onActivity = { [weak self] activity in
            MainActor.assumeIsolated {
                services.state.setActivity(activity)
                self?.pill?.showActivity(activity)
            }
        }

        host.onPreview = { [weak self] text in MainActor.assumeIsolated { self?.pill?.showPreview(text) } }
        host.onInputLevel = { [weak self] level in MainActor.assumeIsolated { self?.pill?.showInputLevel(level) } }
        host.onWindowFrame = { [weak self] frame in MainActor.assumeIsolated { self?.pill?.windowFrame = frame } }
        host.onCaptureStopped = { [weak self] id in MainActor.assumeIsolated { self?.captureStopped(id) } }
        tokens.append(services.settings.observe { [weak self] change in
            guard let self else { return }
            onMain { self.settingsChanged(change) }
        })
        tokens.append(services.models.observe { [weak self] spec in
            guard let self else { return }
            onMain { self.modelChanged(spec) }
        })
    }

    /// Tap the key to start dictating, tap it again to finish; Esc cancels (App.xaml.cs `InstallDictationKeys`).
    private func installKeys(_ settings: AppSettings) {
        let keys = HotkeyTap(tapKey: settings.dictationKey)
        keys.onCommand = { [weak self] command in self?.keyCommand(command) }
        keys.onBlocked = { [weak self] blocker in
            switch blocker {
            case .secureInput:
                self?.pill?.showStatus(Pill.Status(.warning, "Secure Input is on, so dictation can't start."))
            }
        }

        self.keys = keys
        tapAllowed = allowedTap()
        let mode = keys.start()
        Log.info("dictation keys: \(mode)")
        if mode == .off {
            pill?.showStatus(
                Pill.Status(
                    .warning,
                    "ThumbFree can't see the \(settings.dictationKey.displayName) key yet: allow it under "
                        + "Accessibility, from the menu bar."))
        }
    }

    private func keyCommand(_ command: FnTapKeys.Command) {
        switch command {
        case .start:
            if !recording && !paused {
                beginDictation()
            }
        case .finish:
            if recording {
                endDictation(cancel: false)
            }
        case .cancel:
            if recording {
                endDictation(cancel: true)
            }
        }
    }

    /// The microphone is asked for the first time it's needed, and notifications at the first dictation: asking at
    /// launch would come before anyone knows why.
    private func beginDictation() {
        guard let host, let services else { return }
        let key = services.current.dictationKey.displayName
        let problem: String?
        switch services.environment.checkMicrophone() {
        case .allowed:
            problem = nil
        case .notAsked:
            problem = "Allow the microphone, then tap \(key) again."
            permissions.request(.microphone) { [weak self] _ in self?.menuBar?.menu.prepare() }
        case .denied:
            problem = "ThumbFree may not use the microphone: allow it in System Settings › Privacy & Security › "
                + "Microphone (the menu bar opens it)."
        case .noMicrophone:
            problem = "There's no microphone to dictate with."
        }

        if let problem {
            keys?.isRecording = false
            pill?.showStatus(Pill.Status(.warning, problem))
            return
        }

        notifications?.requestPermission()
        recording = true
        recordingId += 1
        keys?.isRecording = true
        menuBar?.setRecording(true)
        host.beginDictationCapture(recordingId)
    }

    private func endDictation(cancel: Bool) {
        recording = false
        keys?.isRecording = false
        menuBar?.setRecording(false)
        host?.endDictationCapture(cancel: cancel)
    }

    /// The recording couldn't start or stopped by itself: the keys stop treating the next tap (and Esc) as recording.
    private func captureStopped(_ id: Int) {
        if id == recordingId && recording {
            recording = false
            keys?.isRecording = false
            menuBar?.setRecording(false)
        }
    }

    private func setPaused(_ paused: Bool) {
        if paused && recording {
            endDictation(cancel: true)
        }

        self.paused = paused
        keys?.isEnabled = !paused
        StateFlags.set(paths.pausedFlag, paused)
        menuBar?.setPaused(paused)
        pill?.setPaused(paused)
        services?.state.setPaused(paused)
        Log.info(paused ? "dictation keys paused" : "dictation keys on")
    }

    private func togglePill() {
        guard let pill else { return }
        pill.pinned.toggle()
        StateFlags.set(paths.pillPinnedFlag, pill.pinned)
    }

    private func settingsChanged(_ change: SettingsChange) {
        guard let services else { return }
        let settings = services.current
        if change.has(.language, .hinglishTier) {
            pill?.setDictationLanguage(
                hinglish: settings.language == .hinglish, accurate: settings.hinglishTier == .accurate)
        }

        if change.has(.dictationKey) {
            if recording {
                endDictation(cancel: true)
            }

            keys?.tapKey = settings.dictationKey
            pill?.keyName = settings.dictationKey.displayName
            warnIfJarvisRuns()
        }

        if change.has(.language, .englishTier, .hinglishTier) {
            warmUpIfNeeded(settings.selectedModel)
        }
    }

    /// A download of the chosen model that has just finished says so.
    private func modelChanged(_ spec: ModelSpec) {
        guard let services else { return }
        let status = services.models.state(spec).status
        if status == .downloading {
            downloading.insert(spec.id)
        } else if downloading.remove(spec.id) != nil, status == .installed, spec == services.current.selectedModel {
            let key = services.current.dictationKey.displayName
            pill?.showStatus(Pill.Status(.success, "The speech model is ready: tap \(key) to dictate."))
        }
    }

    /// ggml (Silero and Whisper) gets ready in the background, so the first dictation doesn't wait for it; English
    /// Live (Kroko) uses neither, so it doesn't warm up for it.
    private func warmUpIfNeeded(_ spec: ModelSpec) {
        if !spec.streaming {
            ThumbFreeSpeech.warmUp()
        }
    }

    /// Jarvis for Mac uses Fn too: with both listening, every dictation would be typed twice (as Windows warns about
    /// Voice Assistant).
    private func warnIfJarvisRuns() {
        if otherApp == nil {
            let other = OtherApp(otherThan: Bundle.main.bundleIdentifier ?? ThumbFreeMac.thumbFreeBundleIdentifier)
            other?.onChange = { [weak self] _ in MainActor.assumeIsolated { self?.warnIfJarvisRuns() } }
            other?.start()
            otherApp = other
        }

        let clash = otherApp?.isRunning == true && services?.current.dictationKey == .fn
        let note = "Jarvis is running too, with the same Fn key: quit one of them, or text is typed twice."
        menuBar?.menu.showNote(clash ? note : nil)
        if clash {
            Log.warn("Jarvis is running too")
            pill?.showStatus(Pill.Status(.warning, note))
        }
    }

    /// A permission given (or taken back) in System Settings since: the dictation key's tap is made again for it.
    private func permissionsMayHaveChanged() {
        guard let keys, !recording else { return }
        let allowed = allowedTap()
        if allowed != tapAllowed {
            tapAllowed = allowed
            Log.info("dictation keys: \(keys.start())")
        }

        menuBar?.refresh()
    }

    /// The tap the permissions allow: active with the right to post events, else listen-only with Input Monitoring.
    private func allowedTap() -> HotkeyTap.Mode {
        if permissions.status(.postEvents) == .granted {
            return .active
        }

        return permissions.status(.inputMonitoring) == .granted ? .listenOnly : .off
    }

    /// First launch: the speech model is offered from the menu bar (a small one also downloads at the first tap).
    private func openAtStart(_ services: AppServices) {
        if let problem = services.settings.problemSummary {
            pill?.showStatus(Pill.Status(.warning, problem))
        }

        let spec = services.current.selectedModel
        if services.models.state(spec).status == .notInstalled {
            let size = ModelConsent.mb(spec.bytes)
            pill?.showStatus(
                Pill.Status(.info, "ThumbFree needs its speech model (\(size)): download it from the menu bar."))
        }
    }

    /// "Open ThumbFree", until its window comes in phase 4: what's where.
    private func showPage(_ page: AppPage) {
        guard let services else { return }
        let key = services.current.dictationKey.displayName
        AppKitHelpers.activate()
        let alert = NSAlert()
        alert.messageText = "ThumbFree is in your menu bar"
        alert.informativeText = [
            "Tap \(key) to dictate, and tap it again to finish; Esc cancels. ThumbFree's window, with History, ",
            "Settings and Help, comes in the next version. Until then the menu bar has the dictation language, the ",
            "speech model and the dictation key, and settings.json has every other setting.",
        ].joined()
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open settings.json")
        if alert.runModal() == .alertSecondButtonReturn {
            services.settings.createIfMissing()
            services.environment.open(URL(fileURLWithPath: paths.settingsFile))
        }
    }

    /// Another copy of ThumbFree was opened and quit: this one shows its menu.
    @objc nonisolated private func showRequested(_ notification: Notification) {
        onMain { [weak self] in self?.menuBar?.open() }
    }

    private static func showError(_ message: String) {
        AppKitHelpers.activate()
        let alert = NSAlert()
        alert.messageText = "ThumbFree"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }

    private static func pillStatus(_ update: StatusUpdate) -> Pill.Status {
        let kind: Pill.Status.Kind
        switch update.kind {
        case .info: kind = .info
        case .success: kind = .success
        case .warning: kind = .warning
        case .error: kind = .error
        }

        return Pill.Status(kind, update.message, heard: update.heard)
    }
}

/// Notifications nowhere: for a bare binary, which Notification Center doesn't know.
private final class SilentSurface: NotificationSurface {
    var onClicked: ((String?) -> Void)?

    func show(_ title: String, _ text: String, warning: Bool, tag: String?) {}

    func hide() {}
}
