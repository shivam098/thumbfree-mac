import ApplicationServices
import XCTest
import ThumbFreeCore
import ThumbFreeMac
@testable import ThumbFreeApp

/// The Mac's desktop for the host, with the Accessibility API, the pasteboard and the keyboard faked: what a box read
/// becomes (thumbfree-windows `FocusInspector`'s rules, on the Accessibility API's facts), the field checks, typing by
/// the insert method, and recognising the box again.
final class MacDesktopTests: XCTestCase {
    private static let window = WindowInfo(handle: 1, processId: 1, processName: "Mail", title: "")
    private static let ownProcess = ProcessInfo.processInfo.processIdentifier

    private let ax = FakeAccessibility()

    override func setUp() {
        useTestBrowsers()
    }

    func testABoxIsReadWithTheRulesForItsAppAndWindow() throws {
        let mail = app(1, "com.apple.mail", "Mail")
        focus(mail, title: "New Message", role: kAXTextAreaRole, text: "Hi Tim")
        let message = try XCTUnwrap(read())
        XCTAssertEqual(message.app, TargetApp(name: "Mail", bundleIdentifier: "com.apple.mail"))
        XCTAssertEqual(message.textBefore, "Hi Tim")
        XCTAssertTrue(message.caretKnown)
        XCTAssertTrue(message.isResolved)
        XCTAssertEqual(message.kind, "AXTextArea multi-line email")
        XCTAssertEqual(message.windowFrame, CGRect(x: 10, y: 20, width: 800, height: 600))
        XCTAssertEqual(message.fieldInfo, FieldInfo(multiLine: true, email: true))

        // Webmail in Chrome, a private Firefox window, any Safari window (its private ones can't be told apart), the
        // same words in another app's title, a search box (never email layout), a password box (its text isn't read)
        // and a box that doesn't say whether it takes line breaks.
        let chrome = app(2, "com.google.Chrome", "Google Chrome")
        let firefox = app(3, "org.mozilla.firefox", "Firefox")
        let notes = app(4, "com.apple.Notes", "Notes")
        let safari = app(6, "com.apple.Safari", "Safari")
        typealias Case = (
            app: FocusedField.App, title: String, role: String?, subrole: String?, kind: String, info: FieldInfo
        )
        let cases: [Case] = [
            (chrome, "Inbox (3) - Gmail - Google Chrome", kAXTextFieldRole, nil, "AXTextField single-line email",
             FieldInfo(email: true)),
            (firefox, "Inbox — Private Browsing", kAXTextAreaRole, nil, "AXTextArea multi-line private",
             FieldInfo(multiLine: true, private: true)),
            (safari, "Inbox (3) - Gmail", kAXTextFieldRole, nil, "AXTextField single-line email private-unknown",
             FieldInfo(private: true, email: true)),
            (notes, "Incognito mode — Gmail", kAXTextAreaRole, nil, "AXTextArea multi-line",
             FieldInfo(multiLine: true)),
            (mail, "Inbox", kAXTextFieldRole, kAXSearchFieldSubrole, "AXTextField/AXSearchField single-line search",
             FieldInfo(search: true)),
            (chrome, "Sign in - Google Chrome", kAXTextFieldRole, kAXSecureTextFieldSubrole,
             "AXTextField/AXSecureTextField single-line secure", FieldInfo(password: true)),
            (app(5, "com.apple.Terminal", "Terminal"), "zsh", nil, nil, "no role", FieldInfo(multiLine: true)),
        ]
        for test in cases {
            focus(test.app, title: test.title, role: test.role, subrole: test.subrole, text: "Hi")
            let field = try XCTUnwrap(read(), test.kind)
            XCTAssertEqual(field.kind, test.kind)
            XCTAssertEqual(field.fieldInfo, test.info, test.kind)
            XCTAssertEqual(field.textBefore, test.info.password ? nil : "Hi", test.kind)
        }
    }

    func testTheFieldCheckSeesPasswordBoxesAndSaysUnknownWhenNothingAnswers() {
        let desktop = makeDesktop()
        let mail = app(1, "com.apple.mail", "Mail")
        focus(mail, title: "New Message", role: kAXTextAreaRole, text: "Hi Tim")
        XCTAssertEqual(try desktop.checkFocusedField(), .safe)
        XCTAssertEqual(desktop.focusedTextEndsWithNonWhitespace(), true)
        focus(mail, title: "New Message", role: kAXTextAreaRole, text: "Hi ")
        XCTAssertEqual(desktop.focusedTextEndsWithNonWhitespace(), false)
        focus(mail, title: "New Message", role: kAXTextAreaRole, text: "")
        XCTAssertEqual(desktop.focusedTextEndsWithNonWhitespace(), false)

        focus(mail, title: "Sign in", role: kAXTextFieldRole, subrole: kAXSecureTextFieldSubrole, text: "secret")
        XCTAssertEqual(try desktop.checkFocusedField(), .password)
        XCTAssertNil(desktop.focusedTextEndsWithNonWhitespace())

        ax.focused = nil
        XCTAssertEqual(try desktop.checkFocusedField(), .unknown)
    }

    func testThePasteInsertMethodPastesAndAnyOtherTypesWithKeys() throws {
        let pasteboard = FakePasteboard()
        pasteboard.text = "copied before"
        let keys = FakeKeys(pasteboard)
        let method = Locked("paste")
        let desktop = makeDesktop(PasteTyper(pasteboard: pasteboard, keys: keys, sleep: { _ in }), { method.value })

        try desktop.typeText("Hello there.")
        XCTAssertEqual(keys.pasted, ["Hello there."])
        XCTAssertEqual(pasteboard.text, "copied before")

        method.update { $0 = "Type" }
        try desktop.typeText(" How are you?")
        XCTAssertEqual(keys.typed, " How are you?")
        XCTAssertEqual(pasteboard.writes, 1)

        // The host's check runs last, and stops the keys by throwing.
        method.update { $0 = "Paste" }
        XCTAssertThrowsError(try desktop.typeText("Not here.", beforeKeys: { throw FieldChanged() }))
        XCTAssertEqual(keys.pasted, ["Hello there."])
        XCTAssertEqual(pasteboard.text, "copied before")
    }

    func testNewLineKeysArePressedAndOnesThumbFreeDoesntKnowThrow() {
        let pasteboard = FakePasteboard()
        let keys = FakeKeys(pasteboard)
        let desktop = makeDesktop(PasteTyper(pasteboard: pasteboard, keys: keys, sleep: { _ in }))

        XCTAssertNoThrow(try desktop.pressKeys("Shift+Enter"))
        XCTAssertNoThrow(try desktop.pressKeys("enter"))
        XCTAssertEqual(keys.pressed, [.shiftReturn, .returnKey])
        XCTAssertThrowsError(try desktop.pressKeys("Ctrl+K")) { error in
            XCTAssertEqual(error as? MacDesktop.UnknownKeys, MacDesktop.UnknownKeys(chord: "Ctrl+K"))
            XCTAssertEqual(
                DictationHost.reason(error), "This app's new-line keys in settings.json aren't keys ThumbFree knows.")
        }

        XCTAssertFalse(desktop.modifiersDown)
        keys.heldModifiers = [.command]
        XCTAssertTrue(desktop.modifiersDown)
    }

    func testTheBoxIsKnownAgainAndNoAppInFrontMeansAnotherBox() throws {
        let mail = app(1, "com.apple.mail", "Mail")
        let box = focus(mail, title: "New Message", role: kAXTextAreaRole, text: "Hi")
        let reader = MacFieldReader(FocusedField.Reader(source: ax))
        let start = try XCTUnwrap(reader.read(Self.window))
        XCTAssertEqual(reader.isSameField(start, Self.window), true)
        XCTAssertEqual(reader.isSameField(start, nil), false)

        // Typing changed the text before the cursor: it's read again while the focus is in the box.
        box.attributes[kAXValueAttribute] = "Hi Tim"
        box.attributes[kAXSelectedTextRangeAttribute] = CFRange(location: 6, length: 0)
        XCTAssertEqual(reader.readAgain(start)?.textBefore, "Hi Tim")

        focus(mail, title: "Re: Lunch", role: kAXTextAreaRole, text: "Hi")
        XCTAssertEqual(reader.isSameField(start, Self.window), false)
        XCTAssertNil(reader.readAgain(start))
    }

    func testAWebPagesBoxIsReadOnceThePageHasDescribedIt() throws {
        // Chrome's page has the focus while it hasn't described its boxes yet; then the box in it does.
        let chrome = app(6, "com.google.Chrome", "Google Chrome")
        let page = focus(chrome, title: "Compose - Gmail - Google Chrome", role: "AXWebArea", text: "")
        let reader = MacFieldReader(FocusedField.Reader(source: ax))
        let start = try XCTUnwrap(reader.read(Self.window))
        XCTAssertFalse(start.isResolved)
        XCTAssertNil(reader.readAgain(start))

        let box = FakeElement(pid: page.pid, [kAXRoleAttribute: kAXTextAreaRole, kAXValueAttribute: "Hi"], parent: page)
        box.attributes[kAXSelectedTextRangeAttribute] = CFRange(location: 2, length: 0)
        ax.focused = box
        let resolved = try XCTUnwrap(reader.readAgain(start))
        XCTAssertTrue(resolved.isResolved)
        XCTAssertEqual(resolved.kind, "AXTextArea multi-line web email")
        XCTAssertEqual(resolved.textBefore, "Hi")
        XCTAssertEqual(reader.isSameField(resolved, Self.window), true)
    }

    func testTheAppOfAWindowWhoseProcessHasGoneIsItsProcessName() {
        let reader = MacFieldReader(FocusedField.Reader(source: ax))
        let gone = WindowInfo(handle: 1, processId: Int(Int32.max), processName: "Bank", title: "")

        XCTAssertEqual(reader.app(of: gone), TargetApp(name: "Bank", bundleIdentifier: nil))
    }

    /// An app other than this test's process (whose own boxes the reader never reads).
    private func app(_ number: Int32, _ bundle: String, _ name: String) -> FocusedField.App {
        let app = FocusedField.App(processIdentifier: Self.ownProcess + number, bundleIdentifier: bundle, name: name)
        ax.apps[app.processIdentifier] = app
        return app
    }

    /// Gives the focus to a new box in a new window of `app`, with the cursor at the end of `text`.
    @discardableResult
    private func focus(
        _ app: FocusedField.App, title: String, role: String?, subrole: String? = nil, text: String
    ) -> FakeElement {
        let window = FakeElement(
            pid: app.processIdentifier, [kAXRoleAttribute: kAXWindowRole, kAXTitleAttribute: title])
        window.frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        var attributes: [String: Any] = [
            kAXValueAttribute: text, kAXSelectedTextRangeAttribute: CFRange(location: text.utf16.count, length: 0),
        ]
        attributes[kAXRoleAttribute] = role
        attributes[kAXSubroleAttribute] = subrole
        let box = FakeElement(pid: app.processIdentifier, attributes, parent: window)
        ax.focused = box
        return box
    }

    private func read() -> DictationField? {
        MacFieldReader(FocusedField.Reader(source: ax)).read(Self.window)
    }

    private func makeDesktop(
        _ typer: PasteTyper = PasteTyper(pasteboard: FakePasteboard(), keys: FakeKeys(FakePasteboard())),
        _ insertMethod: @escaping () -> String = { "Paste" }
    ) -> MacDesktop {
        MacDesktop(
            typer: typer, reader: FocusedField.Reader(source: ax), insertMethod: insertMethod, frontmost: { nil })
    }
}

/// An element of another app's interface: its attributes, its parent, and its window's frame.
final class FakeElement {
    let pid: pid_t
    var attributes: [String: Any]
    let parent: FakeElement?
    var frame: CGRect?

    init(pid: pid_t, _ attributes: [String: Any], parent: FakeElement? = nil) {
        self.pid = pid
        self.attributes = attributes
        self.parent = parent
    }
}

/// The Accessibility API as `FocusedField.Reader` asks it, over `FakeElement`s: the system-wide focus is `focused`.
final class FakeAccessibility: FocusedField.Accessibility, @unchecked Sendable {
    var focused: FakeElement?
    var apps: [pid_t: FocusedField.App] = [:]
    var secureInput = FocusedField.SecureInput.off

    var frontmostProcess: pid_t? { focused?.pid }

    func focusedApplication() throws -> AnyObject? { nil }

    func focusedElement() throws -> AnyObject? { focused }

    func string(_ attribute: String, of element: AnyObject) throws -> String? {
        (element as? FakeElement)?.attributes[attribute] as? String
    }

    func integer(_ attribute: String, of element: AnyObject) throws -> Int? {
        guard attribute == kAXNumberOfCharactersAttribute else { return nil }
        return try string(kAXValueAttribute, of: element)?.utf16.count
    }

    func range(_ attribute: String, of element: AnyObject) throws -> CFRange? {
        (element as? FakeElement)?.attributes[attribute] as? CFRange
    }

    func utf16(_ attribute: String, for range: CFRange, of element: AnyObject) throws -> [UInt16]? {
        guard attribute == kAXStringForRangeParameterizedAttribute,
              let units = try string(kAXValueAttribute, of: element).map({ Array($0.utf16) }),
              range.location >= 0, range.length >= 0, range.location + range.length <= units.count else { return nil }
        return Array(units[range.location..<(range.location + range.length)])
    }

    func element(_ attribute: String, of element: AnyObject) throws -> AnyObject? {
        attribute == kAXParentAttribute ? (element as? FakeElement)?.parent : nil
    }

    func frame(of element: AnyObject) throws -> CGRect? { (element as? FakeElement)?.frame }

    func processIdentifier(of element: AnyObject) throws -> pid_t {
        guard let element = element as? FakeElement else { throw FocusedField.NoAnswer() }
        return element.pid
    }

    func application(_ processIdentifier: pid_t) -> AnyObject {
        FakeElement(pid: processIdentifier, [kAXRoleAttribute: kAXApplicationRole])
    }

    func setFlag(_ attribute: String, _ value: Bool, of element: AnyObject) -> Bool { false }

    func isSame(_ element: AnyObject, as other: AnyObject) -> Bool { element === other }

    func app(_ processIdentifier: pid_t) -> FocusedField.App {
        apps[processIdentifier] ?? FocusedField.App(processIdentifier: processIdentifier)
    }

    func observeActivations(_ handler: @escaping @Sendable (pid_t) -> Void) -> AnyObject { NSObject() }
}

/// A pasteboard holding plain text, or nothing.
final class FakePasteboard: PasteTyper.Pasteboard {
    var changeCount = 0
    var access = PasteTyper.PasteboardAccess.unrestricted
    var text: String?
    var writes = 0

    func save() -> PasteTyper.Saved {
        guard let text else { return .empty }
        let item = [PasteTyper.Contents.Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]
        return .items(PasteTyper.Contents(items: [item]))
    }

    func write(_ text: String) throws -> Int {
        self.text = text
        writes += 1
        changeCount += 1
        return changeCount
    }

    func restore(_ saved: PasteTyper.Saved) {
        switch saved {
        case .empty:
            text = nil
        case .items(let contents):
            text = contents.items.first?.first.map { String(decoding: $0.data, as: UTF8.self) }
        case .unreadable:
            return
        }

        changeCount += 1
    }
}

/// A keyboard that records what was pasted (the pasteboard's text at ⌘V), typed and pressed.
final class FakeKeys: PasteTyper.Keys {
    /// ⌘V: V is key code 9 (kVK_ANSI_V).
    let pasteChord = PasteTyper.Chord(key: 9, modifiers: .command)

    private let pasteboard: FakePasteboard
    var heldModifiers: PasteTyper.Modifiers = []
    var secureInput = FocusedField.SecureInput.off
    var pasted: [String] = []
    var typed = ""
    var pressed: [PasteTyper.Chord] = []

    init(_ pasteboard: FakePasteboard) {
        self.pasteboard = pasteboard
    }

    func post(_ chord: PasteTyper.Chord) throws {
        if chord == pasteChord {
            pasted.append(pasteboard.text ?? "")
        } else {
            pressed.append(chord)
        }
    }

    func type(_ characters: String) throws {
        typed += characters
    }
}
