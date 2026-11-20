/// The text field a dictation goes into, read once when dictation starts. The Mac fills it from Accessibility, Windows
/// from UI Automation and Android from the field's input type. The defaults describe a plain single-line box.
public struct FieldInfo: Equatable, Sendable {
    /// A password or other secure field: never typed into (live typing holds it all, `DictationInserter` refuses).
    public var password: Bool

    /// A search or address box: no trailing full stop, and no smart formatting.
    public var search: Bool

    /// Accepts line breaks. Elsewhere a spoken "new line" becomes a space, since Return would send or search.
    public var multiLine: Bool

    /// A private (incognito) browser window: no voice samples are kept from it.
    public var `private`: Bool

    /// An email app or a webmail compose box: a greeting or a sign-off alone is enough for email layout, so live typing
    /// holds a dictation that starts with a greeting.
    public var email: Bool

    public init(
        password: Bool = false,
        search: Bool = false,
        multiLine: Bool = false,
        `private`: Bool = false,
        email: Bool = false
    ) {
        self.password = password
        self.search = search
        self.multiLine = multiLine
        self.private = `private`
        self.email = email
    }
}

/// How dictated text joins what is already in the field. Same rules as the Android and Windows apps. Line ends in the
/// text before the cursor count as \n whichever way the app reports them (see `normalizeLineEnds`).
public enum Insertion {
    // Text starting with one of these attaches to the word before it (", right?").
    private static let attachesToPrevious: Set<Unicode.Scalar> = [",", ".", ";", ":", "!", "?", ")", "\n"]

    // After one of these the next word follows directly ("(see", "@mail", "#tag", "/path").
    private static let attachesToNext: Set<Unicode.Scalar> = ["(", "[", "{", "\"", "'", "“", "‘", "/", "@", "#"]

    /// The text before the cursor doesn't end a sentence (so "And then…" continues as "and then…").
    public static func continuesSentence(_ before: String?) -> Bool {
        guard let before, let last = before.unicodeScalars.last,
              let trimmedLast = DotNet.trimEnd(before).unicodeScalars.last
        else {
            return false
        }

        return trimmedLast != "." && trimmedLast != "!" && trimmedLast != "?" && !isLineEnd(last)
    }

    /// The text to type: with a leading space when it would otherwise run into the previous word. Text that starts with
    /// whitespace already has its space.
    public static func withSpacing(_ before: String?, _ text: String) -> String {
        guard !text.isEmpty, let last = before?.unicodeScalars.last else { return text }
        let needsSpace = !DotNet.isWhiteSpace(last) && !attachesToNext.contains(last) && !joinsDirectly(text)
        return needsSpace ? " " + text : text
    }

    /// Line breaks typed into a single-line box would trigger its action (send, search): spaces there.
    public static func forField(_ text: String, _ field: FieldInfo) -> String {
        field.multiLine ? text : lineBreaksRegex.replace(text, " ")
    }

    /// Line ends as \n. Apps report them as \r\n or \r, Word's line break (Shift+Enter) as \v, and some as the Unicode
    /// line and paragraph separators.
    public static func normalizeLineEnds(_ text: String?) -> String? { text.map { lineEndsRegex.replace($0, "\n") } }

    /// The text needs no space before it whatever comes before: it starts with whitespace, or with punctuation or a
    /// line break that attaches to the previous word. Also for callers that only know whether the field ends in a word.
    static func joinsDirectly(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return DotNet.isWhiteSpace(first) || attachesToPrevious.contains(first)
    }

    private static func isLineEnd(_ c: Unicode.Scalar) -> Bool {
        c == "\n" || c == "\r" || c == "\u{0B}" || c == "\u{2028}" || c == "\u{2029}"
    }

    private static let lineBreaksRegex = NetRegex(" *\n+ *")

    private static let lineEndsRegex = NetRegex(#"\r\n?|[\v\u2028\u2029]"#)
}

/// Whisper's well-known outputs on silence or noise, dropped for short audio (under 2.5 s).
public enum Hallucinations {
    private static let known = Set(
        ["you", "thanks for watching", "thank you for watching", "please subscribe"].map(DotNet.ordinal))

    public static func isLikely(_ text: String, _ audioSamples: Int) -> Bool {
        audioSamples < Decoding.sampleRate * 5 / 2 && known.contains(DotNet.ordinal(TranscriptText.normalize(text)))
    }
}

/// The personal dictionary as typed in settings: one "heard = typed" per line, for words the recognizer mishears
/// completely ("journals = genres"); `\n` in "typed" is a line break. Becomes `DictationOptions.replacements`.
public enum PersonalDictionary {
    /// In the order the lines are (a "heard" given twice keeps its first place and its last "typed"). Keep that order
    /// when adding these to `DictationOptions.replacements`: of two keys the same length, the earlier wins.
    public static func parse(_ text: String?) -> [(key: String, value: String)] {
        var map: [(key: String, value: String)] = []
        var positions: [[Unicode.Scalar]: Int] = [:]
        for line in DotNet.lines(text ?? "") {
            guard let eq = line.unicodeScalars.firstIndex(of: "="), eq != line.startIndex else { continue }
            let heard = DotNet.trim(String(line[..<eq]))
            let typed = DotNet.replace(DotNet.trim(String(line[line.unicodeScalars.index(after: eq)...])), "\\n", "\n")
            if heard.isEmpty || typed.isEmpty {
                continue
            }

            if let position = positions[DotNet.ordinal(heard)] {
                map[position].value = typed
            } else {
                positions[DotNet.ordinal(heard)] = map.count
                map.append((heard, typed))
            }
        }

        return map
    }
}
