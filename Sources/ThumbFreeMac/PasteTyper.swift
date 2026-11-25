import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Types text by pasting it, which every app takes in one go, as thumbfree-windows `ClipboardPaste` does (docs/mac.md,
/// "Pasting"). The text goes on the pasteboard marked so clipboard managers leave it out and Universal Clipboard keeps
/// it on this Mac, ⌘V goes out once held modifier keys are let go, and what was on the pasteboard goes back afterwards,
/// unless something new was copied meanwhile. When what's there can't be read to put it back (macOS asks each time or
/// never allows it, or the app it came from has quit), the text is typed with keys instead, so that copy is never lost
/// (`whenUnreadable`). Sending keys needs the permission to post events (`Permissions.Kind.postEvents`). Each call
/// blocks (up to a second for held keys, then `restoreDelay`): use it off the main thread, one call at a time, and keep
/// the main thread free meanwhile, as secure input is asked there.
public final class PasteTyper {
    /// How many times the text goes on the pasteboard when something else was copied before ⌘V.
    static let maxPuts = 2

    /// Typing with keys: the most UTF-16 units a key event carries. Apple documents no limit, but a key event types
    /// only its first 20.
    static let unitsPerKey = 20

    /// The pause between those key events, as Windows types (TypingDelayMs): some apps drop fast bursts.
    static let keyPause: TimeInterval = 0.008

    /// How long the app gets to read the pasteboard before it's put back (Windows: RestoreDelayMs).
    public var restoreDelay: TimeInterval = 0.35

    /// How long a paste waits for held modifier keys to be let go, and how often it looks.
    public var modifierTimeout: TimeInterval = 1
    static let modifierPoll: TimeInterval = 0.015

    /// When what's on the pasteboard can't be read to put it back: type the text with keys (the default), or paste it
    /// all the same, replacing that copy.
    public var whenUnreadable = Unreadable.typeWithKeys

    /// How `paste` puts text in: through the pasteboard (the default), or always with key events, as Windows' "Type"
    /// insert method does (some apps drop characters typed that way, but the pasteboard is never touched).
    public var insertMethod = InsertMethod.paste

    private let pasteboard: Pasteboard
    private let keys: Keys
    private let sleep: (TimeInterval) -> Void
    private let now: () -> TimeInterval

    /// NSPasteboard.general and the keyboard (CGEvent), or fakes in tests.
    public init(
        pasteboard: Pasteboard = SystemPasteboard(),
        keys: Keys = SystemKeys(),
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.pasteboard = pasteboard
        self.keys = keys
        self.sleep = sleep
        self.now = now
    }

    /// Pastes `text` (line breaks become spaces: `type` presses the app's new-line keys for them). `beforeKeys` runs
    /// last before ⌘V, after the pasteboard holds the text and held modifier keys are let go; if it throws, nothing is
    /// pasted, the pasteboard goes back, and the error is thrown. Something copied before ⌘V (⌘C while the paste
    /// waits for ⌘ to be let go) is kept: it's what goes back afterwards, the text goes on the pasteboard again and is
    /// checked again, and nothing is pasted if the pasteboard keeps changing (`Failure.pasteboardKeptChanging`). A
    /// pasteboard that can't be read is left alone and the text typed with keys (`whenUnreadable`). With `insertMethod`
    /// `.typeWithKeys`, the text is always typed with keys, after the same checks.
    public func paste(_ text: String, beforeKeys: () throws -> Void = {}) throws {
        let text = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        if insertMethod == .typeWithKeys {
            try typeWithKeys(text, beforeKeys: beforeKeys)
            return
        }

        var put = 1
        while true {
            let saved = saveIfReadable()
            let replacing = saved == .unreadable
            if replacing, whenUnreadable == .typeWithKeys {
                try typeWithKeys(text, beforeKeys: beforeKeys)
                return
            }

            let ours: Int
            do {
                ours = try pasteboard.write(text)
            } catch {
                if !replacing {
                    pasteboard.restore(saved)
                }

                throw error
            }

            let unchanged: Bool
            do {
                try beforeTheKeys(beforeKeys)
                unchanged = pasteboard.changeCount == ours
                if unchanged {
                    try keys.post(keys.pasteChord)
                }
            } catch {
                if !replacing {
                    putBack(saved, unlessChangedSince: ours)
                }

                throw error
            }

            if unchanged {
                if !replacing {
                    sleep(restoreDelay)
                    putBack(saved, unlessChangedSince: ours)
                }

                return
            }

            // Something was copied while the paste waited: that's what goes back, and the text goes on again.
            if put == Self.maxPuts {
                throw Failure.pasteboardKeptChanging
            }

            put += 1
        }
    }

    /// Presses `chord` once held modifier keys are let go and `beforeKeys` has run without throwing.
    public func press(_ chord: Chord, beforeKeys: () throws -> Void = {}) throws {
        try beforeTheKeys(beforeKeys)
        try keys.post(chord)
    }

    /// Types `text` with its line breaks as `newLine`, the app's new-line keys (⇧↩ in chat apps, where ↩ sends): each
    /// line is pasted (or typed with keys) and `newLine` pressed between lines, each after `beforeKeys`, as
    /// DictationInserter types on Windows.
    public func type(_ text: String, newLine: Chord, beforeKeys: () throws -> Void = {}) throws {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if index > 0 {
                try press(newLine, beforeKeys: beforeKeys)
            }

            if !line.isEmpty {
                try paste(String(line), beforeKeys: beforeKeys)
            }
        }
    }

    /// Waits (`modifierTimeout` at most) until ⌘, ⌥, ⌃, ⇧ and Fn are let go, so ⌘V or the new-line keys aren't combined
    /// with keys still held from the dictation key or a shortcut. Then the keys go out anyway, as on Windows.
    public func waitForModifiersReleased() {
        let deadline = now() + modifierTimeout
        while modifiersDown, now() < deadline {
            sleep(Self.modifierPoll)
        }
    }

    /// ⌘, ⌥, ⌃, ⇧ or Fn is held now.
    public var modifiersDown: Bool { !keys.heldModifiers.isEmpty }

    /// What macOS lets ThumbFree do with the pasteboard, for the guide to explain: once macOS has asked, dictations
    /// are typed with keys until you choose Allow for ThumbFree in System Settings (Privacy & Security).
    public var pasteboardAccess: PasteboardAccess { pasteboard.access }

    /// Whether the pasteboard is read, to put it back afterwards: only when that doesn't ask you each time. Before
    /// macOS 15.4, with Always Allow, and before macOS has ever asked (it may then ask once), it is; when macOS asks
    /// each time or always denies, it isn't read at all, and the text is typed with keys.
    static func maySave(_ access: PasteboardAccess) -> Bool {
        switch access {
        case .unrestricted, .default, .alwaysAllow: return true
        case .ask, .alwaysDeny: return false
        }
    }

    /// `text` in pieces of at most `limit` UTF-16 units, each of whole characters; a character longer than that (a
    /// long run of combining marks) is cut between its Unicode scalars, never inside one.
    static func pieces(of text: String, unitsEach limit: Int) -> [String] {
        var pieces: [String] = []
        var piece = String.UnicodeScalarView()
        var units = 0
        for character in text {
            let length = character.utf16.count
            if units + length > limit, !piece.isEmpty {
                pieces.append(String(piece))
                piece = String.UnicodeScalarView()
                units = 0
            }

            if length <= limit {
                piece.append(contentsOf: character.unicodeScalars)
                units += length
                continue
            }

            for scalar in character.unicodeScalars {
                if units + UTF16.width(scalar) > limit {
                    pieces.append(String(piece))
                    piece = String.UnicodeScalarView()
                    units = 0
                }

                piece.append(scalar)
                units += UTF16.width(scalar)
            }
        }

        if !piece.isEmpty {
            pieces.append(String(piece))
        }

        return pieces
    }

    /// Types `text` with key events that carry it (`Keys.type`), `unitsPerKey` UTF-16 units at a time, once held
    /// modifier keys are let go and `beforeKeys` has passed, as before ⌘V. Secure input is checked again before each
    /// key, as a long line takes a while. The pasteboard isn't touched.
    private func typeWithKeys(_ text: String, beforeKeys: () throws -> Void) throws {
        try beforeTheKeys(beforeKeys)
        for (index, piece) in Self.pieces(of: text, unitsEach: Self.unitsPerKey).enumerated() {
            if index > 0 {
                sleep(Self.keyPause)
                try checkSecureInput()
            }

            try keys.type(piece)
        }
    }

    /// What happens right before keys go out: held modifier keys are let go, the caller's check runs, and secure input
    /// is checked.
    private func beforeTheKeys(_ check: () throws -> Void) throws {
        waitForModifiersReleased()
        try check()
        try checkSecureInput()
    }

    /// Nothing goes out while a password is being typed somewhere (secure input), or while that can't be told.
    private func checkSecureInput() throws {
        switch keys.secureInput {
        case .off:
            return
        case .on:
            throw Failure.secureInput
        case .unknown:
            throw Failure.secureInputUnknown
        }
    }

    /// What's on the pasteboard, to put back, or `.unreadable` when it may not be read (`maySave`). When this read was
    /// the first macOS asked you about (the access was `.default` and isn't any more) and it found nothing, the answer
    /// may have been Don't Allow, which can look like an empty pasteboard: it counts as unreadable, so a copy that
    /// couldn't be seen is never emptied.
    private func saveIfReadable() -> Saved {
        let access = pasteboard.access
        guard Self.maySave(access) else { return .unreadable }
        let saved = pasteboard.save()
        if access == .default, saved == .empty, pasteboard.access != .default {
            return .unreadable
        }

        return saved
    }

    private func putBack(_ saved: Saved, unlessChangedSince ours: Int) {
        if pasteboard.changeCount == ours {
            pasteboard.restore(saved)
        }
    }
}

extension PasteTyper {
    /// The pasteboard as the typer uses it: NSPasteboard.general (`SystemPasteboard`), faked in tests.
    public protocol Pasteboard: AnyObject {
        /// Goes up whenever anything is copied.
        var changeCount: Int { get }

        /// What macOS lets ThumbFree do with the pasteboard (pasteboard privacy, macOS 15.4 and later).
        var access: PasteboardAccess { get }

        /// Every item and every type of each that can be read, to put back.
        func save() -> Saved

        /// Replaces what's there with `text`, marked for clipboard managers, and returns `changeCount` after.
        func write(_ text: String) throws -> Int

        /// Puts back what `save` found: an empty pasteboard is emptied again, and an unreadable one never touched.
        func restore(_ saved: Saved)
    }

    /// What `Pasteboard.save` found.
    public enum Saved: Equatable, Sendable {
        case empty
        case items(Contents)
        /// Something whose data couldn't be read: macOS didn't allow it, or the app it came from has quit.
        case unreadable
    }

    /// What macOS lets ThumbFree do with the pasteboard: NSPasteboard.AccessBehavior (macOS 15.4 and later), which you
    /// can change in System Settings once macOS has asked. For the guide to explain.
    public enum PasteboardAccess: Equatable, Sendable {
        /// Before macOS 15.4: any app reads the pasteboard.
        case unrestricted
        /// macOS hasn't asked yet: it asks the first time ThumbFree reads the pasteboard, then turns this to `ask`.
        case `default`
        /// macOS asks each time ThumbFree reads the pasteboard.
        case ask
        case alwaysAllow
        /// macOS never lets ThumbFree read the pasteboard (pasting still works).
        case alwaysDeny
    }

    /// What `paste` does when the pasteboard can't be read to put it back.
    public enum Unreadable: Equatable, Sendable {
        /// Types the text with key events, leaving the pasteboard alone.
        case typeWithKeys
        /// Pastes the text all the same: it replaces what was on the pasteboard.
        case pasteAndReplace
    }

    /// How `paste` puts text in (the insertMethod setting: "Paste" or "Type").
    public enum InsertMethod: Equatable, Sendable {
        /// Through the pasteboard, which is put back afterwards (or with keys when it can't be read).
        case paste
        /// Always with key events, leaving the pasteboard alone.
        case typeWithKeys
    }

    /// The keyboard as the typer uses it: CGEvent (`SystemKeys`), faked in tests.
    public protocol Keys: AnyObject {
        /// The modifier keys held now.
        var heldModifiers: Modifiers { get }

        /// IsSecureEventInputEnabled(): whether a password is being typed somewhere, or that couldn't be told.
        var secureInput: FocusedField.SecureInput { get }

        /// ⌘V in the keyboard layout in use.
        var pasteChord: Chord { get }

        /// Presses and lets go of `chord`.
        func post(_ chord: Chord) throws

        /// Presses and lets go of a key that types `characters` (at most `PasteTyper.unitsPerKey` UTF-16 units),
        /// whatever the keyboard layout.
        func type(_ characters: String) throws
    }

    /// What was on the pasteboard: each item's types and data, in order.
    public struct Contents: Equatable, Sendable {
        public struct Representation: Equatable, Sendable {
            public var type: String
            public var data: Data

            public init(type: String, data: Data) {
                self.type = type
                self.data = data
            }
        }

        public var items: [[Representation]]

        public init(items: [[Representation]]) {
            self.items = items
        }

        /// Marked confidential (a password manager's copy): it's put back for this Mac only, kept from Universal
        /// Clipboard as such apps keep it.
        var isConcealed: Bool {
            items.joined().contains { Self.concealedTypes.contains($0.type) }
        }

        static let concealedTypes: Set<String> = ["org.nspasteboard.ConcealedType", "com.agilebits.onepassword"]
    }

    /// Modifier keys.
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
        /// Fn (🌐), ThumbFree's dictation key.
        public static let function = Modifiers(rawValue: 1 << 4)
    }

    /// A key and the modifier keys held with it, such as ⇧↩.
    public struct Chord: Hashable, Sendable {
        /// The key's virtual key code (kVK_Return…): where it is on the keyboard, not what it types.
        public var key: CGKeyCode
        public var modifiers: Modifiers

        public init(key: CGKeyCode, modifiers: Modifiers = []) {
            self.key = key
            self.modifiers = modifiers
        }

        /// ↩: a line break in editors.
        public static let returnKey = Chord(key: CGKeyCode(kVK_Return))

        /// ⇧↩: a line break in chat apps, where ↩ sends (Windows' default new-line keys, Shift+Enter).
        public static let shiftReturn = Chord(key: CGKeyCode(kVK_Return), modifiers: .shift)

        /// Keys as settings write them, like Windows' new-line keys: "Shift+Return", "Enter", "Cmd+Return". Modifiers
        /// are Shift, Ctrl (Control), Option (Alt) and Cmd (Command); keys are Return (Enter), Tab, Space, Esc, Delete
        /// (Backspace), ForwardDelete, Home, End, PageUp, PageDown, the arrows (Up, Down, Left, Right) and F1 to F20.
        /// Case and spaces don't matter. Nil for anything else, or for more or fewer than one key: letters and digits
        /// aren't taken, since where they are depends on the keyboard layout.
        public init?(_ text: String) {
            var key: CGKeyCode?
            var modifiers: Modifiers = []
            for part in text.split(separator: "+") {
                let name = part.trimmingCharacters(in: .whitespaces).lowercased()
                if name.isEmpty {
                    continue
                }

                if let modifier = Self.modifierNames[name] {
                    modifiers.insert(modifier)
                } else if let code = Self.keyNames[name], key == nil {
                    key = code
                } else {
                    return nil
                }
            }

            guard let key else { return nil }
            self.init(key: key, modifiers: modifiers)
        }

        private static let modifierNames: [String: Modifiers] = [
            "shift": .shift, "ctrl": .control, "control": .control, "option": .option, "opt": .option, "alt": .option,
            "cmd": .command, "command": .command,
        ]

        private static let keyNames: [String: CGKeyCode] = {
            var names: [String: Int] = [
                "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "space": kVK_Space, "esc": kVK_Escape,
                "escape": kVK_Escape, "delete": kVK_Delete, "backspace": kVK_Delete, "forwarddelete": kVK_ForwardDelete,
                "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown, "up": kVK_UpArrow,
                "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            ]
            let functionKeys = [
                kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
                kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
            ]
            for (index, code) in functionKeys.enumerated() {
                names["f\(index + 1)"] = code
            }

            return names.mapValues { CGKeyCode($0) }
        }()
    }

    /// Why nothing was typed. Messages that name the app name the one they run in (`ThumbFreeMac.appName`).
    public enum Failure: Error, Equatable, LocalizedError {
        /// Something kept being copied while the paste waited.
        case pasteboardKeptChanging
        /// The text couldn't be put on the pasteboard.
        case pasteboardUnavailable
        /// The app may not send keys: it hasn't the permission to (`permission`).
        case notAllowed
        /// A password is being typed somewhere (secure input is on).
        case secureInput
        /// Whether a password is being typed couldn't be told (`FocusedField.SecureInput.unknown`).
        case secureInputUnknown
        /// The key events couldn't be made.
        case keysUnavailable

        /// The permission that's missing, for the host to ask for or open in System Settings (`Permissions`).
        public var permission: Permissions.Kind? {
            self == .notAllowed ? .postEvents : nil
        }

        public var errorDescription: String? { message(naming: ThumbFreeMac.appName) }

        /// The message, with `app` as the app's name.
        func message(naming app: String) -> String {
            switch self {
            case .pasteboardKeptChanging:
                return "The pasteboard kept changing, so nothing was pasted."
            case .pasteboardUnavailable:
                return "The text couldn't be put on the pasteboard."
            case .notAllowed:
                return "\(app) may not type: it needs the Accessibility permission."
            case .secureInput:
                return "A password is being typed, so nothing was typed."
            case .secureInputUnknown:
                return "\(app) couldn't tell whether a password is being typed, so nothing was typed."
            case .keysUnavailable:
                return "The keys couldn't be sent."
            }
        }
    }
}
