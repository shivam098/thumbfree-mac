import XCTest
@testable import ThumbFreeCore

private let rate = 16000

/// `(TimeSpan.FromSeconds(start), TimeSpan.FromSeconds(end))` from the C# test: .NET keeps whole ticks of 100 ns, so
/// the seconds here are the same doubles as there, and every sample position comes out the same.
private func seg(_ start: Double, _ end: Double) -> SpeechRegion { SpeechRegion(start: ticks(start), end: ticks(end)) }

private func ticks(_ seconds: Double) -> Double { Double(Int64(seconds * 10_000_000)) / 10_000_000 }

/// Audio whose sample values are their absolute index, so fakes can tell which part they got.
private func audio(_ seconds: Double) -> [Float] { (0..<Int(Double(rate) * seconds)).map { Float($0) } }

/// Speech detector over absolute regions, answering for any slice of `audio` (as in C#, `from` is single precision).
private func detector(_ absolute: SpeechRegion...) -> ([Float]) -> [SpeechRegion] {
    { slice in
        let from = Double(slice.isEmpty ? 0 : slice[0] / Float(rate))
        let to = from + Double(slice.count) / Double(rate)
        return absolute
            .filter { $0.end > from && $0.start < to }
            .map { seg(max($0.start, from) - from, min($0.end, to) - from) }
    }
}

/// `$"[{slice[0] / Rate:0.#}-{(slice[^1] + 1) / Rate:0.#}]"`.
private func label(_ slice: [Float]) -> String {
    "[\(oneDecimal(slice[0] / Float(rate)))-\(oneDecimal((slice[slice.count - 1] + 1) / Float(rate)))]"
}

/// .NET's "0.#" format: at most one decimal, rounded half away from zero.
private func oneDecimal(_ value: Float) -> String {
    let rounded = (Double(value) * 10).rounded(.toNearestOrAwayFromZero) / 10
    return rounded == rounded.rounded(.towardZero) ? String(Int(rounded)) : String(rounded)
}

/// Calls the fakes saw.
private final class Calls {
    var labels: [String] = []
    var count = 0
}

private struct DetectionFailed: Error {}

/// The same cases as thumbfree-windows tests/ThumbFree.Core.Tests/DictationPreviewTests.cs.
final class DictationPreviewTests: XCTestCase {
    func testShortRecordingIsTranscribedWholeEachUpdate() async throws {
        let calls = Calls()
        let preview = DictationPreview(
            transcribe: { calls.labels.append(label($0)); return "hello" },
            detect: detector(seg(0.5, 3)),
            sampleRate: rate)

        let first = try await preview.update(audio(2))
        let second = try await preview.update(audio(4))
        XCTAssertEqual("hello", first)
        XCTAssertEqual("hello", second)
        XCTAssertEqual(["[0-2]", "[0-4]"], calls.labels)
        XCTAssertEqual(0, preview.committedSamples)
    }

    func testSilenceIsNotTranscribed() async throws {
        let calls = Calls()
        let preview = DictationPreview(
            transcribe: { _ in calls.count += 1; return "you" }, detect: detector(), sampleRate: rate)

        let text = try await preview.update(audio(3))
        XCTAssertEqual("", text)
        XCTAssertEqual(0, calls.count)
    }

    func testLongRecordingCommitsTheOldestPartAtAPauseAndKeepsItsText() async throws {
        let calls = Calls()
        let preview = DictationPreview(
            transcribe: { calls.labels.append(label($0)); return label($0) },
            detect: detector(seg(0, 5), seg(6, 11), seg(12.5, 20)),
            sampleRate: rate)

        var text = try await preview.update(audio(16))

        // Latest pause inside the 12 s window is between 11 s and 12.5 s.
        XCTAssertEqual(rate * 23 / 2 + rate * 1 / 4, preview.committedSamples)
        XCTAssertEqual(["[0-11.8]", "[11.8-16]"], calls.labels)
        XCTAssertEqual("[0-11.8] [11.8-16]", text)

        calls.labels.removeAll()
        let longer = audio(18)
        text = try await preview.update(Array(longer[preview.committedSamples...]))
        XCTAssertEqual(["[11.8-18]"], calls.labels)
        XCTAssertEqual("[0-11.8] [11.8-18]", text)
    }

    func testUnbrokenSpeechIsCutAtTheWindow() async throws {
        let preview = DictationPreview(transcribe: { label($0) }, detect: detector(seg(0, 30)), sampleRate: rate)

        let text = try await preview.update(audio(30))

        XCTAssertEqual(rate * 24, preview.committedSamples)
        XCTAssertEqual("[0-12] [12-24] [24-30]", text)
    }

    func testLongSilenceIsDroppedWithoutTranscribing() async throws {
        let calls = Calls()
        let preview = DictationPreview(
            transcribe: { _ in calls.count += 1; return "x" }, detect: detector(), sampleRate: rate)

        let text = try await preview.update(audio(20))
        XCTAssertEqual("", text)
        XCTAssertEqual(rate * 19, preview.committedSamples)
        XCTAssertEqual(0, calls.count)
    }

    func testWithoutADetectorAllAudioCountsAsSpeech() async throws {
        let preview = DictationPreview(transcribe: { label($0) }, detect: nil, sampleRate: rate)

        let text = try await preview.update(audio(2))
        XCTAssertEqual("[0-2]", text)
    }

    func testCommitPointPrefersTheLatestPauseInsideTheWindow() {
        let speech = [seg(0, 2), seg(3, 6), seg(7, 13)]
        let cut = DictationPreview.findCommitPoint(speech, rate * 13, rate, rate * 12, rate * 3)
        XCTAssertEqual(rate * 13 / 2, cut)
    }

    func testCommitPointIgnoresPausesTooEarlyToBeWorthCommitting() {
        let cut = DictationPreview.findCommitPoint([seg(0, 1), seg(1.5, 14)], rate * 14, rate, rate * 12, rate * 3)
        XCTAssertEqual(rate * 12, cut)
    }

    func testWithPhrasesOnEachPauseEndsAPhraseTranscribedOnceAtFinalQuality() async throws {
        let previews = Calls()
        let commits = Calls()
        let preview = DictationPreview(
            transcribe: { previews.labels.append(label($0)); return "tentative " + label($0) },
            detect: detector(seg(0.2, 2), seg(3, 5), seg(5.4, 6.5)),
            sampleRate: rate,
            phrasePauseMs: 700,
            commit: { commits.labels.append(label($0)); return label($0) })

        // 1 s of silence after 2 s ends the first phrase (cut 0.3 s after the speech); 5 to 5.4 s is too short a pause.
        var text = try await preview.update(audio(6.5))
        XCTAssertEqual(["[0-2.3]"], commits.labels)
        XCTAssertEqual(["[0-2.3]"], preview.phrases)
        XCTAssertEqual("tentative [2.3-6.5]", preview.tentative)
        XCTAssertEqual("[0-2.3] tentative [2.3-6.5]", text)
        XCTAssertEqual(rate * 23 / 10, preview.committedSamples)

        // Trailing silence of 0.7 s ends the phrase being spoken too; nothing is left to preview.
        commits.labels.removeAll()
        let longer = audio(7.4)
        text = try await preview.update(Array(longer[preview.committedSamples...]))
        XCTAssertEqual(["[2.3-6.8]"], commits.labels)
        XCTAssertEqual(["[0-2.3]", "[2.3-6.8]"], preview.phrases)
        XCTAssertEqual("", preview.tentative)
        XCTAssertEqual("[0-2.3] [2.3-6.8]", text)
    }

    func testAPhraseEndsOnlyAfterALongEnoughPause() {
        XCTAssertNil(DictationPreview.findPhraseEnd([seg(0, 2), seg(2.5, 4)], rate * 4, rate, rate * 7 / 10))
        XCTAssertNil(DictationPreview.findPhraseEnd([], rate * 4, rate, rate * 7 / 10))
        let pause = rate * 7 / 10
        XCTAssertEqual(rate * 23 / 10, DictationPreview.findPhraseEnd([seg(0, 2), seg(3, 4)], rate * 4, rate, pause))
        XCTAssertEqual(rate * 43 / 10, DictationPreview.findPhraseEnd([seg(0, 2), seg(2.5, 4)], rate * 5, rate, pause))
    }

    // MARK: Beyond the C# tests

    func testADetectorThatFailsStopsTheUpdate() async {
        // As in C#, its error comes through: taken for silence, the audio would be dropped.
        let calls = Calls()
        let speech = detector(seg(0.2, 2), seg(3, 5))
        let preview = DictationPreview(
            transcribe: { "tentative " + label($0) },
            detect: { slice in
                calls.count += 1
                if calls.count == 2 {
                    throw DetectionFailed()
                }

                return speech(slice)
            },
            sampleRate: rate,
            phrasePauseMs: 700,
            commit: { label($0) })

        do {
            _ = try await preview.update(audio(6))
            XCTFail("The update should have failed")
        } catch {
            XCTAssertTrue(error is DetectionFailed)
        }

        // The phrase kept before it failed stays kept; nothing is previewed.
        XCTAssertEqual(["[0-2.3]"], preview.phrases)
        XCTAssertEqual(rate * 23 / 10, preview.committedSamples)
        XCTAssertEqual("", preview.tentative)
    }
}
