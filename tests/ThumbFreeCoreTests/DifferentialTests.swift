import XCTest
@testable import ThumbFreeCore

/// The Swift core against the C# core on 3,000 generated inputs: the hash of each case's outputs must be the one the
/// C# core gives (DifferentialGolden.swift). The inputs come from .NET's `Random`, so they are the C# generator's.
final class DifferentialTests: XCTestCase {
    func testTheSwiftCoreGivesTheCSharpCoresOutputs() {
        let golden = differentialGolden.split(separator: "\n").map(String.init)
        XCTAssertEqual(3000, golden.count)
        var random = DotNetRandom(2026)
        let f1 = DictationFormatter(DictationOptions(
            replacements: [("git hub", "GitHub"), ("kube", "Kubernetes")],
            snippets: [("my signature", "Thanks,\nShivam")]))
        let f2 = DictationFormatter(DictationOptions(
            removeFillerWords: false,
            spokenPunctuation: false,
            replacements: [
                ("kube", "K8s ($0)"), ("dollars", "$$"), ("c++", "C++"), ("naïve", "naive"),
                ("git hub", "GitHub ${0}!"), ("x.", "y"),
            ],
            snippets: [("my signature", "Thanks,\nShivam"), ("My Signature!", "other")]))
        var failures: [String] = []
        for (n, expected) in golden.enumerated() {
            let outs = differentialCase(&random, f1, f2)
            if hash(outs.joined(separator: "\u{1}")) != expected {
                failures.append("case \(n):\n    " + outs.map { Vectors.escape($0) }.joined(separator: "\n    "))
            }
        }

        let shown = failures.prefix(6).joined(separator: "\n")
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(golden.count) differ:\n" + shown)
    }

    /// FNV-1a over the UTF-8 bytes, as 16 hex digits.
    private func hash(_ s: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }

        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

private let tokens = [
    "um", "uh", "hmm", "thik", "hai", "na", "thik hai na", "scratch that", "new line", "new paragraph", "comma",
    "full stop", "question mark", "exclamation mark", "colon", "semicolon", "period", "you know", "I mean",
    "basically", "like", "for example", "so", "ok", "okay", "haan", "to", "toh", "actually", "sorry", "no wait",
    "make it", "at", "on", "3 pm", "4 PM", "Friday", "tomorrow", "6", "7:30", "2.5", "bullet point", "next bullet",
    "first", "second", "third", "finally", "and", "then", "Hey Tim", "Dear John", "Hi", "Thanks", "Best regards",
    "Ben", "Priya Sharma", "Things to do today", "shopping list", "my plan", "milk", "eggs", "git hub", "kube",
    "my signature", "insert", "the", "build", "is", "green", "we", "shipped", "it", "kal", "office", "mein",
    "meeting", "main", "aa", "jaunga", "Kubirnets", "Kubernetes", "GitHub Copilot", "co-pilot", "Windows 10",
    "dollars", "c++", "x.", "=", "a = b", "\\n", "$1",
    ",", ".", "?", "!", ";", ":", "...", "…", "—", "-", "'", "’", "(", ")", "[x]", "*", "\"",
    "😀", "👍🏽", "👨‍👩‍👧", "🇮🇳", "e\u{301}", "café", "naïve", "हिंदी", "नमस्ते", "क्\u{200D}ष", "日本語",
    "\u{A0}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{2028}", "\u{2029}", "\r\n", "\r", "\n", "\t", "\u{0B}", "\u{85}",
    "  ",
    "123", "٣", "²", "½", "_", "a_b", "x²",
]

private let befores: [String?] = [
    "", nil, "We shipped it", "Notes:\n", "Done. ", "Hello\r\n", "(", "line one\u{2028}", "  ", "Dear John,", "Great 👍",
    "नमस्ते।",
]

private let fields = [
    FieldInfo(), FieldInfo(multiLine: true), FieldInfo(multiLine: true, email: true), FieldInfo(search: true),
    FieldInfo(password: true),
]

private let entries = ["Kubernetes", "GitHub Copilot", "naïve", "café au lait", "हिंदी", "Windows 11"]

private func text(_ r: inout DotNetRandom) -> String {
    let count = 1 + r.next(12)
    var s = ""
    for _ in 0..<count {
        var t = tokens[r.next(tokens.count)]
        if r.next(3) == 0 {
            t = r.next(2) == 0 ? DotNet.upperInvariant(t) : DotNet.upperFirst(t)
        }

        s += t
        switch r.next(5) {
        case 0: break
        case 1: s += "  "
        default: s += " "
        }
    }

    return s
}

private func differentialCase(_ r: inout DotNetRandom, _ f1: DictationFormatter, _ f2: DictationFormatter) -> [String] {
    let t = text(&r)
    var outs = [t]
    let formatted = f1.format(t)
    outs.append(formatted)
    outs.append(f1.format(t, continuesSentence: true))
    outs.append(f1.format(t, searchField: true))
    outs.append(f2.format(t))
    outs.append(Layout.apply(formatted, LayoutContext(multiLine: true, atStart: true, email: true)))
    outs.append(Layout.apply(formatted, LayoutContext(multiLine: true, atStart: true, email: false)))
    outs.append(Layout.apply(formatted, LayoutContext(multiLine: true, atStart: false, email: false)))
    outs.append(Layout.mayLayOut(formatted, LayoutContext(multiLine: true, atStart: true, email: true)) ? "1" : "0")
    outs.append(SelfCorrection.apply(t))
    outs.append(TranscriptText.clean(t))
    outs.append(TranscriptText.normalize(t))
    outs.append(TranscriptText.compact(t))
    outs.append(Vocabulary.correct(t, entries))
    outs.append(Vocabulary.isEcho(t, entries) ? "1" : "0")
    outs.append(Insertion.withSpacing(t, "and then"))
    outs.append(Insertion.continuesSentence(t) ? "1" : "0")
    outs.append(Insertion.forField(t, FieldInfo()))
    outs.append(Insertion.normalizeLineEnds(t)!)
    outs.append(LiveText.mergePunctuation(t, formatted))
    outs.append(LiveText.endSentence(t))
    let entry = History.decode(History.encode(HistoryEntry(time: 7, app: t, text: t)))
    outs.append(entry.map { $0.app + "\u{2}" + $0.text } ?? "null")
    outs.append(Vocabulary.parse(t).joined(separator: "\u{2}"))
    outs.append(PersonalDictionary.parse(t).map { $0.key + "=" + $0.value }.joined(separator: "\u{2}"))

    let count = 1 + r.next(4)
    var phrases: [String] = []
    for _ in 0..<count {
        phrases.append(text(&r))
    }

    let before = befores[r.next(befores.count)]
    let field = fields[r.next(fields.count)]
    let smart = r.next(4) != 0
    let live = r.next(5) != 0
    let typing = LiveTyping(f1, LiveTypingContext(textBefore: before, field: field, live: live, smartFormatting: smart))
    for k in 1..<count {
        let step = typing.update(Array(phrases[..<k]), phrases[k])
        outs.append(step.type)
        outs.append(step.pending)
    }

    outs.append(typing.finish(phrases))
    outs.append(typing.typed)
    outs.append(typing.text)
    outs.append(typing.finalText)
    let flags = [typing.finishedWithoutLayout, typing.phrasesChanged, typing.holdsAll].map { $0 ? "1" : "0" }
    outs.append(flags.joined() + "\(typing.typedPhrases)")
    return outs
}
