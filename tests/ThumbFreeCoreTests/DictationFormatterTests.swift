import XCTest
@testable import ThumbFreeCore

/// The same cases as thumbfree-windows tests/ThumbFree.Core.Tests/DictationFormatterTests.cs.
final class DictationFormatterTests: XCTestCase {
    private let formatter = DictationFormatter(DictationOptions(
        replacements: [("git hub", "GitHub"), ("kube", "Kubernetes")],
        snippets: [("my signature", "Thanks,\nShivam")]))

    private func assertFormats(_ cases: [(String, String)], file: StaticString = #filePath, line: UInt = #line) {
        for (input, expected) in cases {
            XCTAssertEqual(expected, formatter.format(input), input, file: file, line: line)
        }
    }

    func testRemovesFillerWordsOnly() {
        assertFormats([
            ("Um, I think we should, uh, ship it.", "I think we should, ship it."),
            ("Uh so the build is green.", "So the build is green."),
            ("Hmm. Let me check.", "Let me check."),
            ("The umbrella is here.", "The umbrella is here."),
        ])
    }

    func testCleansALongHinglishDictation() {
        let spoken = """
            Haan to like English mein bole ki Indian mein bole. Bolte jao. Bekhate hain. Ok. Thik hai to like ek \
            data scrapping tool banaana hai jismen basically for example koi bhi jaise business category hota hai \
            thik hai na to like for example ham kisi business ko search karte hain thik hai na to business ko jo aap \
            search kar rahe hain to aas paas ke jitne bhi uski areas hai. Thik hai na? To vah us area ke saare saare \
            business listing ka vah data nikaal le. For example, like for example there is a place a, thik hai? To \
            vahaan par, To us jagah par usi business se related aur bhi kitne businesses hain vah pata hona chaahie \
            plus vah business jo place a hai vah kis rank par vah kis rank par hai Google business mein thik hai na? \
            Vah pata hona chaahie and it should be. Grid format ki is area mein aap 20th number par aate hain, is \
            number is area mein first number par aata hai, is tarike se ek final result hona chaahie. Ok.
            """
        let clean = """
            English mein bole ki Indian mein bole. Bolte jao. Bekhate hain. Ek data scrapping tool banaana hai \
            jismen for example koi bhi jaise business category hota hai, for example ham kisi business ko search \
            karte hain, to business ko jo aap search kar rahe hain to aas paas ke jitne bhi uski areas hai. To vah \
            us area ke saare saare business listing ka vah data nikaal le. For example there is a place a. To vahaan \
            par, To us jagah par usi business se related aur bhi kitne businesses hain vah pata hona chaahie plus \
            vah business jo place a hai vah kis rank par hai Google business mein. Vah pata hona chaahie and it \
            should be. Grid format ki is area mein aap 20th number par aate hain, is number is area mein first \
            number par aata hai, is tarike se ek final result hona chaahie.
            """
        XCTAssertEqual(clean, formatter.format(spoken))
    }

    func testFillerRemovalKeepsDeliberateRepeatsAndRealQuestions() {
        assertFormats([
            ("Dear John new line new line thanks for the update", "Dear John\n\nThanks for the update"),
            ("My PIN is one two one two", "My PIN is one two one two"),
            ("The code is 1 2 1 2", "The code is 1 2 1 2"),
            ("Papa ki tabiyat thik hai na?", "Papa ki tabiyat thik hai na?"),
            ("Ghar pe sab log thik hain na?", "Ghar pe sab log thik hain na?"),
            ("Kal milte hain thik hai na?", "Kal milte hain."),
            ("So like I said we need more tests.", "So like I said we need more tests."),
            ("So okay to proceed with the merge?", "So okay to proceed with the merge?"),
            ("Haan. Main aa raha hoon.", "Haan. Main aa raha hoon."),
            ("Thik hai na?", "Thik hai na?"),
        ])
    }

    func testRemovesEnglishAndHinglishDiscourseFillers() {
        assertFormats([
            ("Haan to like English mein bolo. Bolte jao.", "English mein bolo. Bolte jao."),
            ("Ok. Thik hai to like ek data scrapping tool banaana hai.", "Ek data scrapping tool banaana hai."),
            ("Category hota hai thik hai na to like for example ham search karte hain.",
             "Category hota hai, for example ham search karte hain."),
            ("Uski ranking pata honi chahiye thik hai na? Vah important hai.",
             "Uski ranking pata honi chahiye. Vah important hai."),
            ("There is a place A, thik hai? To vahaan par dekho.", "There is a place A. To vahaan par dekho."),
            ("For example, like for example there is a cafe.", "For example there is a cafe."),
            ("Jismen basically sab listings hon.", "Jismen sab listings hon."),
            ("Okay so let's ship it.", "Let's ship it."),
            ("So, you know, the build is green.", "So, the build is green."),
            ("I mean, it works.", "It works."),
            ("Vah kis rank par vah kis rank par hai.", "Vah kis rank par hai."),
            ("Final result hona chahiye. Ok.", "Final result hona chahiye."),
        ])
    }

    func testKeepsWordsThatCarryMeaning() {
        for input in [
            "Ok to proceed with the merge?",
            "To do that we need more data.",
            "Kya sab thik hai na?",
            "Do you know him?",
            "Right now the build is green.",
            "Dheere dheere chalo.",
            "Haan, main aa raha hoon.",
            "I mean it.",
            "I like it, you know the drill.",
            "Ok.",
            "Yes. I'll be there.",
            "Haan to main kal aaunga.",
        ] {
            XCTAssertEqual(input, formatter.format(input))
        }
    }

    func testSpokenPunctuation() {
        assertFormats([
            ("Hello comma how are you question mark", "Hello, how are you?"),
            ("Wait exclamation mark that worked", "Wait! That worked"),
            ("Notes colon buy milk", "Notes: buy milk"),
            ("The trial period ended period", "The trial period ended."),
        ])
    }

    func testSpokenNewLinesBecomeLineBreaks() {
        XCTAssertEqual(
            "First item\nSecond item\n\nNext section",
            formatter.format("First item new line second item new paragraph next section"))
    }

    // Rule-based (no language model): "scratch that" removes the phrase spoken just before it, back to the previous
    // sentence or comma boundary.
    func testInlineScratchThatDropsThePreviousClause() {
        assertFormats([
            ("Ship it today. Ship it tomorrow, scratch that, ship it Friday.", "Ship it today. Ship it Friday."),
            ("I'll call you tomorrow. Scratch that. I'll email you.", "I'll email you."),
            ("Send it to John scratch that send it to Sarah.", "Send it to Sarah."),
        ])
    }

    func testReplacementsAreWholeWordAndCaseInsensitive() {
        XCTAssertEqual(
            "Push to GitHub and deploy to Kubernetes.", formatter.format("Push to Git Hub and deploy to kube."))
        XCTAssertEqual("Kubeflow stays.", formatter.format("Kubeflow stays."))
    }

    func testSnippetsExpandWholePhrase() {
        for input in ["My signature.", "Insert my signature"] {
            XCTAssertEqual("Thanks,\nShivam", formatter.format(input), input)
        }
    }

    func testContinuationLowercasesCommonWordsButNotNames() {
        XCTAssertEqual("and then deploy it.", formatter.format("And then deploy it.", continuesSentence: true))
        XCTAssertEqual("GitHub is down.", formatter.format("GitHub is down.", continuesSentence: true))
        XCTAssertEqual("I think so.", formatter.format("I think so.", continuesSentence: true))
    }

    func testSearchFieldsDropTheTrailingFullStop() {
        XCTAssertEqual("Weather in Bangalore", formatter.format("Weather in Bangalore.", searchField: true))
    }

    func testNothingLeftReturnsEmpty() {
        for input in ["", "Um.", "[BLANK_AUDIO]"] {
            XCTAssertEqual("", formatter.format(input), input)
        }
    }
}
