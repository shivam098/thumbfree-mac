import AppKit
import Carbon
import XCTest
@testable import ThumbFreeMac

/// Pasting through a fake pasteboard and keyboard: what's pasted and what's put back when the pasteboard changes
/// meanwhile (the cases of thumbfree-windows tests/ThumbFree.App.Tests/ClipboardPasteTests.cs, then the Mac's own),
/// held keys, line breaks and refusals.
final class PasteTyperTests: XCTestCase {
    private var log: [String] = []

    func testSomethingCopiedWhileThePasteWaitsIsKeptAndTheDictationIsWhatGetsPasted() throws {
        // ⌘C pressed while the paste waits for ⌘ to be let go.
        let (typer, pasteboard, keys) = makeTyper(copied: "copied before")
        var checks = 0

        try typer.paste("Dictated words.") {
            if checks == 0 {
                pasteboard.userCopies("copied meanwhile")
            }

            checks += 1
        }

        XCTAssertEqual(["Dictated words."], keys.pasted)
        XCTAssertEqual("copied meanwhile", pasteboard.text)
    }

    func testAPasteboardThatKeepsChangingPastesNothingAndKeepsTheLatestCopy() {
        let (typer, pasteboard, keys) = makeTyper(copied: "copied before")

        XCTAssertThrowsError(try typer.paste("Dictated words.") { pasteboard.userCopies("copied again") }) {
            XCTAssertEqual(PasteTyper.Failure.pasteboardKeptChanging, $0 as? PasteTyper.Failure)
        }

        XCTAssertEqual([], keys.pasted)
        XCTAssertEqual("copied again", pasteboard.text)
    }

    func testAPasteStoppedBeforeTheKeysPutsThePasteboardBack() {
        let (typer, pasteboard, keys) = makeTyper(copied: "copied before")

        XCTAssertThrowsError(try typer.paste("Dictated words.") { throw MovedToAnotherBox() }) {
            XCTAssertTrue($0 is MovedToAnotherBox)
        }

        XCTAssertEqual([], keys.pasted)
        XCTAssertEqual("copied before", pasteboard.text)
    }

    func testThePasteboardIsPutBackOnceTheAppHadTimeToReadIt() throws {
        let (typer, pasteboard, keys) = makeTyper(copied: "copied before")

        try typer.paste("Hello there.")

        XCTAssertEqual(["Hello there."], keys.pasted)
        XCTAssertEqual("copied before", pasteboard.text)
        XCTAssertEqual(["write Hello there.", "⌘V", "wait 0.35", "restore copied before"], log)
    }

    func testSomethingCopiedAfterThePasteIsKept() throws {
        let (typer, pasteboard, keys) = makeTyper(copied: "copied before")
        keys.afterPaste = { pasteboard.userCopies("copied after") }

        try typer.paste("Hello there.")

        XCTAssertEqual(["Hello there."], keys.pasted)
        XCTAssertEqual("copied after", pasteboard.text)
    }

    func testAnEmptyPasteboardIsLeftEmpty() throws {
        let (typer, pasteboard, keys) = makeTyper(copied: nil)

        try typer.paste("Hello there.")

        XCTAssertEqual(["Hello there."], keys.pasted)
        XCTAssertNil(pasteboard.contents)
    }

    func testThePasteWaitsForHeldModifierKeysToBeLetGo() throws {
        let (typer, _, keys) = makeTyper(copied: "copied before")
        keys.held = [.command, .function, .shift]

        try typer.paste("Hello there.")

        XCTAssertEqual(["Hello there."], keys.pasted)
        let waits = ["wait 0.015", "wait 0.015", "wait 0.015"]
        XCTAssertEqual(["write Hello there."] + waits + ["⌘V", "wait 0.35", "restore copied before"], log)
    }

    func testAKeyHeldForeverIsWaitedForASecondThenThePasteGoesAhead() throws {
        let (typer, _, keys) = makeTyper(copied: "copied before")
        keys.heldForever = .option

        try typer.paste("Hello there.")

        XCTAssertEqual(["Hello there."], keys.pasted)
        let waited = log.filter { $0 == "wait 0.015" }.count
        XCTAssertEqual(67, waited, accuracy: 1)
    }

    func testLineBreaksAreTheAppsNewLineKeys() throws {
        let (typer, _, keys) = makeTyper(copied: "copied before")
        var checks = 0

        try typer.type("Hi Sam,\nThanks for today.\n\n- Ben", newLine: .shiftReturn) { checks += 1 }

        XCTAssertEqual(["Hi Sam,", "Thanks for today.", "- Ben"], keys.pasted)
        XCTAssertEqual(["⌘V", "⇧↩", "⌘V", "⇧↩", "⇧↩", "⌘V"], keys.posted)
        XCTAssertEqual(6, checks, "the check runs before each paste and each new line")
    }

    func testTheChecksStopTheLinesThatFollow() {
        let (typer, _, keys) = makeTyper(copied: "copied before")
        var checks = 0

        XCTAssertThrowsError(try typer.type("One\nTwo", newLine: .returnKey) {
            checks += 1
            if checks == 2 { throw MovedToAnotherBox() }
        })

        XCTAssertEqual(["One"], keys.pasted)
        XCTAssertEqual(["⌘V"], keys.posted)
    }

    func testAPastedPieceHasNoLineBreaks() throws {
        let (typer, _, keys) = makeTyper(copied: "copied before")

        try typer.paste("one\r\ntwo\nthree")

        XCTAssertEqual(["one two three"], keys.pasted)
    }

    func testWithoutAccessibilityNothingIsPastedAndThePasteboardGoesBack() {
        let (typer, pasteboard, keys) = makeTyper(copied: "copied before")
        keys.allowed = false

        XCTAssertThrowsError(try typer.paste("Hello there.")) {
            XCTAssertEqual(PasteTyper.Failure.notAllowed, $0 as? PasteTyper.Failure)
        }

        XCTAssertEqual([], keys.pasted)
        XCTAssertEqual("copied before", pasteboard.text)
    }

    func testNothingIsTypedWhileAPasswordIsBeingTyped() {
        let (typer, pasteboard, keys) = makeTyper(copied: "copied before")
        keys.secureInput = true

        XCTAssertThrowsError(try typer.paste("Hello there.")) {
            XCTAssertEqual(PasteTyper.Failure.secureInput, $0 as? PasteTyper.Failure)
        }

        XCTAssertThrowsError(try typer.press(.shiftReturn)) {
            XCTAssertEqual(PasteTyper.Failure.secureInput, $0 as? PasteTyper.Failure)
        }

        XCTAssertEqual([], keys.posted)
        XCTAssertEqual("copied before", pasteboard.text)
    }

    func testNewLineKeysAreReadAsSettingsWriteThem() {
        let returnKey = CGKeyCode(kVK_Return)
        XCTAssertEqual(PasteTyper.Chord.shiftReturn, PasteTyper.Chord("Shift+Return"))
        XCTAssertEqual(PasteTyper.Chord.shiftReturn, PasteTyper.Chord("shift + enter"))
        XCTAssertEqual(PasteTyper.Chord.returnKey, PasteTyper.Chord("Enter"))
        XCTAssertEqual(PasteTyper.Chord(key: returnKey, modifiers: .command), PasteTyper.Chord("Cmd+Return"))
        XCTAssertEqual(
            PasteTyper.Chord(key: returnKey, modifiers: [.option, .shift, .control]),
            PasteTyper.Chord("Alt+Shift+Ctrl+Return"))
        XCTAssertEqual(PasteTyper.Chord(key: CGKeyCode(kVK_F5)), PasteTyper.Chord("F5"))
        XCTAssertEqual(PasteTyper.Chord(key: CGKeyCode(kVK_Tab), modifiers: .shift), PasteTyper.Chord("Shift++Tab"))
        for unknown in ["", "Shift", "Return+Tab", "Hyper+Return", "Ctrl+V", "F21"] {
            XCTAssertNil(PasteTyper.Chord(unknown), unknown)
        }
    }

    // MARK: A pasteboard that can't be read

    func testThePasteboardIsReadOnlyWhenMacOSDoesntAskEachTime() throws {
        for (access, reads) in [
            (.unrestricted, true), (.default, true), (.alwaysAllow, true), (.ask, false), (.alwaysDeny, false),
        ] as [(PasteTyper.PasteboardAccess, Bool)] {
            let (typer, pasteboard, keys) = makeTyper(copied: "copied before")
            pasteboard.access = access

            try typer.paste("Hello there.")

            XCTAssertEqual(reads ? 1 : 0, pasteboard.saves, "\(access)")
            XCTAssertEqual(reads ? ["Hello there."] : [], keys.pasted, "\(access)")
            XCTAssertEqual(reads ? [] : ["Hello there."], keys.typed, "\(access)")
            XCTAssertEqual("copied before", pasteboard.text, "\(access)")
            if !reads {
                XCTAssertEqual(1, pasteboard.changeCount, "\(access): the pasteboard isn't touched")
            }
        }
    }

    func testAPasteboardWhoseDataCantBeReadIsLeftAloneAndTheTextTypedWithKeys() throws {
        let (typer, pasteboard, keys) = makeTyper(copied: "copied before")
        pasteboard.unreadable = true

        try typer.paste("Hello there.")

        XCTAssertEqual([], keys.pasted)
        XCTAssertEqual(["Hello there."], keys.typed)
        XCTAssertEqual("copied before", pasteboard.text)
        XCTAssertEqual(1, pasteboard.changeCount)
    }

    func testTheHostCanChooseToPasteAndReplaceAPasteboardThatCantBeRead() throws {
        let (typer, pasteboard, keys) = makeTyper(copied: "copied before")
        pasteboard.access = .alwaysDeny
        typer.whenUnreadable = .pasteAndReplace

        try typer.paste("Hello there.")

        XCTAssertEqual(["Hello there."], keys.pasted)
        XCTAssertEqual([], keys.typed)
        XCTAssertEqual("Hello there.", pasteboard.text, "replaced, not put back")
        XCTAssertEqual(["write Hello there.", "⌘V"], log)
    }

    func testTypingWithKeysGoesTwentyUnitsAKeyAndNeverSplitsACharacter() throws {
        func a(_ count: Int) -> String { String(repeating: "a", count: count) }
        func marks(_ count: Int) -> String { String(repeating: "\u{301}", count: count) }
        let family = "👨‍👩‍👧"
        for (text, keys) in [
            (a(45), [a(20), a(20), a(5)]),
            (a(19) + "👋b", [a(19), "👋b"]),
            (a(15) + family + "c", [a(15), family + "c"]),
            // A character longer than a key can carry goes between its scalars.
            ("x" + "e" + marks(25), ["x", "e" + marks(19), marks(6)]),
        ] {
            let (typer, pasteboard, poster) = makeTyper(copied: nil)
            pasteboard.access = .ask

            try typer.paste(text)

            XCTAssertEqual(keys, poster.typed, text)
            XCTAssertEqual(text, poster.typed.joined(), text)
        }
    }

    func testTypingWithKeysWaitsForHeldKeysAndPausesBetweenKeys() throws {
        let (typer, pasteboard, keys) = makeTyper(copied: "copied before")
        pasteboard.access = .alwaysDeny
        keys.held = [.command]

        try typer.paste(String(repeating: "a", count: 25))

        let a = String(repeating: "a", count: 20)
        XCTAssertEqual(["wait 0.015", "type \(a)", "wait 0.008", "type aaaaa"], log)
    }

    func testLinesTypedWithKeysAreSeparatedByTheNewLineKeys() throws {
        let (typer, pasteboard, keys) = makeTyper(copied: "copied before")
        pasteboard.unreadable = true
        var checks = 0

        try typer.type("Hi Sam,\nThanks", newLine: .shiftReturn) { checks += 1 }

        XCTAssertEqual(["type Hi Sam,", "⇧↩", "type Thanks"], keys.posted)
        XCTAssertEqual(3, checks)
    }

    func testNothingIsTypedWithKeysWhileAPasswordIsBeingTypedOrWithoutThePermission() {
        let (typer, pasteboard, keys) = makeTyper(copied: "copied before")
        pasteboard.unreadable = true
        keys.secureInput = true

        XCTAssertThrowsError(try typer.paste("Hello there.")) {
            XCTAssertEqual(PasteTyper.Failure.secureInput, $0 as? PasteTyper.Failure)
        }

        keys.secureInput = false
        keys.allowed = false
        XCTAssertThrowsError(try typer.paste("Hello there.")) {
            XCTAssertEqual(PasteTyper.Failure.notAllowed, $0 as? PasteTyper.Failure)
        }

        XCTAssertEqual([], keys.typed)
        XCTAssertEqual(1, pasteboard.changeCount)
    }

    // MARK: The system's pasteboard and keyboard

    func testTheTextIsMarkedForClipboardManagers() throws {
        let named = NSPasteboard.withUniqueName()
        defer { named.releaseGlobally() }
        let pasteboard = PasteTyper.SystemPasteboard(named)

        let ours = try pasteboard.write("Dictated words.")

        XCTAssertEqual(named.changeCount, ours)
        XCTAssertEqual("Dictated words.", named.string(forType: .string))
        let types = Set(try XCTUnwrap(named.pasteboardItems?.first).types.map(\.rawValue))
        XCTAssertTrue(
            types.isSuperset(of: [
                "public.utf8-plain-text", "org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType",
                "org.nspasteboard.AutoGeneratedType",
            ]),
            "\(types)")
        // Pasteboards other than the general one are always readable.
        XCTAssertTrue(PasteTyper.maySave(pasteboard.access), "\(pasteboard.access)")
    }

    func testEveryItemAndTypeIsSavedAndPutBack() throws {
        let named = NSPasteboard.withUniqueName()
        defer { named.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("app.thumbfree.tests.custom")
        let first = NSPasteboardItem()
        _ = first.setString("one", forType: .string)
        _ = first.setData(Data([1, 2, 3]), forType: custom)
        let second = NSPasteboardItem()
        _ = second.setString("two", forType: .string)
        _ = named.clearContents()
        XCTAssertTrue(named.writeObjects([first, second]))
        let pasteboard = PasteTyper.SystemPasteboard(named)

        let saved = pasteboard.save()
        guard case .items = saved else { return XCTFail("\(saved)") }
        _ = try pasteboard.write("Dictated words.")
        pasteboard.restore(saved)

        let items = try XCTUnwrap(named.pasteboardItems)
        XCTAssertEqual(2, items.count)
        XCTAssertEqual("one", items[0].string(forType: .string))
        XCTAssertEqual(Data([1, 2, 3]), items[0].data(forType: custom))
        XCTAssertEqual("two", items[1].string(forType: .string))
        XCTAssertEqual(saved, pasteboard.save())
    }

    func testAnEmptyPasteboardIsSavedAsEmptyAndPutBackEmpty() throws {
        let named = NSPasteboard.withUniqueName()
        defer { named.releaseGlobally() }
        _ = named.clearContents()
        let pasteboard = PasteTyper.SystemPasteboard(named)

        let saved = pasteboard.save()
        _ = try pasteboard.write("Dictated words.")
        pasteboard.restore(saved)

        XCTAssertEqual(.empty, saved)
        XCTAssertEqual(.empty, pasteboard.save())
    }

    func testAPromiseNobodyKeepsIsUnreadableAndNeverEmptied() throws {
        // What an app that has quit leaves: types without data.
        let named = NSPasteboard.withUniqueName()
        defer { named.releaseGlobally() }
        let promised = NSPasteboard.PasteboardType("app.thumbfree.tests.promised")
        _ = named.declareTypes([promised], owner: nil)
        let pasteboard = PasteTyper.SystemPasteboard(named)

        let saved = pasteboard.save()
        pasteboard.restore(saved)

        XCTAssertEqual(.unreadable, saved)
        XCTAssertEqual([promised], named.types)
    }

    func testThePasteKeyIsTheOneThatTypesVInTheLayout() throws {
        // Dvorak's V is QWERTY's full stop; "Dvorak – QWERTY ⌘" switches to QWERTY while ⌘ is held.
        for (layout, key) in [
            ("com.apple.keylayout.US", kVK_ANSI_V), ("com.apple.keylayout.Dvorak", kVK_ANSI_Period),
            ("com.apple.keylayout.DVORAK-QWERTYCMD", kVK_ANSI_V),
        ] {
            let source = try XCTUnwrap(inputSource(layout), "\(layout) isn't on this Mac")
            XCTAssertEqual(CGKeyCode(key), PasteTyper.SystemKeys.keyCode(typing: "v", in: source), layout)
        }
    }

    func testKeysCarryTheLeftHandModifierKeysOwnFlags() {
        let flags = PasteTyper.SystemKeys.eventFlags([.command, .shift])
        XCTAssertEqual(CGEventFlags([.maskCommand, .maskShift]).rawValue | 0x08 | 0x02, flags.rawValue)
        XCTAssertEqual(0, PasteTyper.SystemKeys.eventFlags([]).rawValue)
    }

    // MARK: Helpers

    private func makeTyper(copied: String?) -> (PasteTyper, FakePasteboard, FakeKeyPoster) {
        log = []
        let pasteboard = FakePasteboard(copied) { [unowned self] in self.log.append($0) }
        let keys = FakeKeyPoster(pasteboard) { [unowned self] in self.log.append($0) }
        let clock = FakeTypingClock { [unowned self] in self.log.append($0) }
        return (PasteTyper(pasteboard: pasteboard, keys: keys, sleep: clock.sleep, now: clock.now), pasteboard, keys)
    }

    private func inputSource(_ id: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue(), CFArrayGetCount(list) > 0,
              let first = CFArrayGetValueAtIndex(list, 0) else { return nil }
        return Unmanaged<TISInputSource>.fromOpaque(first).takeUnretainedValue()
    }
}

private struct MovedToAnotherBox: Error {}

private extension PasteTyper.Contents {
    static func text(_ text: String) -> Self {
        Self(items: [[Representation(type: "public.utf8-plain-text", data: Data(text.utf8))]])
    }

    var text: String? {
        items.first?.first.flatMap { String(data: $0.data, encoding: .utf8) }
    }
}

/// A pasteboard holding one text, with its change count and what macOS lets ThumbFree do with it.
private final class FakePasteboard: PasteTyper.Pasteboard {
    private(set) var contents: PasteTyper.Contents?
    private(set) var changeCount = 1
    var access = PasteTyper.PasteboardAccess.unrestricted
    /// Has types but no data that can be read (the app it came from has quit, or macOS said no).
    var unreadable = false
    private(set) var saves = 0
    private let log: (String) -> Void

    init(_ text: String?, log: @escaping (String) -> Void) {
        contents = text.map { .text($0) }
        self.log = log
    }

    var text: String? { contents?.text }

    func userCopies(_ text: String) {
        contents = .text(text)
        changeCount += 1
    }

    func save() -> PasteTyper.Saved {
        saves += 1
        if unreadable {
            return .unreadable
        }

        return contents.map { .items($0) } ?? .empty
    }

    func write(_ text: String) throws -> Int {
        log("write \(text)")
        contents = .text(text)
        changeCount += 1
        return changeCount
    }

    func restore(_ saved: PasteTyper.Saved) {
        switch saved {
        case .unreadable:
            XCTFail("an unreadable pasteboard is never put back")
        case .empty:
            log("restore nothing")
            contents = nil
        case .items(let contents):
            log("restore \(contents.text ?? "?")")
            self.contents = contents
        }

        changeCount += 1
    }
}

/// A keyboard whose ⌘V reads the fake pasteboard, as the app would.
private final class FakeKeyPoster: PasteTyper.Keys {
    var allowed = true
    var secureInput = false
    /// Held at the first checks, one more let go at each.
    var held: [PasteTyper.Modifiers] = []
    var heldForever: PasteTyper.Modifiers = []
    var afterPaste: (() -> Void)?
    private(set) var posted: [String] = []
    private(set) var pasted: [String] = []
    /// What each key typed with characters of its own carried.
    private(set) var typed: [String] = []
    private let pasteboard: FakePasteboard
    private let log: (String) -> Void

    init(_ pasteboard: FakePasteboard, log: @escaping (String) -> Void) {
        self.pasteboard = pasteboard
        self.log = log
    }

    var heldModifiers: PasteTyper.Modifiers {
        heldForever.isEmpty ? (held.isEmpty ? [] : held.removeFirst()) : heldForever
    }

    var pasteChord: PasteTyper.Chord { PasteTyper.Chord(key: CGKeyCode(kVK_ANSI_V), modifiers: .command) }

    func post(_ chord: PasteTyper.Chord) throws {
        guard allowed else { throw PasteTyper.Failure.notAllowed }
        let name = chord == pasteChord ? "⌘V" : chord == .shiftReturn ? "⇧↩" : chord == .returnKey ? "↩" : "\(chord)"
        log(name)
        posted.append(name)
        if chord == pasteChord {
            pasted.append(pasteboard.text ?? "")
            afterPaste?()
        }
    }

    func type(_ characters: String) throws {
        guard allowed else { throw PasteTyper.Failure.notAllowed }
        XCTAssertLessThanOrEqual(characters.utf16.count, PasteTyper.unitsPerKey, characters)
        log("type \(characters)")
        posted.append("type \(characters)")
        typed.append(characters)
    }
}

/// Time that passes only when the typer waits; each wait is logged.
private final class FakeTypingClock {
    private var time: TimeInterval = 0
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    func sleep(_ interval: TimeInterval) {
        log("wait \(interval)")
        time += interval
    }

    func now() -> TimeInterval {
        time
    }
}
