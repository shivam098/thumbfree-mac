import Foundation
import XCTest
@testable import ThumbFreeCore

final class PackageTests: XCTestCase {
    func testTheSharedTestDataIsFound() throws {
        for name in ["formatter.tsv", "layout.tsv"] {
            let text = try String(contentsOf: TestData.vectors(name), encoding: .utf8)
            XCTAssertGreaterThan(text.split(separator: "\n").count, 10, name)
        }

        for name in ["dictation.wav", "genres.wav", "send-logs.wav"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: TestData.audio(name).path), name)
        }
    }
}
