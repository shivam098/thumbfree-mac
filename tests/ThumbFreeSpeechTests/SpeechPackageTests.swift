import XCTest
@testable import ThumbFreeSpeech

final class SpeechPackageTests: XCTestCase {
    func testTheSpeechLibraryLinksTheCore() {
        XCTAssertFalse(ThumbFreeSpeech.coreVersion.isEmpty)
    }
}
