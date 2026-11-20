/// Where dictated text is going, for `DictationLayout`.
public struct LayoutContext: Equatable, Sendable {
    /// The field accepts line breaks (lists and emails need them).
    public var multiLine: Bool

    /// Only whitespace before the cursor: the dictation starts the text (needed for email layout).
    public var atStart: Bool

    /// An email app or an email body field: a greeting or a sign-off alone is enough for email layout.
    public var email: Bool

    public init(multiLine: Bool, atStart: Bool, email: Bool = false) {
        self.multiLine = multiLine
        self.atStart = atStart
        self.email = email
    }
}

/// Shapes formatted dictation the way it would be typed: an email gets its greeting and sign-off on their own lines, a
/// spoken list becomes a bulleted or numbered list, and a corrected time or day keeps only the correction ("Friday at 3
/// pm… actually 4 pm" → "Friday at 4 pm"). Runs after `DictationFormatter`; conservative by design, so ordinary
/// sentences come back unchanged. Same rules as the Android and Windows apps, held together by
/// tests/vectors/layout.tsv. C#'s `Layout`: SwiftUI has a `Layout` protocol, which the name would clash with in any
/// file that imports both.
public enum DictationLayout {
    private static let greetings = "hi|hello|hey|dear|good morning|good afternoon|good evening|greetings"

    // A name may carry an apostrophe, a full stop or a hyphen ("O'Neil", "St.", "Mary-Ann").
    private static let nameWord = #"[\p{L}][\p{L}'’.-]*"#
    private static let capitalNameWord = #"\p{Lu}[\p{L}'’.-]*"#

    private static let ordinalOrder = [
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
    ]

    public static func apply(_ text: String, _ context: LayoutContext) -> String {
        let corrected = SelfCorrection.apply(text)
        if !context.multiLine || corrected.unicodeScalars.contains("\n") {
            return corrected
        }

        return (context.atStart ? email(corrected, context.email) : nil) ?? list(corrected) ?? corrected
    }

    /// Whether a dictation that begins with `start` (formatted) may be laid out once it's finished: a bullet command, a
    /// "first, …" list, a list heading ("Things to do today", "My shopping list"), or, in an email field, a greeting at
    /// the start of the text. Elsewhere an email also needs a signed name, which only comes at the end, so a greeting
    /// alone doesn't count (chat messages keep live typing). Live typing holds such a dictation back, because text
    /// typed into another app can't be laid out afterwards. Built from the same patterns as `apply`, so it only
    /// predicts what can happen; a spoken line break means no layout at all.
    public static func mayLayOut(_ start: String, _ context: LayoutContext) -> Bool {
        if !context.multiLine || start.unicodeScalars.contains("\n") {
            return false
        }

        let ordinal = ordinalRegex.match(start)
        return (context.atStart && context.email && greetingStartRegex.isMatch(start))
            || bulletRegex.isMatch(start)
            || (ordinal.map { DotNet.ordinalEquals(ordinalWord($0), "first") } ?? false)
            || isListHeading(splitHead(start)?.head ?? start)
    }

    // MARK: Email

    /// Nil unless the text looks like an email (see `LayoutContext.email`).
    private static func email(_ text: String, _ emailApp: Bool) -> String? {
        let greeting = greetingRegex.match(text)
        var body = greeting?.group(2) ?? text
        let signOff = signOffRegex.match(body)
        let signName = signOff.map { DotNet.trimEnd($0.group(2), ["."]) } ?? ""
        let looksLikeEmail = emailApp ? greeting != nil || signOff != nil : greeting != nil && !signName.isEmpty
        if !looksLikeEmail {
            return nil
        }

        var parts: [String] = []
        if let greeting {
            parts.append(DotNet.trim(greeting.group(1)) + ",")
        }

        if let signOff {
            body = String(signOff.text[..<signOff.range.lowerBound])
        }

        body = DotNet.trim(body)
        if !body.isEmpty {
            parts.append(DotNet.capitalize(body))
        }

        if let signOff {
            let phrase = DotNet.capitalize(DotNet.trim(signOff.group(1)))
            let spoken = DotNet.trim(signOff.value).unicodeScalars
            let end = spoken.last == "!" || spoken.last == "." ? DotNet.string(spoken.suffix(1)) : "."
            parts.append(signName.isEmpty ? phrase + end : "\(phrase),\n\(signName)")
        }

        return parts.count < 2 ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: Lists

    /// Nil unless the text is a spoken list.
    private static func list(_ text: String) -> String? { bullets(text) ?? ordinals(text) ?? commaList(text) }

    /// "Shopping list bullet point milk bullet point eggs" → "Shopping list:\n- Milk.\n- Eggs."
    private static func bullets(_ text: String) -> String? {
        let parts = bulletRegex.split(text)
        if parts.count < 2 {
            return nil
        }

        let items = parts.dropFirst().map { item($0) }.filter { !$0.isEmpty }
        return items.count < 2 ? nil : render(header(parts[0]), items.map { "- " + $0 })
    }

    /// "My plan: first, book flights, second, find a hotel, and third, pack" → a numbered list.
    private static func ordinals(_ text: String) -> String? {
        let marks = ordinalRegex.matches(text)
        if marks.count < 3 {
            return nil
        }

        let words = marks.map { ordinalWord($0) }
        if !DotNet.ordinalEquals(words[0], "first") {
            return nil
        }

        for k in 1..<words.count {
            let word = words[k]
            let isLast = k == words.count - 1
            let last = isLast && (DotNet.ordinalEquals(word, "final") || DotNet.ordinalEquals(word, "last"))
            if !(k < ordinalOrder.count && DotNet.ordinalEquals(word, ordinalOrder[k])) && !last {
                return nil
            }
        }

        var items: [String] = []
        for k in marks.indices {
            let end = k + 1 < marks.count ? marks[k + 1].range.lowerBound : text.endIndex
            items.append(item(String(text[marks[k].range.upperBound..<end])))
        }

        if items.contains(where: { $0.isEmpty || wordCount($0) > 20 }) {
            return nil
        }

        let numbered = items.enumerated().map { "\($0.offset + 1). \($0.element)" }
        return render(header(String(text[..<marks[0].range.lowerBound])), numbered)
    }

    /// "Things to do today: order groceries, go on a walk and call mom" → a bulleted list.
    private static func commaList(_ text: String) -> String? {
        guard let split = splitHead(text), isListHeading(split.head) else { return nil }
        var pieces = itemSplitRegex.split(DotNet.trim(split.items)).map { DotNet.trim($0) }.filter { !$0.isEmpty }
        if pieces.isEmpty {
            return nil
        }

        // "go on a walk and call mom" at the end of the list: two items when both sides are real phrases.
        let last = pieces[pieces.count - 1]
        if let and = andRegex.matches(last).last, !leadingJoinerRegex.isMatch(last) {
            let left = String(and.text[..<and.range.lowerBound])
            let right = String(and.text[and.range.upperBound...])
            if wordCount(left) >= 2 && wordCount(right) >= 2 {
                pieces[pieces.count - 1] = left
                pieces.append(right)
            }
        }

        let items = pieces.map { item($0) }.filter { !$0.isEmpty }

        // With a colon two items make a list; without one, three (so "Tasks, then lunch" stays a sentence).
        if items.count < (split.colon ? 2 : 3) || items.contains(where: { wordCount($0) > 12 }) {
            return nil
        }

        return render(header(split.head), items.map { "- " + $0 })
    }

    /// A list heading before a colon (within 100 characters), else before the first item separator; nil if neither.
    private static func splitHead(_ text: String) -> (head: String, items: String, colon: Bool)? {
        if let colon = text.unicodeScalars.firstIndex(of: ":") {
            // C# counts UTF-16 code units.
            let offset = text.utf16.distance(from: text.startIndex, to: colon)
            if offset >= 1 && offset <= 100 {
                return (String(text[..<colon]), String(text[text.unicodeScalars.index(after: colon)...]), true)
            }
        }

        guard let cut = itemSplitRegex.match(text) else { return nil }
        return (String(text[..<cut.range.lowerBound]), String(text[cut.range.upperBound...]), false)
    }

    /// Short, starts with a cue ("things to", "shopping", "agenda"…) and isn't a statement ("The agenda was long").
    private static func isListHeading(_ head: String) -> Bool {
        wordCount(head) <= 10 && cueRegex.isMatch(DotNet.trim(head)) && !copulaRegex.isMatch(head)
    }

    /// "Firstly" → "first", "finally" → "final".
    private static func ordinalWord(_ mark: NetMatch) -> String {
        let word = DotNet.lowerInvariant(mark.group(1))
        return DotNet.endsWith(word, "ly") ? DotNet.string(word.unicodeScalars.dropLast(2)) : word
    }

    private static func render(_ header: String, _ lines: [String]) -> String {
        (header.isEmpty ? "" : header + "\n") + lines.joined(separator: "\n")
    }

    private static func header(_ raw: String) -> String {
        let h = DotNet.trim(DotNet.trimEnd(DotNet.trim(raw), [",", ".", ";", ":", " "]))
        return h.isEmpty ? "" : DotNet.capitalize(h) + ":"
    }

    private static func item(_ raw: String) -> String {
        var s = DotNet.trimEnd(DotNet.trim(raw), [",", ";", ":", " "])
        s = leadingJoinerRegex.replace(s, "")
        s = DotNet.trimEnd(s, [".", ",", ";", " "])
        if s.isEmpty {
            return ""
        }

        s = DotNet.capitalize(s)
        let last = s.unicodeScalars.last
        return last == "!" || last == "?" ? s : s + "."
    }

    private static func wordCount(_ s: String) -> Int { DotNet.words(s).count }

    private static let greetingRegex = NetRegex(
        #"^((?i:\#(greetings))(?:\s+\#(nameWord)){0,3}?)\s*[,!:—–-]\s*(\S.*)$"#, .singleline)

    // The greeting at the start of a dictation still being spoken: what follows it may not have been said yet.
    private static let greetingStartRegex = NetRegex(#"^(?i:\#(greetings))(?:\s+\#(nameWord)){0,3}?\s*(?:[,!:—–-]|$)"#)

    private static let signOffRegex = NetRegex(
        #"(?:^|(?<=[.!?])\s+)((?i:thanks(?: again| so much| a lot)?|thank you(?: so much| again)?|many thanks|regards|"#
            + #"best regards|kind regards|warm regards|warmly|best|best wishes|all the best|cheers|sincerely|"#
            + #"yours sincerely|yours truly|take care|talk soon))(?:\s*[,.!])?"#
            + #"(?:\s+(\#(capitalNameWord)(?:\s+\#(capitalNameWord)){0,2}))?\s*[.!]?\s*$"#)

    // Only unambiguous commands: "bullet point …", "new/next bullet …", or "bullet …" opening the text. Never "bite the
    // bullet", "bullet train" or "bullet-proof".
    private static let bulletRegex = NetRegex(
        #"(?:[,.;:]?\s*(?<![\p{L}])(?i:(?:new |next |another )?bullet point|(?:new|next|another) bullet)|^(?i:bullet))"#
            + #"(?![\p{L}-])[,.;:]?\s*"#)

    private static let ordinalRegex = NetRegex(
        #"(?:^|(?<=[.,;:!?])\s*(?:(?i:and)\s+)?|\s+(?i:and)\s+)(?<![\p{L}])((?i:first(?:ly)?|second(?:ly)?|"#
            + #"third(?:ly)?|fourth|fifth|sixth|seventh|eighth|ninth|tenth|finally|lastly))"#
            + #"(?![\p{L}])(?:\s*[,:])?\s+"#)

    private static let cueRegex = NetRegex(
        #"^(?i:(?:my|our|the|a|your|today's|tomorrow's|this week's|here's (?:my|the|a|our)|"#
            + #"here is (?:my|the|a|our))\s+)?(?i:to[- ]?dos?|things (?:to|I need to|we need to|I have to|we have to)|"#
            + #"shopping|grocer(?:y|ies)|checklist|agenda|action items?|tasks?|reminders?|list|need to buy|steps|"#
            + #"ingredients|packing)(?![\p{L}])"#)

    private static let copulaRegex = NetRegex(
        #"(?<![\p{L}])(?i:is|was|are|were|seems|seemed|looks|looked|felt)(?![\p{L}])"#)

    private static let itemSplitRegex = NetRegex(#"\s*(?:[,;]|\.(?=\s|$))\s*"#)

    private static let leadingJoinerRegex = NetRegex(#"^(?i:and|then|also|and then|plus)\s+"#)

    private static let andRegex = NetRegex(#"\s+(?i:and)\s+"#)
}

/// "at 3 pm… actually 4 pm" → "at 4 pm", "on Monday, sorry, Tuesday" → "on Tuesday". Only times and days are corrected
/// (and a bare number into a time), where a spoken correction is unambiguous.
public enum SelfCorrection {
    private static let weekdays = "monday|tuesday|wednesday|thursday|friday|saturday|sunday"
    private static let day = weekdays + "|today|tomorrow|tonight"
    private static let time = #"\d{1,2}(?::\d{2})?(?:\s?(?:[aApP]\.?\s?[mM](?![\p{L}])\.?|o'clock))?"#
    private static let value = "(?i:" + day + ")|" + time

    // Never inside a decimal ("2.5, actually 3"): no digit-and-point just before or after a value.
    private static let notInNumber = #"(?<![\p{L}\p{Nd}:])(?<!\p{Nd}[.,])"#
    private static let separator = #"\s*(?:\.\.\.|…|[,.;!?—–-])?\s*"#
    private static let markers = "actually|sorry|I mean|no wait|or rather|make (?:it|that)"
    private static let afterMarker = #"(?:\s*[,.]|\s*\.\.\.|\s*…)?"#

    private static let days = Set(DotNet.split(day, ["|"]).map(DotNet.ordinal))
    private static let weekdayNames = Set(DotNet.split(weekdays, ["|"]).map(DotNet.ordinal))

    private enum Kind {
        case day
        case time
        case number
    }

    public static func apply(_ text: String) -> String {
        correctionRegex.replace(text) { m in
            let first = m.group(1)
            let separator = m.group(2)
            let marker = m.group(3)
            let second = m.group(4)

            // "Friday. Actually, tomorrow I'm busy" is a new thought; "3 PM. Actually 4 PM?" only corrects the time.
            let ends = separator.unicodeScalars.contains { $0 == "." || $0 == "!" || $0 == "?" }
            let ellipsis = DotNet.contains(separator, "...") || separator.unicodeScalars.contains("…")
            let capital = marker.unicodeScalars.first.map { DotNet.isUpper($0) } ?? false
            let newSentence = (ends && !ellipsis) || (first.unicodeScalars.last == "." && capital)
            if newSentence && !clauseEndRegex.isMatch(String(text[m.range.upperBound...])) {
                return m.value
            }

            return replacement(first, second, newSentence) ?? m.value
        }
    }

    /// The text ends with a value and a correction marker ("at 6, sorry,"): the words said next may still replace the
    /// value, so nothing before them is final yet.
    static func awaitsValue(_ text: String) -> Bool { awaitsValueRegex.isMatch(text) }

    private static func replacement(_ first: String, _ second: String, _ newSentence: Bool) -> String? {
        switch (kind(first), kind(second)) {
        case (.day, .day):
            let lower = DotNet.lowerInvariant(second)
            return weekdayNames.contains(DotNet.ordinal(lower)) ? DotNet.upperFirst(second) : lower
        case (.time, .time), (.number, .time):
            return second
        case (.time, .number):
            // "3 pm, actually 4" → "4 pm"
            return meridiemRegex.match(first).map { second + $0.value }
        case (.number, .number) where !newSentence:
            // "2, actually 3" only within a sentence ("Chapter 2. Actually 3." is not a correction).
            return second
        default:
            return nil
        }
    }

    private static func kind(_ value: String) -> Kind {
        if days.contains(DotNet.ordinal(DotNet.lowerInvariant(value))) {
            return .day
        }

        return value.unicodeScalars.contains(":") || meridiemRegex.isMatch(value) ? .time : .number
    }

    private static let correctionRegex = NetRegex(
        #"\#(notInNumber)(\#(value))(\#(separator))((?i:\#(markers)))\#(afterMarker)"#
            + #"\s+(?:(?i:at|on|by)\s+)?(\#(value))(?![\p{L}\p{Nd}]|[.,]\p{Nd})"#)

    // The start of a correction at the end of the text, up to an "at", "on" or "by" that may come before the new value.
    private static let awaitsValueRegex = NetRegex(
        #"\#(notInNumber)(?:\#(value))\#(separator)(?i:\#(markers))\#(afterMarker)(?:\s+(?i:at|on|by))?\s*$"#)

    private static let meridiemRegex = NetRegex(#"\s?(?:[ap]\.?\s?m\.?|o'clock)$"#, .ignoreCase)

    private static let clauseEndRegex = NetRegex(#"^\s*(?:[.,!?;:]|$)"#)
}
