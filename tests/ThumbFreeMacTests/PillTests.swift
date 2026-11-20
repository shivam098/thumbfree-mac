import CoreGraphics
import XCTest
@testable import ThumbFreeMac

/// What the pill shows, without a window: the same states, texts, colours and timings as the Windows pill
/// (thumbfree-windows src/ThumbFree.App/UI/OverlayWindow.xaml.cs), and where it goes.
final class PillTests: XCTestCase {
    func testWhileIdleThePillRestsHiddenUnlessPinned() {
        var pill = Pill.Model()
        let display = pill.display

        XCTAssertEqual("Ready · tap Fn to dictate", display.mode)
        XCTAssertEqual(Pill.Colour(0x81C995), display.dot)
        XCTAssertFalse(display.dotPulses)
        XCTAssertNil(display.bars)
        XCTAssertNil(display.hint)
        XCTAssertNil(display.dots)
        XCTAssertFalse(pill.isVisible)

        pill.pinned = true
        XCTAssertTrue(pill.isVisible)

        pill.setPaused(true)
        XCTAssertEqual("Paused · dictation keys are off", pill.display.mode)
        XCTAssertEqual(Pill.Colour(0x9AA0A6), pill.display.dot)
    }

    func testListeningShowsTheLevelMeterAndHowToFinish() {
        var pill = Pill.Model()
        pill.showActivity(Pill.listening)
        let display = pill.display

        XCTAssertEqual("Listening…", display.mode)
        XCTAssertNil(display.dot)
        XCTAssertEqual([4, 4, 4, 4, 4], display.bars)
        XCTAssertEqual("Fn to finish · Esc to cancel", display.hint)
        XCTAssertTrue(pill.isVisible)

        var other = Pill.Model(keyName: "Right Option")
        XCTAssertEqual("Ready · tap Right Option to dictate", other.display.mode)
        other.showActivity(Pill.listening)
        XCTAssertEqual("Right Option to finish · Esc to cancel", other.display.hint)
    }

    func testTheLevelRisesAtOnceAndFallsGently() throws {
        var pill = Pill.Model()
        pill.showActivity(Pill.listening)

        pill.showInputLevel(0.5) { 0.5 }
        XCTAssertEqual(0.5, pill.level, accuracy: 1e-9)
        try assertBars([7.85, 9.6, 11, 9.6, 7.85], pill)

        pill.showInputLevel(0) { 0.5 }
        XCTAssertEqual(0.3, pill.level, accuracy: 1e-9)

        // Full level, wobbling up 20%: no bar grows past 18 points.
        pill.showInputLevel(1) { 1 }
        XCTAssertEqual(1, pill.level, accuracy: 1e-9)
        try assertBars([13.24, 17.44, 18, 17.44, 13.24], pill)

        // A quiet level doesn't wobble.
        pill.showActivity(Pill.listening)
        pill.showInputLevel(0.04) { 1 }
        try assertBars([4.308, 4.448, 4.56, 4.448, 4.308], pill)
    }

    func testTheLevelMovesOnlyWhileListening() {
        var pill = Pill.Model()
        pill.showInputLevel(0.8) { 0.5 }
        XCTAssertEqual(0, pill.level)

        pill.showActivity(Pill.listening)
        pill.showInputLevel(0.8) { 0.5 }
        pill.showActivity(Pill.listening)
        XCTAssertEqual(0, pill.level, "a new dictation starts from silence")
    }

    func testTranscribingAnimatesAndKeepsTheWordsHeardDimmed() {
        var pill = Pill.Model()
        pill.showActivity(Pill.listening)
        pill.showPreview("Hello there")
        XCTAssertEqual("Hello there", pill.display.preview)
        XCTAssertEqual(1, pill.display.previewOpacity)

        pill.showActivity(Pill.transcribing)
        var display = pill.display
        XCTAssertEqual("Transcribing", display.mode)
        XCTAssertEqual("", display.dots)
        XCTAssertEqual(Pill.Colour(0xFBBC04), display.dot)
        XCTAssertTrue(display.dotPulses)
        XCTAssertNil(display.bars)
        XCTAssertNil(display.hint)
        XCTAssertEqual(0.6, display.previewOpacity)

        var dots: [String?] = []
        for _ in 0..<4 {
            pill.advanceDots()
            dots.append(pill.display.dots)
        }

        XCTAssertEqual([".", "..", "...", ""], dots)

        // The last words stay until the text is typed.
        pill.showPreview(nil)
        pill.showPreview("")
        XCTAssertEqual("Hello there", pill.display.preview)

        // Still transcribing: the dots go on.
        pill.advanceDots()
        pill.showActivity(Pill.transcribing)
        XCTAssertEqual(".", pill.display.dots)

        pill.showActivity(nil)
        display = pill.display
        XCTAssertNil(display.preview)
        XCTAssertNil(display.dots)
        XCTAssertEqual("Ready · tap Fn to dictate", display.mode)
        XCTAssertFalse(pill.isVisible)

        // The next transcription's dots start again.
        pill.showActivity(Pill.transcribing)
        XCTAssertEqual("", pill.display.dots)
    }

    func testOtherActivitiesShowWithTheAmberDot() {
        var pill = Pill.Model()
        pill.showActivity("Loading speech model…")
        let display = pill.display

        XCTAssertEqual("Loading speech model…", display.mode)
        XCTAssertEqual(Pill.Colour(0xFBBC04), display.dot)
        XCTAssertFalse(display.dotPulses)
        XCTAssertNil(display.dots)
        XCTAssertTrue(pill.isVisible)
    }

    func testMessagesShowInTheirColoursThenFade() {
        var pill = Pill.Model()
        for (kind, colour) in [
            (Pill.Status.Kind.info, 0xE8EAED), (.success, 0x81C995), (.warning, 0xFDD663), (.error, 0xF28B82),
        ] as [(Pill.Status.Kind, UInt32)] {
            pill.showStatus(Pill.Status(kind, "Dictation cancelled."))
            XCTAssertEqual("Dictation cancelled.", pill.display.message)
            XCTAssertEqual(Pill.Colour(colour), pill.display.messageColour)
        }

        pill.showStatus(Pill.Status(.error, "Couldn't transcribe that. Try again.", heard: "send the logs"))
        XCTAssertEqual("Heard: “send the logs”", pill.display.heard)
        XCTAssertTrue(pill.isVisible)

        pill.fadeStatus()
        XCTAssertNil(pill.display.message)
        XCTAssertNil(pill.display.heard)
        XCTAssertFalse(pill.isVisible)
    }

    func testTypedStaysQuiet() {
        var pill = Pill.Model()

        pill.showStatus(Pill.Status(.success, "Typed.", heard: "Hello there."))
        XCTAssertNil(pill.display.message)
        XCTAssertNil(pill.display.heard, "what was heard shows only under a problem")
        XCTAssertFalse(pill.isVisible)

        pill.showStatus(Pill.Status(.warning, "", heard: "Hello"))
        XCTAssertNil(pill.display.message)
        XCTAssertEqual("Heard: “Hello”", pill.display.heard)
    }

    func testTheWordsHeardKeepTheLatestOnesAndHideTheMessage() {
        var pill = Pill.Model()
        pill.showActivity(Pill.listening)
        pill.showStatus(Pill.Status(.warning, "No sound from the microphone. Is another app or a call using it?"))

        let a = String(repeating: "a", count: 100)
        let b = String(repeating: "b", count: 100)
        pill.showPreview(a + " " + b)
        XCTAssertEqual("…" + b, pill.display.preview, "from the first word in the last 150")
        XCTAssertNil(pill.display.message)

        let c = String(repeating: "c", count: 160)
        pill.showPreview(c)
        XCTAssertEqual("…" + String(repeating: "c", count: 150), pill.display.preview, "no word starts there")

        // A cut inside an emoji's two units starts after it.
        pill.showPreview(String(repeating: "😀", count: 80) + "y")
        XCTAssertEqual("…" + String(repeating: "😀", count: 74) + "y", pill.display.preview)

        pill.showPreview("Hi Sam,\r\nThanks\nBen")
        XCTAssertEqual("Hi Sam, ↵ Thanks ↵ Ben", pill.display.preview)

        pill.showPreview(nil)
        XCTAssertNil(pill.display.preview)
    }

    func testTheLanguageBadge() {
        var pill = Pill.Model()
        XCTAssertNil(pill.display.badge)

        pill.setDictationLanguage(hinglish: true, accurate: false)
        XCTAssertEqual("HI + EN", pill.display.badge)

        pill.setDictationLanguage(hinglish: true, accurate: true)
        XCTAssertEqual("HI + EN · accurate", pill.display.badge)

        pill.setDictationLanguage(hinglish: false, accurate: true)
        XCTAssertNil(pill.display.badge)
    }

    func testThePillSitsAtTheBottomCentreOfTheFocusedWindowsScreen() throws {
        let size = CGSize(width: 300, height: 40)
        let main = Pill.Screen(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805))
        let right = Pill.Screen(
            frame: CGRect(x: 1440, y: -180, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 1440, y: -180, width: 1920, height: 1055))
        let above = Pill.Screen(
            frame: CGRect(x: 0, y: 900, width: 1920, height: 1080),
            visibleFrame: CGRect(x: 0, y: 900, width: 1920, height: 1055))
        let screens = [main, right, above]

        // No window: the main screen, 16 points above the Dock.
        XCTAssertEqual(
            CGRect(x: 570, y: 86, width: 300, height: 40), Pill.frame(size: size, window: nil, screens: screens))

        // Accessibility's y runs down from the top of the main screen.
        let onRight = CGRect(x: 1600, y: 100, width: 800, height: 600)
        XCTAssertEqual(
            CGRect(x: 2250, y: -164, width: 300, height: 40), Pill.frame(size: size, window: onRight, screens: screens))
        let onAbove = CGRect(x: 100, y: -900, width: 800, height: 600)
        XCTAssertEqual(
            CGRect(x: 810, y: 916, width: 300, height: 40), Pill.frame(size: size, window: onAbove, screens: screens))

        // Mostly on the main screen.
        let across = CGRect(x: 1000, y: 200, width: 600, height: 400)
        XCTAssertEqual(570, try XCTUnwrap(Pill.frame(size: size, window: across, screens: screens)).minX)

        // On no screen: the fallback.
        let nowhere = CGRect(x: 9000, y: 9000, width: 100, height: 100)
        XCTAssertEqual(2250, try XCTUnwrap(Pill.frame(size: size, window: nowhere, screens: screens, fallback: 1)).minX)

        XCTAssertNil(Pill.frame(size: size, window: nil, screens: []))
    }

    private func assertBars(_ expected: [Double], _ pill: Pill.Model, line: UInt = #line) throws {
        let bars = try XCTUnwrap(pill.display.bars, line: line)
        XCTAssertEqual(expected.count, bars.count, line: line)
        for (want, got) in zip(expected, bars) {
            XCTAssertEqual(want, got, accuracy: 1e-6, line: line)
        }
    }
}
