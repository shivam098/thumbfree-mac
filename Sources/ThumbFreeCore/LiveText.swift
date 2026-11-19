/// Text that arrives while you speak (live typing). A streaming recognizer gives each phrase as it ends (finished) plus
/// the words of the phrase in progress (partial). Same rules as the Android and Windows apps.
public enum LiveText {
    /// Takes the punctuation from `punctuated` (the punctuation model's output) and keeps the recognizer's own words and
    /// capitals (`original`); the model re-cases words badly ("YOUTUBE"). Where the model puts no mark, a mark the
    /// recognizer wrote itself is kept. A word never ends in two marks: the model sometimes adds one after the mark it was
    /// given ("build.." or "logs.,"), so the first is kept. Sentence starts are capitalized. If the two don't have the
    /// same words, `original` is returned unchanged (trimmed).
    public static func mergePunctuation(_ original: String, _ punctuated: String) -> String {
        let words = DotNet.words(original)
        let marked = DotNet.words(punctuated)
        if words.isEmpty || words.count != marked.count {
            return DotNet.trim(original)
        }

        var result = ""
        var sentenceStart = true
        for (word, markedWord) in zip(words, marked) {
            let bare = withoutTrailingMarks(word)
            if !DotNet.equalsOrdinalIgnoreCase(bare, withoutTrailingMarks(markedWord)) {
                return DotNet.trim(original)
            }

            let modelMarks = trailingMarks(markedWord)
            let ownMarks = trailingMarks(word)
            let mark = (modelMarks.first ?? ownMarks.first).map { String($0) } ?? ""
            if !result.isEmpty {
                result += " "
            }

            result += (sentenceStart ? capitalizingFirst(bare) : bare) + mark
            sentenceStart = mark == "." || mark == "?" || mark == "!"
        }

        return result
    }

    /// The text so far: finished phrases, then the phrase in progress.
    public static func join(_ finished: [String], _ partial: String) -> String {
        (finished + [DotNet.trim(partial)]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The end of a dictation is the end of a sentence: a phrase cut at a pause may end in a comma (or nothing), which
    /// becomes a full stop. Text already ending in . ? ! (or a symbol) is left alone.
    public static func endSentence(_ text: String) -> String {
        let t = DotNet.trimEnd(DotNet.trimEnd(DotNet.trimEnd(text), [",", ";", ":"]))
        guard let last = t.unicodeScalars.last, DotNet.isLetterOrDigit(last) else { return t }
        return t + "."
    }

    private static let marks: Set<Unicode.Scalar> = [".", ",", "?", "!", ";", ":"]

    /// The run of . , ? ! ; : at the end of `word` (`[.,?!;:]+$`).
    private static func trailingMarks(_ word: String) -> [Unicode.Scalar] {
        Array(word.unicodeScalars.reversed().prefix { marks.contains($0) }.reversed())
    }

    private static func withoutTrailingMarks(_ word: String) -> String { DotNet.trimEnd(word, marks) }

    /// The first letter in upper case when it's a lower-case letter (`char.IsLower`, `char.ToUpperInvariant`).
    private static func capitalizingFirst(_ word: String) -> String {
        guard let first = word.unicodeScalars.first, DotNet.isLower(first) else { return word }
        var scalars = String.UnicodeScalarView()
        scalars.append(DotNet.toUpperInvariant(first))
        scalars.append(contentsOf: word.unicodeScalars.dropFirst())
        return String(scalars)
    }
}
