import AppKit
import ThumbFreeCore
import ThumbFreeMac

/// What the menu bar asks of the app (thumbfree-windows `TrayCommands`, and the tray's pill and pause callbacks).
public struct MenuActions {
    /// Opens a page of the window (phase 4); "Open ThumbFree" opens the home page.
    public var open: @MainActor (AppPage) -> Void
    public var pasteLast: @MainActor () -> Void
    public var quit: @MainActor () -> Void
    /// Whether the dictation key is paused now (the pause item flips it).
    public var paused: @MainActor () -> Bool
    public var pillPinned: @MainActor () -> Bool
    public var togglePill: @MainActor () -> Void

    public init(
        open: @escaping @MainActor (AppPage) -> Void,
        pasteLast: @escaping @MainActor () -> Void,
        quit: @escaping @MainActor () -> Void,
        paused: @escaping @MainActor () -> Bool,
        pillPinned: @escaping @MainActor () -> Bool,
        togglePill: @escaping @MainActor () -> Void
    ) {
        self.open = open
        self.pasteLast = pasteLast
        self.quit = quit
        self.paused = paused
        self.pillPinned = pillPinned
        self.togglePill = togglePill
    }
}

/// ThumbFree's menu-bar item (thumbfree-windows `TrayIcon`): the mark, red while recording and dimmed while
/// dictation can't start, with the state in its tooltip and the menu (`StatusMenu`).
@MainActor
public final class MenuBar {
    public let menu: StatusMenu

    private let services: AppServices
    private let permissions: Permissions
    private let item: NSStatusItem
    private var recording = false
    private var paused = false
    private var tokens: [ObservationToken] = []

    public init(services: AppServices, actions: MenuActions, permissions: Permissions) {
        self.services = services
        self.permissions = permissions
        menu = StatusMenu(services: services, actions: actions, permissions: permissions)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Pill.Mark.menuBarImage()
        item.menu = menu.menu
        tokens = [
            services.state.observe { [weak self] in
                guard let self else { return }
                onMain { self.refresh() }
            },
            services.settings.observe { [weak self] _ in
                guard let self else { return }
                onMain { self.refresh() }
            },
            services.models.observe { [weak self] _ in
                guard let self else { return }
                onMain {
                    self.refresh()
                    self.menu.refreshModel()
                }
            },
        ]
        refresh()
    }

    public func setRecording(_ recording: Bool) {
        self.recording = recording
        refresh()
    }

    public func setPaused(_ paused: Bool) {
        self.paused = paused
        refresh()
    }

    /// Opens the menu, as clicking the item does: where the model downloads and the permissions are, until the window
    /// comes in phase 4.
    public func open() {
        item.button?.performClick(nil)
    }

    /// The state in the tooltip and at the top of the menu (thumbfree-windows `TrayIcon.Refresh`).
    public func refresh() {
        let settings = services.current
        let key = settings.dictationKey.displayName
        let model = services.models.state(settings.selectedModel)
        let typing = permissions.status(.postEvents) == .granted && permissions.status(.accessibility) == .granted
        var ready = false
        let label: String
        if recording {
            label = "Recording — tap \(key) to finish"
            ready = true
        } else if paused {
            label = "Paused (dictation keys off)"
        } else if model.status == .downloading {
            label = "Downloading the speech model… \(Int(model.progress * 100))%"
        } else if model.status == .notInstalled {
            label = "Speech model needed — download it below"
        } else if !typing {
            label = "ThumbFree may not type yet — allow it below"
        } else {
            label = "Ready — tap \(key) to dictate"
            ready = true
        }

        item.button?.toolTip = "ThumbFree — \(label)"
        item.button?.appearsDisabled = !ready
        item.button?.contentTintColor = recording ? .systemRed : nil
        menu.showStatus(label, paused: paused)
    }
}

/// The menu (thumbfree-windows `TrayMenu`): open ThumbFree, the status, what's missing (a permission, the speech
/// model), the last five dictations (click copies), the text that wasn't typed, paste last, the language, the model,
/// the dictation key, pause, start at login, the pill, and Quit. Built apart from the item so tests can read it.
@MainActor
public final class StatusMenu: NSObject, NSMenuDelegate {
    static let recentCount = 5
    static let recentChars = 52

    public let menu = NSMenu()

    private let services: AppServices
    private let actions: MenuActions
    private let permissions: Permissions
    private let openItem = NSMenuItem()
    private let statusLine = NSMenuItem()
    private let noteLine = NSMenuItem()
    private let modelError = NSMenuItem()
    private let allowMicrophone = NSMenuItem()
    private let allowTyping = NSMenuItem()
    private let download = NSMenuItem()
    private let cancelDownload = NSMenuItem()
    private let recentEnd = NSMenuItem.separator()
    private let untyped = NSMenuItem()
    private let pasteLast = NSMenuItem()
    private let language = NSMenuItem()
    private let english = NSMenuItem()
    private let hinglish = NSMenuItem()
    private let model = NSMenuItem()
    private let models = NSMenu()
    private let key = NSMenuItem()
    private let fn = NSMenuItem()
    private let rightOption = NSMenuItem()
    private let pause = NSMenuItem()
    private let startAtLogin = NSMenuItem()
    private let showPill = NSMenuItem()
    private let quit = NSMenuItem()
    private var recent: [NSMenuItem] = []

    public init(services: AppServices, actions: MenuActions, permissions: Permissions) {
        self.services = services
        self.actions = actions
        self.permissions = permissions
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        set(openItem, "Open ThumbFree") { [weak self] in self?.actions.open(.home) }
        set(statusLine, "Starting…")
        set(noteLine, "")
        set(modelError, "")
        set(allowMicrophone, "Allow the microphone…") { [weak self] in self?.allow(.microphone) }
        set(allowTyping, "Allow ThumbFree to type (Accessibility)…") { [weak self] in self?.allow(.accessibility) }
        set(download, "Download the speech model") { [weak self] in self?.downloadChosen() }
        set(cancelDownload, "Cancel the download") { [weak self] in self?.cancelChosen() }
        set(untyped, "Copy the text that wasn't typed") { [weak self] in self?.services.notifier?.copyUntyped() }
        set(pasteLast, "Paste last dictation") { [weak self] in self?.actions.pasteLast() }
        set(language, "Dictation language")
        set(english, "English") { [weak self] in self?.services.settings.update { $0.language = .english } }
        set(hinglish, "Hindi + English (typed in Roman letters)") { [weak self] in
            self?.services.settings.update { $0.language = .hinglish }
        }
        set(model, "Speech model")
        set(key, "Dictation key")
        set(fn, "Fn (🌐)") { [weak self] in self?.services.settings.update { $0.dictationKey = .fn } }
        set(rightOption, "Right Option") { [weak self] in
            self?.services.settings.update { $0.dictationKey = .rightOption }
        }

        set(pause, "Pause dictation keys") { [weak self] in
            guard let self else { return }
            self.services.setPaused(!self.actions.paused())
        }

        set(startAtLogin, "Start at login") { [weak self] in
            guard let self else { return }
            self.services.environment.startsAtLogin = !self.services.environment.startsAtLogin
        }

        set(showPill, "Always show status pill") { [weak self] in self?.actions.togglePill() }
        set(quit, "Quit ThumbFree") { [weak self] in self?.actions.quit() }
        quit.keyEquivalent = "q"
        for (item, choices) in [(language, [english, hinglish]), (key, [fn, rightOption])] {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            choices.forEach { submenu.addItem($0) }
            item.submenu = submenu
            item.isEnabled = true
        }

        models.autoenablesItems = false
        model.submenu = models
        model.isEnabled = true
        for item in [
            openItem, NSMenuItem.separator(), statusLine, noteLine, modelError, allowMicrophone, allowTyping, download,
            cancelDownload, recentEnd, untyped, pasteLast, language, model, key, pause, NSMenuItem.separator(),
            startAtLogin, showPill, NSMenuItem.separator(), quit,
        ] {
            menu.addItem(item)
        }

        noteLine.isHidden = true
        prepare()
    }

    /// Brings the menu up to date before it opens: checks, what's missing, recent dictations, kept text.
    public func prepare() {
        let settings = services.current
        english.state = settings.language == .english ? .on : .off
        hinglish.state = settings.language == .hinglish ? .on : .off
        fn.state = settings.dictationKey == .fn ? .on : .off
        rightOption.state = settings.dictationKey == .rightOption ? .on : .off
        showPill.state = actions.pillPinned() ? .on : .off
        startAtLogin.state = services.environment.startsAtLogin ? .on : .off
        untyped.isHidden = services.notifier?.untypedText == nil
        allowMicrophone.isHidden = permissions.status(.microphone) == .granted
        allowTyping.isHidden =
            permissions.status(.postEvents) == .granted && permissions.status(.accessibility) == .granted
        refreshModel()
        showRecent()
    }

    public func showStatus(_ label: String, paused: Bool) {
        statusLine.title = label
        pause.title = paused ? "Resume dictation keys" : "Pause dictation keys"
    }

    /// A line under the status (that Jarvis is running too); nil hides it.
    public func showNote(_ note: String?) {
        noteLine.title = note ?? ""
        noteLine.isHidden = note == nil
    }

    /// The chosen model's download, and the models of the dictation language with their state.
    public func refreshModel() {
        let settings = services.current
        let spec = settings.selectedModel
        let state = services.models.state(spec)
        download.title = "Download the speech model (\(ModelConsent.shortName(spec)), \(ModelConsent.mb(spec.bytes)))"
        download.isHidden = state.status != .notInstalled
        cancelDownload.isHidden = state.status != .downloading
        modelError.title = state.error ?? ""
        modelError.isHidden = state.error == nil
        models.removeAllItems()
        let tiers: [Tier] = settings.language == .hinglish ? [.standard, .accurate] : [.live, .standard, .accurate]
        for tier in tiers {
            let choice = ModelCatalog.forLanguage(settings.language, tier)
            let item = NSMenuItem()
            set(item, Self.modelTitle(tier, choice, services.models.state(choice))) { [weak self] in
                self?.pick(tier)
            }

            item.state = settings.tier(for: settings.language) == tier ? .on : .off
            models.addItem(item)
        }
    }

    /// One line, at most `recentChars` UTF-16 units (thumbfree-windows `TrayMenu.MenuText`). A Mac menu shows "&" as
    /// it is, so it isn't doubled as on Windows.
    static func menuText(_ text: String) -> String {
        let line = DotNet.words(text).joined(separator: " ")
        let units = Array(line.utf16)
        guard units.count > recentChars else { return line }
        let cut = units[...(recentChars - 1)].lastIndex(of: 0x20) ?? -1
        var end = cut > recentChars / 2 ? cut : recentChars - 1
        if end > 0 && UTF16.isLeadSurrogate(units[end - 1]) {
            // Never half of a character made of two.
            end -= 1
        }

        return DotNet.trimEnd(String(decoding: units[..<end], as: UTF16.self), [",", ".", ";", ":"]) + "…"
    }

    /// "Live (types as you speak)", "Standard — 137 MB to download", "Accurate (slower) — downloading 42%".
    static func modelTitle(_ tier: Tier, _ spec: ModelSpec, _ state: ModelState) -> String {
        var title: String
        switch tier {
        case .live: title = "Live (types as you speak)"
        case .standard: title = "Standard"
        case .accurate: title = "Accurate (slower)"
        }

        switch state.status {
        case .installed: break
        case .downloading: title += " — downloading \(Int(state.progress * 100))%"
        case .notInstalled: title += " — \(ModelConsent.mb(spec.bytes)) to download"
        }

        return title
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        prepare()
    }

    /// Tests: what clicking `item` does.
    func click(_ item: NSMenuItem) {
        (item.representedObject as? MenuAction)?.run()
    }

    /// A title, and what clicking does; without an action the item is a line of text.
    private func set(_ item: NSMenuItem, _ title: String, _ action: (@MainActor () -> Void)? = nil) {
        item.title = title
        guard let action else {
            item.isEnabled = false
            return
        }

        item.target = self
        item.action = #selector(clicked(_:))
        item.representedObject = MenuAction(action)
        item.isEnabled = true
    }

    @objc private func clicked(_ sender: NSMenuItem) {
        click(sender)
    }

    /// The microphone is asked for the first time; otherwise System Settings opens where it's switched on. Typing:
    /// the first request lists ThumbFree under Accessibility, switched off; the pane opens to switch it on.
    private func allow(_ kind: Permissions.Kind) {
        permissions.request(kind == .microphone ? .microphone : .postEvents) { [weak self] status in
            guard let self else { return }
            if status != .granted {
                self.permissions.openSettings(kind)
            }

            self.prepare()
        }
    }

    private func downloadChosen() {
        ModelActions.download(services, services.current.selectedModel)
    }

    private func cancelChosen() {
        services.models.cancel(services.current.selectedModel)
    }

    /// Another model for the dictation language: a big one not on this Mac asks first, and stays unchosen if the answer
    /// is no; a small one downloads at once.
    private func pick(_ tier: Tier) {
        let settings = services.current
        let spec = ModelCatalog.forLanguage(settings.language, tier)
        if services.models.state(spec).status == .notInstalled && !ModelActions.download(services, spec) {
            return
        }

        services.settings.update { settings in
            if settings.language == .hinglish {
                settings.hinglishTier = tier
            } else {
                settings.englishTier = tier
            }
        }
    }

    /// The last dictations, newest first, right in the menu: click one to copy it.
    private func showRecent() {
        recent.forEach { menu.removeItem($0) }
        recent = []
        let entries = services.current.keepHistory ? Array(services.history.entries().prefix(Self.recentCount)) : []
        if !entries.isEmpty {
            let header = NSMenuItem()
            set(header, "Recent dictations: click one to copy it")
            recent = [.separator(), header]
        }

        for entry in entries {
            let item = NSMenuItem()
            let text = entry.text
            set(item, Self.menuText(text)) { [weak self] in self?.services.environment.copyText(text) }
            item.toolTip = text.count > 300 ? String(text.prefix(300)) + "…" : text
            recent.append(item)
        }

        var at = menu.index(of: recentEnd)
        for item in recent {
            menu.insertItem(item, at: at)
            at += 1
        }
    }
}

/// What a menu item does when it's clicked.
private final class MenuAction {
    let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) {
        self.run = run
    }
}

/// Download for the model choices, with the big-model question (PLAN 3.1) first (thumbfree-windows `ModelActions`;
/// deleting comes with the Settings page, in phase 4).
@MainActor
enum ModelActions {
    /// Starts downloading `spec`; a big model first asks about its size, memory and data. False when the answer is no.
    @discardableResult
    static func download(_ services: AppServices, _ spec: ModelSpec) -> Bool {
        if ModelConsent.needed(spec) {
            let environment = services.environment
            let question = Confirmation(
                title: ModelConsent.title(spec),
                message: ModelConsent.message(
                    spec, totalMemoryBytes: environment.totalMemoryBytes, metered: environment.isMeteredConnection()),
                confirm: "Download (\(ModelConsent.mb(spec.bytes)))",
                cancel: "Not now")
            if !environment.confirm(question) {
                return false
            }
        }

        services.models.start(spec)
        return true
    }
}
