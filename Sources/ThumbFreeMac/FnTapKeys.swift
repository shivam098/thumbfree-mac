/// Tap-to-dictate keys, kept apart from the event tap (HotkeyTap) so they can be tested. Tap Fn (🌐), or Right Option
/// when that's the chosen key, to start recording: press it and let go with no other key in between. Tap it again to
/// finish. Both happen when the key is let go, so it never has to be held, and no modifier is down when typing starts.
/// Esc cancels while recording.
///
/// The key pressed together with another key, a modifier, a mouse button or the scroll wheel is a macOS shortcut
/// (Fn+arrows, Fn+Delete, Fn+F-keys, Fn+E for emoji, Option+letters, Option-click, Option-drag, Option-scroll): it
/// starts nothing, and while recording it neither finishes nor cancels. Under Secure Input the other keys are hidden,
/// so a press there never starts dictation but says why (see `process`), and Esc can't cancel.
///
/// The port of thumbfree-windows `TapToDictateKeys` (Ctrl+Win), with one change: Windows starts as soon as the keys go
/// down, so the first words aren't lost, and cancels when they turn out to be a shortcut. Fn and Option are in everyday
/// Mac shortcuts (Fn+Delete, Fn+arrows), and starting on the press would turn the microphone on and off for each one,
/// so here a press only counts once it's let go.
public struct FnTapKeys: Sendable {
    /// The key that starts and finishes dictation (a setting).
    public enum TapKey: String, CaseIterable, Sendable {
        /// Fn, or 🌐 on newer keyboards: the default.
        case fn
        /// Right Option, for a keyboard whose Fn key macOS doesn't see, or when Fn already does something else.
        case rightOption

        /// The key's name in settings.json ("dictationKey"), ThumbFree's and Jarvis's alike: "Fn" or "RightOption".
        /// Settings files keep it, so it never changes.
        public var settingsName: String {
            switch self {
            case .fn: return "Fn"
            case .rightOption: return "RightOption"
            }
        }
    }

    /// A key as far as the dictation keys care.
    public enum Key: Equatable, Sendable {
        case fn
        case rightOption
        case escape
        /// Any other key, modifier or media key, a mouse button going down or up, or the scroll wheel.
        case other
    }

    /// What a key event asks dictation to do.
    public enum Command: Equatable, Sendable {
        /// Start recording.
        case start
        /// Stop recording, then transcribe and type.
        case finish
        /// Stop recording and throw it away (Esc).
        case cancel
    }

    /// What kept a tap of the key from starting dictation, so the host can say why nothing happened.
    public enum Blocker: Equatable, Sendable {
        /// Secure Input was on, so the tap may have been a shortcut whose other key macOS hid (see `process`).
        case secureInput
    }

    public struct Result: Equatable, Sendable {
        /// What dictation should do; nil for nothing.
        public var command: Command?
        /// True when the key must not reach the focused app: the Esc that cancels.
        public var swallow: Bool
        /// What kept what looked like a tap from starting dictation; nil when nothing did.
        public var blocked: Blocker?

        public init(_ command: Command? = nil, swallow: Bool = false, blocked: Blocker? = nil) {
            self.command = command
            self.swallow = swallow
            self.blocked = blocked
        }
    }

    /// The key that starts and finishes dictation. Changing it forgets a press in progress.
    public var tapKey: TapKey {
        didSet { reset() }
    }

    /// True from `start` until `finish` or `cancel`. The host clears it when a recording stops on its own (an error,
    /// the time limit).
    public var isRecording = false

    /// The tap key is down.
    private var held = false
    /// The tap key went down while recording, so letting it go finishes.
    private var finishing = false
    /// Another key went down while the tap key was down: a shortcut, not a tap.
    private var usedWithOtherKey = false
    /// Secure Event Input was on when the tap key went down.
    private var secureAtPress = false

    public init(tapKey: TapKey = .fn) {
        self.tapKey = tapKey
    }

    /// Forgets any key in progress (the tap was paused, or missed events); `isRecording` is unchanged.
    public mutating func reset() {
        held = false
        finishing = false
        usedWithOtherKey = false
        secureAtPress = false
    }

    /// - Parameters:
    ///   - key: The key that went down or up.
    ///   - down: True when it went down, false when it went up.
    ///   - secureInput: Secure Event Input is on (a password field, Terminal's Secure Keyboard Entry, a password
    ///     manager, the lock screen), which any app can leave on, even in the background. macOS then hides key-downs
    ///     from event taps but not modifier keys, so a press of the tap key can't be told from a shortcut (Fn+↑,
    ///     Fn+Delete, Option+letter). On when the key goes down or when it's let go, the press never starts dictation;
    ///     it still finishes one, which is always safe. What would have started gives `blocked: .secureInput`
    ///     instead, and so does a shortcut hidden this way, since it can't be told from a tap.
    public mutating func process(_ key: Key, down: Bool, secureInput: Bool = false) -> Result {
        if isTapKey(key) {
            return down ? press(secureInput: secureInput) : release(secureInput: secureInput)
        }

        if down && held {
            usedWithOtherKey = true
            return Result()
        }

        if key == .escape && down && isRecording {
            isRecording = false
            return Result(.cancel, swallow: true)
        }

        return Result()
    }

    /// Whether `key` is the one that starts and finishes dictation.
    public func isTapKey(_ key: Key) -> Bool {
        switch (key, tapKey) {
        case (.fn, .fn), (.rightOption, .rightOption):
            return true
        default:
            return false
        }
    }

    private mutating func press(secureInput: Bool) -> Result {
        // Modifier keys don't repeat, so a press while the key is already down means its release was lost (a user
        // switch, another tap keeping it): this is a new press.
        held = true
        finishing = isRecording
        usedWithOtherKey = false
        secureAtPress = secureInput
        return Result()
    }

    private mutating func release(secureInput: Bool) -> Result {
        guard held else { return Result() }
        held = false
        if usedWithOtherKey {
            return Result()
        }

        if finishing {
            // A recording that stopped on its own while the key was down isn't finished twice.
            guard isRecording else { return Result() }
            isRecording = false
            return Result(.finish)
        }

        // A recording that started some other way while the key was down isn't started twice.
        guard !isRecording else { return Result() }
        // Under Secure Input the other keys of a shortcut are hidden, so this may not have been a tap.
        guard !secureAtPress, !secureInput else { return Result(blocked: .secureInput) }
        isRecording = true
        return Result(.start)
    }
}
