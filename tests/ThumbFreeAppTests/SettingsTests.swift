import XCTest
import ThumbFreeCore
@testable import ThumbFreeApp

/// thumbfree-windows tests/ThumbFree.App.Tests/SettingsTests.cs, on the Mac. Windows also copies Voice Dictation's
/// settings and reads its old flag files when there's no settings.json yet; there's no Voice Dictation for the Mac, so
/// those two tests keep only what applies (the older "livePreview" carrying over).
final class SettingsTests: XCTestCase {
    private static let voiceDictationFile = #"""
        {
          // Voice Dictation 0.4, edited by hand
          "modelFile": "ggml-small.en-q8_0.bin",
          "insertMethod": "Type",
          "livePreview": false,
          "replacements": { "git hub": "GitHub", "journals": "genres" },
          "snippets": { "my signature": "Thanks,\nShivam" },
          "newLineKeys": { "Notepad": "Enter", "obsidian": "Enter" },
          "someFutureSetting": { "nested": [1, 2, 3] },
          "voiceDictationOnly": true,
        }
        """#

    private static let wrongTypes = """
        {
          "threads": "four",
          "microphoneDevice": null,
          "keepHistory": false,
          "insertMethod": "Type",
          "replacements": { "journals": "genres", "thumb free": "ThumbFree" }
        }
        """

    private var folder: TempFolder!
    private var path: String { folder.file("settings.json") }

    override func setUp() {
        folder = TempFolder()
    }

    override func tearDown() {
        folder.remove()
    }

    func testSavingAChangeKeepsEverythingElseInTheFile() throws {
        TestFiles.write(path, Self.voiceDictationFile)
        let store = SettingsStore(AppSettings.load(from: path), path: path)
        var changed: SettingsChange?
        store.observe { changed = $0 }

        XCTAssertTrue(store.update { $0.keepHistory = false })

        let file = try TestFiles.json(path)
        XCTAssertEqual(file["keepHistory"] as? Bool, false)
        XCTAssertEqual(file["insertMethod"] as? String, "Type")
        XCTAssertEqual((file["snippets"] as? [String: Any])?["my signature"] as? String, "Thanks,\nShivam")
        XCTAssertEqual((file["newLineKeys"] as? [String: Any])?["obsidian"] as? String, "Enter")
        XCTAssertEqual((file["replacements"] as? [String: Any])?["journals"] as? String, "genres")
        XCTAssertEqual(((file["someFutureSetting"] as? [String: Any])?["nested"] as? [Any])?.count, 3)
        XCTAssertEqual(file["voiceDictationOnly"] as? Bool, true)
        XCTAssertEqual(changed?.keys, [.keepHistory])
        XCTAssertEqual(changed?.needsRestart, false)
    }

    func testASaveWritesOnlyWhatChangedSoHandEditsSinceLoadingSurvive() throws {
        TestFiles.write(path, Self.voiceDictationFile)
        let store = SettingsStore(AppSettings.load(from: path), path: path)
        TestFiles.write(path, Self.voiceDictationFile.replacingOccurrences(of: "\"Type\"", with: "\"Paste\""))

        store.update { $0.smartFormatting = false }

        let file = try TestFiles.json(path)
        XCTAssertEqual(file["insertMethod"] as? String, "Paste")
        XCTAssertEqual(file["smartFormatting"] as? Bool, false)
        XCTAssertEqual(store.current.insertMethod, "Type")
    }

    func testOlderChoicesCarryOver() {
        TestFiles.write(path, Self.voiceDictationFile)

        let settings = AppSettings.load(from: path)

        XCTAssertFalse(settings.liveTyping)
        XCTAssertEqual(settings.englishTier, .live)
        XCTAssertEqual(settings.selectedModel, ModelCatalog.englishLive)
        XCTAssertTrue(settings.keepHistory)
        XCTAssertFalse(settings.saveSamples)
        XCTAssertFalse(settings.guideDone)
        XCTAssertEqual(settings.insertMethod, "Type")
        XCTAssertEqual(settings.replacements["GIT HUB"], "GitHub")
    }

    func testANewerFieldWinsOverAnOlderOne() {
        TestFiles.write(path, #"{ "language": "English", "liveTyping": true, "livePreview": false }"#)

        let settings = AppSettings.load(from: path)

        XCTAssertEqual(settings.language, .english)
        XCTAssertTrue(settings.liveTyping)
    }

    func testUnknownChoicesFallBackToDefaultsWithoutLosingTheRest() throws {
        TestFiles.write(
            path,
            #"{ "englishTier": "Turbo", "hinglishTier": "live", "language": 7, "#
                + #""replacements": { "thumb free": "ThumbFree" } }"#)

        let store = SettingsStore(AppSettings.load(from: path), path: path)

        XCTAssertEqual(store.current.englishTier, .live)
        XCTAssertEqual(store.current.hinglishTier, .standard)
        XCTAssertEqual(store.current.language, .english)
        XCTAssertEqual(store.current.replacements["thumb free"], "ThumbFree")
        let error = try XCTUnwrap(store.lastError)
        XCTAssertTrue(error.contains("“englishTier” should be Live, Standard or Accurate"), error)
        XCTAssertTrue(error.contains("“language” should be English or Hinglish"), error)
        XCTAssertFalse(error.contains("hinglishTier"), error)
    }

    func testAFileWithAMistakeIsNeverOverwritten() throws {
        let broken = "{\n  \"insertMethod\": \"Type\",\n  \"oops\" \"no colon\"\n}"
        TestFiles.write(path, broken)
        let store = SettingsStore(AppSettings.load(from: path), path: path)
        XCTAssertTrue(try XCTUnwrap(store.lastError).hasPrefix("settings.json has a mistake near line 3,"))
        XCTAssertEqual(store.lastError, store.problemSummary)
        var changed = false
        store.observe { _ in changed = true }

        XCTAssertFalse(store.update { $0.soundFeedback = false })

        XCTAssertEqual(TestFiles.text(path), broken)
        let error = try XCTUnwrap(store.lastError)
        XCTAssertTrue(error.hasPrefix("This change isn't saved: settings.json has a mistake near line 3."), error)
        XCTAssertTrue(changed)
        XCTAssertFalse(store.current.soundFeedback)
    }

    func testAFileFixedWhileThumbFreeRunsWaitsForARestartAndADeletedOneStartsAgain() throws {
        TestFiles.write(path, #"{ "replacements": { "journals": "genres" }, }}"#)
        let store = SettingsStore(AppSettings.load(from: path), path: path)
        let fixedByHand = #"{ "replacements": { "journals": "genres" } }"#
        TestFiles.write(path, fixedByHand)

        XCTAssertFalse(store.update { $0.replacements["thumb free"] = "ThumbFree" })
        XCTAssertEqual(TestFiles.text(path), fixedByHand)
        XCTAssertTrue(try XCTUnwrap(store.lastError).contains("Restart ThumbFree"))

        try FileManager.default.removeItem(atPath: path)
        XCTAssertTrue(store.update { $0.soundFeedback = false })
        XCTAssertNil(store.lastError)
        XCTAssertFalse(AppSettings.load(from: path).soundFeedback)
        XCTAssertEqual(AppSettings.load(from: path).replacements["thumb free"], "ThumbFree")
    }

    func testEnumsAreWrittenAsNamesAndKeysThisVersionDoesNotReadAreLeftAlone() {
        TestFiles.write(path, #"{ "KeepHistory": true, "pasteLastHotkey": "Alt+Shift+Z" }"#)
        let store = SettingsStore(AppSettings.load(from: path), path: path)

        store.update {
            $0.keepHistory = false
            $0.englishTier = .accurate
        }

        XCTAssertEqual(
            TestFiles.text(path),
            #"{ "KeepHistory": true, "pasteLastHotkey": "Alt+Shift+Z","englishTier":"Accurate","keepHistory":false }"#)
        XCTAssertFalse(AppSettings.load(from: path).keepHistory)
    }

    func testANewFileGetsEverySettingAndAClearedValueBecomesNull() throws {
        let store = SettingsStore(AppSettings(), path: path)

        store.update { $0.profession = "Developer" }
        XCTAssertEqual(try TestFiles.json(path)["profession"] as? String, "Developer")
        XCTAssertNotNil(try TestFiles.json(path)["replacements"])

        store.update { $0.profession = nil }
        XCTAssertTrue(try TestFiles.json(path)["profession"] is NSNull)
        XCTAssertNil(AppSettings.load(from: path).profession)
    }

    func testNoChangeWritesNothing() {
        TestFiles.write(path, "{ }")
        let store = SettingsStore(AppSettings.load(from: path), path: path)
        var raised = false
        store.observe { _ in raised = true }

        store.update { $0.keepHistory = true }

        XCTAssertEqual(TestFiles.text(path), "{ }")
        XCTAssertFalse(raised)
    }

    func testSettingsReadOnlyAtStartSaySo() {
        let store = SettingsStore(AppSettings(), path: path)
        var changed: SettingsChange?
        store.observe { changed = $0 }

        store.update { $0.insertMethod = "Type" }

        XCTAssertEqual(changed?.needsRestart, true)
    }

    func testThePersonalDictionaryRoundTripsThroughText() {
        let entries: SettingsDictionary = [
            "journals": "genres", "my address": "1 Main Street\nBengaluru", "back slash": #"C:\temp"#,
        ]

        let (parsed, mistake) = PersonalDictionary.tryParse(PersonalDictionary.format(entries))

        XCTAssertNil(mistake)
        XCTAssertEqual(parsed, entries)
        XCTAssertEqual(parsed["JOURNALS"], "genres")
    }

    func testThePersonalDictionaryNamesTheLineWithAMistake() {
        let cases: [(text: String, valid: Bool, line: String?)] = [
            ("journals = genres\r\n\r\nthumb free = ThumbFree\r\n", true, nil),
            ("journals genres", false, "Line 1"),
            ("ok = fine\n = nothing heard", false, "Line 2"),
        ]
        for (text, valid, line) in cases {
            let (entries, mistake) = PersonalDictionary.tryParse(text)
            XCTAssertEqual(mistake == nil, valid, text)
            if let line {
                XCTAssertTrue(mistake?.hasPrefix(line) == true, text)
            } else {
                XCTAssertEqual(entries.count, 2, text)
            }
        }
    }

    func testAKeyWrittenTwiceLoadsAndTheLastOneWins() {
        TestFiles.write(path, """
            {
              "insertMethod": "Paste",
              "soundFeedback": false,
              "insertMethod": "Type"
            }
            """)

        let settings = AppSettings.load(from: path)

        XCTAssertEqual(settings.insertMethod, "Type")
        XCTAssertFalse(settings.soundFeedback)
    }

    func testDictionaryEntriesThatDifferOnlyInCaseAreMergedAndTheLastOneWins() {
        TestFiles.write(
            path, #"{ "replacements": { "Git Hub": "Github", "journals": "genres", "git hub": "GitHub" } }"#)

        let settings = AppSettings.load(from: path)

        XCTAssertEqual(settings.replacements.count, 2)
        XCTAssertEqual(settings.replacements["GIT HUB"], "GitHub")
        // As in a C# Dictionary: the first keeps its place and its spelling.
        XCTAssertEqual(settings.replacements.pairs.map { $0.key }, ["Git Hub", "journals"])
    }

    func testLoadingNeverThrows() {
        let deep = #"{ "a": "# + String(repeating: "[", count: 70) + String(repeating: "]", count: 70) + " }"
        let cases: [(text: String, problem: Bool)] = [
            (#"{ "insertMethod": "Paste", "insertMethod": "Type" }"#, false),
            (#"{ "snippets": { "Sig": "a", "sig": "b" }, "newLineKeys": { "Code": "Enter", "code": "Shift+Enter" } }"#,
             false),
            (#"{ "replacements": ["git hub", "GitHub"] }"#, true),
            (#"{ "replacements": { "git hub": 5, "journals": null } }"#, true),
            (#"{ "threads": 1e40, "maxDictationSeconds": -1.5, "language": {} }"#, true),
            ("[1, 2, 3]", true),
            ("null", true),
            (#""just text""#, true),
            ("{ } { }", true),
            (deep, true),
            ("", false),
        ]
        for (text, problem) in cases {
            TestFiles.write(path, text)

            let store = SettingsStore(AppSettings.load(from: path), path: path)

            // Whatever the file holds, it's a problem to report, never a crash.
            XCTAssertEqual(store.lastError != nil, problem, text)
        }
    }

    func testAWrongValueKeepsItsDefaultAndEveryOtherValue() throws {
        TestFiles.write(path, Self.wrongTypes)

        let store = SettingsStore(AppSettings.load(from: path), path: path)

        XCTAssertFalse(store.current.keepHistory)
        XCTAssertEqual(store.current.insertMethod, "Type")
        XCTAssertEqual(store.current.replacements["journals"], "genres")
        XCTAssertEqual(store.current.threads, AppSettings().threads)
        XCTAssertEqual(store.current.microphoneDevice, -1)
        let error = try XCTUnwrap(store.lastError)
        XCTAssertTrue(error.contains("“threads” should be a whole number"), error)
        XCTAssertTrue(error.contains("“microphoneDevice” should be a whole number"), error)
        XCTAssertEqual(
            store.problemSummary,
            "Some values in settings.json can't be used (“threads”, “microphoneDevice”), so ThumbFree uses its "
                + "defaults for them. Settings shows what to fix.")
    }

    func testAnUnrelatedSaveKeepsTheRealEntriesAndTheWrongValueAsWritten() throws {
        TestFiles.write(path, Self.wrongTypes)
        let store = SettingsStore(AppSettings.load(from: path), path: path)

        store.update { $0.replacements["co pilot"] = "Copilot" }

        let text = TestFiles.text(path)
        XCTAssertTrue(try XCTUnwrap(store.lastError).contains("“threads” should be a whole number"))
        XCTAssertTrue(text.contains("\"threads\": \"four\","), text)
        XCTAssertTrue(text.contains("\"microphoneDevice\": null,"), text)
        XCTAssertTrue(text.contains("\"keepHistory\": false,"), text)
        XCTAssertEqual(
            AppSettings.load(from: path).replacements,
            ["journals": "genres", "thumb free": "ThumbFree", "co pilot": "Copilot"])
    }

    func testNamesJoinedByACommaAreAMistakeNotAChoice() throws {
        let cases = [
            ("englishTier", "Live, Accurate"), ("hinglishTier", "Live,Accurate"), ("language", "English,Hinglish"),
            ("language", "Hinglish, English"),
        ]
        for (key, value) in cases {
            TestFiles.write(path, #"{ ""# + key + #"": ""# + value + #"", "keepHistory": false }"#)

            let store = SettingsStore(AppSettings.load(from: path), path: path)

            XCTAssertEqual(store.current.englishTier, .live)
            XCTAssertEqual(store.current.hinglishTier, .standard)
            XCTAssertEqual(store.current.language, .english)
            XCTAssertFalse(store.current.keepHistory)
            XCTAssertTrue(try XCTUnwrap(store.lastError).contains("In settings.json, “\(key)” should be "), value)
        }
    }

    func testTextSavedInAnotherEncodingCostsOnlyItsOwnSetting() throws {
        let cases: [(line: String, key: String?, named: String?)] = [
            (
                #""replacements": { "caf@": "Caf@", "journals": "genres" }"#, "replacements",
                "an entry in “replacements”"
            ),
            (#""snippets": { "sig": "Thanks, Ren@" }"#, "snippets", "an entry in “snippets”"),
            (#""vocabulary": "Caf@\nGitHub""#, "vocabulary", "“vocabulary”"),
            (#""caf@": true"#, nil, nil),
            (#"/* caf@ */ "x": 1"#, nil, nil),
        ]
        for (line, key, named) in cases {
            let original = Self.ansi("{\n  \"keepHistory\": false,\n  " + line + ",\n  \"insertMethod\": \"Type\"\n}")
            TestFiles.write(path, bytes: original)

            let store = SettingsStore(AppSettings.load(from: path), path: path)

            XCTAssertFalse(store.current.keepHistory, line)
            XCTAssertEqual(store.current.insertMethod, "Type", line)
            XCTAssertEqual(store.current.vocabulary, "", line)
            XCTAssertTrue(store.current.snippets.isEmpty, line)
            let replacements: SettingsDictionary =
                key == "replacements" ? ["journals": "genres"] : AppSettings().replacements
            XCTAssertEqual(store.current.replacements, replacements, line)
            if let named {
                let expected = "In settings.json, \(named) has text that isn't UTF-8 (the file may have been saved in "
                    + "another encoding)"
                XCTAssertTrue(try XCTUnwrap(store.lastError).hasPrefix(expected), line)
            } else {
                XCTAssertNil(store.lastError, line)
            }

            XCTAssertTrue(store.update { $0.soundFeedback = false }, line)
            let saved = TestFiles.bytes(path)
            XCTAssertEqual(saved.filter { $0 == 0xE9 }.count, original.filter { $0 == 0xE9 }.count, line)
            XCTAssertFalse(AppSettings.load(from: path).soundFeedback, line)
        }
    }

    func testCommentsAndFormattingSurviveASave() {
        let original = """
            {
              // Voice Dictation 0.4, edited by hand
              "insertMethod": "Type", /* keystrokes for my old editor */
              "soundFeedback": true,
              "voiceDictationOnly": true,
            }
            """
        TestFiles.write(path, original)
        let store = SettingsStore(AppSettings.load(from: path), path: path)

        XCTAssertTrue(store.update { $0.soundFeedback = false })

        XCTAssertEqual(
            TestFiles.text(path),
            original.replacingOccurrences(of: "\"soundFeedback\": true", with: "\"soundFeedback\": false"))
    }

    func testNewKeysGoBeforeTheClosingBraceWithTheFilesIndentationAndLineEndings() {
        TestFiles.write(path, "{\r\n    \"insertMethod\": \"Type\" // mine\r\n}\r\n")
        let store = SettingsStore(AppSettings.load(from: path), path: path)

        store.update {
            $0.keepHistory = false
            $0.replacements = ["journals": "genres"]
        }

        XCTAssertEqual(
            TestFiles.text(path),
            "{\r\n    \"insertMethod\": \"Type\", // mine\r\n    \"replacements\": {\r\n"
                + "      \"journals\": \"genres\"\r\n    },\r\n    \"keepHistory\": false\r\n}\r\n")
    }

    func testNewKeysRespectTrailingCommasAndFilesOnOneLine() {
        let cases = [
            (
                "{\n  \"insertMethod\": \"Type\",\n}\n",
                "{\n  \"insertMethod\": \"Type\",\n  \"keepHistory\": false\n}\n"
            ),
            ("{\"insertMethod\":\"Type\",}", "{\"insertMethod\":\"Type\",\"keepHistory\":false}"),
            ("{\n}", "{\n  \"keepHistory\": false\n}"),
            ("{}", "{\"keepHistory\":false}"),
            (
                "{\n  \"insertMethod\": \"Type\" /* a, b */ }",
                "{\n  \"insertMethod\": \"Type\", /* a, b */ \n  \"keepHistory\": false\n}"
            ),
            (
                "{ \"insertMethod\": \"Type\",\n\t\"x\": 2\n}",
                "{ \"insertMethod\": \"Type\",\n\t\"x\": 2,\n\t\"keepHistory\": false\n}"
            ),
        ]
        for (original, expected) in cases {
            TestFiles.write(path, original)
            let store = SettingsStore(AppSettings.load(from: path), path: path)

            XCTAssertTrue(store.update { $0.keepHistory = false }, original)

            XCTAssertEqual(TestFiles.text(path), expected)
            XCTAssertFalse(AppSettings.load(from: path).keepHistory, original)
        }
    }

    func testEveryCopyOfAKeyWrittenTwiceIsUpdated() {
        TestFiles.write(
            path, "{\n  \"soundFeedback\": true,\n  // again, further down\n  \"soundFeedback\": true,\n}\n")
        let store = SettingsStore(AppSettings.load(from: path), path: path)

        store.update { $0.soundFeedback = false }

        XCTAssertEqual(
            TestFiles.text(path),
            "{\n  \"soundFeedback\": false,\n  // again, further down\n  \"soundFeedback\": false,\n}\n")
    }

    func testADictionaryIsRewrittenInPlaceUnderItsKey() {
        TestFiles.write(
            path, "{\n  // the defaults\n  \"replacements\": {\n    \"git hub\": \"GitHub\"\n  },\n  \"x\": 1\n}")
        let store = SettingsStore(AppSettings.load(from: path), path: path)

        store.update { $0.replacements["journals"] = "genres" }

        XCTAssertEqual(
            TestFiles.text(path),
            "{\n  // the defaults\n  \"replacements\": {\n    \"git hub\": \"GitHub\",\n"
                + "    \"journals\": \"genres\"\n  },\n  \"x\": 1\n}")
    }

    func testAByteOrderMarkAndUnusualSpacingAreKept() {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let original = "{ \"soundFeedback\"  :   true ,\n\t\"modelFile\": \"ggml-base.en-q8_0.bin\" }"
        TestFiles.write(path, bytes: bom + Array(original.utf8))
        let store = SettingsStore(AppSettings.load(from: path), path: path)
        XCTAssertEqual(store.current.modelFile, "ggml-base.en-q8_0.bin")

        store.update { $0.soundFeedback = false }

        let expected = bom + Array(original.replacingOccurrences(of: "true", with: "false").utf8)
        XCTAssertEqual(TestFiles.bytes(path), expected)
    }

    func testSettingsTheHostAppliesAtOnceAreEachReportedOnTheirOwn() {
        let cases: [(AppSettings.Key, (inout AppSettings) -> Void)] = [
            (.soundFeedback, { $0.soundFeedback = false }),
            (.removeFillerWords, { $0.removeFillerWords = false }),
            (.spokenPunctuation, { $0.spokenPunctuation = false }),
            (.replacements, { $0.replacements["journals"] = "genres" }),
        ]
        for (key, change) in cases {
            let store = SettingsStore(AppSettings(), path: folder.file("\(key.rawValue).json"))
            var changed: SettingsChange?
            store.observe { changed = $0 }

            store.update(change)

            XCTAssertEqual(changed?.keys, [key])
            XCTAssertEqual(changed?.needsRestart, false, key.rawValue)
        }
    }

    /// The file as an editor saving "ANSI" writes it: each "@" stands for "é", the single byte E9, which isn't UTF-8.
    private static func ansi(_ json: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for (i, part) in json.components(separatedBy: "@").enumerated() {
            if i > 0 {
                bytes.append(0xE9)
            }

            bytes += Array(part.utf8)
        }

        return bytes
    }
}
