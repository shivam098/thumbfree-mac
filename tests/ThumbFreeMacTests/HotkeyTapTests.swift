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

/// Whether Secure Input is on, as the tests set it, and how often the tap asked.
final class FakeSecureInput: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    private var questions = 0

    var isOn: Bool {
        get { locked { on } }
        set { locked { on = newValue } }
    }

    var asked: Int {
        locked { questions }
    }

    func check() -> Bool {
        locked {
            questions += 1
            return on
        }
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
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
    private func makeTap(
        _ source: FakeFnEventSource, tapKey: FnTapKeys.TapKey = .fn, secureInput: FakeSecureInput = FakeSecureInput()
    ) -> (HotkeyTap, Commands) {
        let tap = HotkeyTap(tapKey: tapKey, source: source, secureInput: { secureInput.check() })
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

    func testOtherModifiersMediaKeysClicksAndScrollingAreOtherKeys() {
        XCTAssertEqual("other down", change(modifier(HotkeyCode.shift, .maskShift)))
        XCTAssertEqual("other up", change(modifier(HotkeyCode.shift)))
        XCTAssertEqual("other down", change(modifier(HotkeyCode.rightCommand, .maskCommand)))
        XCTAssertEqual("other down", change(modifier(HotkeyCode.control, .maskControl)))
        XCTAssertEqual("other down", change(modifier(HotkeyCode.option, .maskAlternate)))
        XCTAssertEqual("other down", change(modifier(HotkeyCode.capsLock)))
        XCTAssertEqual("other down", change(HotkeyEvent(.mediaKey(down: true))))
        XCTAssertEqual("other up", change(HotkeyEvent(.mediaKey(down: false))))
        // A click or a scroll is input, like a key going down.
        XCTAssertEqual("other down", change(HotkeyEvent(.mouseDown)))
        XCTAssertEqual("other down", change(HotkeyEvent(.mouseUp)))
        XCTAssertEqual("other down", change(HotkeyEvent(.scroll)))
        XCTAssertNil(change(HotkeyEvent(.tapReenabled)))
    }

    func testOnlyTheFlagsOfAnotherKeyShowTheTapKeyUp() {
        XCTAssertTrue(modifier(HotkeyCode.shift, .maskShift).showsUp(.fn))
        XCTAssertFalse(modifier(HotkeyCode.shift, [.maskShift, .maskSecondaryFn]).showsUp(.fn))
        XCTAssertTrue(escDown.showsUp(.fn))
        XCTAssertFalse(arrowKey(down: true).showsUp(.fn))
        // Its own event says up or down itself; a click or a media key carries no flags here.
        XCTAssertFalse(fnUp.showsUp(.fn))
        XCTAssertFalse(HotkeyEvent(.mouseDown).showsUp(.fn))
        XCTAssertFalse(HotkeyEvent(.mediaKey(down: true)).showsUp(.fn))

        XCTAssertTrue(escDown.showsUp(.rightOption))
        XCTAssertFalse(HotkeyEvent(.keyDown, keyCode: 0x0E, flags: rightOptionDown.flags).showsUp(.rightOption))
        XCTAssertFalse(rightOptionUp.showsUp(.rightOption))
        XCTAssertTrue(fnDown.isChange(of: .fn))
        XCTAssertFalse(fnDown.isChange(of: .rightOption))
        XCTAssertTrue(rightOptionUp.isChange(of: .rightOption))
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
    func testClicksAndScrollingWhileRightOptionIsHeldAreShortcuts() {
        let source = FakeFnEventSource()
        let (tap, commands) = makeTap(source, tapKey: .rightOption)

        // A Finder Option-drag ends with the button going up; an Option-scroll zooms.
        source.send([HotkeyEvent(.mouseDown), rightOptionDown, HotkeyEvent(.mouseUp), rightOptionUp])
        source.send([rightOptionDown, HotkeyEvent(.scroll), HotkeyEvent(.scroll), rightOptionUp])
        drainMainQueue()
        XCTAssertEqual([], commands.list)

        source.send([rightOptionDown, rightOptionUp])
        drainMainQueue()
        XCTAssertEqual([.start], commands.list)
        XCTAssertTrue(tap.isRecording)
    }

    @MainActor
    func testUnderSecureInputFnNeverStartsDictationButStillFinishesIt() {
        let source = FakeFnEventSource()
        let secure = FakeSecureInput()
        let (tap, commands) = makeTap(source, secureInput: secure)

        // Fn+↑ in a password field: the arrow is hidden, so it looks like a tap. On all along, only when Fn goes
        // down, or only when it's let go.
        secure.isOn = true
        source.send([fnDown, fnUp, fnDown])
        secure.isOn = false
        source.send([fnUp, fnDown])
        secure.isOn = true
        source.send(fnUp)
        drainMainQueue()
        XCTAssertEqual([], commands.list)
        XCTAssertFalse(tap.isRecording)

        secure.isOn = false
        source.send([fnDown, fnUp])
        secure.isOn = true
        source.send([fnDown, fnUp])
        drainMainQueue()
        XCTAssertEqual([.start, .finish], commands.list)

        // It's asked only when Fn goes down or up.
        XCTAssertEqual(10, secure.asked)
        source.send([arrowKey(down: true), arrowKey(down: false), escDown, HotkeyEvent(.scroll), rightOptionDown])
        XCTAssertEqual(10, secure.asked)
    }

    @MainActor
    func testAReleaseLostMidPressIsForgotten() {
        let source = FakeFnEventSource()
        let (tap, commands) = makeTap(source)
        source.send([fnDown, fnUp])

        // The finishing press loses its release (a user switch): Esc, which carries no Fn flag, still cancels.
        source.send(fnDown)
        XCTAssertTrue(source.send(escDown))
        // Lost again: Fn doesn't repeat, so the next press of Fn is a new tap.
        source.send([fnDown, fnDown, fnUp])
        drainMainQueue()

        XCTAssertEqual([.start, .cancel, .start], commands.list)
        XCTAssertTrue(tap.isRecording)
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
