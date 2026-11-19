import CoreGraphics
import XCTest
@testable import ThumbFreeMac

/// A key-event source the tests type on: it hands each event to the tap's handler, as the Quartz event tap would.
final class FakeFnEventSource: HotkeyTap.EventSource, @unchecked Sendable {
    var mode = HotkeyTap.Mode.active
    private(set) var starts = 0
    private(set) var stops = 0
    private var handler: (@Sendable (HotkeyTap.Event) -> Bool)?

    func start(_ handler: @escaping @Sendable (HotkeyTap.Event) -> Bool) -> HotkeyTap.Mode {
        starts += 1
        self.handler = mode == .off ? nil : handler
        return mode
    }

    func stop() {
        stops += 1
        handler = nil
    }

    /// True when the tap kept the event from the app.
    @discardableResult
    func send(_ event: HotkeyTap.Event) -> Bool {
        handler?(event) ?? false
    }

    func send(_ events: [HotkeyTap.Event]) {
        for event in events {
            send(event)
        }
    }
}

private typealias HotkeyEvent = HotkeyTap.Event
private typealias HotkeyCode = HotkeyTap.Event.Code

private let fnDown = HotkeyEvent(.flagsChanged, keyCode: 63, flags: .maskSecondaryFn)
private let fnUp = HotkeyEvent(.flagsChanged, keyCode: 63)
private let escDown = HotkeyEvent(.keyDown, keyCode: 53)
private let escUp = HotkeyEvent(.keyUp, keyCode: 53)
private let rightOptionDown = modifier(61, CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40))
private let rightOptionUp = modifier(61)

/// A modifier key's flags-changed event, with the flags after the change.
private func modifier(_ keyCode: Int64, _ flags: CGEventFlags = []) -> HotkeyEvent {
    HotkeyEvent(.flagsChanged, keyCode: keyCode, flags: flags)
}

/// The left arrow, which Apple keyboards report with the Fn flag (and the keypad flag) even without Fn.
private func arrowKey(down: Bool) -> HotkeyEvent {
    HotkeyEvent(down ? .keyDown : .keyUp, keyCode: 0x7B, flags: [.maskSecondaryFn, .maskNumericPad])
}

final class HotkeyTapTests: XCTestCase {
    @MainActor
    private final class Commands {
        var list: [FnTapKeys.Command] = []
        var onMainThread = true
    }

    private func change(_ event: HotkeyEvent) -> String? {
        event.keyChange.map { "\($0.key) \($0.down ? "down" : "up")" }
    }

    /// Lets the main queue run everything sent to it so far.
    @MainActor
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        wait(for: [drained], timeout: 2)
    }

    @MainActor
    private func makeTap(_ source: FakeFnEventSource, tapKey: FnTapKeys.TapKey = .fn) -> (HotkeyTap, Commands) {
        let tap = HotkeyTap(tapKey: tapKey, source: source)
        let commands = Commands()
        tap.onCommand = { command in
            commands.list.append(command)
            commands.onMainThread = commands.onMainThread && Thread.isMainThread
        }
        tap.start()
        return (tap, commands)
    }

    func testFnIsKeyCode63WithTheSecondaryFunctionFlag() {
        XCTAssertEqual("fn down", change(fnDown))
        XCTAssertEqual("fn up", change(fnUp))
        XCTAssertEqual("escape down", change(escDown))
        XCTAssertEqual("escape up", change(escUp))
    }

    func testArrowsWithTheFnFlagAreNeverFn() {
        XCTAssertEqual("other down", change(arrowKey(down: true)))
        XCTAssertEqual("other up", change(arrowKey(down: false)))
        // Some keyboards also send a flags-changed event for such a key: it isn't a modifier, so it's ignored.
        XCTAssertNil(change(modifier(0x7B, .maskSecondaryFn)))
    }

    func testOtherModifiersMediaKeysAndClicksAreOtherKeys() {
        XCTAssertEqual("other down", change(modifier(HotkeyCode.shift, .maskShift)))
        XCTAssertEqual("other up", change(modifier(HotkeyCode.shift)))
        XCTAssertEqual("other down", change(modifier(HotkeyCode.rightCommand, .maskCommand)))
        XCTAssertEqual("other down", change(modifier(HotkeyCode.control, .maskControl)))
        XCTAssertEqual("other down", change(modifier(HotkeyCode.option, .maskAlternate)))
        XCTAssertEqual("other down", change(modifier(HotkeyCode.capsLock)))
        XCTAssertEqual("other down", change(HotkeyEvent(.mediaKey(down: true))))
        XCTAssertEqual("other up", change(HotkeyEvent(.mediaKey(down: false))))
        XCTAssertEqual("other down", change(HotkeyEvent(.mouseDown)))
        XCTAssertNil(change(HotkeyEvent(.tapReenabled)))
    }

    func testRightOptionIsToldFromLeftOptionByItsOwnFlag() {
        let left = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | HotkeyCode.leftOptionBit)
        let both = CGEventFlags(rawValue: left.rawValue | HotkeyCode.rightOptionBit)

        XCTAssertEqual("rightOption down", change(rightOptionDown))
        XCTAssertEqual("rightOption down", change(modifier(61, both)))
        // Let go while Left Option stays down: the Option flag is still set.
        XCTAssertEqual("rightOption up", change(modifier(61, left)))
        XCTAssertEqual("rightOption up", change(rightOptionUp))
        // A keyboard that doesn't say which side: the Option flag.
        XCTAssertEqual("rightOption down", change(modifier(61, .maskAlternate)))
    }

    @MainActor
    func testFnTapsReportStartAndFinishOnTheMainThread() {
        let source = FakeFnEventSource()
        let (tap, commands) = makeTap(source)
        XCTAssertEqual(.active, tap.mode)

        let sent = expectation(description: "keys sent from the tap's thread")
        DispatchQueue.global().async {
            source.send([fnDown, fnUp, fnDown, fnUp])
            sent.fulfill()
        }
        wait(for: [sent], timeout: 2)
        drainMainQueue()

        XCTAssertEqual([.start, .finish], commands.list)
        XCTAssertTrue(commands.onMainThread)
        XCTAssertFalse(tap.isRecording)
    }

    @MainActor
    func testFnShortcutsAndArrowsNeverStartDictation() {
        let source = FakeFnEventSource()
        let (tap, commands) = makeTap(source)

        source.send([arrowKey(down: true), arrowKey(down: false)])
        source.send([fnDown, arrowKey(down: true), arrowKey(down: false), fnUp])
        source.send([fnDown, HotkeyEvent(.mediaKey(down: true)), HotkeyEvent(.mediaKey(down: false)), fnUp])
        source.send([fnDown, HotkeyEvent(.mouseDown), fnUp])
        source.send([fnDown, modifier(HotkeyCode.shift, [.maskShift, .maskSecondaryFn]), fnUp])
        drainMainQueue()

        XCTAssertEqual([], commands.list)
        XCTAssertFalse(tap.isRecording)
    }

    @MainActor
    func testEscCancelsAndOnlyAnActiveTapKeepsItFromTheApp() {
        let source = FakeFnEventSource()
        let (tap, commands) = makeTap(source)

        source.send([fnDown, fnUp])
        XCTAssertTrue(source.send(escDown))
        XCTAssertFalse(source.send(escUp))
        XCTAssertFalse(source.send(escDown))

        source.mode = .listenOnly
        XCTAssertEqual(.listenOnly, tap.start())
        source.send([fnDown, fnUp])
        XCTAssertFalse(source.send(escDown))
        drainMainQueue()

        XCTAssertEqual([.start, .cancel, .start, .cancel], commands.list)
        XCTAssertFalse(tap.isRecording)
    }

    @MainActor
    func testKeysThisAppPostsAreIgnored() {
        let source = FakeFnEventSource()
        let (tap, commands) = makeTap(source)
        source.send([fnDown, fnUp])
        XCTAssertFalse(source.send(HotkeyEvent(.keyDown, keyCode: 53, fromThisApp: true)))

        // The ⌘V that types the dictation, pasted while the person taps Fn to finish.
        source.send(fnDown)
        source.send(HotkeyEvent(.keyDown, keyCode: 0x09, flags: .maskCommand, fromThisApp: true))
        source.send(HotkeyEvent(.keyUp, keyCode: 0x09, flags: .maskCommand, fromThisApp: true))
        source.send(fnUp)
        drainMainQueue()

        XCTAssertEqual([.start, .finish], commands.list)
        XCTAssertFalse(tap.isRecording)
    }

    @MainActor
    func testATapTurnedBackOnForgetsTheKeyInProgress() {
        let source = FakeFnEventSource()
        let (tap, commands) = makeTap(source)

        source.send([fnDown, HotkeyEvent(.tapReenabled), fnUp])
        drainMainQueue()
        XCTAssertEqual([], commands.list)

        source.send([fnDown, fnUp])
        drainMainQueue()
        XCTAssertEqual([.start], commands.list)
        XCTAssertTrue(tap.isRecording)
    }

    @MainActor
    func testPausedKeysPassThroughAndTheHostCanClearRecording() {
        let source = FakeFnEventSource()
        let (tap, commands) = makeTap(source)
        source.send([fnDown, fnUp])

        tap.isEnabled = false
        source.send([fnDown, fnUp])
        XCTAssertFalse(source.send(escDown))
        tap.isEnabled = true

        // The recording stopped on its own (the time limit): the next tap starts a new one.
        tap.isRecording = false
        source.send([fnDown, fnUp])
        drainMainQueue()

        XCTAssertEqual([.start, .start], commands.list)
        XCTAssertTrue(tap.isRecording)
    }

    @MainActor
    func testRightOptionWhenChosen() {
        let source = FakeFnEventSource()
        let (tap, commands) = makeTap(source, tapKey: .rightOption)

        source.send([fnDown, fnUp])
        source.send([rightOptionDown, rightOptionUp])
        // Option-click and Option+letter are shortcuts.
        source.send([rightOptionDown, HotkeyEvent(.mouseDown), rightOptionUp])
        source.send([rightOptionDown, HotkeyEvent(.keyDown, keyCode: 0x0E, flags: .maskAlternate), rightOptionUp])
        source.send([rightOptionDown, rightOptionUp])
        drainMainQueue()
        XCTAssertEqual([.start, .finish], commands.list)

        tap.tapKey = .fn
        source.send([rightOptionDown, rightOptionUp, fnDown, fnUp])
        drainMainQueue()
        XCTAssertEqual([.start, .finish, .start], commands.list)
    }

    @MainActor
    func testStartAndStopFollowTheSource() {
        let source = FakeFnEventSource()
        source.mode = .off
        let (tap, commands) = makeTap(source)
        XCTAssertEqual(.off, tap.mode)
        source.send([fnDown, fnUp])

        source.mode = .listenOnly
        XCTAssertEqual(.listenOnly, tap.start())
        source.send(fnDown)
        tap.stop()
        XCTAssertEqual(.off, tap.mode)
        source.send(fnUp)
        drainMainQueue()

        XCTAssertEqual([], commands.list)
        XCTAssertEqual(2, source.starts)
        XCTAssertEqual(3, source.stops)
    }
}
