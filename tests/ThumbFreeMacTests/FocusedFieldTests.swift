import ApplicationServices
import XCTest
@testable import ThumbFreeMac

/// Reading the focused box through a fake Accessibility API: what kind of box it is, the text before the cursor (in
/// UTF-16 units, as apps count it), the same-box check, and waking Chromium and Electron apps.
final class FocusedFieldTests: XCTestCase {
    private let notes: pid_t = 11
    private let chrome: pid_t = 12
    private let slack: pid_t = 13

    func testATextAreaTakesLineBreaksAndGivesTheTextBeforeTheCursor() throws {
        let system = FakeAXSystem()
        system.apps[notes] = FocusedField.App(
            processIdentifier: notes, bundleIdentifier: "com.apple.Notes", name: "Notes")
        let window = system.window("Shopping", in: notes)
        window.frame = CGRect(x: 100, y: 50, width: 800, height: 600)
        let box = FakeAXField("AXTextArea", in: window, [kAXValueAttribute: "Milk\nEggs and bread"])
        box.selection = CFRange(location: 9, length: 0)
        system.focus = box

        let field = try XCTUnwrap(FocusedField.Reader(source: system).read())

        XCTAssertEqual("AXTextArea", field.role)
        XCTAssertNil(field.subrole)
        XCTAssertEqual(true, field.takesLineBreaks)
        XCTAssertEqual("Milk\nEggs", field.textBefore)
        XCTAssertTrue(field.caretKnown)
        XCTAssertFalse(field.isSecure)
        XCTAssertFalse(field.isSearch)
        XCTAssertFalse(field.isInWebPage)
        XCTAssertFalse(field.secureEventInput)
        XCTAssertEqual(
            FocusedField.App(processIdentifier: notes, bundleIdentifier: "com.apple.Notes", name: "Notes"), field.app)
        XCTAssertEqual("Shopping", field.windowTitle)
        XCTAssertEqual(CGRect(x: 100, y: 50, width: 800, height: 600), field.windowFrame)
        XCTAssertEqual("AXTextArea multi-line", field.kind)
    }

    func testTextFieldsComboBoxesAndSearchBoxesTakeNoLineBreaks() throws {
        for (role, subrole, search) in [
            ("AXTextField", nil, false), ("AXComboBox", nil, false), ("AXTextField", "AXSearchField", true),
            ("AXSearchField", nil, true),
        ] as [(String, String?, Bool)] {
            let system = FakeAXSystem()
            let window = system.window("Find", in: notes)
            system.focus = FakeAXField(role, subrole: subrole, in: window, [kAXValueAttribute: "milk"])

            let field = try XCTUnwrap(FocusedField.Reader(source: system).read())

            XCTAssertEqual(false, field.takesLineBreaks, role)
            XCTAssertEqual(search, field.isSearch, role)
            XCTAssertEqual("milk", field.textBefore, role)
        }
    }

    func testSearchBoxesAreAlsoKnownByTheirLabelsAndIdentifiers() throws {
        for (attribute, label, search) in [
            ("AXPlaceholderValue", "Search mail", true), (kAXDescriptionAttribute, "Address and search bar", true),
            (kAXTitleAttribute, "SEARCH", true), ("AXDOMIdentifier", "searchbox", true),
            ("AXIdentifier", "find-search", true), (kAXDescriptionAttribute, "Message body", false),
        ] {
            let system = FakeAXSystem()
            system.focus = FakeAXField("AXTextArea", in: system.window("Inbox", in: notes), [attribute: label])

            let field = try XCTUnwrap(FocusedField.Reader(source: system).read())

            XCTAssertEqual(search, field.isSearch, label)
            XCTAssertEqual(search ? false : true, field.takesLineBreaks, label)
        }
    }

    func testPasswordBoxesAreNeverRead() throws {
        let boxes: [(String, String?)] = [("AXTextField", "AXSecureTextField"), ("AXSecureTextField", nil)]
        for (role, subrole) in boxes {
            let system = FakeAXSystem()
            let box = FakeAXField(
                role, subrole: subrole, in: system.window("Sign in", in: notes),
                [kAXValueAttribute: "hunter2", "AXPlaceholderValue": "Search password"])
            box.selection = CFRange(location: 7, length: 0)
            system.focus = box

            let field = try XCTUnwrap(FocusedField.Reader(source: system).read())

            XCTAssertTrue(field.isSecure, role)
            XCTAssertFalse(field.isSearch, role)
            XCTAssertEqual(false, field.takesLineBreaks, role)
            XCTAssertNil(field.textBefore, role)
            XCTAssertFalse(field.caretKnown, role)
            XCTAssertFalse(box.asked.contains(kAXValueAttribute), role)
            XCTAssertFalse(box.asked.contains("AXPlaceholderValue"), role)
        }
    }

    func testSecureEventInputIsReported() throws {
        let system = FakeAXSystem()
        system.secureEventInput = true
        system.focus = FakeAXField("AXTextField", in: system.window("Terminal", in: notes))

        let field = try XCTUnwrap(FocusedField.Reader(source: system).read())

        XCTAssertTrue(field.secureEventInput)
        XCTAssertFalse(field.isSecure)
    }

    func testTheTextBeforeTheCursorIsCountedInUTF16UnitsAsAppsCountIt() throws {
        for (value, location, before) in [
            ("Hi 👋 there", 5, "Hi 👋"),
            // A cursor inside an emoji's two units stops before it.
            ("Hi 👋 there", 4, "Hi "),
            ("Go 🇮🇳 now", 7, "Go 🇮🇳"),
            ("Café ☕️ ok", 7, "Café ☕️"),
            ("We 👨‍👩‍👧 went", 11, "We 👨‍👩‍👧"),
            ("short", 99, "short"),
            ("start", 0, ""),
        ] {
            let system = FakeAXSystem()
            let box = FakeAXField("AXTextArea", in: system.window("Chat", in: notes), [kAXValueAttribute: value])
            box.selection = CFRange(location: location, length: 2)
            system.focus = box

            let field = try XCTUnwrap(FocusedField.Reader(source: system).read())

            XCTAssertEqual(before, field.textBefore, "\(value) at \(location)")
            XCTAssertTrue(field.caretKnown)
        }
    }

    func testOnlyTheLast2000UnitsBeforeTheCursorAreKept() throws {
        let system = FakeAXSystem()
        let many = String(repeating: "a", count: 1999)
        let window = system.window("Essay", in: notes)
        let box = FakeAXField("AXTextArea", in: window, [kAXValueAttribute: "👋" + many + " end"])
        box.selection = CFRange(location: 2001, length: 0)
        system.focus = box

        let field = try XCTUnwrap(FocusedField.Reader(source: system).read())

        // The cut falls inside the emoji, so all of it goes: 1999 units are kept.
        XCTAssertEqual(many, field.textBefore)
    }

    func testWithoutACursorTheWholeValueCounts() throws {
        let system = FakeAXSystem()
        system.focus = FakeAXField(
            "AXTextArea", in: system.window("Note", in: notes),
            [kAXValueAttribute: String(repeating: "b", count: 2500)])

        let field = try XCTUnwrap(FocusedField.Reader(source: system).read())

        XCTAssertEqual(String(repeating: "b", count: 2000), field.textBefore)
        XCTAssertFalse(field.caretKnown)
    }

    func testOtherRolesDontSayWhetherTheyTakeLineBreaks() throws {
        let system = FakeAXSystem()
        system.focus = FakeAXField("AXGroup", in: system.window("Editor", in: notes))

        let field = try XCTUnwrap(FocusedField.Reader(source: system).read())

        XCTAssertNil(field.takesLineBreaks)
        XCTAssertNil(field.textBefore)
        XCTAssertEqual("AXGroup", field.kind)
    }

    func testNothingIsReadWithoutTheFocusOrAnAnswer() {
        let system = FakeAXSystem()
        XCTAssertNil(FocusedField.Reader(source: system).read())

        system.focus = FakeAXField("AXTextField", in: system.window("Find", in: notes))
        system.answering = false
        XCTAssertNil(FocusedField.Reader(source: system).read())

        // ThumbFree never reads its own windows.
        system.answering = true
        let own = system.window("Settings", in: ProcessInfo.processInfo.processIdentifier)
        system.focus = FakeAXField("AXTextField", in: own)
        XCTAssertNil(FocusedField.Reader(source: system).read())
    }

    func testAnAppThatStopsAnsweringIsAskedNothingMore() throws {
        let system = FakeAXSystem()
        let box = FakeAXField("AXTextArea", in: system.window("Busy", in: notes), [kAXValueAttribute: "Hello"])
        system.focus = box
        // The focus, the process, the role and the subrole are answered; nothing after that.
        system.answersLeft = 4

        let field = try XCTUnwrap(FocusedField.Reader(source: system).read())

        XCTAssertEqual("AXTextArea", field.role)
        XCTAssertNil(field.textBefore)
        XCTAssertNil(field.windowTitle)
        XCTAssertEqual(1, system.unanswered)
    }

    func testTheSameBoxIsRecognisedAgain() throws {
        let system = FakeAXSystem()
        let window = system.window("Notes", in: notes)
        let box = FakeAXField("AXTextArea", in: window)
        system.focus = box
        let reader = FocusedField.Reader(source: system)
        let field = try XCTUnwrap(reader.read())

        XCTAssertEqual(true, reader.isSameField(field))

        system.focus = FakeAXField("AXTextField", in: window)
        XCTAssertEqual(false, reader.isSameField(field), "another box in the same window")

        system.focus = FakeAXField("AXTextArea", in: system.window("Chat", in: slack))
        XCTAssertEqual(false, reader.isSameField(field), "another app")

        system.focus = nil
        XCTAssertEqual(false, reader.isSameField(field), "nothing has the focus")

        system.focus = box
        system.answering = false
        XCTAssertNil(reader.isSameField(field), "no answer")
    }

    func testChromiumBrowsersAreWokenOnceAndTheirBoxIsWaitedFor() throws {
        let system = FakeAXSystem()
        system.apps[chrome] = FocusedField.App(
            processIdentifier: chrome, bundleIdentifier: "com.google.Chrome.canary", name: "Chrome")
        let app = system.application(chrome) as! FakeAXField
        let page = FakeAXField("AXWebArea", in: system.window("Inbox - Gmail", in: chrome))
        let box = FakeAXField("AXTextArea", in: FakeAXField("AXGroup", in: page))
        system.focus = page
        // The page describes its box once Chrome has been asked to.
        system.onFocusQuery = { [unowned system] in
            if app.flags["AXEnhancedUserInterface"] == true { system.focus = box }
        }
        let clock = FakeReaderClock()
        let reader = FocusedField.Reader(source: system, sleep: clock.sleep, now: clock.now)

        let field = try XCTUnwrap(reader.read())

        XCTAssertEqual("AXTextArea", field.role)
        XCTAssertTrue(field.isInWebPage)
        XCTAssertEqual("Inbox - Gmail", field.windowTitle)
        XCTAssertEqual(["AXEnhancedUserInterface": true], app.flags)
        XCTAssertEqual(0.05, clock.time, accuracy: 0.001)
        XCTAssertEqual(true, reader.isSameField(field))

        // Once a Chrome is woken, it isn't asked again.
        app.flags = [:]
        system.focus = page
        let again = try XCTUnwrap(reader.read())
        XCTAssertEqual("AXWebArea", again.role)
        XCTAssertEqual([:], app.flags)
    }

    func testElectronAppsAreWokenWithManualAccessibility() throws {
        let system = FakeAXSystem()
        system.apps[slack] = FocusedField.App(
            processIdentifier: slack, bundleIdentifier: "com.tinyspeck.slackmacgap", isElectron: true)
        let app = system.application(slack) as! FakeAXField
        system.focus = FakeAXField("AXTextArea", in: FakeAXField("AXWebArea", in: system.window("general", in: slack)))
        let clock = FakeReaderClock()

        let field = try XCTUnwrap(FocusedField.Reader(source: system, sleep: clock.sleep, now: clock.now).read())

        XCTAssertEqual(["AXManualAccessibility": true], app.flags)
        XCTAssertEqual("AXTextArea", field.role)
        // The box had the focus already: nothing was waited for.
        XCTAssertEqual(0, clock.time)
    }

    func testTheWakeCanBeTurnedOff() throws {
        let system = FakeAXSystem()
        system.apps[chrome] = FocusedField.App(processIdentifier: chrome, bundleIdentifier: "com.google.Chrome")
        let app = system.application(chrome) as! FakeAXField
        system.focus = FakeAXField("AXWebArea", in: system.window("New Tab", in: chrome))
        let clock = FakeReaderClock()
        let reader = FocusedField.Reader(source: system, sleep: clock.sleep, now: clock.now)
        reader.wakesWebContent = false

        let field = try XCTUnwrap(reader.read())

        XCTAssertEqual([:], app.flags)
        XCTAssertEqual("AXWebArea", field.role)
        XCTAssertEqual(0, clock.time)
    }

    func testAPageWhoseBoxWasntFoundIsRecognisedByThePage() throws {
        let system = FakeAXSystem()
        system.apps[chrome] = FocusedField.App(processIdentifier: chrome, bundleIdentifier: "com.microsoft.edgemac")
        let window = system.window("Docs", in: chrome)
        let page = FakeAXField("AXWebArea", in: window)
        system.focus = page
        let clock = FakeReaderClock()
        let reader = FocusedField.Reader(source: system, sleep: clock.sleep, now: clock.now)

        let field = try XCTUnwrap(reader.read())

        // Waited 1.2 s for a box that never came.
        XCTAssertEqual(1.2, clock.time, accuracy: 0.06)
        XCTAssertEqual("AXWebArea web unresolved", field.kind)
        XCTAssertNil(field.takesLineBreaks)

        system.focus = FakeAXField("AXTextArea", in: FakeAXField("AXGroup", in: page))
        XCTAssertEqual(true, reader.isSameField(field), "the page's box, described at last")

        let toolbar = FakeAXField("AXToolbar", in: window)
        system.focus = FakeAXField("AXTextField", in: toolbar, [kAXDescriptionAttribute: "Address and search bar"])
        XCTAssertEqual(false, reader.isSameField(field), "the address bar")

        system.focus = FakeAXField("AXTextArea", in: FakeAXField("AXWebArea", in: window))
        XCTAssertEqual(false, reader.isSameField(field), "another tab")
    }
}

/// An element of a fake app: its attributes, its parent, and what it was asked.
private final class FakeAXField {
    let pid: pid_t
    let role: String?
    let subrole: String?
    let parent: FakeAXField?
    var strings: [String: String]
    var selection: CFRange?
    var frame: CGRect?
    var flags: [String: Bool] = [:]
    var asked: [String] = []

    init(_ role: String?, subrole: String? = nil, in parent: FakeAXField?, _ strings: [String: String] = [:]) {
        self.role = role
        self.subrole = subrole
        self.parent = parent
        self.pid = parent?.pid ?? 0
        self.strings = strings
    }

    init(application pid: pid_t) {
        self.pid = pid
        role = "AXApplication"
        subrole = nil
        parent = nil
        strings = [:]
    }
}

/// Accessibility over fake elements. `answering` false, or `answersLeft` used up, makes every call go unanswered.
private final class FakeAXSystem: FocusedField.Accessibility {
    var focus: FakeAXField?
    var answering = true
    var answersLeft = Int.max
    var unanswered = 0
    var apps: [pid_t: FocusedField.App] = [:]
    var secureEventInput = false
    /// Runs at each focus query, before it's answered: the focus moving while the reader waits.
    var onFocusQuery: (() -> Void)?
    private var applications: [pid_t: FakeAXField] = [:]

    /// A window titled `title`, in the app `pid`.
    func window(_ title: String, in pid: pid_t) -> FakeAXField {
        FakeAXField("AXWindow", in: application(pid) as? FakeAXField, [kAXTitleAttribute: title])
    }

    func focusedElement() throws -> AnyObject? {
        onFocusQuery?()
        try answer()
        return focus
    }

    func string(_ attribute: String, of element: AnyObject) throws -> String? {
        try answer()
        let field = element as! FakeAXField
        field.asked.append(attribute)
        switch attribute {
        case kAXRoleAttribute: return field.role
        case kAXSubroleAttribute: return field.subrole
        default: return field.strings[attribute]
        }
    }

    func range(_ attribute: String, of element: AnyObject) throws -> CFRange? {
        try answer()
        let field = element as! FakeAXField
        field.asked.append(attribute)
        return attribute == kAXSelectedTextRangeAttribute ? field.selection : nil
    }

    func element(_ attribute: String, of element: AnyObject) throws -> AnyObject? {
        try answer()
        return attribute == kAXParentAttribute ? (element as! FakeAXField).parent : nil
    }

    func frame(of element: AnyObject) throws -> CGRect? {
        try answer()
        return (element as! FakeAXField).frame
    }

    func processIdentifier(of element: AnyObject) throws -> pid_t {
        try answer()
        return (element as! FakeAXField).pid
    }

    func application(_ processIdentifier: pid_t) -> AnyObject {
        if let app = applications[processIdentifier] {
            return app
        }

        let app = FakeAXField(application: processIdentifier)
        applications[processIdentifier] = app
        return app
    }

    func setFlag(_ attribute: String, _ value: Bool, of element: AnyObject) -> Bool {
        (element as! FakeAXField).flags[attribute] = value
        return true
    }

    func isSame(_ element: AnyObject, as other: AnyObject) -> Bool {
        element === other
    }

    func app(_ processIdentifier: pid_t) -> FocusedField.App {
        apps[processIdentifier] ?? FocusedField.App(processIdentifier: processIdentifier)
    }

    private func answer() throws {
        answersLeft -= 1
        guard answering, answersLeft >= 0 else {
            unanswered += 1
            throw FocusedField.NoAnswer()
        }
    }
}

/// Time that passes only when the reader sleeps.
private final class FakeReaderClock {
    private(set) var time: TimeInterval = 0

    func sleep(_ interval: TimeInterval) {
        time += interval
    }

    func now() -> TimeInterval {
        time
    }
}
