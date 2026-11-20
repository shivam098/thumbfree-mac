/// What `DictationFormatter` does besides tidying.
public struct DictationOptions: Sendable {
    public var removeFillerWords: Bool

    /// Convert spoken “comma”, “question mark”, “new line”… into symbols.
    public var spokenPunctuation: Bool

    /// Whole-word, case-insensitive fixes applied to dictated text (e.g. "git hub" → "GitHub"). Longer keys go first;
    /// of keys the same length, the one listed first (in C#, the dictionary's order). Keep the settings file's order:
    /// decoding it into a `[String: String]` loses it, and with it which of two such keys wins.
    public var replacements: [(key: String, value: String)]

    /// Saying the trigger (or “insert <trigger>”) as a whole phrase types the expansion instead. Of two triggers that
    /// read the same, the first counts, so this too must keep the settings file's order.
    public var snippets: [(key: String, value: String)]

    public init(
        removeFillerWords: Bool = true,
        spokenPunctuation: Bool = true,
        replacements: [(key: String, value: String)] = [],
        snippets: [(key: String, value: String)] = []
    ) {
        self.removeFillerWords = removeFillerWords
        self.spokenPunctuation = spokenPunctuation
        self.replacements = replacements
        self.snippets = snippets
    }
}

/// Local, rule-based clean-up of dictated text: filler words, spoken punctuation, inline “scratch that”, personal
/// replacements, snippets, and capitalisation across pause-split phrases. May return text containing "\n" (the caller
/// presses the app's new-line keys for those). Held to tests/vectors/formatter.tsv, which the C# formatter generated.
public final class DictationFormatter: Sendable {
    private static let continuationWords = Set([
        "a", "an", "and", "as", "at", "but", "by", "for", "from", "if", "in", "into", "is", "it", "of", "on", "or",
        "so", "than", "that", "the", "then", "this", "to", "was", "when", "where", "which", "while", "with", "because",
        "before", "after", "about", "are", "be", "can", "could", "should", "would", "will", "we", "you", "they", "he",
        "she", "my", "our", "your", "their", "its", "not", "also", "just", "maybe", "please", "there", "what", "how",
    ].map(DotNet.ordinal))

    private let options: DictationOptions
    private let replacements: [(pattern: NetRegex, value: String)]
    private let snippets: [[Unicode.Scalar]: String]

    public init(_ options: DictationOptions = DictationOptions()) {
        self.options = options
        let keyed = options.replacements.filter { !DotNet.isNullOrWhiteSpace($0.key) }
        replacements = DotNet.orderByDescending(keyed) { $0.key.utf16.count }.compactMap { replacement in
            NetRegex.wholeWord(DotNet.trim(replacement.key)).map { (pattern: $0, value: replacement.value) }
        }

        var snippets: [[Unicode.Scalar]: String] = [:]
        for snippet in options.snippets where !DotNet.isNullOrWhiteSpace(snippet.key) {
            let key = DotNet.ordinal(TranscriptText.normalize(snippet.key))
            if snippets[key] == nil {
                snippets[key] = snippet.value
            }
        }

        self.snippets = snippets
    }

    /// - Parameters:
    ///   - continuesSentence: The previously typed text did not end a sentence, so don't start with a capital.
    ///   - searchField: Typing into a search or address box: drop a trailing full stop.
    public func format(_ transcript: String, continuesSentence: Bool = false, searchField: Bool = false) -> String {
        var text = TranscriptText.clean(transcript)
        if text.isEmpty {
            return ""
        }

        if let expansion = expandSnippet(text) {
            return expansion
        }

        if options.removeFillerWords {
            text = Self.removeFillers(text)
        }

        text = Self.applyScratchThat(text)
        if options.spokenPunctuation {
            text = Self.applySpokenPunctuation(text)
        }

        for (pattern, value) in replacements {
            text = pattern.replace(text, value)
        }

        text = Self.tidy(text)
        if text.isEmpty {
            return ""
        }

        text = continuesSentence ? Self.lowercaseContinuation(text) : DotNet.upperFirst(text)
        if searchField {
            text = DotNet.trimEnd(text, [".", " "])
        }

        return text
    }

    /// The transcript as "scratch that" sees it: cleaned and with fillers removed (when on), spoken punctuation still
    /// words. Live typing reads from it the written marks a "scratch that" would stop at ("Um," leaves none).
    func beforeScratch(_ transcript: String) -> String {
        let text = TranscriptText.clean(transcript)
        return !text.isEmpty && options.removeFillerWords ? Self.removeFillers(text) : text
    }

    /// Drops sounds and discourse fillers that carry no meaning, in English and Hinglish: “um/uh”; tags such as “thik
    /// hai na?” and “…, thik hai?”; “basically”; “you know” / “I mean” between commas; a run of two or more fillers
    /// opening a sentence or clause (“Haan to like …”, “Okay so …”, “Thik hai to like …”); “like” before “for example”;
    /// a phrase said twice in a row (“for example, for example”); and sentences that are only fillers (“Ok.”) when
    /// something else was said. Single words that may carry meaning (“to”, “so”, “haan”, “like”, “right”) are kept.
    static func removeFillers(_ input: String) -> String {
        var text = fillerRegex.replace(input, " ")
        text = removeThikHaiNa(text)
        text = commaTagRegex.replace(text, ". ")
        text = basicallyRegex.replace(text, " ")
        text = youKnowRegex.replace(text, "")
        text = DotNet.trim(spacesRegex.replace(text, " "))
        text = openingRunRegex.replace(text, "")
        text = likeBeforeExampleRegex.replace(text, "")
        for _ in 0..<3 {
            let deduped = repeatedPhraseRegex.replace(text) { m in
                isDeliberateRepeat(m.group(1)) ? m.value : m.group(1)
            }

            if DotNet.ordinalEquals(deduped, text) {
                break
            }

            text = deduped
        }

        let sentences = sentenceSplitRegex.split(text)
        let kept = sentences.filter { !fillerSentenceRegex.isMatch(DotNet.trim($0)) }
        return !kept.isEmpty && kept.count < sentences.count ? kept.joined(separator: " ") : text
    }

    // Words that end a clause; “… mein thik hai na?” is a tag, “Papa ki tabiyat thik hai na?” a real question.
    private static let clauseEnders = Set([
        "hai", "hain", "ho", "hoga", "hogi", "honge", "tha", "thi", "the", "hoon", "hu", "hun", "chahiye", "chahie",
        "chaahie", "chaahiye", "mein", "me", "par", "pe", "ko", "se", "karna", "karo", "karenge", "karunga", "karungi",
        "kar", "dena", "lena", "do", "lo", "jao", "aana", "jaana", "milenge", "milte", "sakte", "sakta", "sakti",
    ].map(DotNet.ordinalIgnoreCase))

    private static let protectingWords = Set(
        ["sab", "kya", "bilkul", "ekdum", "bhi", "kuch"].map(DotNet.ordinalIgnoreCase))

    private static let spokenSymbolWords = Set([
        "new", "line", "paragraph", "comma", "full", "stop", "question", "exclamation", "mark", "point", "colon",
        "semicolon", "period",
    ].map(DotNet.ordinalIgnoreCase))

    private static let numberWords = Set([
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "double", "triple",
    ].map(DotNet.ordinalIgnoreCase))

    /// “thik hai na” as a tag: inside a sentence (“… hota hai thik hai na to …”), as a sentence of its own, after a
    /// comma, or after a word that ends a clause (“… mein thik hai na?”). Kept when it is the question itself (“Papa ki
    /// tabiyat thik hai na?”, “Kya sab thik hai na?”) or when it is all that was said.
    private static func removeThikHaiNa(_ text: String) -> String {
        tagRegex.replace(text) { m in
            let before = DotNet.trimEnd(String(text[..<m.range.lowerBound]))
            let prevWord = DotNet.ordinalIgnoreCase(previousWordRegex.match(before)?.value ?? "")
            if protectingWords.contains(prevWord) {
                return m.value
            }

            let p = m.group(named: "p")
            let after = DotNet.trimStart(String(text[m.range.upperBound...]))
            if p.isEmpty || p == ",", let first = after.unicodeScalars.first, DotNet.isLetterOrDigit(first) {
                return ", " // mid-sentence
            }

            let last = before.unicodeScalars.last
            let ownSentence = last == nil || last == "." || last == "!" || last == "?" || last == "\n"
            if ownSentence {
                return before.isEmpty && after.isEmpty ? m.value : " "
            }

            return last == "," || clauseEnders.contains(prevWord) ? ". " : m.value
        }
    }

    /// Repeats that are meant: spoken punctuation (“new line new line”) and digits (“1 2 1 2”, “one two one two”).
    private static func isDeliberateRepeat(_ phrase: String) -> Bool {
        DotNet.split(phrase, [" "]).filter { !$0.isEmpty }.allSatisfy { w in
            spokenSymbolWords.contains(DotNet.ordinalIgnoreCase(w)) || numberWords.contains(DotNet.ordinalIgnoreCase(w))
                || w.unicodeScalars.allSatisfy { DotNet.isDigit($0) }
        }
    }

    private func expandSnippet(_ text: String) -> String? {
        var key = TranscriptText.normalize(text)
        if DotNet.startsWith(key, "insert ") {
            key = DotNet.dropPrefix(key, "insert ")
        }

        return snippets[DotNet.ordinal(key)]
    }

    private static let clauseBoundaries: Set<Unicode.Scalar> = [".", "!", "?", ",", ";", ":", "\n"]

    /// “Let's meet at 2, scratch that, 3 pm” → “Let's meet at 3 pm”: drops the clause before the marker.
    private static func applyScratchThat(_ input: String) -> String {
        var text = input
        while let match = scratchRegex.match(text) {
            let before = DotNet.trimEnd(String(text[..<match.range.lowerBound])).unicodeScalars
            var kept = String.UnicodeScalarView()
            if let boundary = before.lastIndex(where: { clauseBoundaries.contains($0) }) {
                kept.append(contentsOf: before[...boundary])
            }

            if kept.last == "," {
                kept.removeLast()
            }

            text = String(kept) + " " + DotNet.trimStart(String(text[match.range.upperBound...]), [" ", ",", "."])
        }

        return text
    }

    private static func applySpokenPunctuation(_ input: String) -> String {
        var text = newParagraphRegex.replace(input, "\n\n")
        text = newLineRegex.replace(text, "\n")
        text = symbolRegex.replace(text) { m in
            switch DotNet.lowerInvariant(m.group(named: "word")) {
            case "comma": return ","
            case "full stop": return "."
            case "question mark": return "?"
            case "exclamation mark", "exclamation point": return "!"
            case "colon": return ":"
            case "semicolon": return ";"
            default: return m.value
            }
        }

        return trailingPeriodRegex.replace(text, ".")
    }

    private static func tidy(_ input: String) -> String {
        var text = spacesRegex.replace(input, " ")
        text = spaceBeforePunctuationRegex.replace(text, "$1")
        text = doublePunctuationRegex.replace(text, "$1")
        text = spaceAroundNewlineRegex.replace(text, "\n")
        text = DotNet.trim(text, [" ", ","])
        text = DotNet.trimStart(text, [".", " "])

        // Capitalise the first letter of each sentence and line.
        return sentenceStartRegex.replace(text) { m in m.group(1) + DotNet.upperInvariant(m.group(2)) }
    }

    private static func lowercaseContinuation(_ text: String) -> String {
        let firstWord = (firstWordRegex.match(text)?.value ?? "").unicodeScalars
        guard firstWord.count > 1, let first = firstWord.first, DotNet.isUpper(first),
              firstWord.dropFirst().allSatisfy({ DotNet.isLower($0) }),
              continuationWords.contains(DotNet.ordinal(DotNet.lowerInvariant(String(firstWord))))
        else {
            return text
        }

        return DotNet.lowerFirst(text)
    }

    private static let fillerRegex = NetRegex(
        #"(?<![\w'-])(?:u+m+|u+h+|uhm|e+r+m+|e+r|a+h+|h+m+|m+h*m+)(?![\w'-])[,.]?"#, .ignoreCase)

    // Fillers that may open a sentence or clause. “to/toh” only counts inside a run that doesn't end with it, so “Ok to
    // proceed” and “To do that” stay.
    private static let openingFiller =
        #"(?:haan|han|haa|so|ok|okay|ach+ha|acha|accha|achcha|th(?:i|ee)k\s+hai|matlab|chalo|alright|like)"#

    // “thik hai na” as a tag (not “sab thik hai na?” = “is everything fine?”).
    private static let tagRegex = NetRegex(
        #"\b(?:th(?:i|ee|ea)k|thick)\s+(?:hai|he|hain)\s+(?:na+|nah)(?![\p{L}'])\s*(?<p>[?.!,]?)"#, .ignoreCase)

    private static let previousWordRegex = NetRegex(#"[\p{L}]+$"#)

    private static let commaTagRegex = NetRegex(#",\s*(?:th(?:i|ee|ea)k|thick)\s+(?:hai|he)\s*\?"#, .ignoreCase)

    private static let basicallyRegex = NetRegex(#",?\s*\bbasically\b,?"#, .ignoreCase)

    private static let youKnowRegex = NetRegex(
        #",\s*you know\s*(?=[,.!?]|$)|(?<=^|[.!?]\s+|,\s+)(?:you know|i mean),\s*"#, .ignoreCase)

    private static let openingRunRegex = NetRegex(
        #"(?<=^|[.!?]\s+|,\s+|\n)(?:(?:\#(openingFiller)|toh?)(?![\w'-]),?\s+)+\#(openingFiller)(?![\w'-]),?\s+"#
            + #"(?=[\p{L}\p{N}])(?!toh?\b|i\s+(?:said|told|mentioned|meant|was\s+saying)\b)"#,
        .ignoreCase)

    private static let likeBeforeExampleRegex = NetRegex(
        #"(?<=^|[.!?]\s+|,\s+)like,?\s+(?=for example\b|jaise\b)"#, .ignoreCase)

    // The same 2–4 words said twice in a row (“for example, for example”). Single words are left alone: Hindi doubles
    // words on purpose (“dheere dheere”).
    private static let repeatedPhraseRegex = NetRegex(
        #"\b((?:[\p{L}\p{N}']+\s+){1,3}[\p{L}\p{N}']+),?\s+\1\b"#, .ignoreCase)

    private static let sentenceSplitRegex = NetRegex(#"(?<=[.!?])[ \t]+"#)

    private static let fillerSentenceRegex = NetRegex(
        #"^(?:(?:ok|okay|th(?:i|ee)k\s+hai(?:\s+na)?|ach+ha|acha|accha|achcha|hmm+|alright|chalo)[\s,]*)+[.!?]*$"#,
        .ignoreCase)

    private static let scratchRegex = NetRegex(#"[,.;]?\s*\bscratch that\b[,.!]?"#, .ignoreCase)

    private static let newParagraphRegex = NetRegex(#"[,.]?\s*\bnew paragraph\b[,.]?\s*"#, .ignoreCase)

    private static let newLineRegex = NetRegex(#"[,.]?\s*\bnew line\b[,.]?\s*"#, .ignoreCase)

    private static let symbolRegex = NetRegex(
        #"[,.]?\s*\b(?<word>comma|full stop|question mark|exclamation mark|exclamation point|colon|semicolon)\b[,.]?"#,
        .ignoreCase)

    private static let trailingPeriodRegex = NetRegex(#"[,]?\s*\bperiod[.!?]?\s*$"#, .ignoreCase)

    private static let spacesRegex = NetRegex(#"[ \t]{2,}"#)

    private static let spaceBeforePunctuationRegex = NetRegex(#"[ \t]+([,.;:!?])"#)

    private static let doublePunctuationRegex = NetRegex(#"([,.;:!?])[,.;:]+"#)

    private static let spaceAroundNewlineRegex = NetRegex(#"[ \t]*\n[ \t]*"#)

    private static let sentenceStartRegex = NetRegex(#"((?:^|[.!?]\s+|\n))(\p{Ll})"#)

    private static let firstWordRegex = NetRegex(#"^[\p{L}']+"#)
}
