import XCTest
@testable import ThumbFreeCore

/// The level meter's scale: -60 dBFS (and silence) is 0, -12 dBFS and louder is 1, linear in decibels between.
final class AudioLevelTests: XCTestCase {
    func testTheLevelIsLinearInDecibelsBetweenTheFloorAndTheCeiling() {
        XCTAssertEqual(0, AudioLevel.of([Float]()))
        XCTAssertEqual(0, AudioLevel.of([Float](repeating: 0, count: 160)))
        XCTAssertEqual(1, AudioLevel.of([Float](repeating: 1, count: 160)))
        XCTAssertEqual(0, AudioLevel.of([Float](repeating: 0.001, count: 160)), accuracy: 1e-6)

        // -36 dBFS is halfway, whatever the sign of each sample.
        let amplitude = Float(pow(10, -36.0 / 20))
        XCTAssertEqual(0.5, AudioLevel.of([Float](repeating: amplitude, count: 160)), accuracy: 1e-5)
        XCTAssertEqual(0.5, AudioLevel.of((0..<160).map { $0 % 2 == 0 ? amplitude : -amplitude }), accuracy: 1e-5)
        XCTAssertEqual(0.5, AudioLevel.of([Float](repeating: amplitude, count: 160)[10..<100]), accuracy: 1e-5)
    }
}
