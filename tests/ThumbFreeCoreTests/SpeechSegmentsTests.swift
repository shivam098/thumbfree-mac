import XCTest
@testable import ThumbFreeCore

private let rate = 16000
private let tenSeconds = (0..<(rate * 10)).map { Float($0) }

/// Seconds as .NET's `TimeSpan.FromSeconds` keeps them (whole ticks of 100 ns), as in the C# test.
private func seg(_ start: Double, _ end: Double) -> SpeechRegion { SpeechRegion(start: ticks(start), end: ticks(end)) }

private func ticks(_ seconds: Double) -> Double { Double(Int64(seconds * 10_000_000)) / 10_000_000 }

/// The same cases as thumbfree-windows tests/ThumbFree.Core.Tests/SpeechSegmentsTests.cs.
final class SpeechSegmentsTests: XCTestCase {
    func testNoSpeechGivesNoPieces() {
        XCTAssertTrue(SpeechSegments.split(tenSeconds, [], sampleRate: rate, minGapMs: 600, padMs: 250).isEmpty)
        XCTAssertTrue(SpeechSegments.chunk(tenSeconds, [], sampleRate: rate, maxMs: 14000, padMs: 200).isEmpty)
    }

    func testSplitSeparatesRegionsWithALongGapAndMergesShortGaps() {
        let regions = [seg(1, 3), seg(3.3, 4), seg(6, 7)]
        let pieces = SpeechSegments.split(tenSeconds, regions, sampleRate: rate, minGapMs: 600, padMs: 250)
        XCTAssertEqual(2, pieces.count)
        XCTAssertEqual(Double(rate) * 0.75, Double(pieces[0][0]))
        XCTAssertEqual(Int(Double(rate) * 4.25), pieces[0].count + Int(pieces[0][0]))
        XCTAssertEqual(Double(rate) * 5.75, Double(pieces[1][0]))
    }

    func testChunkKeepsShortDictationWhole() {
        let regions = [seg(1, 3), seg(4, 6)]
        let chunks = SpeechSegments.chunk(tenSeconds, regions, sampleRate: rate, maxMs: 14000, padMs: 200)
        XCTAssertEqual(1, chunks.count)
    }

    func testChunkCutsLongDictationAtPausesWithinTheLimit() {
        let audio = [Float](repeating: 0, count: rate * 40)
        let regions = [seg(0, 8), seg(9, 13), seg(14, 20), seg(21, 30)]
        let chunks = SpeechSegments.chunk(audio, regions, sampleRate: rate, maxMs: 14000, padMs: 200)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= rate * 14 })
        XCTAssertEqual(3, chunks.count)
    }

    func testChunkHardSplitsASingleOverlongRegion() {
        let audio = [Float](repeating: 0, count: rate * 40)
        let chunks = SpeechSegments.chunk(audio, [seg(0, 30)], sampleRate: rate, maxMs: 14000, padMs: 0)
        XCTAssertEqual(3, chunks.count)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= rate * 14 })
        XCTAssertEqual(rate * 30, chunks.reduce(0) { $0 + $1.count })
    }
}
