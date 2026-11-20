/// A top-level window: which app it belongs to and its title.
public struct WindowInfo: Equatable, Sendable {
    public var handle: Int
    public var processId: Int
    public var processName: String
    public var title: String

    public init(handle: Int, processId: Int, processName: String, title: String) {
        self.handle = handle
        self.processId = processId
        self.processName = processName
        self.title = title
    }
}

public enum FieldCheck: Sendable {
    /// Positively confirmed not to be a password field.
    case safe

    case password

    /// The window runs as administrator; Windows silently drops synthesized input to it.
    case elevated

    /// Accessibility query failed or timed out.
    case unknown
}

public enum StatusKind: Sendable {
    case info
    case success
    case warning
    case error
}

public struct StatusUpdate: Equatable, Sendable {
    public var kind: StatusKind
    public var message: String
    public var heard: String?

    public init(_ kind: StatusKind, _ message: String, heard: String? = nil) {
        self.kind = kind
        self.message = message
        self.heard = heard
    }
}

/// Operating-system side effects needed to insert text: Accessibility and the pasteboard on the Mac, faked in tests.
public protocol Desktop: AnyObject {
    func foregroundWindow() -> WindowInfo?

    func checkFocusedField() -> FieldCheck

    /// True if the focused text field ends in a non-space character (so a leading space is needed); nil if unknown.
    func focusedTextEndsWithNonWhitespace() -> Bool?

    func typeText(_ text: String)

    func pressKeys(_ chord: String)
}

/// Formats dictated speech and inserts it where the cursor is. The key press that started dictation is the user's
/// consent, so only password fields and administrator windows are refused. Spacing, continuing a sentence and the field
/// rules are the ones every platform shares (`Insertion`, `LiveTyping`); typing, line breaks as each app's new-line
/// keys and the refusals are the platform's own.
public final class DictationInserter {
    public static let defaultNewLineKeys = "Shift+Enter"

    private static let passwordRefusal = "That's a password field — I won't type there."

    private let desktop: any Desktop
    private let formatter: DictationFormatter
    private let newLineKeys: [[Unicode.Scalar]: String]

    /// - Parameter newLineKeysByProcess: Keys for a line break per process name, in any case (editors: Enter). Others
    ///   get Shift+Enter, which chat apps treat as a new line instead of “send”.
    public init(_ desktop: any Desktop, _ formatter: DictationFormatter, newLineKeysByProcess: [String: String] = [:]) {
        self.desktop = desktop
        self.formatter = formatter
        var newLineKeys: [[Unicode.Scalar]: String] = [:]
        for (process, keys) in newLineKeysByProcess {
            newLineKeys[DotNet.ordinalIgnoreCase(process)] = keys
        }

        self.newLineKeys = newLineKeys
    }

    /// Problems, and what was typed, for the pill (C#'s `Status` event).
    public var onStatus: ((StatusUpdate) -> Void)?

    /// The last dictation, for “paste last dictation”, without the space that joined it to the text before. Kept only
    /// in memory. After a dictation typed live, set it to `LiveTyping.text`.
    public var lastText: String?

    /// Formats the transcript and inserts it at the cursor. Returns false if nothing was inserted.
    /// - Parameters:
    ///   - transcript: What was said (word list already applied).
    ///   - context: The field and the text before the cursor, as found when dictation started. With it the whole shared
    ///     pipeline runs, exactly as `LiveTyping` finishes a dictation that wasn't typed live: continuing the sentence,
    ///     smart formatting, the field's rules (no line breaks in single-line boxes, no full stop in search boxes) and
    ///     spacing. Without it only the formatter runs and the field is treated as multi-line.
    @discardableResult
    public func insert(_ transcript: String, _ context: LiveTypingContext? = nil) -> Bool {
        let heard = TranscriptText.clean(transcript)
        if context?.field.password == true {
            report(.warning, Self.passwordRefusal, heard)
            return false
        }

        let text: String
        let remembered: String
        if var context {
            context.live = false
            let typing = LiveTyping(formatter, context)
            text = typing.finish([transcript])
            remembered = typing.text
        } else {
            text = formatter.format(transcript)
            remembered = text
        }

        if text.isEmpty {
            report(.info, "I didn't catch anything to type.")
            return false
        }

        if !typeOut(text, addSpace: context?.textBefore == nil, heard: heard) {
            return false
        }

        lastText = remembered
        report(.success, "Typed.", heard)
        return true
    }

    /// Types text that is already final, such as a piece from `LiveTyping` (formatted and spaced): line breaks become
    /// the app's new-line keys. The same refusals as `insert`, also when `field` says it's a password field, but only
    /// problems are reported, so the pill isn't flooded while speaking. Returns false if nothing was typed.
    @discardableResult
    public func typePrepared(_ text: String, _ field: FieldInfo? = nil) -> Bool {
        if field?.password == true {
            report(.warning, Self.passwordRefusal)
            return false
        }

        return !text.isEmpty && typeOut(text, addSpace: false, heard: nil)
    }

    /// Inserts the last dictated text again.
    @discardableResult
    public func repeatLast() -> Bool {
        guard let last = lastText, !last.isEmpty else {
            report(.info, "There's no previous dictation yet.")
            return false
        }

        if !typeOut(last, addSpace: true, heard: nil) {
            return false
        }

        report(.success, "Typed.")
        return true
    }

    private func typeOut(_ text: String, addSpace: Bool, heard: String?) -> Bool {
        guard let window = desktop.foregroundWindow() else {
            report(.warning, "There's no window to type into.", heard)
            return false
        }

        let refusal: String?
        switch desktop.checkFocusedField() {
        case .password: refusal = Self.passwordRefusal
        case .elevated: refusal = "That window runs as administrator; Windows won't let me type into it."
        case .safe, .unknown: refusal = nil
        }

        if let refusal {
            report(.warning, refusal, heard)
            return false
        }

        // Only whether the field ends in a word is known here: a space goes before anything that doesn't attach to it.
        var text = text
        if addSpace && desktop.focusedTextEndsWithNonWhitespace() == true && !Insertion.joinsDirectly(text) {
            text = " " + text
        }

        let newLine = newLineKeys[DotNet.ordinalIgnoreCase(window.processName)] ?? Self.defaultNewLineKeys
        for (i, part) in DotNet.split(text, ["\n"]).enumerated() {
            if i > 0 {
                desktop.pressKeys(newLine)
            }

            if !part.isEmpty {
                desktop.typeText(part)
            }
        }

        return true
    }

    private func report(_ kind: StatusKind, _ message: String, _ heard: String? = nil) {
        onStatus?(StatusUpdate(kind, message, heard: heard))
    }
}
