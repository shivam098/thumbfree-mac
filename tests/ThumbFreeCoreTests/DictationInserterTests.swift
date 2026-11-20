import XCTest
@testable import ThumbFreeCore

/// The same cases as thumbfree-windows tests/ThumbFree.Core.Tests/DictationInserterTests.cs.
final class DictationInserterTests: XCTestCase {
    private struct TypingFailed: Error {}

    private struct FieldChanged: Error {}

    private final class FakeDesktop: Desktop {
        var foreground: WindowInfo? = WindowInfo(handle: 1, processId: 1, processName: "slack", title: "Slack")
        var field = FieldCheck.safe
        var endsWithText: Bool? = false
        var actions: [String] = []

        /// How many more keystrokes go through before typing fails (the text box lost focus, say); nil: never.
        var failAfter: Int?

        /// The field check throws, as the Windows host's does for a password field that isn't the dictation's box.
        var fieldChanged = false

        func foregroundWindow() -> WindowInfo? { foreground }

        func checkFocusedField() throws -> FieldCheck {
            if fieldChanged {
                throw FieldChanged()
            }

            return field
        }

        func focusedTextEndsWithNonWhitespace() -> Bool? { endsWithText }

        func typeText(_ text: String) throws { try act("type:\(text)") }

        func pressKeys(_ chord: String) throws { try act("keys:\(chord)") }

        private func act(_ action: String) throws {
            if let left = failAfter {
                if left == 0 {
                    throw TypingFailed()
                }

                failAfter = left - 1
            }

            actions.append(action)
        }
    }

    private final class StatusLog {
        var updates: [StatusUpdate] = []
    }

    private let desktop = FakeDesktop()
    private let statuses = StatusLog()
    private lazy var inserter: DictationInserter = {
        let inserter = DictationInserter(
            self.desktop, DictationFormatter(), newLineKeysByProcess: [("notepad", "Enter")])
        let log = self.statuses
        inserter.onStatus = { log.updates.append($0) }
        return inserter
    }()

    func testInsertsCleanedText() throws {
        XCTAssertTrue(try inserter.insert("um so the demo is ready comma can you check it question mark"))
        XCTAssertEqual(["type:So the demo is ready, can you check it?"], desktop.actions)
        XCTAssertEqual(.success, statuses.updates.last?.kind)
    }

    func testAddsASpaceAfterExistingText() throws {
        desktop.endsWithText = true
        try inserter.insert("Second sentence.")
        XCTAssertEqual(["type: Second sentence."], desktop.actions)
    }

    func testChatAppsGetShiftEnterAndEditorsGetEnterForNewLines() throws {
        try inserter.insert("first new line second")
        XCTAssertEqual(["type:First", "keys:Shift+Enter", "type:Second"], desktop.actions)

        desktop.actions.removeAll()
        desktop.foreground = WindowInfo(handle: 2, processId: 2, processName: "Notepad", title: "Untitled - Notepad")
        try inserter.insert("first new line second")
        XCTAssertEqual(["type:First", "keys:Enter", "type:Second"], desktop.actions)
    }

    func testRefusesPasswordFieldsAndAdminWindows() throws {
        for check in [FieldCheck.password, .elevated] {
            let desktop = FakeDesktop()
            let statuses = StatusLog()
            let inserter = DictationInserter(
                desktop, DictationFormatter(), newLineKeysByProcess: [("notepad", "Enter")])
            inserter.onStatus = { statuses.updates.append($0) }
            desktop.field = check
            XCTAssertFalse(try inserter.insert("secret"))
            XCTAssertTrue(desktop.actions.isEmpty)
            XCTAssertEqual(.warning, statuses.updates.last?.kind)
        }
    }

    func testUnknownFieldsAreAllowedBecauseTheKeyPressIsConsent() throws {
        desktop.field = .unknown
        XCTAssertTrue(try inserter.insert("hello"))
    }

    func testNoWindowMeansNothingIsTyped() throws {
        desktop.foreground = nil
        XCTAssertFalse(try inserter.insert("hello"))
        XCTAssertTrue(desktop.actions.isEmpty)
    }

    func testOnlyFillerWordsTypesNothing() throws {
        XCTAssertFalse(try inserter.insert("um uh"))
        XCTAssertTrue(desktop.actions.isEmpty)
    }

    func testRepeatLastTypesThePreviousTextAgain() throws {
        XCTAssertFalse(try inserter.repeatLast())
        try inserter.insert("hello there")
        desktop.actions.removeAll()
        XCTAssertTrue(try inserter.repeatLast())
        XCTAssertEqual(["type:Hello there"], desktop.actions)
    }

    func testNoSpaceGoesBeforePunctuation() throws {
        // Shared rule (Insertion.withSpacing): before, this typed " ?" after the word.
        desktop.endsWithText = true
        try inserter.insert("question mark")
        XCTAssertEqual(["type:?"], desktop.actions)
    }

    func testWithTheFieldAndTheTextBeforeItTheSharedPipelineRuns() throws {
        let multiLine = FieldInfo(multiLine: true)
        func context(_ before: String?, _ field: FieldInfo) -> LiveTypingContext {
            LiveTypingContext(textBefore: before, field: field, live: true, smartFormatting: true)
        }

        // The text before decides the space and the lowercase "and", not the desktop's guess.
        XCTAssertTrue(try inserter.insert("and then we celebrated", context("We shipped it", multiLine)))
        XCTAssertEqual(["type: and then we celebrated"], desktop.actions)
        XCTAssertEqual("and then we celebrated", inserter.lastText)

        // Enter in a single-line box would send or search.
        desktop.actions.removeAll()
        try inserter.insert("first new line second", context("", FieldInfo()))
        XCTAssertEqual(["type:First Second"], desktop.actions)

        desktop.actions.removeAll()
        try inserter.insert("weather in Delhi full stop", context("", FieldInfo(search: true)))
        XCTAssertEqual(["type:Weather in Delhi"], desktop.actions)

        desktop.actions.removeAll()
        try inserter.insert("my shopping list: milk, eggs, bread and butter.", context("", multiLine))
        XCTAssertEqual(
            [
                "type:My shopping list:", "keys:Shift+Enter", "type:- Milk.", "keys:Shift+Enter", "type:- Eggs.",
                "keys:Shift+Enter", "type:- Bread and butter.",
            ],
            desktop.actions)

        // Unknown text before: the desktop's answer adds the space, as without a context.
        desktop.actions.removeAll()
        desktop.endsWithText = true
        try inserter.insert("see you there", context(nil, multiLine))
        XCTAssertEqual(["type: See you there"], desktop.actions)
    }

    func testAPasswordFieldInTheContextIsRefused() throws {
        let password = FieldInfo(password: true)
        let context = LiveTypingContext(textBefore: "", field: password, live: true, smartFormatting: true)
        XCTAssertFalse(try inserter.insert("open sesame", context))
        XCTAssertTrue(desktop.actions.isEmpty)
        XCTAssertEqual(.warning, statuses.updates.last?.kind)
    }

    func testLivePiecesAreTypedAsGivenAndOnlyProblemsAreReported() throws {
        desktop.endsWithText = true
        XCTAssertTrue(try inserter.typePrepared("Hello there."))
        XCTAssertTrue(try inserter.typePrepared("\n\nThanks,\nBen"))
        XCTAssertFalse(try inserter.typePrepared(""))
        XCTAssertEqual(
            [
                "type:Hello there.", "keys:Shift+Enter", "keys:Shift+Enter", "type:Thanks,", "keys:Shift+Enter",
                "type:Ben",
            ],
            desktop.actions)
        XCTAssertTrue(statuses.updates.isEmpty)
        XCTAssertNil(inserter.lastText)

        desktop.field = .password
        XCTAssertFalse(try inserter.typePrepared("more"))
        XCTAssertEqual(.warning, statuses.updates.last?.kind)
    }

    func testLivePiecesForAPasswordFieldAreRefused() throws {
        // The field read when dictation started says password, even if the desktop can't tell now.
        XCTAssertFalse(try inserter.typePrepared("open sesame", FieldInfo(password: true)))
        XCTAssertTrue(desktop.actions.isEmpty)
        XCTAssertEqual(.warning, statuses.updates.last?.kind)
        XCTAssertTrue(try inserter.typePrepared("Hello", FieldInfo(multiLine: true)))
    }

    // MARK: Beyond the C# tests

    func testATypingFailureStopsTheDictationWhereItWas() throws {
        // As when the C# desktop throws (the text box lost focus, the clipboard was busy): the error comes through, the
        // rest isn't typed, nothing more is reported and the last dictation stays the one before.
        try inserter.insert("hello there")
        let reported = statuses.updates.count
        desktop.actions.removeAll()
        desktop.failAfter = 1
        XCTAssertThrowsError(try inserter.insert("first new line second")) { XCTAssertTrue($0 is TypingFailed) }
        XCTAssertEqual(["type:First"], desktop.actions)
        XCTAssertEqual(reported, statuses.updates.count)
        XCTAssertEqual("Hello there", inserter.lastText)

        desktop.actions.removeAll()
        desktop.failAfter = 0
        XCTAssertThrowsError(try inserter.repeatLast()) { XCTAssertTrue($0 is TypingFailed) }
        XCTAssertThrowsError(try inserter.typePrepared("More.")) { XCTAssertTrue($0 is TypingFailed) }
        XCTAssertTrue(desktop.actions.isEmpty)
        XCTAssertEqual(reported, statuses.updates.count)
        XCTAssertEqual("Hello there", inserter.lastText)
    }

    func testAFieldCheckThatThrowsNeitherTypesNorRefuses() throws {
        // The Windows host's check throws when the password field that has the focus isn't the dictation's own text
        // box, and keeps the dictation to copy: nothing is typed, no refusal is shown and the last dictation is kept.
        try inserter.insert("hello there")
        let reported = statuses.updates.count
        desktop.actions.removeAll()
        desktop.field = .password
        desktop.fieldChanged = true
        XCTAssertThrowsError(try inserter.insert("open sesame")) { XCTAssertTrue($0 is FieldChanged) }
        XCTAssertThrowsError(try inserter.typePrepared("More.")) { XCTAssertTrue($0 is FieldChanged) }
        XCTAssertThrowsError(try inserter.repeatLast()) { XCTAssertTrue($0 is FieldChanged) }
        XCTAssertTrue(desktop.actions.isEmpty)
        XCTAssertEqual(reported, statuses.updates.count)
        XCTAssertEqual("Hello there", inserter.lastText)
    }

    func testOfNewLineKeysForOneAppTheLastEntryCounts() throws {
        // Names that differ only in case are the same app; as when the Windows app merges its settings, the later wins.
        desktop.foreground = WindowInfo(handle: 2, processId: 2, processName: "notepad", title: "Untitled - Notepad")
        let enterLast = DictationInserter(
            desktop, DictationFormatter(), newLineKeysByProcess: [("NOTEPAD", "Ctrl+Enter"), ("Notepad", "Enter")])
        try enterLast.insert("first new line second")
        XCTAssertEqual(["type:First", "keys:Enter", "type:Second"], desktop.actions)

        desktop.actions.removeAll()
        let enterFirst = DictationInserter(
            desktop, DictationFormatter(), newLineKeysByProcess: [("Notepad", "Enter"), ("NOTEPAD", "Ctrl+Enter")])
        try enterFirst.insert("first new line second")
        XCTAssertEqual(["type:First", "keys:Ctrl+Enter", "type:Second"], desktop.actions)
    }

    func testNewLineKeysAreFoundByTheProcessNameThenByTheAppsName() throws {
        // The Mac's own case: an app's name is translated in some languages, its executable's name never is.
        let inserter = DictationInserter(
            desktop, DictationFormatter(), newLineKeysByProcess: [("TextEdit", "Enter"), ("Code", "Ctrl+Enter")])
        desktop.foreground = WindowInfo(
            handle: 2, processId: 2, processName: "TextEdit", title: "", appName: "テキストエディット")
        try inserter.insert("first new line second")
        XCTAssertEqual(["type:First", "keys:Enter", "type:Second"], desktop.actions)

        desktop.actions.removeAll()
        desktop.foreground = WindowInfo(handle: 3, processId: 3, processName: "Electron", title: "", appName: "Code")
        try inserter.insert("first new line second")
        XCTAssertEqual(["type:First", "keys:Ctrl+Enter", "type:Second"], desktop.actions)

        desktop.actions.removeAll()
        desktop.foreground = WindowInfo(handle: 4, processId: 4, processName: "Slack", title: "", appName: "Slack")
        try inserter.insert("first new line second")
        XCTAssertEqual(["type:First", "keys:Shift+Enter", "type:Second"], desktop.actions)
    }
}
