import AppKit
import AVFoundation
import XCTest
import ThumbFreeCore
import ThumbFreeMac
@testable import ThumbFreeApp

/// The menu bar's menu (thumbfree-windows tests' UiTests: the tray menu, and TextTests: its one-line items), read and
/// clicked as `StatusMenu` builds it, with no status item on the screen.
final class MenuBarTests: XCTestCase {
    @MainActor
    func testTheMenuListsTheLastFiveDictationsToCopy() throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let environment = FakeEnvironment()
        let models = FakeModelManager()
        models.install(ModelCatalog.englishLive)
        let now = Locked(Date())
        let services = TestServices.create(folder, environment: environment, models: models, clock: { now.value })
        Self.seed(services, now)
        let notifier = Notifier(surface: FakeSurface(), state: services.state, copy: { _ in }, queue: nil)
        services.notifier = notifier
        notifier.showUntyped("Call me at 4 PM.")
        let opened = Locked<[AppPage]>([])
        let menu = StatusMenu(
            services: services, actions: Self.actions(open: { page in opened.update { $0.append(page) } }),
            permissions: Permissions(system: FakePermissions()))
        menu.showStatus("Ready — tap Fn to dictate", paused: false)

        menu.prepare()
        let items = Self.shown(menu.menu)
        XCTAssertEqual(items.first?.title, "Open ThumbFree")
        let header = try XCTUnwrap(items.firstIndex { $0.title == "Recent dictations: click one to copy it" })
        XCTAssertEqual(
            items[(header + 1)...].prefix(5).map(\.title),
            [
                "Hey Tim, Would love to connect. Are you available…",
                "Notes from the design review. The guide needs a…",
                "Kal ki meeting cancel ho gayi hai, please sabko…",
                "Things to do today: - Order groceries. - Go on a…",
                "Can you send me the build logs? Thanks!",
            ])
        XCTAssertTrue(items.contains { $0.title == "Copy the text that wasn't typed" })
        XCTAssertEqual(items.last?.title, "Quit ThumbFree")

        menu.click(try XCTUnwrap(items.first { $0.title.hasPrefix("Can you send") }))
        XCTAssertEqual(environment.copied, ["Can you send me the build logs? Thanks!"])
        menu.click(items[0])
        XCTAssertEqual(opened.value, [.home])

        // Opening again rebuilds the list instead of adding to it.
        menu.prepare()
        XCTAssertEqual(Self.shown(menu.menu).count, items.count)
    }

    @MainActor
    func testMenuItemsAreOneShortLine() {
        // Windows doubles "&", which its menus would take for a shortcut; a Mac menu shows it as it is.
        let cases = [
            ("Short one.", "Short one."),
            ("Tom & Jerry", "Tom & Jerry"),
            ("Hey Tim,\n\nWould love to connect.\n\nThanks,\nBen", "Hey Tim, Would love to connect. Thanks, Ben"),
            (
                "Things to do today: order groceries, go on a walk, and call mom please",
                "Things to do today: order groceries, go on a walk…"
            ),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(StatusMenu.menuText(text), expected, text)
        }
    }

    /// The Mac's own: the speech models of the dictation language, with what each needs; a big one asks first, and a
    /// no leaves the choice as it was.
    @MainActor
    func testTheModelChoicesSayWhatTheyNeedAndABigOneAsksFirst() throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let environment = FakeEnvironment()
        environment.answer = false
        let models = FakeModelManager()
        models.install(ModelCatalog.englishLive)
        let services = TestServices.create(folder, environment: environment, models: models)
        let menu = StatusMenu(
            services: services, actions: Self.actions(), permissions: Permissions(system: FakePermissions()))
        let choices = try XCTUnwrap(menu.menu.items.first { $0.title == "Speech model" }?.submenu)
        let standard = ModelConsent.mb(ModelCatalog.englishFast.bytes)
        XCTAssertEqual(
            choices.items.map(\.title),
            [
                "Live (types as you speak)", "Standard — \(standard) to download",
                "Accurate (slower) — 661 MB to download",
            ])
        XCTAssertEqual(choices.items.map(\.state), [.on, .off, .off])

        menu.click(choices.items[2])
        XCTAssertEqual(environment.questions.map(\.title), ["Download “English, accurate”?"])
        XCTAssertEqual(services.current.englishTier, .live)
        XCTAssertEqual(services.models.state(ModelCatalog.englishAccurate).status, .notInstalled)

        environment.answer = true
        menu.click(choices.items[2])
        models.waitStarted(ModelCatalog.englishAccurate)
        XCTAssertEqual(services.current.englishTier, .accurate)
        menu.click(choices.items[1])
        models.waitStarted(ModelCatalog.englishFast)
        XCTAssertEqual(environment.questions.count, 2)
        XCTAssertEqual(services.current.englishTier, .standard)

        menu.refreshModel()
        let refreshed = try XCTUnwrap(menu.menu.items.first { $0.title == "Speech model" }?.submenu)
        XCTAssertEqual(refreshed.items.map(\.title)[2], "Accurate (slower) — downloading 0%")
        XCTAssertEqual(refreshed.items.map(\.state), [.off, .on, .off])
        models.finish(ModelCatalog.englishAccurate)
        models.finish(ModelCatalog.englishFast)
    }

    /// The Mac's own: a permission dictation needs and doesn't have is named in the menu, and its item opens the pane
    /// of System Settings where it's switched on (macOS has asked already, so it can't ask again).
    @MainActor
    func testAMissingPermissionIsNamedAndItsItemOpensItsPane() throws {
        let folder = TempFolder()
        defer { folder.remove() }
        let system = FakePermissions(granted: false)
        let menu = StatusMenu(
            services: TestServices.create(folder), actions: Self.actions(), permissions: Permissions(system: system))
        let items = Self.shown(menu.menu)
        let microphone = try XCTUnwrap(items.first { $0.title == "Allow the microphone…" })
        let typing = try XCTUnwrap(items.first { $0.title == "Allow ThumbFree to type (Accessibility)…" })

        menu.click(microphone)
        Self.runMainLoop { system.opened.count == 1 }
        menu.click(typing)
        Self.runMainLoop { system.opened.count == 2 }

        XCTAssertEqual(system.opened, [Permissions.settingsURL(.microphone), Permissions.settingsURL(.accessibility)])
    }

    /// The items a person sees: not hidden, and not separators.
    @MainActor
    private static func shown(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }
    }

    @MainActor
    private static func actions(open: @escaping @MainActor (AppPage) -> Void = { _ in }) -> MenuActions {
        MenuActions(
            open: open, pasteLast: {}, quit: {}, paused: { false }, pillPinned: { false }, togglePill: {})
    }

    /// Runs the main thread's loop, where permissions answer, until `done` (2 s at most).
    @MainActor
    private static func runMainLoop(until done: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(2)
        while !done() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertTrue(done(), "timed out", file: file, line: line)
    }

    /// Six dictations, newest first: an email, notes, Hinglish, a list, a question and an older one that isn't shown.
    private static func seed(_ services: AppServices, _ now: Locked<Date>) {
        let real = Date()
        let dictations: [(ago: TimeInterval, app: String, text: String)] = [
            (
                3 * 86_400, "Microsoft Word",
                "Our Q3 plan focuses on three things: faster onboarding, fewer support tickets and a cleaner settings "
                    + "page. Priya owns onboarding, Sam owns support, and I'll take settings."
            ),
            (26 * 3_600, "Slack", "Can you send me the build logs? Thanks!"),
            (5 * 3_600, "Google Chrome", "Things to do today:\n- Order groceries.\n- Go on a walk.\n- Call mom."),
            (40 * 60, "Microsoft Teams", "Kal ki meeting cancel ho gayi hai, please sabko bata dena."),
            (
                9 * 60, "Notes",
                "Notes from the design review. The guide needs a shorter welcome, the settings page should save as you "
                    + "go, and History should open from the tray. We agreed to keep everything on the device: no "
                    + "uploads, no accounts. Next steps: render every page offscreen, check the layout at 100% and "
                    + "150% scaling, and write the release notes. Follow up with the team on Friday about the icons "
                    + "and the Hindi + English model sizes."
            ),
            (
                2 * 60, "Mail",
                "Hey Tim,\n\nWould love to connect. Are you available on Friday at 4 PM?\n\nThanks,\nBen"
            ),
        ]
        for dictation in dictations {
            now.update { $0 = real.addingTimeInterval(-dictation.ago) }
            services.history.add(dictation.text, app: dictation.app, passwordField: false)
        }

        now.update { $0 = real }
        XCTAssertTrue(services.history.flush(timeout: 5))
    }
}

/// macOS's permissions as these tests see them: all allowed, or none (and macOS has asked already). Records the System
/// Settings panes opened.
final class FakePermissions: Permissions.System, @unchecked Sendable {
    private let granted: Bool
    private let openedURLs = Locked<[URL]>([])

    init(granted: Bool = true) {
        self.granted = granted
    }

    var opened: [URL] { openedURLs.value }

    func microphoneStatus() -> AVAuthorizationStatus { granted ? .authorized : .denied }

    func requestMicrophone(_ completion: @escaping @Sendable (Bool) -> Void) {
        completion(granted)
    }

    func isAccessibilityTrusted(prompt: Bool) -> Bool { granted }

    func canPostEvents() -> Bool { granted }

    func requestPostEvents() -> Bool { granted }

    func canListenToEvents() -> Bool { granted }

    func requestListenToEvents() -> Bool { granted }

    func open(_ url: URL) -> Bool {
        openedURLs.update { $0.append(url) }
        return true
    }
}
