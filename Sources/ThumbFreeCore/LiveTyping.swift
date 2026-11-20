/// Where a dictation is typed, decided once when it starts (PLAN 3.10, rule 1).
public struct LiveTypingContext: Equatable, Sendable {
    /// The text before the cursor when dictation started (its end is enough), or nil if it couldn't be read: the
    /// dictation then starts a sentence, gets no joining space and isn't taken as the start of the text (so no email
    /// layout). Line ends count as \n however the app reports them (\r\n, \r, \v, \u{2028}, \u{2029}).
    public var textBefore: String?

    /// The field it goes into.
    public var field: FieldInfo

    /// Type finished phrases while speaking (the Live typing switch); false types everything at the end.
    public var live: Bool

    /// Emails, lists and corrections (`DictationLayout`).
    public var smartFormatting: Bool

    public init(textBefore: String?, field: FieldInfo, live: Bool, smartFormatting: Bool) {
        self.textBefore = textBefore
        self.field = field
        self.live = live
        self.smartFormatting = smartFormatting
    }
}

/// What an update while speaking asks for.
public struct LiveStep: Equatable, Sendable {
    /// Text to type now, after everything typed before (often empty).
    public var type: String

    /// Said but not typed yet, formatted: shown in the pill.
    public var pending: String

    public init(type: String, pending: String) {
        self.type = type
        self.pending = pending
    }
}

/// Live typing where words can't sit in the text box as underlined composing text, as in any app on the Mac or Windows
/// (PLAN 3.10): finished phrases are typed at pauses, and the phrase still being spoken is shown in the pill. Text
/// typed into another app can't be taken back (Backspace could destroy the person's own text), so only final text is
/// typed: the finished phrases before the last one, once the text with all of them still begins with them, both laid
/// out as it would be at the end and with more words after it ("… actually 4 pm", "scratch that", a repeated phrase, a
/// sign-off or a Hindi tag can still change them); not while a correction waits for its new value ("at 6, sorry,");
/// while the speech marks its clauses with written punctuation, only up to where a "scratch that" said next would stop
/// (it drops the sentence or clause it follows), so a clause waits for the phrase after the one that ends it; and with
/// a space, line break or comma at the end of a piece held for the next one, since what's said next can still take it
/// back ("new line" then "comma"). A clause that runs on over two pauses without a mark, like speech without written
/// punctuation (often Hindi + English), is typed one pause late as any phrase is, so there a "scratch that" said later
/// can't take back typed text. While nothing is typed, a dictation that may become a list, or an email in an email
/// field, is held and typed whole at the end. One with nothing typed live ends exactly like a dictation typed at the
/// end. Pure logic: the app does the typing.
public final class LiveTyping {
    // Stands for whatever is said next: an ordinary word that no formatting rule treats specially.
    private static let nextWord = "zebra"

    private let formatter: DictationFormatter
    private let context: LiveTypingContext
    private let textBefore: String?
    private let smart: Bool
    private let holdAll: Bool
    private var layoutHold = false
    private var joinedWithSpace = false
    private var heldBreak = ""
    private var finished: [String] = []
    private var typedPhraseList: [String] = []

    public init(_ formatter: DictationFormatter, _ context: LiveTypingContext) {
        self.formatter = formatter
        self.context = context
        textBefore = Insertion.normalizeLineEnds(context.textBefore)

        // As on Android, search and address boxes get no smart formatting.
        smart = context.smartFormatting && !context.field.search
        holdAll = !context.live || context.field.password
    }

    /// Everything typed so far (all that `update` and `finish` returned), including the joining space.
    public private(set) var typed = ""

    /// How many phrases, from the first, `typed` holds.
    public var typedPhrases: Int { typedPhraseList.count }

    /// Nothing is typed until `finish`: live typing is off, it's a password field, or (while nothing is typed) a list
    /// or an email may be coming.
    public var holdsAll: Bool { holdAll || layoutHold }

    /// `finish` couldn't type the final text as a whole, because its layout or a correction would have changed text
    /// already typed: the phrases not typed yet were formatted on their own and typed after it. Worth a log line.
    public private(set) var finishedWithoutLayout = false

    /// `finish` got phrases that don't begin with the ones already typed, against the contract of `update`, so nothing
    /// more was typed: offer `finalText` to copy instead.
    public private(set) var phrasesChanged = false

    /// The whole dictation as it would be typed at the end (formatted and laid out, without the joining space), set by
    /// `finish`. Empty for a password field.
    public private(set) var finalText = ""

    /// The dictation as typed, without the space that joined it to the text before (for History and "paste last").
    public var text: String { joinedWithSpace ? DotNet.string(typed.unicodeScalars.dropFirst()) : typed }

    /// The text before what's still to be typed, with a space, line break or comma held back from the last piece.
    private var before: String? { typed.isEmpty ? textBefore : (textBefore ?? "") + typed + heldBreak }

    /// The recognizer's progress: `finishedPhrases`, the raw text of each phrase that ended at a pause (word list
    /// already applied; a phrase never changes once given), and `partial`, the phrase being spoken. Returns what to
    /// type now and what to show in the pill (nothing for a password field).
    public func update(_ finishedPhrases: [String], _ partial: String) -> LiveStep {
        var type = ""
        if !DotNet.sequenceEqual(finishedPhrases, finished) {
            finished = finishedPhrases
            type = typeFinished()
        }

        let notTyped = Array(finished.dropFirst(typedPhrases))
        let pending = context.field.password ? "" : shape(LiveText.join(notTyped, partial), layout: false, before)
        return LiveStep(type: type, pending: pending)
    }

    /// The dictation is over: `allPhrases` are all its phrases (those given to `update` and the last one), so the final
    /// text comes from the same phrase texts as what was typed. Returns the text still to type: the rest of the final
    /// text (laid out) after `typed`, or, if that would change typed text, the phrases not typed yet formatted on their
    /// own (`finishedWithoutLayout`). Nothing for a password field.
    public func finish(_ allPhrases: [String]) -> String {
        if context.field.password {
            return ""
        }

        let (complete, joined) = prepare(LiveText.join(allPhrases, ""), layout: true)
        finalText = joined ? DotNet.string(complete.unicodeScalars.dropFirst()) : complete
        let rest: String
        if DotNet.startsWith(complete, typed) {
            rest = DotNet.dropPrefix(complete, typed)
            joinedWithSpace = joinedWithSpace || (typed.isEmpty && joined)
        } else {
            finishedWithoutLayout = true
            if !DotNet.sequenceEqual(Array(allPhrases.prefix(typedPhrases)), typedPhraseList) {
                phrasesChanged = true
                return ""
            }

            // Typed text stays as it is; a list in the rest is still laid out, on lines of its own.
            let before = self.before
            let notTyped = LiveText.join(Array(allPhrases.dropFirst(typedPhrases)), "")
            rest = heldBreak + Insertion.withSpacing(before, shape(notTyped, layout: true, before))
        }

        typed += rest
        heldBreak = ""
        typedPhraseList = allPhrases
        return rest
    }

    /// Types the longest run of finished phrases, before the last one, that is final.
    private func typeFinished() -> String {
        if holdAll {
            return ""
        }

        let said = LiveText.join(finished, "")
        if typed.isEmpty {
            // Judged again at each pause until something is typed: a list or an email is only laid out at the end.
            let continues = Insertion.continuesSentence(textBefore)
            let start = formatter.format(said, continuesSentence: continues, searchField: context.field.search)
            let layout = LayoutContext(multiLine: true, atStart: Self.atStart(textBefore), email: context.field.email)
            layoutHold = !start.isEmpty && context.field.multiLine && smart && DictationLayout.mayLayOut(start, layout)
            if start.isEmpty || layoutHold {
                return ""
            }
        }

        let last = lastSpoken()
        if last <= typedPhrases {
            return ""
        }

        let complete = prepare(said, layout: true).text
        if !DotNet.startsWith(complete, typed) || (smart && SelfCorrection.awaitsValue(complete)) {
            return ""
        }

        // What a "scratch that" said next would keep (while the speech marks its clauses), and what more words would
        // leave unchanged (a Hindi tag, a run of fillers or a filler-only sentence is formatted by what follows it).
        let kept = marksItsClauses(said, last) ? prepare(said + " scratch that", layout: false).text : complete
        let continued = prepare(said + " " + Self.nextWord, layout: false).text
        if kept.utf16.count <= typed.utf16.count || !DotNet.startsWith(kept, typed)
            || !DotNet.startsWith(continued, typed) {
            return ""
        }

        // The longest run of phrases that is final: all before the last phrase, or one or two fewer. Trying only these
        // keeps a pause's cost in proportion to the text, however long the dictation (a run can't be judged by its
        // length, as a "scratch that" in a longer one shortens it).
        var k = last
        while k > typedPhrases && k > last - 3 {
            // A space, line break or comma at the end goes out with the next piece: what's said next can still take it
            // back ("new line" then "comma"), and a comma that ends up last is dropped. The text without it is where
            // the text with it begins, so it passes whatever that passes.
            let (full, joined) = prepare(LiveText.join(Array(finished.prefix(k)), ""), layout: false)
            let scalars = full.unicodeScalars
            var end = scalars.endIndex
            while end > scalars.startIndex {
                let previous = scalars.index(before: end)
                if !DotNet.isWhiteSpace(scalars[previous]) && scalars[previous] != "," {
                    break
                }

                end = previous
            }

            let candidate = String(full[..<end])
            if candidate.utf16.count > typed.utf16.count && DotNet.startsWith(candidate, typed)
                && DotNet.startsWith(complete, candidate) && DotNet.startsWith(kept, candidate)
                && DotNet.startsWith(continued, candidate) {
                let type = DotNet.dropPrefix(candidate, typed)
                joinedWithSpace = joinedWithSpace || (typed.isEmpty && joined)
                typed = candidate
                heldBreak = String(full[end...])
                typedPhraseList = Array(finished.prefix(k))
                return type
            }

            k -= 1
        }

        return ""
    }

    /// The speech marks its clauses with written punctuation here: what follows the last written mark lies within the
    /// last finished phrase. Only then is the clause a "scratch that" would drop held back; one that has run on over
    /// two pauses without a mark is typed like unpunctuated speech, or live typing would stop for the rest of the
    /// dictation. Marks are read in what was said as "scratch that" sees it, after filler removal ("Um," leaves none).
    private func marksItsClauses(_ said: String, _ last: Int) -> Bool {
        let text = formatter.beforeScratch(said)

        // C# searches right to left; for a one-character pattern that's the last match from the left.
        guard let mark = Self.lastClauseMarkRegex.matches(text).last else { return false }
        let after = DotNet.trimStart(String(text[mark.range.upperBound...]))

        // Lengths in UTF-16 code units, as C# measures them.
        return after.utf16.count <= formatter.beforeScratch(finished[last]).utf16.count
    }

    /// The last finished phrase with words in it (blank or filler-only phrases don't count), or -1.
    private func lastSpoken() -> Int {
        for i in finished.indices.reversed() where !formatter.format(finished[i]).isEmpty {
            return i
        }

        return -1
    }

    /// The dictation from its start, as typed after the text before the cursor, and whether a space joins the two.
    private func prepare(_ said: String, layout: Bool) -> (text: String, joined: Bool) {
        let text = shape(said, layout: layout, textBefore)
        let spaced = Insertion.withSpacing(textBefore, text)
        return (spaced, spaced.utf16.count > text.utf16.count)
    }

    /// The shared pipeline for text that follows `before`: the formatter, then layout or corrections only (smart
    /// formatting), then the field's rules. No joining space.
    private func shape(_ said: String, layout: Bool, _ before: String?) -> String {
        let atStart = Self.atStart(before)
        let continues = Insertion.continuesSentence(before)
        var text = formatter.format(said, continuesSentence: continues, searchField: context.field.search)
        if !text.isEmpty && smart {
            let corrected = SelfCorrection.apply(text)
            let email = context.field.email
            let laid = layout && context.field.multiLine
                ? DictationLayout.apply(text, LayoutContext(multiLine: true, atStart: atStart, email: email))
                : corrected

            // A laid-out list or email starts on its own line unless the cursor is at the start of one (PLAN 3.3).
            let midLine = before.flatMap { $0.unicodeScalars.last }.map { $0 != "\n" } ?? false
            text = !DotNet.ordinalEquals(laid, corrected) && !atStart && midLine ? "\n" + laid : laid
        }

        return Insertion.forField(text, context.field)
    }

    /// Only whitespace before the cursor. Unknown text isn't the start.
    private static func atStart(_ before: String?) -> Bool { before != nil && DotNet.isNullOrWhiteSpace(before) }

    // The last written mark that ends a sentence or clause (not the point in "2.5" or the colon in "3:30"): "scratch
    // that" drops back to it. Spoken "comma" or "full stop" become marks only after that, so they don't count.
    private static let lastClauseMarkRegex = NetRegex(#"[.!?,;:](?=\s|$)"#)
}
