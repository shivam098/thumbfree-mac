import XCTest
@testable import ThumbFreeCore

/// The same cases as thumbfree-windows tests/ThumbFree.Core.Tests/SharedCoreTests.cs.
final class LiveTextTests: XCTestCase {
    func testLiveTextKeepsTheRecognizersCapitalsAndTakesThePunctuation() {
        XCTAssertEqual(
            "I tested it on YouTube videos of different genres.",
            LiveText.mergePunctuation("I tested it on YouTube videos of different genres", "I tested it on YOUTUBE videos of different genres."))
        XCTAssertEqual(
            "Hey, Tim would love to connect. Are you available on Friday? Thanks, Ben",
            LiveText.mergePunctuation(
                "hey Tim would love to connect are you available on Friday thanks Ben",
                "Hey, Tim would love to connect. Are you available on Friday? Thanks, Ben"))

        // Different words: keep the recognizer's text.
        XCTAssertEqual("send the logs", LiveText.mergePunctuation("send the logs", "Send the log."))
        XCTAssertEqual("send the logs", LiveText.mergePunctuation(" send the logs ", ""))
        XCTAssertEqual("One. two three", LiveText.join(["One."], " two three "))
        XCTAssertEqual("One.", LiveText.join(["One."], ""))
        XCTAssertEqual("Please send me the latest build logs.", LiveText.endSentence("Please send me the latest build logs, "))
        XCTAssertEqual("Are you free?", LiveText.endSentence("Are you free?"))
        XCTAssertEqual("Meet at 4 pm.", LiveText.endSentence("Meet at 4 pm"))
        XCTAssertEqual("", LiveText.endSentence(""))

        // The recognizer's own marks stay where the model adds none; the model's win; never two in a row.
        XCTAssertEqual(
            "So I wanted to check. Then push the build.",
            LiveText.mergePunctuation("so I wanted to check. then push the build.", "So I wanted to check then push the build."))
        XCTAssertEqual("Build, logs.", LiveText.mergePunctuation("build. logs", "build, logs."))
        XCTAssertEqual(
            "Please send me the latest build, logs.",
            LiveText.mergePunctuation("Please send me the latest build logs.", "Please send me the latest build, logs.,"))
        XCTAssertEqual("Push the build.", LiveText.mergePunctuation("push the build.", "Push the Build.."))
        XCTAssertEqual("Ready? Go!", LiveText.mergePunctuation("ready go", "Ready?. Go!!"))
        XCTAssertEqual("We shipped it, today", LiveText.mergePunctuation("we shipped it, today", "We shipped it,. today"))
    }

    func testDotNetTextRules() {
        // .NET's simple case mapping: ß has no one-letter capital.
        XCTAssertEqual("ß", String(Character(DotNet.toUpperInvariant("ß"))))
        XCTAssertTrue(DotNet.equalsOrdinalIgnoreCase("YouTube", "YOUTUBE"))
        // ² is a number but not a decimal digit, so no full stop is added after it.
        XCTAssertEqual("area in m²", LiveText.endSentence("area in m²"))
        // A non-breaking space is whitespace, a zero-width space isn't.
        XCTAssertEqual(["a", "b"], DotNet.words("a\u{00A0}b"))
        XCTAssertEqual(["a\u{200B}b"], DotNet.words("a\u{200B}b"))
    }
}
