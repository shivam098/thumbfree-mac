import XCTest
@testable import ThumbFreeCore

private let singleLine = FieldInfo()
private let multiLine = FieldInfo(multiLine: true)
private let emailBody = FieldInfo(multiLine: true, email: true)

/// Live typing on the desktop (PLAN 3.10): finished phrases are typed at pauses, and nothing typed is ever changed, so
/// every piece is only added after the ones before it. The same cases as thumbfree-windows
/// tests/ThumbFree.Core.Tests/LiveTypingTests.cs; the generated dictations come from .NET's own `Random`, so they are
/// the very ones the C# tests check.
final class LiveTypingTests: XCTestCase {
    func testPhrasesAreTypedOnePauseLate() {
        let d = Dictation("", singleLine)
        XCTAssertEqual("", d.pause("hello there."))
        XCTAssertEqual("Hello there.", d.pending)
        XCTAssertEqual("Hello there.", d.pause("how are you?"))
        XCTAssertEqual("How are you?", d.pending)
        XCTAssertEqual(" How are you?", d.pause("see you soon."))
        XCTAssertEqual(" See you soon.", d.finish())

        XCTAssertEqual("Hello there. How are you? See you soon.", d.all)
        XCTAssertEqual(d.all, d.typing.typed)
        XCTAssertEqual(3, d.typing.typedPhrases)
        XCTAssertFalse(d.typing.finishedWithoutLayout)
    }

    func testThePillShowsWhatIsSaidButNotTyped() {
        let d = Dictation("", singleLine)
        d.pause("hello there.")
        XCTAssertEqual("Hello there. How are", d.typing.update(d.finished, "how are").pending)
        d.pause("how are you?")
        XCTAssertEqual("How are you? See", d.typing.update(d.finished, "see").pending)
    }

    func testACorrectionAfterAPauseChangesThePhraseBeforeItIsTyped() {
        let d = Dictation("", multiLine)
        XCTAssertEqual("", d.pause("Let's meet on Friday at 3 pm,"))
        XCTAssertEqual("", d.pause("actually 4 pm."))
        XCTAssertEqual("Let's meet on Friday at 4 pm.", d.pending)
        XCTAssertEqual("Let's meet on Friday at 4 pm.", d.pause("In the big room."))
        XCTAssertEqual(" In the big room.", d.finish())
        XCTAssertFalse(d.pieces.contains { DotNet.contains($0, "3 pm") })
    }

    func testACorrectionMarkerInAPhraseOfItsOwnWaitsForTheNewValue() {
        for marker in ["sorry,", "actually,", "I mean", "no wait"] {
            let d = Dictation("", singleLine)
            XCTAssertEqual("", d.pause("Meet me at the cafe at 6,"), marker)
            XCTAssertEqual("", d.pause(marker), marker)
            XCTAssertEqual("", d.pause("7 tonight."), marker)
            XCTAssertEqual("Meet me at the cafe at 7 tonight. See you there.", d.finish("See you there."), marker)
            XCTAssertEqual(d.all, atTheEnd(d), marker)
        }
    }

    func testAnApologyAtTheEndOfAPhraseDoesNotHoldTyping() {
        // Only a marker after a time, day or number can take a new value.
        let d = Dictation("", singleLine)
        XCTAssertEqual("", d.pause("We missed the bus."))
        XCTAssertEqual("We missed the bus.", d.pause("I'm so sorry,"))
    }

    func testACorrectionInTheLastPhraseIsMadeWhenFinishing() {
        let d = Dictation("", singleLine)
        XCTAssertEqual("", d.pause("Friday at 3 pm"))
        XCTAssertEqual("Friday at 4 pm", d.finish("actually 4 pm"))
        XCTAssertEqual(["Friday at 4 pm"], d.pieces)
    }

    func testScratchThatAfterAPauseDropsThePhraseBeforeItIsTyped() {
        let d = Dictation("", singleLine)
        XCTAssertEqual("", d.pause("I'll call you tomorrow."))
        XCTAssertEqual("", d.pause("scratch that. I'll email you."))
        XCTAssertEqual("I'll email you.", d.pause("talk soon."))
        XCTAssertEqual(" Talk soon.", d.finish())
        XCTAssertFalse(d.pieces.contains { DotNet.contains($0, "call") })
    }

    func testAnUnfinishedSentenceWaitsWhileScratchThatCouldStillDropIt() {
        let d = Dictation("", singleLine)
        XCTAssertEqual("", d.pause("I'll call you"))
        XCTAssertEqual("", d.pause("tomorrow."))
        XCTAssertEqual("I'll email you tonight.", d.finish("Scratch that. I'll email you tonight."))

        // Sentences before it are typed; the one "scratch that" can drop waits.
        let e = Dictation("", singleLine)
        XCTAssertEqual("", e.pause("We shipped it."))
        XCTAssertEqual("We shipped it.", e.pause("I'll call you"))
        XCTAssertEqual("", e.pause("tomorrow."))
        XCTAssertEqual("", e.pause("Scratch that."))
        XCTAssertEqual(" I'll email you tonight.", e.finish("I'll email you tonight."))
        XCTAssertEqual("We shipped it. I'll email you tonight.", e.all)
        XCTAssertEqual(e.all, atTheEnd(e))
    }

    func testWithoutWrittenPunctuationScratchThatTwoPhrasesLaterCannotTakeBackTypedText() {
        // The documented limit: unpunctuated speech has no boundary to hold back to, so phrases are typed as before.
        let d = Dictation("", singleLine)
        XCTAssertEqual("", d.pause("kal call karunga"))
        XCTAssertEqual("Kal call karunga", d.pause("parso milte hain"))
        XCTAssertEqual("", d.pause("scratch that"))
        XCTAssertEqual(" Email karunga", d.finish("email karunga"))
        XCTAssertTrue(d.typing.finishedWithoutLayout)
        XCTAssertEqual("Email karunga", atTheEnd(d))
    }

    func testAFillerCommaLeavesSpeechUnpunctuated() {
        // "Um," is gone once the filler is removed, so it's no mark for "scratch that" to stop at.
        let d = Dictation("", singleLine)
        XCTAssertEqual("", d.pause("Um, so the demo is ready"))
        XCTAssertEqual("So the demo is ready", d.pause("and we can ship it"))
        XCTAssertEqual(" and we can ship it", d.pause("on Friday after the review"))
        XCTAssertEqual(" on Friday after the review", d.pause("with the whole team"))
        XCTAssertEqual(" with the whole team", d.finish())
    }

    func testLiveTypingGoesOnAfterTheLastWrittenMark() {
        // A clause that runs on over two pauses without a mark is typed like unpunctuated speech.
        let d = Dictation("", multiLine)
        XCTAssertEqual("", d.pause("We shipped it. and then we"))
        XCTAssertEqual("We shipped it. And then we", d.pause("went to the office"))
        XCTAssertEqual(" went to the office", d.pause("and had a long meeting"))
        XCTAssertEqual(" and had a long meeting about the launch", d.finish("about the launch"))

        let e = Dictation("", singleLine)
        XCTAssertEqual("", e.pause("Um so the demo is ready"))
        XCTAssertEqual("So the demo is ready", e.pause("and we can ship it"))
        XCTAssertEqual(" and we can ship it", e.pause("on Friday, after the review"))
        XCTAssertEqual(" on Friday, after the review", e.pause("with the whole team"))
        XCTAssertEqual(" with the whole team and then celebrate", e.finish("and then celebrate"))
    }

    func testAnEmailIsHeldAndTypedLaidOutWhenFinished() throws {
        let rows = try Vectors.rows("layout.tsv").map { DotNet.split($0, ["\t"]) }
        let row = try XCTUnwrap(rows.first { $0[0] == "mse" && DotNet.startsWith($0[1], "Hey Tim") })
        let phrases = [
            "Hey Tim, would love to connect.", "Are you available on Friday at 3 PM...", "actually 4 PM?",
            "Thanks, Ben.",
        ]
        XCTAssertEqual(row[1], phrases.joined(separator: " "))

        let d = Dictation("", emailBody)
        for phrase in phrases.dropLast() {
            XCTAssertEqual("", d.pause(phrase))
        }

        XCTAssertTrue(d.typing.holdsAll)
        XCTAssertEqual(Vectors.unescape(row[2]), d.finish(phrases[phrases.count - 1]))
        XCTAssertEqual(1, d.pieces.count)
    }

    func testAGreetingInANonEmailFieldIsTypedLive() {
        // Outside email apps an email also needs a signed name, which only comes at the end: chat messages keep live
        // typing.
        let d = Dictation("", multiLine)
        XCTAssertEqual("", d.pause("Hey Tim, are you free tonight?"))
        XCTAssertFalse(d.typing.holdsAll)
        XCTAssertEqual("Hey Tim, are you free tonight?", d.pause("Want to grab dinner?"))
        XCTAssertEqual(" Want to grab dinner?", d.finish())
    }

    func testAGreetingInAnEmailFieldHoldsTheDictation() {
        let d = Dictation("", emailBody)
        XCTAssertEqual("", d.pause("Hey Tim, are you free tonight?"))
        XCTAssertTrue(d.typing.holdsAll)
        XCTAssertEqual("", d.pause("Want to grab dinner?"))
        XCTAssertEqual("Hey Tim,\n\nAre you free tonight? Want to grab dinner?", d.finish())
    }

    func testASignOffWaitsForTheEndAndGoesOnItsOwnLines() {
        let d = Dictation("", emailBody)
        XCTAssertEqual("", d.pause("Can you send me the build logs?"))
        XCTAssertEqual("Can you send me the build logs?", d.pause("Thanks, Ben."))
        XCTAssertFalse(d.typing.holdsAll)
        XCTAssertEqual("\n\nThanks,\nBen", d.finish())
        XCTAssertEqual("Can you send me the build logs?\n\nThanks,\nBen", d.all)
    }

    func testAListIsHeldAndTypedLaidOutWhenFinished() {
        let d = Dictation("", multiLine)
        XCTAssertEqual("", d.pause("Things to do today:"))
        XCTAssertTrue(d.typing.holdsAll)
        XCTAssertEqual("", d.pause("order groceries, go on a walk,"))
        XCTAssertEqual("Things to do today: order groceries, go on a walk", d.pending)
        XCTAssertEqual(
            "Things to do today:\n- Order groceries.\n- Go on a walk.\n- Call mom.", d.finish("and call mom."))

        // After other text, the list starts on a line of its own.
        let after = Dictation("Plans for Saturday", multiLine)
        after.pause("things to do today:")
        XCTAssertEqual(
            "\nThings to do today:\n- Order groceries.\n- Call mom.", after.finish("order groceries and call mom."))
    }

    func testAListThatStartsInALaterPhraseIsHeldWhileNothingIsTyped() throws {
        let rows = try Vectors.rows("layout.tsv").map { DotNet.split($0, ["\t"]) }
        let row = try XCTUnwrap(rows.first { DotNet.startsWith($0[1], "My plan:") })
        let phrases = ["My plan:", "first, book the flights,", "second, find a hotel,", "and third, pack the bags."]
        XCTAssertEqual(row[1], phrases.joined(separator: " "))

        let d = Dictation("", multiLine)
        XCTAssertEqual("", d.pause(phrases[0]))
        XCTAssertFalse(d.typing.holdsAll)
        XCTAssertEqual("", d.pause(phrases[1]))
        XCTAssertTrue(d.typing.holdsAll)
        XCTAssertEqual("", d.pause(phrases[2]))
        XCTAssertEqual(Vectors.unescape(row[2]), d.finish(phrases[3]))

        let bullets = Dictation("", multiLine)
        XCTAssertEqual("", bullets.pause("Meeting notes."))
        XCTAssertEqual("", bullets.pause("Bullet point launch moved to Friday."))
        XCTAssertEqual(
            "Meeting notes:\n- Launch moved to Friday.\n- Priya owns the docs.",
            bullets.finish("Bullet point Priya owns the docs."))
    }

    func testAListStartedAfterTypedTextIsLaidOutAfterIt() {
        let d = Dictation("", multiLine)
        XCTAssertEqual("", d.pause("Meeting notes."))
        XCTAssertEqual("Meeting notes.", d.pause("Two things."))
        XCTAssertEqual(" Two things.", d.pause("Bullet point launch moved to Friday."))
        XCTAssertEqual("", d.pause("Bullet point Priya owns the docs."))
        XCTAssertEqual("\n- Launch moved to Friday.\n- Priya owns the docs.", d.finish())
        XCTAssertTrue(d.typing.finishedWithoutLayout)
        XCTAssertEqual("Meeting notes. Two things.\n- Launch moved to Friday.\n- Priya owns the docs.", d.all)
    }

    func testWhenTheFinalTextWouldChangeTypedTextTheRestIsTypedAfterIt() {
        let d = Dictation("", multiLine)
        XCTAssertEqual("", d.pause("We have a plan."))
        XCTAssertEqual("We have a plan.", d.pause("It's simple."))
        XCTAssertEqual(" It's simple.", d.pause("First, we book the flights."))
        XCTAssertEqual(" First, we book the flights.", d.pause("Second, we find a hotel."))

        // The third item would make it a numbered list, changing what's typed: from here it waits.
        XCTAssertEqual("", d.pause("And third, we pack the bags."))
        XCTAssertEqual(" Second, we find a hotel. And third, we pack the bags.", d.finish())
        XCTAssertTrue(d.typing.finishedWithoutLayout)
        XCTAssertFalse(d.typing.phrasesChanged)
        XCTAssertEqual(
            "We have a plan. It's simple. First, we book the flights. Second, we find a hotel. And third, we pack the "
                + "bags.",
            d.all)
        XCTAssertEqual(d.all, d.typing.typed)
    }

    func testPhrasesThatDoNotBeginWithTheTypedOnesTypeNothingMore() {
        let d = Dictation("", multiLine)
        d.pause("We have a plan.")
        XCTAssertEqual("We have a plan.", d.pause("It's simple."))

        // Against the contract: the app sends other phrases at the end. Typing more could repeat or garble what's
        // there.
        XCTAssertEqual("", d.typing.finish(["We have another plan.", "It's simple."]))
        XCTAssertTrue(d.typing.phrasesChanged)
        XCTAssertEqual("We have another plan. It's simple.", d.typing.finalText)
        XCTAssertEqual("We have a plan.", d.typing.typed)
    }

    func testASingleLineFieldGetsSpacesForSpokenNewLines() {
        let d = Dictation("", singleLine)
        XCTAssertEqual("", d.pause("First point."))
        XCTAssertEqual("", d.pause("New line, second point."))
        XCTAssertEqual("First point Second point.", d.pause("Third point."))
        XCTAssertEqual(" Third point.", d.finish())
        XCTAssertFalse(d.all.unicodeScalars.contains("\n"))

        // A line break at the start becomes the joining space, not a second one.
        let e = Dictation("We shipped it", singleLine)
        XCTAssertEqual(" It was fun.", e.finish("new line it was fun."))
    }

    func testASearchBoxGetsNoFullStop() {
        let d = Dictation("", FieldInfo(search: true))
        XCTAssertEqual("", d.pause("weather in Delhi"))
        XCTAssertEqual("Weather in Delhi", d.pause("this weekend full stop"))
        XCTAssertEqual(" this weekend", d.finish())
    }

    func testDictationContinuesTheSentenceBeforeTheCursor() {
        let d = Dictation("We shipped it", multiLine)
        XCTAssertEqual("", d.pause("and then we celebrated."))
        XCTAssertEqual(" and then we celebrated.", d.pause("It was fun."))
        XCTAssertEqual(" It was fun.", d.finish())
        XCTAssertEqual("and then we celebrated. It was fun.", d.typing.text)
    }

    func testUnknownTextBeforeTheCursorStartsASentenceWithoutEmailLayout() {
        let d = Dictation(nil, emailBody)
        XCTAssertEqual("", d.pause("hey Tim, would love to connect."))
        XCTAssertFalse(d.typing.holdsAll)
        XCTAssertEqual("Hey Tim, would love to connect.", d.pause("Thanks, Ben."))
        XCTAssertEqual(" Thanks, Ben.", d.finish())
        XCTAssertEqual(d.all, d.typing.text)
    }

    func testWithLiveTypingOffEverythingIsTypedAtTheEnd() {
        let d = Dictation("", singleLine, live: false)
        XCTAssertEqual("", d.pause("hello there."))
        XCTAssertEqual("", d.pause("how are you?"))
        XCTAssertEqual("Hello there. How are you?", d.pending)
        XCTAssertTrue(d.typing.holdsAll)
        XCTAssertEqual("Hello there. How are you? See you.", d.finish("see you."))
        XCTAssertEqual(1, d.pieces.count)
    }

    func testHinglishWithoutPunctuationWaitsForTheNextPhrase() {
        let d = Dictation("", multiLine)
        XCTAssertEqual("", d.pause("kal office mein meeting hai thik hai na"))

        // On its own the tag ends a sentence ("… hai."); followed by more it's a comma: wait for that.
        XCTAssertEqual("", d.pause("main 5 baje tak aa jaunga"))
        XCTAssertEqual("Kal office mein meeting hai, main 5 baje tak aa jaunga", d.pause("tum bhi aa jana"))
        XCTAssertEqual(" tum bhi aa jana", d.finish())
        XCTAssertEqual("Kal office mein meeting hai, main 5 baje tak aa jaunga tum bhi aa jana", d.all)
    }

    func testAPhraseMoreWordsWouldStillDropIsNotTyped() {
        // "thik hai na" alone is kept, but before more words it's a tag and dropped. The first one matched the kept
        // second one, so the text with the next phrase alone wasn't enough to tell.
        let d = Dictation("", multiLine)
        XCTAssertEqual("", d.pause("thik hai na"))
        XCTAssertEqual("", d.pause("thik hai na"))
        XCTAssertEqual("", d.pause("I think"))
        XCTAssertEqual("I think we should go", d.finish("we should go"))
    }

    func testALineBreakGoesOutWithTheWordsAfterIt() {
        // A spoken mark right after spoken line breaks takes them back ("…it, we left"): the words are typed, the break
        // waits.
        let d = Dictation("", singleLine)
        XCTAssertEqual("", d.pause("We shipped it new line"))
        XCTAssertEqual("We shipped it", d.pause("new line"))
        XCTAssertEqual(", we left", d.finish("comma we left"))
        XCTAssertEqual("We shipped it, we left", d.all)
        XCTAssertFalse(d.typing.finishedWithoutLayout)
        XCTAssertEqual(d.all, atTheEnd(d))

        let e = Dictation("", multiLine)
        XCTAssertEqual("", e.pause("Dear team new line"))
        XCTAssertEqual("", e.pause("the build is green."))
        XCTAssertEqual("Dear team\nThe build is green.", e.pause("Thanks."))

        // A comma kept only for the line break after it waits with the break: at the end of the text it's dropped.
        let f = Dictation("", multiLine)
        XCTAssertEqual("", f.pause("kal office mein meeting hai"))
        XCTAssertEqual("", f.pause("comma"))
        XCTAssertEqual("Kal office mein meeting hai", f.pause("new line"))
        XCTAssertEqual("", f.pause("new line"))
        XCTAssertEqual("", f.finish("comma"))
        XCTAssertEqual(f.all, atTheEnd(f))
        XCTAssertFalse(f.typing.finishedWithoutLayout)
    }

    func testLineByLineDictationIsTypedLive() {
        let list = Dictation("", multiLine)
        XCTAssertEqual("", list.pause("milk new line"))
        XCTAssertEqual("Milk", list.pause("eggs new line"))
        XCTAssertEqual("\nEggs", list.pause("bread new line"))
        XCTAssertEqual("\nBread", list.pause("butter new line"))
        XCTAssertEqual("\nButter\nCheese", list.finish("cheese"))
        XCTAssertEqual(list.all, atTheEnd(list))

        let note = Dictation("", multiLine)
        XCTAssertEqual("", note.pause("Dear team, new line"))
        XCTAssertEqual("Dear team", note.pause("the build is green, new line"))
        XCTAssertEqual("\nThe build is green", note.pause("the release is on Friday, new line"))
        XCTAssertEqual("\nThe release is on Friday\nPriya", note.finish("Priya"))
        XCTAssertEqual(note.all, atTheEnd(note))

        let box = Dictation("", singleLine)
        XCTAssertEqual("", box.pause("first item new line"))
        XCTAssertEqual("First item", box.pause("second item new line"))
        XCTAssertEqual(" Second item", box.pause("third item new line"))
        XCTAssertEqual(" Third item Fourth item", box.finish("fourth item"))
        XCTAssertEqual(box.all, atTheEnd(box))
    }

    func testAHeldLineBreakComesFirstWhenTheRestIsTypedApart() {
        // Unpunctuated, so "scratch that" takes back typed lines (the documented limit); the rest still starts on its
        // own line.
        let d = Dictation("", multiLine)
        d.pause("milk new line")
        XCTAssertEqual("Milk", d.pause("eggs new line"))
        XCTAssertEqual("\nEggs", d.pause("bread new line"))
        XCTAssertEqual("", d.pause("scratch that"))
        XCTAssertEqual("\nButter", d.finish("butter"))
        XCTAssertTrue(d.typing.finishedWithoutLayout)
    }

    func testEmptyAndFillerOnlyPhrasesAreIgnored() {
        let d = Dictation("", singleLine)
        XCTAssertEqual("", d.pause("See you on Friday at 3 pm,"))
        XCTAssertEqual("", d.pause(""))
        XCTAssertEqual("", d.pause("um"))
        XCTAssertEqual("", d.pause("sorry, 4 pm."))
        XCTAssertEqual("", d.pause("  "))
        XCTAssertEqual("See you on Friday at 4 pm.", d.pause("Bye."))
        XCTAssertEqual(5, d.typing.typedPhrases)
        XCTAssertEqual(" Bye.", d.finish())
    }

    func testLineEndsFromTheAppCountAsNewLines() {
        for lineEnd in ["\r\n", "\r", "\u{0B}", "\u{2028}", "\u{2029}"] {
            let what = Vectors.escape(lineEnd)
            let letter = Dictation("Dear John," + lineEnd, multiLine)
            XCTAssertEqual("And then we met.", letter.finish("and then we met."), what)

            // Already on a line of its own: no blank line before the list.
            let notes = Dictation("Notes" + lineEnd, multiLine)
            XCTAssertEqual(
                "Things to do today:\n- Order groceries.\n- Go on a walk.\n- Call mom.",
                notes.finish("things to do today: order groceries, go on a walk and call mom."),
                what)
        }
    }

    func testNothingIsTypedTwiceWhileAPhraseIsSpoken() {
        let d = Dictation("", singleLine)
        d.pause("hello there.")
        d.pause("how are you?")
        for _ in 0..<3 {
            XCTAssertEqual("", d.typing.update(d.finished, "see").type)
        }

        XCTAssertEqual(["Hello there."], d.pieces)
    }

    func testLiveTypingHoldsWhatMayBecomeAnEmailOrAList() {
        let cases: [(String, Bool)] = [
            ("Hey Tim,", true),
            ("Hi", true),
            ("Good morning team: quick update", true),
            ("Hello. How are you?", false),
            ("History is fun", false),
            ("Shopping list bullet point milk", true),
            ("Bullet point milk", true),
            ("We should bite the bullet and ship it.", false),
            ("My plan: first, book the flights,", true),
            ("At first I was scared,", false),
            ("Things to do today", true),
            ("The agenda was long, boring,", false),
            ("I need to finish the list, then email Bob.", false),
            ("Dear team\nThe build is green.", false),
        ]
        for (start, expected) in cases {
            let email = LayoutContext(multiLine: true, atStart: true, email: true)
            XCTAssertEqual(expected, Layout.mayLayOut(start, email), start)
        }
    }

    func testGreetingsHoldOnlyAtTheStartOfAnEmailAndNothingHoldsInASingleLineField() {
        XCTAssertTrue(Layout.mayLayOut("Hey Tim,", LayoutContext(multiLine: true, atStart: true, email: true)))
        XCTAssertFalse(Layout.mayLayOut("Hey Tim,", LayoutContext(multiLine: true, atStart: true, email: false)))
        XCTAssertFalse(Layout.mayLayOut("Hey Tim,", LayoutContext(multiLine: true, atStart: false, email: true)))
        let list = "Things to do today"
        XCTAssertTrue(Layout.mayLayOut(list, LayoutContext(multiLine: true, atStart: false, email: false)))
        XCTAssertFalse(Layout.mayLayOut(list, LayoutContext(multiLine: false, atStart: true, email: true)))
    }

    /// Typing live doesn't change the outcome unless `LiveTyping.finishedWithoutLayout` says so. Over generated
    /// dictations (fixed seed), the same dictation typed at the end, by a separate `LiveTyping`, is compared with what
    /// was actually typed: where it begins with the pieces typed while speaking, `LiveTyping.finish` must add exactly
    /// the rest; where it doesn't, the dictation must say it ended apart.
    func testTypingLiveEndsWithTheTextTypedAtTheEnd() {
        continueAfterFailure = false
        var random = DotNetRandom(310)
        let formatter = DictationFormatter()
        var typedLive = 0
        var apart = 0
        let runs = 3000
        for _ in 0..<runs {
            let context = randomContext(&random)
            let phrases = randomPhrases(&random, rich)
            let atEnd = LiveTyping(formatter, atTheEnd(context)).finish(phrases)
            let (live, rest, typing) = typeLive(formatter, context, phrases)
            typedLive += live.isEmpty ? 0 : 1
            XCTAssertFalse(typing.phrasesChanged)
            let what = "\(describe(context, phrases))\n  live:   \(Vectors.escape(live))|\(Vectors.escape(rest))\n"
                + "  at end: \(Vectors.escape(atEnd))"
            if DotNet.startsWith(atEnd, live) {
                XCTAssertTrue(!typing.finishedWithoutLayout && DotNet.ordinalEquals(live + rest, atEnd), what)
            } else {
                XCTAssertTrue(typing.finishedWithoutLayout, what)
                apart += 1
            }
        }

        // Not true by holding everything back: most dictations type something while speaking, and few end apart.
        XCTAssertGreaterThan(typedLive, runs / 3, "only \(typedLive) of \(runs) typed anything live")
        XCTAssertLessThan(apart, runs / 20, "\(apart) of \(runs) ended apart")
    }

    /// Plain speech (no corrections, "scratch that", lists or emails): what's typed while speaking is always where the
    /// end result begins.
    func testPlainSpeechNeverEndsApart() {
        continueAfterFailure = false
        var random = DotNetRandom(311)
        let formatter = DictationFormatter()
        for _ in 0..<1500 {
            let context = randomContext(&random)
            let phrases = randomPhrases(&random, plain)
            let atEnd = LiveTyping(formatter, atTheEnd(context)).finish(phrases)
            let (live, rest, typing) = typeLive(formatter, context, phrases)
            let what = "\(describe(context, phrases))\n  live:   \(Vectors.escape(live))|\(Vectors.escape(rest))\n"
                + "  at end: \(Vectors.escape(atEnd))"
            let same = DotNet.startsWith(atEnd, live) && DotNet.ordinalEquals(live + rest, atEnd)
            XCTAssertTrue(same && !typing.finishedWithoutLayout, what)
        }
    }

    /// Unpunctuated speech is typed while speaking, also after a filler comma ("Um, …") or one written mark, and when
    /// it's dictated line by line (every phrase ending in "new line"): by the time three phrases have finished,
    /// something is typed.
    func testUnpunctuatedSpeechIsTypedWhileSpeaking() {
        continueAfterFailure = false
        var random = DotNetRandom(312)
        let formatter = DictationFormatter()
        for _ in 0..<2000 {
            let lineByLine = random.next(3) == 0
            let count = 4 + random.next(4)
            var phrases = (0..<count).map { _ in pick(&random, unpunctuated) + (lineByLine ? " new line" : "") }
            if random.next(3) == 1 {
                phrases[0] = "Um, " + phrases[0]
            } else if random.next(2) == 1 {
                // One mark after any word but the very last.
                let i = random.next(phrases.count - 1)
                var words = DotNet.split(phrases[i], [" "])
                let w = random.next(words.count)
                words[w] += pick(&random, [",", "."])
                phrases[i] = words.joined(separator: " ")
            }

            let before = pick(&random, ["", nil, "We shipped it", "Notes:\n"] as [String?])
            let field = pick(&random, [singleLine, multiLine])
            let smart = random.next(4) != 0
            let context = LiveTypingContext(textBefore: before, field: field, live: true, smartFormatting: smart)
            let typing = LiveTyping(formatter, context)
            for k in 1..<phrases.count {
                _ = typing.update(Array(phrases[..<k]), phrases[k])
                XCTAssertTrue(
                    k < 3 || !typing.typed.isEmpty, "nothing typed after \(k) phrases: \(describe(context, phrases))")
            }
        }
    }

    func testTheGeneratorIsDotNets() {
        // The first numbers of `new Random(seed)` in .NET.
        var a = DotNetRandom(310)
        XCTAssertEqual([6, 7, 4, 7, 1, 4, 8, 9, 3, 5, 6, 4], (0..<12).map { _ in a.next(10) })
        var b = DotNetRandom(311)
        XCTAssertEqual([1, 0, 1, 6, 4, 2, 1, 3, 3, 6, 2, 1], (0..<12).map { _ in b.next(7) })
        var c = DotNetRandom(312)
        XCTAssertEqual([722, 363, 852, 152, 69, 215, 699, 967, 577, 324, 151, 50], (0..<12).map { _ in c.next(1000) })
        var d = DotNetRandom(310)
        XCTAssertEqual([1_456_188_622, 1_668_802_697, 975_601_257], (0..<3).map { _ in d.next() })
    }

    // MARK: Generated dictations

    /// A context as the C# test draws one: the text before, the field, then smart formatting (3 times in 4).
    private func randomContext(_ random: inout DotNetRandom) -> LiveTypingContext {
        let before = pick(&random, befores)
        let field = pick(&random, fields)
        return LiveTypingContext(textBefore: before, field: field, live: true, smartFormatting: random.next(4) != 0)
    }

    private func randomPhrases(_ random: inout DotNetRandom, _ pool: [String]) -> [String] {
        let count = 1 + random.next(7)
        return (0..<count).map { _ in pick(&random, pool) }
    }

    /// Phrase by phrase, the next one being spoken while the ones before have paused; the last one ends it. Returns
    /// what was typed while speaking and what `LiveTyping.finish` added.
    private func typeLive(
        _ formatter: DictationFormatter,
        _ context: LiveTypingContext,
        _ phrases: [String]
    ) -> (live: String, atFinish: String, typing: LiveTyping) {
        let typing = LiveTyping(formatter, context)
        var live = ""
        for k in 1..<phrases.count {
            live += typing.update(Array(phrases[..<k]), phrases[k]).type
            XCTAssertEqual(live, typing.typed)
        }

        return (live, typing.finish(phrases), typing)
    }

    private func describe(_ context: LiveTypingContext, _ phrases: [String]) -> String {
        let before = context.textBefore.map { Vectors.escape($0) } ?? "null"
        return "before=\(before) field=\(context.field) smart=\(context.smartFormatting)\n  phrases: "
            + phrases.joined(separator: " | ")
    }
}

private let befores: [String?] = [
    "", nil, "We shipped it", "Notes:\n", "Done. ", "Hello\r\n", "(", "line one\u{2028}", "  ", "Dear John,",
]

private let fields = [
    FieldInfo(), FieldInfo(multiLine: true), FieldInfo(multiLine: true, email: true), FieldInfo(search: true),
    FieldInfo(password: true),
]

private let unpunctuated = [
    "so the demo is ready", "and we can ship it", "on Friday after the review", "with the whole team",
    "we should talk about the plan", "the build is green", "then we went home", "the release went out",
    "everyone was happy", "kal office mein meeting hai", "main 5 baje tak aa jaunga", "tum bhi aa jana",
]

private let plain = [
    "We shipped it.", "It was fun.", "The build is green.", "Can you check it?", "See you soon!", "When we shipped it,",
    "the team was happy.", "and then we celebrated.", "so the demo is ready", "can you check it", "we should go",
    "kal office mein meeting hai", "main 5 baje tak aa jaunga", "tum bhi aa jana", "thik hai na", "um", "", "  ", "Ok.",
    "haan to like", "for example,", "for example we could ship it.", "I think", "that's fine.", "new line", "comma",
    "full stop", "question mark", "I'm so sorry,", "Thanks for the help.", "Um, so the demo is ready",
    "We shipped it. and then we", "on Friday, after the review", "and had a long meeting",
]

private let rich = plain + [
    "Meet me at the cafe at 6,", "sorry,", "actually", "I mean,", "no wait", "7 tonight.", "Friday at 3 pm",
    "actually 4 pm.", "on Monday, sorry, Tuesday.", "make it 5.", "scratch that.", "Scratch that, I'll email you.",
    "scratch that", "Things to do today:", "My plan:", "first, book the flights,", "second, find a hotel,",
    "and third, pack the bags.", "bullet point milk", "bullet point eggs", "next bullet bread",
    "order groceries, go on a walk,", "and call mom.", "Hey Tim,", "Hi Sam, the report is attached.", "Thanks, Ben.",
    "Best regards, Priya Sharma.", "Cheers!",
]

private func pick<T>(_ random: inout DotNetRandom, _ items: [T]) -> T { items[random.next(items.count)] }

/// The context with live typing off: the same dictation typed at the end.
private func atTheEnd(_ context: LiveTypingContext) -> LiveTypingContext {
    var atEnd = context
    atEnd.live = false
    return atEnd
}

/// The same dictation typed at the end.
private func atTheEnd(_ d: Dictation) -> String {
    LiveTyping(DictationFormatter(), atTheEnd(d.context)).finish(d.finished)
}

/// A dictation as the app drives it: each phrase is spoken word by word (the partial), then a pause finishes it.
private final class Dictation {
    let context: LiveTypingContext
    let typing: LiveTyping
    private(set) var finished: [String] = []

    /// Every piece typed into the app, in order.
    private(set) var pieces: [String] = []

    /// The pill after the latest update.
    private(set) var pending = ""

    init(_ textBefore: String?, _ field: FieldInfo, live: Bool = true, smart: Bool = true) {
        context = LiveTypingContext(textBefore: textBefore, field: field, live: live, smartFormatting: smart)
        typing = LiveTyping(DictationFormatter(), context)
    }

    var all: String { pieces.joined() }

    /// Speaks `phrase`, then pauses; returns what is typed at the pause.
    @discardableResult
    func pause(_ phrase: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        speak(phrase, file: file, line: line)
        finished.append(phrase)
        let step = typing.update(finished, "")
        pending = step.pending
        if !step.type.isEmpty {
            pieces.append(step.type)
        }

        return step.type
    }

    /// Ends the dictation, optionally after one more phrase that never paused; returns what is typed at the end.
    @discardableResult
    func finish(_ tail: String? = nil, file: StaticString = #filePath, line: UInt = #line) -> String {
        if let tail {
            speak(tail, file: file, line: line)
            finished.append(tail)
        }

        let rest = typing.finish(finished)
        if !rest.isEmpty {
            pieces.append(rest)
        }

        return rest
    }

    private func speak(_ phrase: String, file: StaticString, line: UInt) {
        let words = DotNet.split(phrase, [" "])
        for n in 1...words.count {
            let step = typing.update(finished, words[..<n].joined(separator: " "))
            XCTAssertEqual("", step.type, "typed while speaking", file: file, line: line)
            pending = step.pending
        }
    }
}

/// .NET's `new Random(seed)`: the seeded generator (Knuth's subtractive method) that `Random` keeps for compatibility,
/// so a seed gives the numbers it gives in C#.
struct DotNetRandom {
    private var seeds = [Int](repeating: 0, count: 56)
    private var inext = 0
    private var inextp = 21

    init(_ seed: Int) {
        let intMax = Int(Int32.max)
        var mj = 161_803_398 - (seed == Int(Int32.min) ? intMax : abs(seed))
        seeds[55] = mj
        var mk = 1
        var ii = 0
        for _ in 1..<55 {
            ii += 21
            if ii >= 55 {
                ii -= 55
            }

            seeds[ii] = mk
            mk = mj - mk
            if mk < 0 {
                mk += intMax
            }

            mj = seeds[ii]
        }

        for _ in 1..<5 {
            for i in 1..<56 {
                var n = i + 30
                if n >= 55 {
                    n -= 55
                }

                seeds[i] -= seeds[1 + n]
                if seeds[i] < 0 {
                    seeds[i] += intMax
                }
            }
        }
    }

    /// `Random.Next()`.
    mutating func next() -> Int {
        inext = inext + 1 >= 56 ? 1 : inext + 1
        inextp = inextp + 1 >= 56 ? 1 : inextp + 1
        var value = seeds[inext] - seeds[inextp]
        if value == Int(Int32.max) {
            value -= 1
        }

        if value < 0 {
            value += Int(Int32.max)
        }

        seeds[inext] = value
        return value
    }

    /// `Random.Next(maxValue)`.
    mutating func next(_ maxValue: Int) -> Int { Int(Double(next()) * (1.0 / Double(Int32.max)) * Double(maxValue)) }
}
