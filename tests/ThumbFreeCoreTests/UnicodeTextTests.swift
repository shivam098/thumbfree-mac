import XCTest
@testable import ThumbFreeCore

/// Emoji, combining marks and Devanagari through the core: nothing is split, dropped or crashes, and the results are
/// the C# core's (worked out by running it on the same input).
final class UnicodeTextTests: XCTestCase {
    /// Exactly the same scalars: `XCTAssertEqual` on strings would take "é" and "e\u{301}" as equal.
    private func assertScalars(
        _ expected: String,
        _ actual: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(Array(expected.unicodeScalars), Array(actual.unicodeScalars), message, file: file, line: line)
    }

    func testTheFormatterKeepsEmojiMarksAndDevanagariWhole() {
        let formatter = DictationFormatter(DictationOptions(replacements: [("naïve", "naive"), ("अच्छा", "accha")]))
        let cases: [(String, String)] = [
            ("um I love it 👍🏽 comma ship it", "I love it 👍🏽, ship it"),
            ("send it to the 👨‍👩‍👧 group new line thanks", "Send it to the 👨‍👩‍👧 group\nThanks"),
            ("cafe\u{301} new line menu", "Cafe\u{301}\nMenu"),
            ("नमस्ते comma कैसे हो question mark", "नमस्ते, कैसे हो?"),
            ("अच्छी बात अच्छी बात है", "अच्छी बात अच्छी बात है"),
            ("हिंदी हिंदी अच्छी है", "हिंदी हिंदी अच्छी है"),
            ("that's naïve, very naïve 🙂 period", "That's naive, very naive 🙂."),
            ("ठीक है अच्छा फिर मिलते हैं", "ठीक है accha फिर मिलते हैं"),
            ("great job 👍 see you. 👋 bye", "Great job 👍 see you. 👋 bye"),
            ("क्\u{200D}ष new paragraph ok", "क्\u{200D}ष\n\nOk"),
        ]
        for (input, expected) in cases {
            assertScalars(expected, formatter.format(input), input)
            assertScalars(expected, formatter.format(input, continuesSentence: true), input)
        }
    }

    func testListsAndEmailsWithEmojiAndAccents() {
        let formatter = DictationFormatter()
        let context = LayoutContext(multiLine: true, atStart: true, email: true)
        let cases: [(String, String)] = [
            ("Shopping list bullet point 🍎 apples bullet point 🥚 eggs", "Shopping list:\n- 🍎 apples.\n- 🥚 eggs."),
            ("Hi Priyā, the café is open. Thanks, Zoë.", "Hi Priyā,\n\nThe café is open.\n\nThanks,\nZoë"),
            ("My plan: first, नमस्ते, second, 👍, third, done.", "My plan:\n1. नमस्ते.\n2. 👍.\n3. Done."),
        ]
        for (input, expected) in cases {
            assertScalars(expected, Layout.apply(formatter.format(input), context), input)
        }
    }

    func testNormalizingAndTheWordList() {
        assertScalars("café नमस त", TranscriptText.normalize("Café 👍 नमस्ते"))
        assertScalars("caféनमसत", TranscriptText.compact("Café 👍 नमस्ते"))
        assertScalars("cafe copilots", TranscriptText.normalize("Cafe\u{301} co-pilot’s"))
        assertScalars("", TranscriptText.normalize("👨‍👩‍👧"))

        let text = "I said नमस्ते to the cafe\u{301} owner 👍"
        assertScalars(text, Vocabulary.correct(text, ["नमस्ते", "Café"]))
        assertScalars("Kubernetes 🚀 rocks", Vocabulary.correct("Kubirnets 🚀 rocks", ["Kubernetes"]))
    }

    func testJoiningTextThatEndsInAnEmojiOrADanda() {
        XCTAssertEqual(" see you", Insertion.withSpacing("Great 👍", "see you"))
        XCTAssertTrue(Insertion.continuesSentence("नमस्ते।"))
        XCTAssertTrue(Insertion.continuesSentence("Done 👍"))
    }

    func testHistoryKeepsEveryScalar() {
        let entry = HistoryEntry(time: 7, app: "Notes 📝", text: "Cafe\u{301}\tनमस्ते\n👨‍👩‍👧 \\ end")
        let line = History.encode(entry)
        assertScalars("7\tNotes 📝\tCafe\u{301}\\tनमस्ते\\n👨‍👩‍👧 \\\\ end", line)
        let decoded = History.decode(line)
        assertScalars(entry.text, decoded?.text ?? "")
        assertScalars(entry.app, decoded?.app ?? "")
    }

    func testLiveTypingNeverSplitsACharacter() {
        let formatter = DictationFormatter()
        let hindi = ["मैं कल आऊंगा 👍", "फिर मिलते हैं।", "ठीक है"]
        let emoji = ["We shipped it 🎉.", "The café was great.", "See you 👋"]
        let marks = ["cafe\u{301} new line", "menu new line", "the end"]
        let cases: [([String], FieldInfo, [String])] = [
            (hindi, FieldInfo(), ["", "मैं कल आऊंगा 👍", " फिर मिलते हैं। ठीक है"]),
            (hindi, FieldInfo(multiLine: true), ["", "मैं कल आऊंगा 👍", " फिर मिलते हैं। ठीक है"]),
            (emoji, FieldInfo(), ["", "We shipped it 🎉.", " The café was great. See you 👋"]),
            (marks, FieldInfo(), ["", "Cafe\u{301}", " Menu The end"]),
            (marks, FieldInfo(multiLine: true), ["", "Cafe\u{301}", "\nMenu\nThe end"]),
        ]
        for (phrases, field, expected) in cases {
            let context = LiveTypingContext(textBefore: "", field: field, live: true, smartFormatting: true)
            let typing = LiveTyping(formatter, context)
            var pieces: [String] = []
            for k in 1..<phrases.count {
                pieces.append(typing.update(Array(phrases[..<k]), "").type)
            }

            pieces.append(typing.finish(phrases))
            let what = phrases.joined(separator: " | ")
            XCTAssertEqual(expected.map { Array($0.unicodeScalars) }, pieces.map { Array($0.unicodeScalars) }, what)

            // Had a piece ended inside a character (a base and its mark, or an emoji sequence), the pieces would have
            // more characters between them than the text they make up.
            XCTAssertEqual(pieces.joined().count, pieces.map(\.count).reduce(0, +))
        }
    }

    func testDotNetCaseRules() {
        XCTAssertEqual("ß", String(Character(DotNet.toUpperInvariant("ß"))))
        XCTAssertEqual("\u{1F88}", String(Character(DotNet.toUpperInvariant("\u{1F80}"))))
        XCTAssertEqual("\u{131}", String(Character(DotNet.toUpperInvariant("\u{131}"))))
        XCTAssertEqual("\u{130}", String(Character(DotNet.toLowerInvariant("\u{130}"))))
        XCTAssertEqual("ß", String(Character(DotNet.toLowerInvariant("\u{1E9E}"))))

        // StringComparison.OrdinalIgnoreCase.
        XCTAssertTrue(DotNet.equalsOrdinalIgnoreCase("\u{1F80}", "\u{1F88}"))
        XCTAssertFalse(DotNet.equalsOrdinalIgnoreCase("\u{17F}", "S"))
        XCTAssertFalse(DotNet.equalsOrdinalIgnoreCase("\u{212A}", "k"))
        XCTAssertFalse(DotNet.equalsOrdinalIgnoreCase("ß", "SS"))

        // Ordinal, like C#'s ==, where Swift's == treats canonically equivalent strings as equal.
        XCTAssertTrue("é" == "e\u{301}")
        XCTAssertFalse(DotNet.ordinalEquals("é", "e\u{301}"))
        XCTAssertFalse(DotNet.startsWith("e\u{301}x", "é"))
        XCTAssertTrue(DotNet.startsWith("e\u{301}x", "e"))
    }
}
