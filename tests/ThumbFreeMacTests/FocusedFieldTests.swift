import ApplicationServices
import XCTest
@testable import ThumbFreeMac

/// Reading the focused box through a fake Accessibility API: what kind of box it is, the text before the cursor (in
/// UTF-16 units, as apps count it, fetched on its own), the same-box check, and waking Chromium and Electron apps.
final class FocusedFieldTests: XCTestCase {
    private let notes: pid_t = 11
    private let chrome: pid_t = 12
    private let slack: pid_t = 13
    private let spotlight: pid_t = 14
    private let safari: pid_t = 15
    private let webContent: pid_t = 16

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
        XCTAssertTrue(field.isResolved)
        XCTAssertFalse(field.isSecure)
        XCTAssertFalse(field.isSearch)
        XCTAssertFalse(field.isInWebPage)
        XCTAssertEqual(.off, field.secureInput)
        XCTAssertEqual(
            FocusedField.App(processIdentifier: notes, bundleIdentifier: "com.apple.Notes", name: "Notes"), field.app)
        XCTAssertEqual("Shopping", field.windowTitle)
        XCTAssertEqual(CGRect(x: 100, y: 50, width: 800, height: 600), field.windowFrame)
        XCTAssertEqual("AXTextArea multi-line", field.kind)
        // Only the text before the cursor was fetched, not the box's whole text.
        XCTAssertTrue(box.asked.contains("\(kAXStringForRangeParameterizedAttribute) 0+9"), "\(box.asked)")
        XCTAssertFalse(box.asked.contains(kAXValueAttribute))
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
            XCTAssertEqual([kAXRoleAttribute, kAXSubroleAttribute], box.asked, role)
        }
    }

    func testSecureInputIsReportedAndSoIsNotKnowingIt() throws {
        let system = FakeAXSystem()
        system.focus = FakeAXField("AXTextField", in: system.window("Terminal", in: notes))
        let states: [(FocusedField.SecureInput, String)] = [
            (.on, "AXTextField single-line secure-input"), (.unknown, "AXTextField single-line secure-input-unknown"),
        ]
        for (secureInput, kind) in states {
            system.secureInput = secureInput

            let field = try XCTUnwrap(FocusedField.Reader(source: system).read())

            XCTAssertEqual(secureInput, field.secureInput)
            XCTAssertFalse(field.isSecure)
            XCTAssertEqual(kind, field.kind)
        }
    }

    func testTheTextBeforeTheCursorIsCountedInUTF16UnitsAsAppsCountIt() throws {
        for ranges in [true, false] {
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
                box.ranges = ranges
                system.focus = box

                let field = try XCTUnwrap(FocusedField.Reader(source: system).read())

                XCTAssertEqual(before, field.textBefore, "\(value) at \(location), ranges \(ranges)")
                XCTAssertTrue(field.caretKnown)
            }
        }
    }

    func testOnlyTheLast2000UnitsBeforeTheCursorAreFetched() throws {
        let a = String(repeating: "a", count: 500)
        let b = String(repeating: "b", count: 2000)
        let c = String(repeating: "c", count: 500)
        for (value, cursor, range, before) in [
            (a + b + c, 2500, "499+2001", b),
            // An emoji cut in two at the start of what's fetched goes: 2000 units are left.
            ("x" + "👋" + b, 2003, "2+2001", b),
            // An emoji whole at the start goes too, as the 2000 units start inside it.
            ("x" + "👋" + String(b.dropFirst()), 2002, "1+2001", String(b.dropFirst())),
        ] {
            let system = FakeAXSystem()
            let box = FakeAXField("AXTextArea", in: system.window("Essay", in: notes), [kAXValueAttribute: value])
            box.selection = CFRange(location: cursor, length: 0)
            system.focus = box

            let field = try XCTUnwrap(FocusedField.Reader(source: system).read())

            XCTAssertEqual(before, field.textBefore, range)
            XCTAssertTrue(box.asked.contains("\(kAXStringForRangeParameterizedAttribute) \(range)"), "\(box.asked)")
            XCTAssertFalse(box.asked.contains(kAXValueAttribute))
        }
    }

    func testWithoutACursorOnlyTheEndOfTheTextIsFetched() throws {
        for ranges in [true, false] {
            let system = FakeAXSystem()
            let box = FakeAXField(
                "AXTextArea", in: system.window("Note", in: notes),
                [kAXValueAttribute: String(repeating: "b", count: 2500)])
            box.ranges = ranges
            system.focus = box

            let field = try XCTUnwrap(FocusedField.Reader(source: system).read())

            XCTAssertEqual(String(repeating: "b", count: 2000), field.textBefore)
            XCTAssertFalse(field.caretKnown)
            // The whole text is read only from a box that can't give a range.
            XCTAssertEqual(!ranges, box.asked.contains(kAXValueAttribute), "ranges \(ranges)")
        }
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

    func testTheFocusComesFromTheAppTakingTheKeysWhenTheSystemWideElementHasNone() throws {
        let system = FakeAXSystem()
        let box = FakeAXField("AXTextField", in: system.window("Search", in: notes))
        system.focus = box
        system.systemWideFocus = false
        (system.application(notes) as? FakeAXField)?.focused = box
        system.front = slack
        let reader = FocusedField.Reader(source: system)

        let field = try XCTUnwrap(reader.read())

        XCTAssertEqual("AXTextField", field.role)
        XCTAssertEqual(notes, field.app.processIdentifier)
        XCTAssertEqual(true, reader.isSameField(field))

        // When the system-wide element doesn't say which app takes the keys either, the app in front is asked.
        system.systemWideApp = false
        system.front = notes
        XCTAssertEqual("AXTextField", reader.read()?.role)
        XCTAssertEqual(true, reader.isSameField(field))
    }

    func testAnAppThatStopsAnsweringIsAskedNothingMore() throws {
        let system = FakeAXSystem()
        let box = FakeAXField("AXTextArea", in: system.window("Busy", in: notes), [kAXValueAttribute: "Hello"])
        system.focus = box
        // The app taking the keys, its process, the focus, the role and the subrole are answered; nothing after that.
        system.answersLeft = 5

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
        system.front = notes
        XCTAssertEqual(false, reader.isSameField(field), "nothing has the focus")
    }

    func testAnotherAppInFrontIsAnotherBoxEvenWithoutAnAnswer() throws {
        let system = FakeAXSystem()
        system.focus = FakeAXField("AXTextArea", in: system.window("Notes", in: notes))
        let reader = FocusedField.Reader(source: system)
        let field = try XCTUnwrap(reader.read())
        system.answering = false

        XCTAssertNil(reader.isSameField(field), "Notes in front, but its focus can't be told")

        system.front = slack
        XCTAssertEqual(false, reader.isSameField(field), "Slack in front")
    }

    func testABoxInAPanelThatTakesTheKeysWhileAnotherAppStaysInFrontIsStillTheSameBox() throws {
        // Spotlight, Alfred, Raycast and notifications' reply boxes take the keys without coming to the front.
        let system = FakeAXSystem()
        system.apps[spotlight] = FocusedField.App(processIdentifier: spotlight, bundleIdentifier: "com.apple.Spotlight")
        let box = FakeAXField("AXTextField", in: system.window("Spotlight", in: spotlight))
        system.focus = box
        system.front = notes
        let reader = FocusedField.Reader(source: system)

        let field = try XCTUnwrap(reader.read())

        XCTAssertEqual("com.apple.Spotlight", field.app.bundleIdentifier)
        XCTAssertEqual(true, reader.isSameField(field))

        system.focus = FakeAXField("AXTextArea", in: system.window("Shopping", in: notes))
        XCTAssertEqual(false, reader.isSameField(field), "back in Notes")

        // Without an answer, the app in front decides: Spotlight isn't it, so the focus may have gone.
        system.focus = box
        system.answering = false
        XCTAssertEqual(false, reader.isSameField(field))
    }

    func testAWebPageDescribedByAHelperProcessBelongsToTheAppTakingTheKeys() throws {
        // Safari's pages are described by WebKit's WebContent process, while Safari takes the keys.
        let system = FakeAXSystem()
        system.apps[safari] = FocusedField.App(processIdentifier: safari, bundleIdentifier: "com.apple.Safari")
        system.apps[webContent] = FocusedField.App(
            processIdentifier: webContent, bundleIdentifier: "com.apple.WebKit.WebContent")
        let window = system.window("Inbox", in: safari)
        let page = FakeAXField("AXWebArea", in: window, process: webContent)
        let box = FakeAXField("AXTextArea", in: page, [kAXValueAttribute: "Hi Sam"])
        box.selection = CFRange(location: 6, length: 0)
        system.focus = box
        system.keyApp = safari
        system.front = safari
        let reader = FocusedField.Reader(source: system)

        let field = try XCTUnwrap(reader.read())

        XCTAssertEqual(webContent, box.pid)
        XCTAssertEqual("com.apple.Safari", field.app.bundleIdentifier)
        XCTAssertEqual("Inbox", field.windowTitle)
        XCTAssertTrue(field.isInWebPage)
        XCTAssertEqual("Hi Sam", field.textBefore)
        XCTAssertEqual(true, reader.isSameField(field))

        system.focus = FakeAXField("AXTextField", in: page)
        XCTAssertEqual(false, reader.isSameField(field), "another box in the page")

        // When the system-wide element doesn't say which app takes the keys, the element's own process is all there is.
        system.focus = box
        system.systemWideApp = false
        XCTAssertEqual(webContent, reader.read()?.app.processIdentifier)
    }

    func testChromiumIsWokenWhenItComesToTheFrontAndItsBoxReadOnceDescribed() throws {
        let system = FakeAXSystem()
        system.apps[chrome] = FocusedField.App(processIdentifier: chrome, bundleIdentifier: "com.google.Chrome.canary")
        let app = try XCTUnwrap(system.application(chrome) as? FakeAXField)
        let page = FakeAXField("AXWebArea", in: system.window("Inbox - Gmail", in: chrome))
        let box = FakeAXField("AXTextArea", in: FakeAXField("AXGroup", in: page), [kAXValueAttribute: "Hi Sam"])
        box.selection = CFRange(location: 6, length: 0)
        system.focus = page
        // Chromium describes its pages 2 s after it's woken.
        let clock = FakeReaderClock()
        var wokenAt: TimeInterval?
        system.onSetFlag = { _ in wokenAt = clock.time }
        system.onFocusQuery = { [unowned system] in
            if let wokenAt, clock.time >= wokenAt + 2 { system.focus = box }
        }
        system.front = notes
        let reader = FocusedField.Reader(source: system)
        reader.startWaking()

        system.activate(chrome)
        XCTAssertEqual(["AXEnhancedUserInterface": true], app.flags)

        // A dictation starting half a second later doesn't wait for the page.
        clock.time = 0.5
        let field = try XCTUnwrap(reader.read())
        XCTAssertFalse(field.isResolved)
        XCTAssertEqual("AXWebArea web unresolved", field.kind)
        XCTAssertNil(field.textBefore)
        XCTAssertNil(field.takesLineBreaks)
        XCTAssertNil(reader.resolved(field), "not described yet")
        XCTAssertEqual(true, reader.isSameField(field))

        // By the first piece of typing, it is.
        clock.time = 2.2
        let described = try XCTUnwrap(reader.resolved(field))
        XCTAssertTrue(described.isResolved)
        XCTAssertEqual("AXTextArea", described.role)
        XCTAssertEqual(true, described.takesLineBreaks)
        XCTAssertEqual("Hi Sam", described.textBefore)
        XCTAssertEqual(true, reader.isSameField(described))
        XCTAssertEqual(true, reader.isSameField(field), "the same page")
        XCTAssertEqual(1, system.flagsAsked, "woken once")
    }

    func testAWakeCountsOnlyOnceTheAppHasTakenIt() throws {
        let system = FakeAXSystem()
        system.apps[chrome] = FocusedField.App(processIdentifier: chrome, bundleIdentifier: "com.brave.Browser")
        let app = try XCTUnwrap(system.application(chrome) as? FakeAXField)
        system.front = notes
        let reader = FocusedField.Reader(source: system)
        reader.startWaking()

        // Still starting, it refuses the flag, so it's asked again the next time it comes to the front.
        system.takesFlags = false
        system.activate(chrome)
        XCTAssertEqual([:], app.flags)

        system.takesFlags = true
        system.activate(chrome)
        XCTAssertEqual(["AXEnhancedUserInterface": true], app.flags)

        system.activate(chrome)
        XCTAssertEqual(2, system.flagsAsked)
    }

    func testTheAppInFrontIsWokenAtStart() {
        let system = FakeAXSystem()
        system.apps[slack] = FocusedField.App(
            processIdentifier: slack, bundleIdentifier: "com.tinyspeck.slackmacgap", isElectron: true)
        system.front = slack
        let woken = expectation(description: "Slack woken")
        system.onSetFlag = { attribute in
            XCTAssertEqual("AXManualAccessibility", attribute)
            woken.fulfill()
        }

        let reader = FocusedField.Reader(source: system)
        reader.startWaking()

        wait(for: [woken], timeout: 5)
    }

    func testAReadWakesAnAppThatWasntWokenYet() throws {
        let system = FakeAXSystem()
        system.apps[chrome] = FocusedField.App(processIdentifier: chrome, bundleIdentifier: "com.google.Chrome")
        let app = try XCTUnwrap(system.application(chrome) as? FakeAXField)
        system.focus = FakeAXField("AXWebArea", in: system.window("New Tab", in: chrome))
        let reader = FocusedField.Reader(source: system)

        let field = try XCTUnwrap(reader.read())
        _ = reader.read()

        XCTAssertFalse(field.isResolved)
        XCTAssertEqual(["AXEnhancedUserInterface": true], app.flags)
        XCTAssertEqual(1, system.flagsAsked)
    }

    func testElectronAppsAreWokenWithManualAccessibility() throws {
        let system = FakeAXSystem()
        system.apps[slack] = FocusedField.App(
            processIdentifier: slack, bundleIdentifier: "com.tinyspeck.slackmacgap", isElectron: true)
        let app = try XCTUnwrap(system.application(slack) as? FakeAXField)
        system.focus = FakeAXField("AXTextArea", in: FakeAXField("AXWebArea", in: system.window("general", in: slack)))
        system.front = notes
        let reader = FocusedField.Reader(source: system)
        reader.startWaking()

        system.activate(slack)
        let field = try XCTUnwrap(reader.read())

        XCTAssertEqual(["AXManualAccessibility": true], app.flags)
        XCTAssertTrue(field.isResolved)
        XCTAssertEqual(1, system.flagsAsked)
    }

    func testTheWakeCanBeTurnedOff() throws {
        let system = FakeAXSystem()
        system.apps[chrome] = FocusedField.App(processIdentifier: chrome, bundleIdentifier: "com.google.Chrome")
        system.focus = FakeAXField("AXWebArea", in: system.window("New Tab", in: chrome))
        system.front = notes
        let reader = FocusedField.Reader(source: system)
        reader.wakesWebContent = false
        reader.startWaking()

        system.activate(chrome)
        let field = try XCTUnwrap(reader.read())

        XCTAssertEqual(0, system.flagsAsked)
        XCTAssertEqual("AXWebArea", field.role)
    }

    func testAPageNotDescribedYetIsRecognisedByThePage() throws {
        let system = FakeAXSystem()
        system.apps[chrome] = FocusedField.App(processIdentifier: chrome, bundleIdentifier: "com.microsoft.edgemac")
        let window = system.window("Docs", in: chrome)
        let page = FakeAXField("AXWebArea", in: window)
        system.focus = page
        let reader = FocusedField.Reader(source: system)

        let field = try XCTUnwrap(reader.read())

        XCTAssertEqual("AXWebArea web unresolved", field.kind)
        XCTAssertNil(field.takesLineBreaks)

        system.focus = FakeAXField("AXTextArea", in: FakeAXField("AXGroup", in: page))
        XCTAssertEqual(true, reader.isSameField(field), "the page's box, described at last")

        let toolbar = FakeAXField("AXToolbar", in: window)
        system.focus = FakeAXField("AXTextField", in: toolbar, [kAXDescriptionAttribute: "Address and search bar"])
        XCTAssertEqual(false, reader.isSameField(field), "the address bar")
        XCTAssertNil(reader.resolved(field), "the address bar isn't the page's box")

        system.focus = FakeAXField("AXTextArea", in: FakeAXField("AXWebArea", in: window))
        XCTAssertEqual(false, reader.isSameField(field), "another tab")
    }

    func testAPaneInNoWindowIsRecognisedOnlyByItself() throws {
        let system = FakeAXSystem()
        system.apps[chrome] = FocusedField.App(processIdentifier: chrome, bundleIdentifier: "com.google.Chrome")
        let app = system.application(chrome) as? FakeAXField
        system.focus = FakeAXField("AXGroup", in: app)
        let reader = FocusedField.Reader(source: system)

        let field = try XCTUnwrap(reader.read())

        XCTAssertFalse(field.isResolved)
        XCTAssertEqual(true, reader.isSameField(field))
        system.focus = FakeAXField("AXGroup", in: app)
        XCTAssertEqual(false, reader.isSameField(field), "another element of the same app")
    }

    func testAnUndescribedPageWhoseWindowCantBeFoundIsntRead() {
        let system = FakeAXSystem()
        system.apps[chrome] = FocusedField.App(processIdentifier: chrome, bundleIdentifier: "com.google.Chrome")
        system.focus = FakeAXField("AXGroup", in: system.window("Docs", in: chrome))
        // The app taking the keys, its process, the focus, the role and the subrole are answered, the parents aren't.
        system.answersLeft = 5

        XCTAssertNil(FocusedField.Reader(source: system).read())
    }

    func testADescribedBoxInAnotherWindowIsntTheOneStarted() throws {
        let system = FakeAXSystem()
        system.apps[slack] = FocusedField.App(processIdentifier: slack, isElectron: true)
        let window = system.window("general", in: slack)
        system.focus = FakeAXField("AXGroup", in: window)
        // Which app is in front doesn't matter while Accessibility answers.
        system.front = notes
        let reader = FocusedField.Reader(source: system)
        reader.wakesWebContent = false
        let field = try XCTUnwrap(reader.read())
        XCTAssertFalse(field.isResolved)

        system.focus = FakeAXField("AXTextArea", in: FakeAXField("AXWebArea", in: system.window("random", in: slack)))
        XCTAssertNil(reader.resolved(field))
        XCTAssertEqual(false, reader.isSameField(field))

        system.focus = FakeAXField("AXTextArea", in: FakeAXField("AXWebArea", in: window))
        XCTAssertEqual("AXTextArea", try XCTUnwrap(reader.resolved(field)).role)
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
    /// Gives kAXStringForRangeParameterizedAttribute and kAXNumberOfCharactersAttribute, as most boxes do.
    var ranges = true
    /// An app's focused element (kAXFocusedUIElementAttribute of the app).
    var focused: FakeAXField?
    var flags: [String: Bool] = [:]
    var asked: [String] = []

    init(
        _ role: String?, subrole: String? = nil, in parent: FakeAXField?, process: pid_t? = nil,
        _ strings: [String: String] = [:]
    ) {
        self.role = role
        self.subrole = subrole
        self.parent = parent
        self.pid = process ?? parent?.pid ?? 0
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
    /// The system-wide element says which element has the focus (some apps say so only through themselves).
    var systemWideFocus = true
    /// The app taking the keys, as the system-wide element says; by default the focused element's.
    var keyApp: pid_t?
    /// The system-wide element says which app takes the keys.
    var systemWideApp = true
    var answering = true
    var answersLeft = Int.max
    var unanswered = 0
    var apps: [pid_t: FocusedField.App] = [:]
    var secureInput = FocusedField.SecureInput.off
    /// The app in front; by default the focused element's.
    var front: pid_t?
    /// Whether apps take the flags set on them.
    var takesFlags = true
    private(set) var flagsAsked = 0
    var onSetFlag: ((String) -> Void)?
    /// Runs at each focus query, before it's answered: the focus moving while time passes.
    var onFocusQuery: (() -> Void)?
    private var applications: [pid_t: FakeAXField] = [:]
    private var activated: (@Sendable (pid_t) -> Void)?

    /// A window titled `title`, in the app `pid`.
    func window(_ title: String, in pid: pid_t) -> FakeAXField {
        FakeAXField("AXWindow", in: application(pid) as? FakeAXField, [kAXTitleAttribute: title])
    }

    /// The app `pid` comes to the front.
    func activate(_ pid: pid_t) {
        front = pid
        activated?(pid)
    }

    var frontmostProcess: pid_t? { front ?? focus?.pid }

    func observeActivations(_ handler: @escaping @Sendable (pid_t) -> Void) -> AnyObject {
        activated = handler
        return NSObject()
    }

    func focusedApplication() throws -> AnyObject? {
        try answer()
        guard systemWideApp, let pid = keyApp ?? focus?.pid else { return nil }
        return application(pid)
    }

    func focusedElement() throws -> AnyObject? {
        onFocusQuery?()
        try answer()
        return systemWideFocus ? focus : nil
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

    func integer(_ attribute: String, of element: AnyObject) throws -> Int? {
        try answer()
        let field = element as! FakeAXField
        field.asked.append(attribute)
        guard field.ranges, attribute == kAXNumberOfCharactersAttribute else { return nil }
        return field.strings[kAXValueAttribute]?.utf16.count
    }

    func range(_ attribute: String, of element: AnyObject) throws -> CFRange? {
        try answer()
        let field = element as! FakeAXField
        field.asked.append(attribute)
        return attribute == kAXSelectedTextRangeAttribute ? field.selection : nil
    }

    /// The units in `range` as an app gives them, cutting an emoji in two if the range does.
    func utf16(_ attribute: String, for range: CFRange, of element: AnyObject) throws -> [UInt16]? {
        try answer()
        let field = element as! FakeAXField
        field.asked.append("\(attribute) \(range.location)+\(range.length)")
        guard field.ranges, attribute == kAXStringForRangeParameterizedAttribute,
              let value = field.strings[kAXValueAttribute] else { return nil }
        let units = Array(value.utf16)
        let start = min(max(range.location, 0), units.count)
        return Array(units[start..<min(start + max(range.length, 0), units.count)])
    }

    func element(_ attribute: String, of element: AnyObject) throws -> AnyObject? {
        try answer()
        let field = element as! FakeAXField
        switch attribute {
        case kAXParentAttribute: return field.parent
        case kAXFocusedUIElementAttribute: return field.focused
        default: return nil
        }
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
        flagsAsked += 1
        onSetFlag?(attribute)
        guard takesFlags else { return false }
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

/// Time that passes only when a test says so.
private final class FakeReaderClock {
    var time: TimeInterval = 0
}
