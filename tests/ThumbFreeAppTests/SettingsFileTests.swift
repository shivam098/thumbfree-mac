import XCTest
import ThumbFreeCore
import ThumbFreeMac
@testable import ThumbFreeApp

/// The text in `windowsFile` (`trickyText`) in JSON, as ThumbFree for Windows writes it.
private let trickyJSON = #"a\"b\\c\nd\te\u0001f\uD83D\uDE00g\u00A0hé\u2028i\#u{AD}j<>&'+`\uFEFFk\uE000l\r"#

/// settings.json as ThumbFree for Windows 0.8 writes it (`AppSettings.Save`, here with \n line ends) with every value
/// changed from its default.
private let windowsFile = #"""
    {
      "modelFile": "ggml-base.en-q8_0.bin",
      "vadModelFile": "silero.bin",
      "hinglishModelFile": "hinglish.bin",
      "hinglishAccurateModelFile": "apex.bin",
      "dictationLanguageHotkey": "Ctrl+Alt+H",
      "pasteLastHotkey": "Ctrl+Alt+Z",
      "threads": 3,
      "audioContextSize": 1500,
      "vocabularyPrompt": "GitHub, Kubernetes",
      "microphoneDevice": 2,
      "insertMethod": "Type",
      "soundFeedback": false,
      "liveTyping": false,
      "maxDictationSeconds": 0,
      "removeFillerWords": false,
      "spokenPunctuation": false,
      "replacements": {
        "journals": "genres",
        "mac book": "MacBook",
        "\#(trickyJSON)": "\#(trickyJSON)"
      },
      "snippets": {
        "my signature": "Thanks,\nShivam",
        "my address": "1 Main Street\r\nBengaluru"
      },
      "newLineKeys": {
        "Slack": "Shift+Enter",
        "TextEdit": "Enter"
      },
      "language": "Hinglish",
      "englishTier": "Accurate",
      "hinglishTier": "Accurate",
      "smartFormatting": false,
      "vocabulary": "GitHub\nKubernetes\n\#(trickyJSON)",
      "profession": "Developer",
      "keepHistory": false,
      "saveSamples": true,
      "guideDone": true
    }
    """#

/// The Mac's own settings: settings.json kept in the file's order and in Windows' format, and its reader held to
/// System.Text.Json's rules (the cases were run through it).
final class SettingsFileTests: XCTestCase {
    private var folder: TempFolder!
    private var path: String { folder.file("settings.json") }

    override func setUp() {
        folder = TempFolder()
    }

    override func tearDown() {
        folder.remove()
    }

    /// Of two replacements the same length the first in the file wins, and of two snippets that read the same the
    /// first counts, so the reader keeps the file's order (as a C# Dictionary does), unlike a Swift dictionary.
    func testTheFilesOrderDecidesWhichReplacementAndSnippetWin() {
        TestFiles.write(
            path,
            #"{ "replacements": { "mac book": "MacBook", "book pro": "Pro Book" }, "#
                + #""snippets": { "my sig": "Ren", "My sig!": "Shivam" } }"#)
        let settings = AppSettings.load(from: path)
        XCTAssertEqual(settings.replacements.pairs.map { $0.key }, ["mac book", "book pro"])
        XCTAssertEqual(settings.snippets.pairs.map { $0.key }, ["my sig", "My sig!"])
        XCTAssertEqual(DictationFormatter(settings.dictationOptions).format("mac book pro"), "MacBook pro")
        XCTAssertEqual(DictationFormatter(settings.dictationOptions).format("my sig"), "Ren")

        TestFiles.write(
            path,
            #"{ "replacements": { "book pro": "Pro Book", "mac book": "MacBook" }, "#
                + #""snippets": { "My sig!": "Shivam", "my sig": "Ren" } }"#)
        let reversed = AppSettings.load(from: path)
        XCTAssertEqual(DictationFormatter(reversed.dictationOptions).format("mac book pro"), "Mac Pro Book")
        XCTAssertEqual(DictationFormatter(reversed.dictationOptions).format("my sig"), "Shivam")
    }

    func testAWindowsSettingsFileReadsTheSameAndIsWrittenTheSame() {
        TestFiles.write(path, windowsFile.replacingOccurrences(of: "\n", with: "\r\n"))

        let settings = AppSettings.load(from: path)

        XCTAssertNil(SettingsStore(settings, path: path).lastError)
        XCTAssertEqual(settings.modelFile, "ggml-base.en-q8_0.bin")
        XCTAssertEqual(settings.vadModelFile, "silero.bin")
        XCTAssertEqual(settings.hinglishModelFile, "hinglish.bin")
        XCTAssertEqual(settings.hinglishAccurateModelFile, "apex.bin")
        XCTAssertEqual(settings.dictationLanguageHotkey, "Ctrl+Alt+H")
        XCTAssertEqual(settings.pasteLastHotkey, "Ctrl+Alt+Z")
        XCTAssertEqual(settings.threads, 3)
        XCTAssertEqual(settings.audioContextSize, 1500)
        XCTAssertEqual(settings.vocabularyPrompt, "GitHub, Kubernetes")
        XCTAssertEqual(settings.microphoneDevice, 2)
        XCTAssertEqual(settings.insertMethod, "Type")
        XCTAssertFalse(settings.soundFeedback)
        XCTAssertFalse(settings.liveTyping)
        XCTAssertEqual(settings.maxDictationSeconds, 0)
        XCTAssertFalse(settings.removeFillerWords)
        XCTAssertFalse(settings.spokenPunctuation)
        XCTAssertEqual(settings.replacements, ["journals": "genres", "mac book": "MacBook", trickyText: trickyText])
        XCTAssertEqual(
            settings.snippets, ["my signature": "Thanks,\nShivam", "my address": "1 Main Street\r\nBengaluru"])
        XCTAssertEqual(settings.newLineKeys, ["Slack": "Shift+Enter", "TextEdit": "Enter"])
        XCTAssertEqual(settings.language, .hinglish)
        XCTAssertEqual(settings.englishTier, .accurate)
        XCTAssertEqual(settings.hinglishTier, .accurate)
        XCTAssertEqual(settings.selectedModel, ModelCatalog.hinglishAccurate)
        XCTAssertFalse(settings.smartFormatting)
        XCTAssertTrue(DotNet.ordinalEquals(settings.vocabulary, "GitHub\nKubernetes\n" + trickyText))
        XCTAssertEqual(settings.profession, "Developer")
        XCTAssertFalse(settings.keepHistory)
        XCTAssertTrue(settings.saveSamples)
        XCTAssertTrue(settings.guideDone)
        XCTAssertEqual(settings.dictationKey, .fn)

        // A new file on the Mac is the same text, with the Mac's own setting at the end.
        XCTAssertEqual(
            settings.fileText, windowsFile.replacingOccurrences(of: "\n}", with: ",\n  \"dictationKey\": \"Fn\"\n}"))
    }

    func testTheDictationKeyIsFnOrRightOption() throws {
        TestFiles.write(path, #"{ "dictationKey": " rightoption " }"#)
        XCTAssertEqual(AppSettings.load(from: path).dictationKey, .rightOption)

        TestFiles.write(path, #"{ "dictationKey": "Ctrl+Win" }"#)
        let store = SettingsStore(AppSettings.load(from: path), path: path)
        XCTAssertEqual(store.current.dictationKey, .fn)
        XCTAssertTrue(try XCTUnwrap(store.lastError).contains("“dictationKey” should be Fn or RightOption"))

        // By the names ThumbFreeMac gives the keys, which Jarvis's settings use too.
        for key in FnTapKeys.TapKey.allCases {
            var settings = AppSettings()
            settings.dictationKey = key
            XCTAssertTrue(settings.fileText.contains("\"dictationKey\": \"\(key.settingsName)\""), "\(key)")
            try settings.save(to: path)
            XCTAssertEqual(AppSettings.load(from: path).dictationKey, key)
        }
    }

    /// A trailing comma after a line comment that ends at a carriage return alone is seen as one, so a new key gets no
    /// second comma (which the read-back would refuse).
    func testANewKeyAfterACommentEndingAtACarriageReturnGetsNoSecondComma() {
        TestFiles.write(path, "{\n  \"soundFeedback\": true // sounds\r,\n}")
        let store = SettingsStore(AppSettings.load(from: path), path: path)

        XCTAssertTrue(store.update { $0.liveTyping = false })

        XCTAssertNil(store.lastError)
        XCTAssertEqual(TestFiles.text(path), "{\n  \"soundFeedback\": true // sounds\r,\n  \"liveTyping\": false\n}")
        XCTAssertFalse(AppSettings.load(from: path).liveTyping)
    }

    /// What System.Text.Json takes, with comments skipped and trailing commas allowed, and the line of what it
    /// doesn't, from 0 (the message says "near line" one more).
    func testTheReaderTakesWhatWindowsTakesAndNamesTheSameLine() {
        let deep = { (depth: Int) in
            #"{ "a": "# + String(repeating: "[", count: depth) + String(repeating: "]", count: depth) + " }"
        }
        let cases: [(text: String, line: Int?)] = [
            // A line comment can't hold a line or paragraph separator; a carriage return ends one.
            ("{ \"a\": 1 // c\u{2028} }", 0),
            ("{ // x\r \"a\": 1 }", nil),
            // A comment that isn't closed is a mistake where it starts.
            ("{ \"a\": 1 }\n\n /* x\n\n", 2),
            // Lines are counted at line feeds, also in comments, but not at carriage returns, except one that ends a
            // line comment: System.Text.Json counts a line at the end of each line comment.
            ("{ \"a\": 1 \r\n\r\n \"b\": 2 }", 2),
            ("{\r  \"a\": 1,\r  \"b\" 2\r}", 0),
            ("{\n  // ok\n  /* ok\n  ok */ \"a\" 2\n}", 3),
            ("{ // x\r \"a\" 1 }", 1),
            ("{ // x\r\n \"a\" 1 }", 1),
            ("{ // x\r\r\n \"a\" 1 }", 2),
            ("{ /* x\r */ \"a\" 1 }", 0),
            ("{ \"a\": 1 } // x\r x", 1),
            ("{\n \"a\": \"x\ny\" }", 1),
            ("{ \"a\": \"x\u{7F}y\" }", nil),
            ("{ \"a\": 01 }", 0),
            ("{ \"a\": 1.}", 0),
            ("{ \"a\": .5}", 0),
            ("{ \"a\": -}", 0),
            ("{ \"a\": nullx}", 0),
            ("{ \"a\": 1E+2, \"b\": -0, \"c\": 0.0e-0, \"d\": 1e400 }", nil),
            ("{ \"a\": [1,], }", nil),
            ("{ \"a\": [,] }", 0),
            ("{,}", 0),
            ("{\"a\":1,,}", 0),
            // Comments go wherever white space may, except between a name and its colon.
            ("{ /* c */ \"a\": /* c */ 1 /* c */ , /* c */ \"b\": [ /* c */ ], /* c */ } // end", nil),
            ("{ \"a\" /* c */ : 1 }", 0),
            ("{ } { }", 0),
            ("{ \"a\": 1 }\n\n\n x", 3),
            ("{\n  \"a\": 1\n", 2),
            ("\u{C}{}", 0),
            // At most 64 objects and arrays deep, the file's own object included.
            (deep(63), nil),
            (deep(64), 0),
        ]
        for (text, line) in cases {
            do {
                _ = try SettingsJSON.values(Array(text.utf8))
                XCTAssertNil(line, "read: \(text.debugDescription)")
            } catch let mistake as SettingsJSON.Mistake {
                XCTAssertEqual(mistake.line, line, "\(text.debugDescription): \(mistake.message)")
            } catch {
                XCTFail("\(text.debugDescription): \(error)")
            }
        }
    }

    /// Text the reader takes but can't read, as C#'s GetString throws: bytes that aren't UTF-8, half a UTF-16
    /// character.
    func testTextThatIsntUTF8IsUnreadableNotAMistake() throws {
        func value(_ bytes: [UInt8]) throws -> SettingsJSON.Value? {
            try SettingsJSON.values(Array(#"{ "a": ""#.utf8) + bytes + Array(#"", "b": 1 }"#.utf8))["a"]
        }

        XCTAssertEqual(try value(Array(#"\uD800"#.utf8)), .string(nil))
        XCTAssertEqual(try value(Array(#"\uDE00\uD83D"#.utf8)), .string(nil))
        XCTAssertEqual(try value(Array(#"\uD83Dx"#.utf8)), .string(nil))
        XCTAssertEqual(try value(Array(#"\uD83D\uDE00"#.utf8)), .string("😀"))
        XCTAssertEqual(try value(Array(#"\/\b\f\n\r\t\"\\\u0041\u00e9"#.utf8)), .string("/\u{8}\u{C}\n\r\t\"\\Aé"))
        for unreadable: [UInt8] in [[0xE9], [0xC0, 0xAF], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82]] {
            XCTAssertEqual(try value(unreadable), .string(nil), "\(unreadable)")
        }

        XCTAssertEqual(try value([0xEF, 0xBF, 0xBE]), .string("\u{FFFE}"))
        XCTAssertEqual(try value([0xF0, 0x9F, 0x98, 0x80]), .string("😀"))

        // Outside a string, such a byte is a mistake.
        XCTAssertThrowsError(try SettingsJSON.values(Array(#"{ "b": 1 }"#.utf8) + [0xE9]))
    }
}
