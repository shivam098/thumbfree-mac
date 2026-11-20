import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// The dictation keys for the whole Mac: a Quartz event tap at the session level feeds key events to FnTapKeys, and
/// Start, Finish and Cancel are reported on the main thread.
///
/// Fn arrives as a flags-changed event for key code 63 (`kVK_Function`) with the secondary-function flag
/// (`CGEventFlags.maskSecondaryFn`). On Apple keyboards the arrows, the navigation keys and the F-keys carry that flag
/// too, so only that key code counts as Fn.
///
/// Esc: the Esc that cancels a recording is kept from the app, as on Windows, and only an active (filtering) tap can
/// do that. An active tap needs the right to post events, which typing into other apps needs anyway (System Settings
/// shows it under Accessibility), so the tap is active when the app has it. Without it the tap is listen-only, which
/// needs Input Monitoring: the keys work the same, but the app sees the Esc too. The tap runs on a thread of its own,
/// so a busy main thread never holds up anyone's typing, and it never keeps any other event. It doesn't ask for either
/// permission (Permissions does).
///
/// Secure Input (a password field, Terminal's Secure Keyboard Entry, a password manager, the lock screen) hides
/// key-downs from every event tap but not modifier keys, so a press of the tap key there never starts dictation; see
/// `FnTapKeys.process`.
@MainActor
public final class HotkeyTap {
    /// How the tap sees the keys.
    public enum Mode: Equatable, Sendable {
        /// No tap: the app may neither post nor listen to events.
        case off
        /// A passive tap (Input Monitoring): Esc cancels, but still reaches the app.
        case listenOnly
        /// An active tap (the right to post events): the Esc that cancels is kept from the app.
        case active
    }

    /// How the tap sees the keys since the last `start()`.
    public private(set) var mode = Mode.off

    /// Runs on the main thread for each Start, Finish and Cancel, in order. The host checks its own state before
    /// acting, as on Windows: a recording may have stopped on its own just before.
    public var onCommand: (@MainActor (FnTapKeys.Command) -> Void)? {
        get { core.onCommand }
        set { core.onCommand = newValue }
    }

    /// Whether the keys treat dictation as recording (the next tap finishes it, Esc cancels it). The keys update it
    /// themselves; the host clears it when a recording stops on its own.
    public var isRecording: Bool {
        get { core.isRecording }
        set { core.isRecording = newValue }
    }

    /// False while the dictation keys are paused: every key passes through untouched.
    public var isEnabled: Bool {
        get { core.isEnabled }
        set { core.isEnabled = newValue }
    }

    /// Fn or Right Option (a setting).
    public var tapKey: FnTapKeys.TapKey {
        get { core.tapKey }
        set { core.tapKey = newValue }
    }

    private let core: Core
    private let source: any EventSource

    /// - Parameters:
    ///   - source: Where the key events come from; the Quartz event tap when nil.
    ///   - secureInput: Whether Secure Event Input is on; `IsSecureEventInputEnabled()` when nil. It's asked on the
    ///     tap's thread, only when the tap key goes down or up.
    public init(
        tapKey: FnTapKeys.TapKey = .fn, source: (any EventSource)? = nil, secureInput: (@Sendable () -> Bool)? = nil
    ) {
        core = Core(tapKey: tapKey, secureInput: secureInput ?? { IsSecureEventInputEnabled() })
        self.source = source ?? SystemTap()
    }

    /// Installs the tap: active if the app may post events, else listen-only if it has Input Monitoring. Call it again
    /// once a permission has been granted: the tap is made again for the new permissions.
    @discardableResult
    public func start() -> Mode {
        source.stop()
        core.resetKeys()
        let core = self.core
        let mode = source.start { event in core.handle(event) }
        core.canSwallow = mode == .active
        self.mode = mode
        return mode
    }

    /// Removes the tap.
    public func stop() {
        source.stop()
        core.resetKeys()
        core.canSwallow = false
        mode = .off
    }
}

extension HotkeyTap {
    /// Where the key events come from: the Quartz event tap (SystemTap), or a fake in tests.
    public protocol EventSource: AnyObject {
        /// Starts sending key events to `handler`, on the source's own thread. The handler returns true when the event
        /// must not reach the app, which only an active tap can do. Returns how the source sees the keys.
        func start(_ handler: @escaping @Sendable (HotkeyTap.Event) -> Bool) -> HotkeyTap.Mode

        func stop()
    }

    /// A key event as the dictation keys see it.
    public struct Event: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case keyDown
            case keyUp
            /// A modifier key (Shift, Control, Option, Command, Caps Lock, Fn) went down or up.
            case flagsChanged
            /// A mouse button went down.
            case mouseDown
            /// A mouse button went up, such as at the end of an Option-drag.
            case mouseUp
            /// The person scrolled (not the scrolling that carries on after a flick), such as an Option-scroll zoom.
            case scroll
            /// A media or brightness key (a system-defined event) went down or up.
            case mediaKey(down: Bool)
            /// macOS turned the tap off (it took too long, or because of user input) and it was turned back on, so
            /// keys may have been missed.
            case tapReenabled
        }

        public var kind: Kind
        /// `kCGKeyboardEventKeycode`, for key and flags-changed events.
        public var keyCode: Int64
        /// The modifier flags, for key and flags-changed events.
        public var flags: CGEventFlags
        /// Posted by this app, like the ⌘V that types a dictation: never a dictation key. (Windows likewise ignores
        /// injected keys.)
        public var fromThisApp: Bool

        public init(_ kind: Kind, keyCode: Int64 = 0, flags: CGEventFlags = [], fromThisApp: Bool = false) {
            self.kind = kind
            self.keyCode = keyCode
            self.flags = flags
            self.fromThisApp = fromThisApp
        }

        /// Which key went down or up as far as FnTapKeys cares; nil for events the dictation keys ignore. A click or
        /// a scroll counts as another key going down.
        public var keyChange: (key: FnTapKeys.Key, down: Bool)? {
            let key: FnTapKeys.Key = keyCode == Code.escape ? .escape : .other
            switch kind {
            case .keyDown:
                return (key, true)
            case .keyUp:
                return (key, false)
            case .flagsChanged:
                return modifierChange
            case .mouseDown, .mouseUp, .scroll:
                return (FnTapKeys.Key.other, true)
            case .mediaKey(let down):
                return (FnTapKeys.Key.other, down)
            case .tapReenabled:
                return nil
            }
        }

        /// The tap key's own event: the flags-changed event for its key code.
        public func isChange(of tapKey: FnTapKeys.TapKey) -> Bool {
            kind == .flagsChanged && keyCode == (tapKey == .fn ? Code.function : Code.rightOption)
        }

        /// The flags of another key's event say the tap key is up. While a press is in progress, that means its
        /// release was lost. (Only key and flags-changed events carry the flags; a missing flag proves the key is up,
        /// while the Fn flag alone doesn't prove Fn is down, since arrows carry it too.)
        public func showsUp(_ tapKey: FnTapKeys.TapKey) -> Bool {
            switch kind {
            case .keyDown, .keyUp, .flagsChanged:
                guard !isChange(of: tapKey) else { return false }
                return tapKey == .fn ? !flags.contains(.maskSecondaryFn) : !rightOptionDown
            default:
                return false
            }
        }

        /// Flags-changed events say which modifier key changed (the key code), and the flags after the change.
        private var modifierChange: (key: FnTapKeys.Key, down: Bool)? {
            switch keyCode {
            case Code.function:
                return (FnTapKeys.Key.fn, flags.contains(.maskSecondaryFn))
            case Code.rightOption:
                return (FnTapKeys.Key.rightOption, rightOptionDown)
            case Code.command, Code.rightCommand:
                return (FnTapKeys.Key.other, flags.contains(.maskCommand))
            case Code.shift, Code.rightShift:
                return (FnTapKeys.Key.other, flags.contains(.maskShift))
            case Code.option:
                return (FnTapKeys.Key.other, flags.contains(.maskAlternate))
            case Code.control, Code.rightControl:
                return (FnTapKeys.Key.other, flags.contains(.maskControl))
            case Code.capsLock:
                // The flag is the Caps Lock light, not the key: every change is a press.
                return (FnTapKeys.Key.other, true)
            default:
                // Not a modifier key, such as an arrow that some keyboards report with the Fn flag.
                return nil
            }
        }

        /// Right Option's own bit when the keyboard says which Option key is down, else the Option flag.
        private var rightOptionDown: Bool {
            let sides = flags.rawValue & (Code.leftOptionBit | Code.rightOptionBit)
            return sides == 0 ? flags.contains(.maskAlternate) : (flags.rawValue & Code.rightOptionBit) != 0
        }

        /// Key codes from Carbon's HIToolbox/Events.h, and the device-dependent flags from IOKit's IOLLEvent.h.
        enum Code {
            static let escape: Int64 = 0x35 // kVK_Escape
            static let rightCommand: Int64 = 0x36 // kVK_RightCommand
            static let command: Int64 = 0x37 // kVK_Command
            static let shift: Int64 = 0x38 // kVK_Shift
            static let capsLock: Int64 = 0x39 // kVK_CapsLock
            static let option: Int64 = 0x3A // kVK_Option
            static let control: Int64 = 0x3B // kVK_Control
            static let rightShift: Int64 = 0x3C // kVK_RightShift
            static let rightOption: Int64 = 0x3D // kVK_RightOption
            static let rightControl: Int64 = 0x3E // kVK_RightControl
            static let function: Int64 = 0x3F // kVK_Function: Fn, 🌐 on newer keyboards
            static let leftOptionBit: UInt64 = 0x20 // NX_DEVICELALTKEYMASK
            static let rightOptionBit: UInt64 = 0x40 // NX_DEVICERALTKEYMASK
        }
    }
}

extension HotkeyTap {
    /// FnTapKeys behind a lock: events arrive on the tap's thread, while the setting, `isRecording` and the handler
    /// are set on the main thread. Commands go to the main queue in the order they happen.
    final class Core: @unchecked Sendable {
        private let lock = NSLock()
        private let secureInput: @Sendable () -> Bool
        private var keys: FnTapKeys
        private var enabled = true
        private var swallowing = false
        private var handler: (@MainActor (FnTapKeys.Command) -> Void)?

        init(tapKey: FnTapKeys.TapKey, secureInput: @escaping @Sendable () -> Bool) {
            keys = FnTapKeys(tapKey: tapKey)
            self.secureInput = secureInput
        }

        var onCommand: (@MainActor (FnTapKeys.Command) -> Void)? {
            get { locked { handler } }
            set { locked { handler = newValue } }
        }

        var isRecording: Bool {
            get { locked { keys.isRecording } }
            set { locked { keys.isRecording = newValue } }
        }

        var isEnabled: Bool {
            get { locked { enabled } }
            set {
                locked {
                    enabled = newValue
                    keys.reset()
                }
            }
        }

        var tapKey: FnTapKeys.TapKey {
            get { locked { keys.tapKey } }
            set { locked { keys.tapKey = newValue } }
        }

        /// The tap can keep events from the app (it's an active tap).
        var canSwallow: Bool {
            get { locked { swallowing } }
            set { locked { swallowing = newValue } }
        }

        func resetKeys() {
            locked { keys.reset() }
        }

        /// The tap's thread: runs the keys on `event`. True when the event must not reach the app.
        func handle(_ event: HotkeyTap.Event) -> Bool {
            guard !event.fromThisApp else { return false }
            // Only the tap key's own presses ask about Secure Input, outside the lock.
            let secure = event.isChange(of: tapKey) && secureInput()
            let result: FnTapKeys.Result = locked {
                guard enabled else { return FnTapKeys.Result() }
                if event.kind == .tapReenabled || event.showsUp(keys.tapKey) {
                    keys.reset()
                }

                guard let change = event.keyChange else { return FnTapKeys.Result() }
                var processed = keys.process(change.key, down: change.down, secureInput: secure)
                processed.swallow = processed.swallow && swallowing
                return processed
            }

            if let command = result.command {
                DispatchQueue.main.async { [self] in
                    MainActor.assumeIsolated {
                        if let onCommand = self.onCommand {
                            onCommand(command)
                        }
                    }
                }
            }

            return result.swallow
        }

        private func locked<Value>(_ body: () -> Value) -> Value {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }
}

extension HotkeyTap {
    /// The Quartz event tap at the session level, on a thread of its own.
    public final class SystemTap: EventSource {
        private var tap: TapThread?

        public init() {}

        deinit {
            tap?.stop()
        }

        public func start(_ handler: @escaping @Sendable (HotkeyTap.Event) -> Bool) -> HotkeyTap.Mode {
            stop()
            // tapCreate quietly drops the key events it isn't allowed to see (and would still return a tap for the
            // mouse ones), so the permissions decide which tap to try: an active tap needs the right to post events,
            // a listen-only one the right to listen (Input Monitoring).
            var modes: [HotkeyTap.Mode] = []
            if CGPreflightPostEventAccess() {
                modes.append(.active)
            }

            if CGPreflightListenEventAccess() {
                modes.append(.listenOnly)
            }

            for mode in modes {
                let tap = TapThread(active: mode == .active, handler: handler)
                if tap.start() {
                    self.tap = tap
                    return mode
                }
            }

            return .off
        }

        public func stop() {
            tap?.stop()
            tap = nil
        }
    }

    /// One event tap and the thread whose run loop it's on.
    final class TapThread: @unchecked Sendable {
        /// NX_SYSDEFINED in IOKit's IOLLEvent.h: among others, the media and brightness keys, which are the F-keys
        /// pressed with Fn when "Use F1, F2, etc. keys as standard function keys" is on.
        static let systemDefined: UInt32 = 14

        /// The events the keys need: mouse buttons and the scroll wheel too, since Option-click, Option-drag and
        /// Option-scroll are shortcuts.
        static let mask: CGEventMask = {
            let types: [CGEventType] = [
                .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp, .scrollWheel,
            ]
            return types.reduce(CGEventMask(1) << TapThread.systemDefined) { mask, type in
                mask | (CGEventMask(1) << type.rawValue)
            }
        }()

        private let active: Bool
        private let handler: @Sendable (HotkeyTap.Event) -> Bool
        private let started = DispatchSemaphore(value: 0)
        private let finished = DispatchSemaphore(value: 0)
        // Set on the tap's thread before `started` is signalled; only read after that.
        private var port: CFMachPort?
        private var runLoop: CFRunLoop?

        init(active: Bool, handler: @escaping @Sendable (HotkeyTap.Event) -> Bool) {
            self.active = active
            self.handler = handler
        }

        /// Makes the tap on a new thread; false when macOS refused it.
        func start() -> Bool {
            let thread = Thread { [self] in
                run()
            }
            thread.name = "ThumbFree dictation keys"
            thread.qualityOfService = .userInteractive
            thread.start()
            started.wait()
            return port != nil
        }

        /// Removes the tap and ends its thread.
        func stop() {
            guard let runLoop else { return }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
                // Off first: an active tap that stops answering would hold up every key until macOS gives up on it.
                if let port {
                    CGEvent.tapEnable(tap: port, enable: false)
                }

                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            CFRunLoopWakeUp(runLoop)
            finished.wait()
            self.runLoop = nil
        }

        private func run() {
            let callback: CGEventTapCallBack = { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                return Unmanaged<TapThread>.fromOpaque(info).takeUnretainedValue().handle(type, event)
            }

            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: active ? .defaultTap : .listenOnly,
                eventsOfInterest: TapThread.mask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
            else {
                started.signal()
                return
            }

            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                CFMachPortInvalidate(port)
                started.signal()
                return
            }

            let runLoop = CFRunLoopGetCurrent()
            self.port = port
            self.runLoop = runLoop
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            started.signal()
            CFRunLoopRun()

            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(port)
            finished.signal()
        }

        /// The tap's thread.
        private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
            autoreleasepool { () -> Unmanaged<CGEvent>? in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let port {
                        CGEvent.tapEnable(tap: port, enable: true)
                    }

                    _ = handler(HotkeyTap.Event(.tapReenabled))
                    return Unmanaged.passUnretained(event)
                }

                guard let keyEvent = HotkeyTap.Event(type: type, event: event) else {
                    return Unmanaged.passUnretained(event)
                }

                return handler(keyEvent) && active ? nil : Unmanaged.passUnretained(event)
            }
        }
    }
}

extension HotkeyTap.Event {
    /// The event as the dictation keys see it; nil for the events they ignore.
    init?(type: CGEventType, event: CGEvent) {
        let fromThisApp = event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid())
        switch type {
        case .keyDown:
            self.init(.keyDown, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
                      fromThisApp: fromThisApp)
        case .keyUp:
            self.init(.keyUp, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
                      fromThisApp: fromThisApp)
        case .flagsChanged:
            self.init(.flagsChanged, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
                      fromThisApp: fromThisApp)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            self.init(.mouseDown, fromThisApp: fromThisApp)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            self.init(.mouseUp, fromThisApp: fromThisApp)
        case .scrollWheel:
            // The scrolling that carries on after a trackpad flick isn't the person's doing: a tap right after it
            // still counts.
            guard event.getIntegerValueField(.scrollWheelEventMomentumPhase) == 0 else { return nil }
            self.init(.scroll, fromThisApp: fromThisApp)
        default:
            // Media keys are system-defined events of subtype 8 (NX_SUBTYPE_AUX_CONTROL_BUTTONS); data1 holds the
            // key in its high 16 bits and its state in bits 8 to 15: 0xA down, 0xB up.
            guard type.rawValue == HotkeyTap.TapThread.systemDefined, let media = NSEvent(cgEvent: event),
                  media.type == .systemDefined, media.subtype.rawValue == 8
            else { return nil }
            self.init(.mediaKey(down: (media.data1 & 0xFF00) >> 8 == 0xA), fromThisApp: fromThisApp)
        }
    }
}
