import XCTest
@testable import ThumbFreeCore

/// The .NET regular expressions of the C# core on ICU: translated so they match what .NET matches. The expected
/// translations are the ones that were checked against ICU, call by call, on the whole C# test suite.
final class NetRegexTests: XCTestCase {
    private static let w = #"\p{L}\p{Mn}\p{Nd}\p{Pc}"#
    private static let s = #"\t-\r\x{85}\p{Z}"#
    private static let b = w + #"\x{200C}\x{200D}"#

    func testDotNetShorthandsAreSpelledOut() {
        let cases: [(String, String)] = [
            (#"\w\W\s\S\d\D\v"#, "[\(Self.w)][^\(Self.w)][\(Self.s)][^\(Self.s)]" + #"\p{Nd}\P{Nd}\x{0B}"#),
            (#"\bx\B"#, "(?:(?<=[\(Self.b)])(?![\(Self.b)])|(?<![\(Self.b)])(?=[\(Self.b)]))x"
                + "(?:(?<=[\(Self.b)])(?=[\(Self.b)])|(?<![\(Self.b)])(?![\(Self.b)]))"),
            (#"[\w'-]"#, "[\(Self.w)'" + #"\-]"#),
            (#"[- ]"#, #"[\-\x{20}]"#),
            (#"[^\]]*"#, #"[^\]]*"#),
            (#"[\s,]"#, "[\(Self.s),]"),
            (#"[\v\u2028]"#, #"[\x{0B}\u2028]"#),
            (#"[\b]"#, #"[\x{08}]"#),
            (#"[]a&b[]"#, #"[\]a\&b\[]"#),
            (#"(?<!a{2,})(?<=b{1,3})(?=\s+)y+"#, #"(?<!a{2,32})(?<=b{1,3})(?=[\t-\r\x{85}\p{Z}]+)y+"#),
            (#"(?<p>[?.!,]?)\1"#, #"(?<p>[?.!,]?)\1"#),
            (#"\p{L}\P{Lu}[\p{Nd}]"#, #"\p{L}\P{Lu}[\p{Nd}]"#),
            (#"a.b$\."#, #"a.b$\."#),
        ]
        for (net, icu) in cases {
            XCTAssertEqual(icu, NetRegex.translate(net), net)
        }
    }

    func testLookBehindsAreBounded() {
        // ICU tries every length up to the bound at each position: 32 keeps a long dictation fast.
        XCTAssertEqual(
            "(?<=^|[.!?][\(Self.s)]{1,32}|,[\(Self.s)]{0,32})x",
            NetRegex.translate(#"(?<=^|[.!?]\s+|,\s*)x"#))

        // Up to 32 spaces, a look-behind sees them as .NET does; .NET sees longer runs too.
        let regex = NetRegex(#"(?<=,\s+)x"#)
        XCTAssertTrue(regex.isMatch("," + String(repeating: " ", count: 32) + "x"))
        XCTAssertFalse(regex.isMatch("," + String(repeating: " ", count: 33) + "x"))
        XCTAssertFalse(regex.isMatch("a" + String(repeating: " ", count: 32) + "x"))

        // Each filler taken out leaves two spaces where “I mean,” is looked for after a sentence or a comma: 15 in a
        // row leave 31, within the bound, so it's dropped as in C#; from 16 it stays, where C# drops it.
        let formatter = DictationFormatter()
        func said(_ fillers: Int) -> String {
            "It's done." + String(repeating: " um", count: fillers) + " I mean, it works."
        }

        XCTAssertEqual("It's done. It works.", formatter.format(said(15)))
        XCTAssertEqual("It's done. I mean, it works.", formatter.format(said(16)))
    }

    func testMatchingFollowsDotNet() {
        // \w has Devanagari's virama (a non-spacing mark) but not its vowel sign i (a spacing mark).
        XCTAssertTrue(NetRegex(#"^\w+$"#).isMatch("\u{915}\u{94D}"))
        XCTAssertFalse(NetRegex(#"^\w+$"#).isMatch("\u{915}\u{93F}"))

        // \b takes the zero-width joiner as part of a word, and stops before a spacing mark.
        XCTAssertFalse(NetRegex(#"\bx"#).isMatch("\u{200D}x"))
        XCTAssertTrue(NetRegex(#"a\b"#).isMatch("a\u{93F}"))

        // Only \n ends a line: $ doesn't stop before \r, and . takes it.
        XCTAssertFalse(NetRegex("a$").isMatch("a\r"))
        XCTAssertTrue(NetRegex("a$").isMatch("a\n"))
        XCTAssertTrue(NetRegex("a.b").isMatch("a\rb"))
        XCTAssertFalse(NetRegex("a.b").isMatch("a\nb"))
        XCTAssertTrue(NetRegex("a.b", .singleline).isMatch("a\nb"))

        // \v is the vertical tab only.
        XCTAssertFalse(NetRegex(#"\v"#).isMatch("\n"))
        XCTAssertTrue(NetRegex(#"\v"#).isMatch("\u{0B}"))
    }

    func testReplacementsUseDotNetSyntax() {
        let regex = NetRegex("(b)")
        let cases: [(String, String)] = [
            ("[$1]", "a[b]c"), ("$$", "a$c"), ("<$&>", "a<b>c"), ("<$`>", "a<a>c"), ("<$'>", "a<c>c"),
            ("<$_>", "a<abc>c"),
            ("<$+>", "a<b>c"), ("<${1}>", "a<b>c"), ("<$2>", "a<$2>c"), (#"<\1>"#, #"a<\1>c"#), ("end$", "aend$c"),
            ("<${x}>", "a<${x}>c"), ("<$10>", "a<$10>c"), ("<${1>", "a<${1>c"), ("<$01>", "a<b>c"), ("<$00>", "a<b>c"),
        ]
        for (replacement, expected) in cases {
            XCTAssertEqual(expected, regex.replace("abc", replacement), replacement)
        }

        let noGroups = NetRegex("b")
        XCTAssertEqual("a<b>c", noGroups.replace("abc", "<$+>"))
        XCTAssertEqual("a<$1>c", noGroups.replace("abc", "<$1>"))
        XCTAssertEqual("a<b>c", noGroups.replace("abc", "<$0>"))
    }

    func testWholeWordsAreMatchedLiterally() {
        let regex = NetRegex.wholeWord("c++ (x) $5")
        let text = "I like c++ (X) $5 a lot, c++ (x) $5x too"
        XCTAssertEqual("I like C! a lot, c++ (x) $5x too", regex?.replace(text, "C!"))
        XCTAssertEqual("C++ yes, c++x no", NetRegex.wholeWord("c++")?.replace("c++ yes, c++x no", "C++"))
    }

    func testSplitKeepsEmptyPiecesAtTheEnds() {
        XCTAssertEqual(["", "a", ""], NetRegex(",").split(",a,"))
        XCTAssertEqual(["abc"], NetRegex(",").split("abc"))
    }

    func testMatchesMayEndInsideACharacter() {
        // As in C#, a match may stop before a combining mark or between \r and \n; no scalar is lost.
        let words = NetRegex(#"\p{L}+"#).matches("cafe\u{301}s").map { Array($0.value.unicodeScalars) }
        XCTAssertEqual([Array("cafe".unicodeScalars), ["s"]], words)
        XCTAssertEqual(Array("a\r b".unicodeScalars), Array(NetRegex("\n").replace("a\r\nb", " ").unicodeScalars))
        let capital = NetRegex(#"^\p{L}"#).replace("cafe\u{301}", "C")
        XCTAssertEqual(Array("Cafe\u{301}".unicodeScalars), Array(capital.unicodeScalars))
    }
}
