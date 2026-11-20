import XCTest
@testable import ThumbFreeMac

/// The cases of thumbfree-windows tests/ThumbFree.Core.Tests/TapToDictateKeysTests.cs that apply to Fn, where a tap
/// counts once the key is let go. The audio level cases of that file are in ThumbFreeCoreTests' AudioLevelTests.
final class FnTapKeysTests: XCTestCase {
    private func press(_ keys: inout FnTapKeys, _ key: FnTapKeys.Key = .fn) -> FnTapKeys.Result {
        keys.process(key, down: true)
    }

    private func release(_ keys: inout FnTapKeys, _ key: FnTapKeys.Key = .fn) -> FnTapKeys.Result {
        keys.process(key, down: false)
    }

    private func tap(_ keys: inout FnTapKeys, _ key: FnTapKeys.Key = .fn) -> [FnTapKeys.Command?] {
        [press(&keys, key).command, release(&keys, key).command]
    }

    func testTapStartsRecordingWhenTheKeyIsLetGo() {
        var keys = FnTapKeys()

        XCTAssertEqual(FnTapKeys.Result(), press(&keys))
        XCTAssertFalse(keys.isRecording)
        XCTAssertEqual(FnTapKeys.Result(.start), release(&keys))
        XCTAssertTrue(keys.isRecording)
    }

    func testSecondTapFinishesWhenTheKeyIsLetGo() {
        var keys = FnTapKeys()
        _ = tap(&keys)

        XCTAssertNil(press(&keys).command)
        XCTAssertTrue(keys.isRecording)
        XCTAssertEqual(FnTapKeys.Result(.finish), release(&keys))
        XCTAssertFalse(keys.isRecording)
        XCTAssertEqual([nil, .start], tap(&keys))
    }

    func testHoldingTheKeyStartsOnceWhenItIsLetGo() {
        var keys = FnTapKeys()

        for _ in 0..<20 {
            XCTAssertNil(press(&keys).command)
        }

        XCTAssertEqual(.start, release(&keys).command)
        XCTAssertNil(release(&keys).command)
        XCTAssertTrue(keys.isRecording)
    }

    func testOtherKeysPassThrough() {
        var keys = FnTapKeys()
        XCTAssertEqual(FnTapKeys.Result(), keys.process(.other, down: true))
        XCTAssertEqual(FnTapKeys.Result(), keys.process(.other, down: false))
        _ = tap(&keys)

        XCTAssertEqual(FnTapKeys.Result(), keys.process(.other, down: true))
        XCTAssertEqual(FnTapKeys.Result(), keys.process(.other, down: false))
        XCTAssertTrue(keys.isRecording)
    }

    func testEscCancelsWhileRecordingAndIsSwallowed() {
        var keys = FnTapKeys()
        _ = tap(&keys)

        XCTAssertEqual(FnTapKeys.Result(.cancel, swallow: true), keys.process(.escape, down: true))
        XCTAssertFalse(keys.isRecording)
        XCTAssertEqual(FnTapKeys.Result(), keys.process(.escape, down: false))
        XCTAssertEqual([nil, .start], tap(&keys))
    }

    func testEscPassesThroughWhenNotRecording() {
        var keys = FnTapKeys()

        XCTAssertEqual(FnTapKeys.Result(), keys.process(.escape, down: true))
    }

    /// Windows: a shortcut with the Ctrl+Win that started recording cancels it. Here nothing has started yet.
    func testShortcutWithTheKeyStartsNothing() {
        var keys = FnTapKeys()

        _ = press(&keys)
        XCTAssertEqual(FnTapKeys.Result(), keys.process(.other, down: true))
        XCTAssertEqual(FnTapKeys.Result(), keys.process(.other, down: true))
        XCTAssertEqual(FnTapKeys.Result(), keys.process(.other, down: false))
        XCTAssertNil(release(&keys).command)
        XCTAssertFalse(keys.isRecording)
        XCTAssertEqual([nil, .start], tap(&keys))
    }

    func testShortcutWhileRecordingKeepsRecording() {
        var keys = FnTapKeys()
        _ = tap(&keys)

        _ = press(&keys)
        XCTAssertNil(keys.process(.other, down: true).command)
        XCTAssertNil(release(&keys).command)

        XCTAssertTrue(keys.isRecording)
        XCTAssertEqual([nil, .finish], tap(&keys))
    }

    func testEscWhileTheFinishingKeyIsHeldKeepsRecording() {
        var keys = FnTapKeys()
        _ = tap(&keys)

        _ = press(&keys)
        XCTAssertFalse(keys.process(.escape, down: true).swallow)
        XCTAssertNil(release(&keys).command)
        XCTAssertTrue(keys.isRecording)
    }

    func testRecordingThatStoppedOnItsOwnStartsAgainOnTheNextTap() {
        var keys = FnTapKeys()
        _ = tap(&keys)

        keys.isRecording = false

        XCTAssertEqual([nil, .start], tap(&keys))
    }

    func testStopOnItsOwnWhileTheFinishingKeyIsHeldNeitherFinishesNorStarts() {
        var keys = FnTapKeys()
        _ = tap(&keys)

        _ = press(&keys)
        keys.isRecording = false

        XCTAssertNil(release(&keys).command)
        XCTAssertFalse(keys.isRecording)
    }

    /// Windows: Ctrl or Win alone does nothing. The Mac has one key, and the one not chosen is just another key.
    func testTheKeyThatIsNotChosenDoesNothing() {
        var keys = FnTapKeys()
        XCTAssertEqual([nil, nil], tap(&keys, .rightOption))
        XCTAssertFalse(keys.isRecording)

        keys = FnTapKeys(tapKey: .rightOption)
        XCTAssertEqual([nil, nil], tap(&keys, .fn))
        XCTAssertFalse(keys.isRecording)
    }

    func testRightOptionStartsAndFinishesWhenChosen() {
        var keys = FnTapKeys(tapKey: .rightOption)

        XCTAssertEqual([nil, .start], tap(&keys, .rightOption))
        XCTAssertEqual([nil, .finish], tap(&keys, .rightOption))

        // Fn with Right Option, like Option with a letter, is a shortcut.
        _ = press(&keys, .rightOption)
        XCTAssertNil(keys.process(.fn, down: true).command)
        XCTAssertNil(release(&keys, .rightOption).command)
        XCTAssertFalse(keys.isRecording)
    }

    func testAKeyHeldFromBeforeAndLetGoDuringTheTapDoesNotSpoilIt() {
        var keys = FnTapKeys()
        _ = keys.process(.other, down: true)

        _ = press(&keys)
        XCTAssertNil(keys.process(.other, down: false).command)
        XCTAssertEqual(.start, release(&keys).command)
    }

    func testChangingTheKeyOrResettingForgetsAPressInProgress() {
        var keys = FnTapKeys()
        _ = press(&keys)
        keys.reset()
        XCTAssertNil(release(&keys).command)

        _ = press(&keys)
        keys.tapKey = .rightOption
        keys.tapKey = .fn
        XCTAssertNil(release(&keys).command)
        XCTAssertFalse(keys.isRecording)
        XCTAssertEqual([nil, .start], tap(&keys))
    }

    /// Secure Input hides the other key of Fn+↑ or Fn+Delete in a password field, so it looks like a tap: it starts
    /// nothing and says why.
    func testUnderSecureInputAPressNeverStartsSaysWhyAndStillFinishes() {
        var keys = FnTapKeys()
        for (atPress, atRelease) in [(true, true), (true, false), (false, true)] {
            XCTAssertEqual(FnTapKeys.Result(), keys.process(.fn, down: true, secureInput: atPress))
            XCTAssertEqual(
                FnTapKeys.Result(blocked: .secureInput), keys.process(.fn, down: false, secureInput: atRelease))
        }
        XCTAssertFalse(keys.isRecording)

        // Already recording: stopping the microphone is always safe.
        XCTAssertEqual([nil, .start], tap(&keys))
        XCTAssertNil(keys.process(.fn, down: true, secureInput: true).command)
        XCTAssertEqual(FnTapKeys.Result(.finish), keys.process(.fn, down: false, secureInput: true))
        XCTAssertFalse(keys.isRecording)
        XCTAssertEqual([nil, .start], tap(&keys))
    }

    /// A shortcut whose other key still shows (a modifier, a click) is only a shortcut, and a recording that started
    /// some other way while the key was down wouldn't start anyway: neither says it was blocked.
    func testOnlyWhatLooksLikeATapSaysItWasBlocked() {
        var keys = FnTapKeys()
        _ = keys.process(.fn, down: true, secureInput: true)
        _ = keys.process(.other, down: true)
        XCTAssertEqual(FnTapKeys.Result(), keys.process(.fn, down: false, secureInput: true))

        _ = keys.process(.fn, down: true, secureInput: true)
        keys.isRecording = true
        XCTAssertEqual(FnTapKeys.Result(), keys.process(.fn, down: false, secureInput: true))
        XCTAssertTrue(keys.isRecording)
    }

    /// A user switch mid-press, or another tap keeping the release: modifier keys don't repeat, so the next press of
    /// the key is a new one.
    func testALostReleaseDoesNotLeaveTheKeysStuck() {
        var keys = FnTapKeys()
        _ = press(&keys)
        XCTAssertNil(keys.process(.other, down: true).command)
        XCTAssertEqual([nil, .start], tap(&keys))

        _ = press(&keys)
        XCTAssertEqual([nil, .finish], tap(&keys))
        XCTAssertFalse(keys.isRecording)
    }
}
