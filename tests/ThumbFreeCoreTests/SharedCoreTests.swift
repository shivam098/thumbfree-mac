import XCTest
@testable import ThumbFreeCore

/// The parts of the core every platform shares: the same cases as thumbfree-windows
/// tests/ThumbFree.Core.Tests/SharedCoreTests.cs (ported there from the Android core tests). Its live text test is in
/// LiveTextTests.
final class SharedCoreTests: XCTestCase {
    func testModelCatalogMatchesTheAndroidApp() {
        XCTAssertEqual(ModelCatalog.englishLive, ModelCatalog.forLanguage(.english, .live))
        XCTAssertEqual(ModelCatalog.englishFast, ModelCatalog.forLanguage(.english, .standard))
        XCTAssertEqual(ModelCatalog.englishAccurate, ModelCatalog.forLanguage(.english, .accurate))
        XCTAssertEqual(ModelCatalog.hinglish, ModelCatalog.forLanguage(.hinglish, .live))
        XCTAssertEqual(ModelCatalog.hinglish, ModelCatalog.forLanguage(.hinglish, .standard))
        XCTAssertEqual(ModelCatalog.hinglishAccurate, ModelCatalog.forLanguage(.hinglish, .accurate))
        XCTAssertTrue(ModelCatalog.englishLive.streaming)
        XCTAssertEqual(78_693_144, ModelCatalog.englishLive.bytes)
        XCTAssertFalse(ModelCatalog.hinglish.promptVocabulary)
        XCTAssertTrue(ModelCatalog.hinglishAccurate.promptVocabulary)
        XCTAssertFalse(ModelCatalog.hinglishAccurate.livePreview)
        XCTAssertEqual(Engine.parakeet, ModelCatalog.englishFast.engine)
        XCTAssertEqual(136_490_421, ModelCatalog.englishFast.bytes)
        XCTAssertEqual(Decoding.sampleRate * 30, ModelCatalog.englishFast.maxPieceSamples)
        XCTAssertEqual(Decoding.maxPieceSamples, ModelCatalog.hinglish.maxPieceSamples)
        XCTAssertEqual("parakeet-tdt-110m/tokens.txt", ModelCatalog.englishFast.file("tokens.txt").path)
        XCTAssertEqual(ModelCatalog.all.reduce(0) { $0 + $1.files.count } + 1, ModelCatalog.knownPaths.count)
        XCTAssertEqual(ModelCatalog.englishLive, ModelCatalog.byId("en-kroko-live"))
        XCTAssertNil(ModelCatalog.byId("whisper-small"))
    }

    func testHistoryRoundTripsPrunesAndSearches() {
        let email = HistoryEntry(time: 1_000, app: "OUTLOOK", text: "Hey Tim,\n\nAre you free?\tThanks, C:\\Ben")
        XCTAssertEqual(email, History.decode(History.encode(email)))
        XCTAssertFalse(History.encode(email).unicodeScalars.contains("\n"))
        XCTAssertNil(History.decode("garbage"))
        XCTAssertNil(History.decode("12\tapp\t   "))

        let now = History.maxAgeMs + 10_000
        let old = HistoryEntry(time: 5_000, app: "", text: "too old")
        let recent = (1...(History.maxEntries + 5)).map {
            HistoryEntry(time: now - Int64($0), app: "", text: "entry \($0)")
        }
        let kept = History.prune(recent + [old], now: now)
        XCTAssertEqual(History.maxEntries, kept.count)
        XCTAssertEqual("entry 1", kept[0].text)
        XCTAssertFalse(kept.contains { $0.text == "too old" })

        let two = [
            HistoryEntry(time: 2, app: "", text: "Send me the build logs"),
            HistoryEntry(time: 1, app: "", text: "Call mom"),
        ]
        XCTAssertEqual([two[0]], History.search(two, " logs  SEND "))
        XCTAssertEqual(two, History.search(two, ""))
    }

    func testWordListFixesNearMissesButNotOrdinaryWords() {
        let words = ["Kubernetes", "GitHub Copilot", "genres", "vibe coding"]
        XCTAssertEqual("Review the Kubernetes config.", Vocabulary.correct("Review the Kubirnets config.", words))
        XCTAssertEqual("Ask GitHub Copilot to review it", Vocabulary.correct("Ask GitHub co-pilot to review it", words))
        XCTAssertEqual("ask GitHub Copilot now", Vocabulary.correct("ask git hub copilot now", words))
        XCTAssertEqual("I love vibe coding.", Vocabulary.correct("I love Vibe Coding.", words))
        XCTAssertEqual("Pick a genre or two genes", Vocabulary.correct("Pick a genre or two genes", words))
        XCTAssertEqual("Review the Cabernets config", Vocabulary.correct("Review the Cabernets config", words))
        XCTAssertEqual("nothing to do here", Vocabulary.correct("nothing to do here", words))
        XCTAssertEqual("Kubernetes, Kubernetes!", Vocabulary.correct("Kubernets, kubernetes!", words))

        // Numbers, endings and punctuation are never changed.
        let upgraded = "I upgraded to Windows 10 yesterday."
        XCTAssertEqual(upgraded, Vocabulary.correct(upgraded, ["Windows 11"]))
        XCTAssertEqual("Pixel 8 Pro is fine", Vocabulary.correct("Pixel 8 Pro is fine", ["Pixel 9 Pro"]))
        XCTAssertEqual("Ask Priyanka's team.", Vocabulary.correct("Ask Priyanka's team.", ["Priyanka"]))
        XCTAssertEqual("We sold two Chromebooks.", Vocabulary.correct("We sold two Chromebooks.", ["Chromebook"]))
        XCTAssertEqual(
            "Let me check it out. Look at this.", Vocabulary.correct("Let me check it out. Look at this.", ["Outlook"]))
        XCTAssertEqual("Open Outlook now", Vocabulary.correct("Open out look now", ["Outlook"]))
        XCTAssertEqual("Genres matter.", DictationFormatter().format(Vocabulary.correct("Genres matter.", words)))
    }

    func testVocabularyBecomesAPromptAndEchoesAreDropped() {
        let words = Vocabulary.parse("GitHub Copilot\n vibe coding, genres\n\ngenres\nGENRES\n")
        XCTAssertEqual(["GitHub Copilot", "vibe coding", "genres"], words)
        XCTAssertEqual("GitHub Copilot, vibe coding, genres", Vocabulary.prompt(words))
        XCTAssertNil(Vocabulary.prompt([]))
        XCTAssertTrue(Vocabulary.isEcho("GitHub Copilot, vibe coding, genres.", words))
        XCTAssertTrue(Vocabulary.isEcho("Vibe coding, genres", words))
        XCTAssertFalse(Vocabulary.isEcho("Genres.", words)) // saying one listed word is real dictation
        XCTAssertFalse(Vocabulary.isEcho("I tested videos of different genres", words))
        XCTAssertFalse(Vocabulary.isEcho("", words))
    }

    func testProfessionWordsAreAddedOnceAndNeverRewriteOrdinaryWords() {
        XCTAssertEqual(
            "genres\ngithub\nGitHub Copilot\npull request\nKubernetes\nDocker\nAPI\nJSON\nTypeScript\nJavaScript\n"
                + "Python\nPostgreSQL\nVS Code",
            Professions.addTo("genres\ngithub", "Developer"))
        XCTAssertEqual("genres", Professions.addTo("genres", "Other"))
        XCTAssertEqual(Professions.addTo("", "Sales"), Professions.addTo(Professions.addTo("", "Sales"), "Sales"))

        // Long all-lowercase entries are reachable from ordinary words by the near-miss correction.
        let jargon = [
            "ibuprofen", "paracetamol", "amoxicillin", "affidavit", "indemnity", "plaintiff", "defendant", "syllabus",
            "go-to-market", "pull request", "term sheet",
        ]
        for (role, list) in Professions.all {
            for word in list {
                let scalars = word.unicodeScalars
                let long = scalars.filter({ DotNet.isLetterOrDigit($0) }).count >= 8
                if long && !scalars.contains(where: { DotNet.isUpper($0) }) {
                    XCTAssertTrue(jargon.contains(word), "\(role): \"\(word)\" could rewrite ordinary words")
                }
            }
        }
    }

    func testDictationJoinsTheTextAlreadyThere() {
        XCTAssertEqual(" and then", Insertion.withSpacing("We shipped it", "and then"))
        XCTAssertEqual("Hello", Insertion.withSpacing("", "Hello"))
        XCTAssertEqual("Hello", Insertion.withSpacing(nil, "Hello"))
        XCTAssertEqual("Hello", Insertion.withSpacing("Hi ", "Hello"))
        XCTAssertEqual(", right?", Insertion.withSpacing("ok", ", right?"))
        XCTAssertEqual("mail", Insertion.withSpacing("@", "mail"))

        // Text that already starts with whitespace (a line break turned into a space) gets no second one.
        XCTAssertEqual(" Hello", Insertion.withSpacing("Hi", " Hello"))
        XCTAssertTrue(Insertion.continuesSentence("We shipped it"))
        XCTAssertFalse(Insertion.continuesSentence("We shipped it. "))
        XCTAssertFalse(Insertion.continuesSentence(""))
        XCTAssertFalse(Insertion.continuesSentence(nil))
        XCTAssertFalse(Insertion.continuesSentence("Dear John,\n"))

        // However the app reports a line end.
        for lineEnd in ["\r\n", "\r", "\u{0B}", "\u{2028}", "\u{2029}"] {
            XCTAssertFalse(Insertion.continuesSentence("Dear John," + lineEnd), Vectors.escape(lineEnd))
        }

        XCTAssertEqual("a\nb\nc\nd\ne\nf\n", Insertion.normalizeLineEnds("a\r\nb\rc\u{0B}d\u{2028}e\u{2029}f\n"))
        XCTAssertNil(Insertion.normalizeLineEnds(nil))
        let singleLine = FieldInfo(password: false, search: false, multiLine: false, private: false)
        let multiLine = FieldInfo(password: false, search: false, multiLine: true, private: false)
        XCTAssertEqual("a b", Insertion.forField("a\nb", singleLine))
        XCTAssertEqual("a\nb", Insertion.forField("a\nb", multiLine))
    }

    func testPersonalDictionaryLinesBecomeReplacements() {
        let map = PersonalDictionary.parse(
            "git hub = GitHub\n\nno equals sign\n = empty heard\nsig = Thanks,\\nShivam\n")
        XCTAssertEqual(["git hub", "sig"], map.map { $0.key })
        XCTAssertEqual(["GitHub", "Thanks,\nShivam"], map.map { $0.value })
        let formatter = DictationFormatter(DictationOptions(replacements: map))
        XCTAssertEqual("Push to GitHub.", formatter.format("push to git hub."))
    }

    func testShortKnownHallucinationsAreDropped() {
        XCTAssertTrue(Hallucinations.isLikely("Thanks for watching!", Decoding.sampleRate))
        XCTAssertFalse(Hallucinations.isLikely("Thanks for watching!", 4 * Decoding.sampleRate))
        XCTAssertFalse(Hallucinations.isLikely("Send it", Decoding.sampleRate))
    }

    /// Android reads these from the field's input type, Windows from UI Automation and the Mac from Accessibility (in
    /// the app). Either way the core applies the same rules to them.
    func testPasswordAndSearchFieldsAreRecognised() {
        let formatter = DictationFormatter()
        func typing(_ field: FieldInfo) -> LiveTyping {
            LiveTyping(formatter, LiveTypingContext(textBefore: "", field: field, live: true, smartFormatting: true))
        }

        let password = typing(FieldInfo(password: true))
        let step = password.update(["my secret is", "open sesame"], "and more")
        XCTAssertEqual("", step.type)
        XCTAssertEqual("", step.pending)
        XCTAssertTrue(password.holdsAll)
        XCTAssertEqual("", password.finish(["my secret is", "open sesame"]))
        XCTAssertEqual("", password.finalText)

        // Search boxes: no full stop and no smart formatting.
        XCTAssertEqual("Weather in Delhi", typing(FieldInfo(search: true)).finish(["weather in Delhi."]))
        XCTAssertEqual(
            "Flights at 3 pm actually 4 pm", typing(FieldInfo(search: true)).finish(["flights at 3 pm actually 4 pm."]))
        XCTAssertEqual("Flights at 4 pm.", typing(FieldInfo()).finish(["flights at 3 pm actually 4 pm."]))

        XCTAssertEqual(
            "Dear team The build is green.", typing(FieldInfo()).finish(["dear team new line the build is green."]))
        XCTAssertEqual(
            "Dear team\nThe build is green.",
            typing(FieldInfo(multiLine: true)).finish(["dear team new line the build is green."]))
    }
}
