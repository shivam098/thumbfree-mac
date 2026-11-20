import XCTest
@testable import ThumbFreeCore

/// The same cases as thumbfree-windows tests/ThumbFree.Core.Tests/DictationInserterTests.cs.
final class DictationInserterTests: XCTestCase {
    private final class FakeDesktop: Desktop {
        var foreground: WindowInfo? = WindowInfo(handle: 1, processId: 1, processName: "slack", title: "Slack")
        var field = FieldCheck.safe
        var endsWithText: Bool? = false
        var actions: [String] = []

        func foregroundWindow() -> WindowInfo? { foreground }

        func checkFocusedField() -> FieldCheck { field }

        func focusedTextEndsWithNonWhitespace() -> Bool? { endsWithText }

        func typeText(_ text: String) { actions.append("type:\(text)") }

        func pressKeys(_ chord: String) { actions.append("keys:\(chord)") }
    }

    private final class StatusLog {
        var updates: [StatusUpdate] = []
    }

    private let desktop = FakeDesktop()
    private let statuses = StatusLog()
    private lazy var inserter: DictationInserter = {
        let inserter = DictationInserter(self.desktop, DictationFormatter(), newLineKeysByProcess: ["notepad": "Enter"])
        let log = self.statuses
        inserter.onStatus = { log.updates.append($0) }
        return inserter
    }()

    func testInsertsCleanedText() {
        XCTAssertTrue(inserter.insert("um so the demo is ready comma can you check it question mark"))
        XCTAssertEqual(["type:So the demo is ready, can you check it?"], desktop.actions)
        XCTAssertEqual(.success, statuses.updates.last?.kind)
    }

    func testAddsASpaceAfterExistingText() {
        desktop.endsWithText = true
        inserter.insert("Second sentence.")
        XCTAssertEqual(["type: Second sentence."], desktop.actions)
    }

    func testChatAppsGetShiftEnterAndEditorsGetEnterForNewLines() {
        inserter.insert("first new line second")
        XCTAssertEqual(["type:First", "keys:Shift+Enter", "type:Second"], desktop.actions)

        desktop.actions.removeAll()
        desktop.foreground = WindowInfo(handle: 2, processId: 2, processName: "Notepad", title: "Untitled - Notepad")
        inserter.insert("first new line second")
        XCTAssertEqual(["type:First", "keys:Enter", "type:Second"], desktop.actions)
    }

    func testRefusesPasswordFieldsAndAdminWindows() {
        for check in [FieldCheck.password, .elevated] {
            let desktop = FakeDesktop()
            let statuses = StatusLog()
            let inserter = DictationInserter(desktop, DictationFormatter(), newLineKeysByProcess: ["notepad": "Enter"])
            inserter.onStatus = { statuses.updates.append($0) }
            desktop.field = check
            XCTAssertFalse(inserter.insert("secret"))
            XCTAssertTrue(desktop.actions.isEmpty)
            XCTAssertEqual(.warning, statuses.updates.last?.kind)
        }
    }

    func testUnknownFieldsAreAllowedBecauseTheKeyPressIsConsent() {
        desktop.field = .unknown
        XCTAssertTrue(inserter.insert("hello"))
    }

    func testNoWindowMeansNothingIsTyped() {
        desktop.foreground = nil
        XCTAssertFalse(inserter.insert("hello"))
        XCTAssertTrue(desktop.actions.isEmpty)
    }

    func testOnlyFillerWordsTypesNothing() {
        XCTAssertFalse(inserter.insert("um uh"))
        XCTAssertTrue(desktop.actions.isEmpty)
    }

    func testRepeatLastTypesThePreviousTextAgain() {
        XCTAssertFalse(inserter.repeatLast())
        inserter.insert("hello there")
        desktop.actions.removeAll()
        XCTAssertTrue(inserter.repeatLast())
        XCTAssertEqual(["type:Hello there"], desktop.actions)
    }

    func testNoSpaceGoesBeforePunctuation() {
        // Shared rule (Insertion.withSpacing): before, this typed " ?" after the word.
        desktop.endsWithText = true
        inserter.insert("question mark")
        XCTAssertEqual(["type:?"], desktop.actions)
    }

    func testWithTheFieldAndTheTextBeforeItTheSharedPipelineRuns() {
        let multiLine = FieldInfo(multiLine: true)
        func context(_ before: String?, _ field: FieldInfo) -> LiveTypingContext {
            LiveTypingContext(textBefore: before, field: field, live: true, smartFormatting: true)
        }

        // The text before decides the space and the lowercase "and", not the desktop's guess.
        XCTAssertTrue(inserter.insert("and then we celebrated", context("We shipped it", multiLine)))
        XCTAssertEqual(["type: and then we celebrated"], desktop.actions)
        XCTAssertEqual("and then we celebrated", inserter.lastText)

        // Enter in a single-line box would send or search.
        desktop.actions.removeAll()
        inserter.insert("first new line second", context("", FieldInfo()))
        XCTAssertEqual(["type:First Second"], desktop.actions)

        desktop.actions.removeAll()
        inserter.insert("weather in Delhi full stop", context("", FieldInfo(search: true)))
        XCTAssertEqual(["type:Weather in Delhi"], desktop.actions)

        desktop.actions.removeAll()
        inserter.insert("my shopping list: milk, eggs, bread and butter.", context("", multiLine))
        XCTAssertEqual(
            [
                "type:My shopping list:", "keys:Shift+Enter", "type:- Milk.", "keys:Shift+Enter", "type:- Eggs.",
                "keys:Shift+Enter", "type:- Bread and butter.",
            ],
            desktop.actions)

        // Unknown text before: the desktop's answer adds the space, as without a context.
        desktop.actions.removeAll()
        desktop.endsWithText = true
        inserter.insert("see you there", context(nil, multiLine))
        XCTAssertEqual(["type: See you there"], desktop.actions)
    }

    func testAPasswordFieldInTheContextIsRefused() {
        let password = FieldInfo(password: true)
        let context = LiveTypingContext(textBefore: "", field: password, live: true, smartFormatting: true)
        XCTAssertFalse(inserter.insert("open sesame", context))
        XCTAssertTrue(desktop.actions.isEmpty)
        XCTAssertEqual(.warning, statuses.updates.last?.kind)
    }

    func testLivePiecesAreTypedAsGivenAndOnlyProblemsAreReported() {
        desktop.endsWithText = true
        XCTAssertTrue(inserter.typePrepared("Hello there."))
        XCTAssertTrue(inserter.typePrepared("\n\nThanks,\nBen"))
        XCTAssertFalse(inserter.typePrepared(""))
        XCTAssertEqual(
            [
                "type:Hello there.", "keys:Shift+Enter", "keys:Shift+Enter", "type:Thanks,", "keys:Shift+Enter",
                "type:Ben",
            ],
            desktop.actions)
        XCTAssertTrue(statuses.updates.isEmpty)
        XCTAssertNil(inserter.lastText)

        desktop.field = .password
        XCTAssertFalse(inserter.typePrepared("more"))
        XCTAssertEqual(.warning, statuses.updates.last?.kind)
    }

    func testLivePiecesForAPasswordFieldAreRefused() {
        // The field read when dictation started says password, even if the desktop can't tell now.
        XCTAssertFalse(inserter.typePrepared("open sesame", FieldInfo(password: true)))
        XCTAssertTrue(desktop.actions.isEmpty)
        XCTAssertEqual(.warning, statuses.updates.last?.kind)
        XCTAssertTrue(inserter.typePrepared("Hello", FieldInfo(multiLine: true)))
    }
}
