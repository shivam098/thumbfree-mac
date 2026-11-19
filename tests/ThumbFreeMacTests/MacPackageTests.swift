import XCTest
@testable import ThumbFreeMac

final class MacPackageTests: XCTestCase {
    func testTheMacLibraryLinksTheCore() {
        XCTAssertFalse(ThumbFreeMac.coreVersion.isEmpty)
    }
}
