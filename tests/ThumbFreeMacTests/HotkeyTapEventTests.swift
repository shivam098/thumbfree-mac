import AppKit
import CoreGraphics
import XCTest
@testable import ThumbFreeMac

/// HotkeyTap.Event made from Quartz events as the tap gets them. Making (not posting) events needs no permission.
final class HotkeyTapEventTests: XCTestCase {
    @MainActor
    private final class Commands {
        var list: [FnTapKeys.Command] = []
    }

    /// A key event, or a flags-changed one, from process 1 unless said otherwise.
    private func keyEvent(
        _ keyCode: CGKeyCode, _ type: CGEventType = .keyDown, flags: CGEventFlags = [], process: pid_t = 1
    ) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: type != .keyUp))
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(process))
        return event
    }

    /// An Option key's flags-changed event, with the Option flag and these device bits.
    private func option(_ keyCode: CGKeyCode, deviceBits: UInt64) throws -> HotkeyTap.Event {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | deviceBits)
        return try XCTUnwrap(parsed(keyEvent(keyCode, .flagsChanged, flags: flags)))
    }

    private func parsed(_ event: CGEvent) -> HotkeyTap.Event? {
        HotkeyTap.Event(type: event.type, event: event)
    }

    /// A system-defined event, as media and brightness keys send.
    @MainActor
    private func systemDefined(subtype: Int16, data1: Int) throws -> CGEvent {
        let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            subtype: subtype, data1: data1, data2: -1)
        return try XCTUnwrap(event?.cgEvent)
    }

    func testFnIsAFlagsChangedEventForKeyCode63WithTheFnFlag() throws {
        let down = try XCTUnwrap(parsed(keyEvent(63, .flagsChanged, flags: .maskSecondaryFn)))
        let up = try XCTUnwrap(parsed(keyEvent(63, .flagsChanged)))

        XCTAssertEqual(.flagsChanged, down.kind)
        XCTAssertEqual(63, down.keyCode)
        XCTAssertTrue(down.flags.contains(.maskSecondaryFn))
        XCTAssertFalse(down.fromThisApp)
        XCTAssertEqual(.fn, down.keyChange?.key)
        XCTAssertEqual(true, down.keyChange?.down)
        XCTAssertEqual(.fn, up.keyChange?.key)
        XCTAssertEqual(false, up.keyChange?.down)
    }

    func testAnArrowCarryingTheFnFlagIsAnotherKey() throws {
        let arrow = try XCTUnwrap(parsed(keyEvent(0x7E, flags: [.maskSecondaryFn, .maskNumericPad])))

        XCTAssertEqual(.keyDown, arrow.kind)
        XCTAssertEqual(0x7E, arrow.keyCode)
        XCTAssertEqual(.other, arrow.keyChange?.key)
        XCTAssertEqual(true, arrow.keyChange?.down)
    }

    func testRightAndLeftOptionAreToldApartByTheirDeviceBits() throws {
        let right = try option(61, deviceBits: 0x40)
        let left = try option(58, deviceBits: 0x20)
        // Right Option let go while Left Option stays down: the Option flag is still set.
        let rightUp = try option(61, deviceBits: 0x20)

        XCTAssertEqual(.rightOption, right.keyChange?.key)
        XCTAssertEqual(true, right.keyChange?.down)
        XCTAssertEqual(.other, left.keyChange?.key)
        XCTAssertEqual(true, left.keyChange?.down)
        XCTAssertEqual(.rightOption, rightUp.keyChange?.key)
        XCTAssertEqual(false, rightUp.keyChange?.down)
    }

    /// The typing side's ⌘V, pasted while the person taps Fn to finish, mustn't spoil the tap.
    @MainActor
    func testAnEventFromThisProcessIsIgnored() throws {
        let own = try XCTUnwrap(parsed(keyEvent(0x09, flags: .maskCommand, process: getpid())))
        let other = try XCTUnwrap(parsed(keyEvent(0x09, flags: .maskCommand)))
        XCTAssertTrue(own.fromThisApp)
        XCTAssertFalse(other.fromThisApp)

        let source = FakeFnEventSource()
        let tap = HotkeyTap(source: source, secureInput: { false })
        let commands = Commands()
        tap.onCommand = { command in commands.list.append(command) }
        tap.start()
        let fnDown = try XCTUnwrap(parsed(keyEvent(63, .flagsChanged, flags: .maskSecondaryFn)))
        let fnUp = try XCTUnwrap(parsed(keyEvent(63, .flagsChanged)))
        source.send([fnDown, fnUp, fnDown, own, fnUp])
        // From another app, the same ⌘V during a press means it wasn't a tap.
        source.send([fnDown, other, fnUp])

        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual([.start, .finish], commands.list)
    }

    @MainActor
    func testMediaKeysAreSystemDefinedEventsOfSubtype8() throws {
        // NX_KEYTYPE_PLAY (16) in the high 16 bits; the state in bits 8 to 15.
        for (state, down) in [(0xA, true), (0xB, false)] {
            let event = try systemDefined(subtype: 8, data1: 16 << 16 | state << 8)

            XCTAssertEqual(14, event.type.rawValue)
            XCTAssertEqual(.mediaKey(down: down), parsed(event)?.kind)
        }

        // Other system-defined events, such as mouse-button changes (subtype 7), aren't keys.
        XCTAssertNil(try parsed(systemDefined(subtype: 7, data1: 1)))
    }

    func testMouseButtonsAndScrollingButNotTheScrollingAfterAFlick() throws {
        let buttons: [(CGEventType, CGMouseButton, HotkeyTap.Event.Kind)] = [
            (.leftMouseDown, .left, .mouseDown), (.leftMouseUp, .left, .mouseUp),
            (.rightMouseDown, .right, .mouseDown), (.rightMouseUp, .right, .mouseUp),
            (.otherMouseDown, .center, .mouseDown), (.otherMouseUp, .center, .mouseUp),
        ]
        for (type, button, kind) in buttons {
            let event = try XCTUnwrap(
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: button))
            XCTAssertEqual(kind, parsed(event)?.kind)
        }

        let scroll = try XCTUnwrap(
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 4, wheel2: 0, wheel3: 0))
        XCTAssertEqual(.scroll, parsed(scroll)?.kind)
        scroll.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
        XCTAssertNil(parsed(scroll))
    }
}
