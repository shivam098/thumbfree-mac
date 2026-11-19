import XCTest
@testable import ThumbFreeCore

final class ModelsTests: XCTestCase {
    func testTheCatalogPicksTheModelForEachLanguageAndTier() {
        XCTAssertEqual(ModelCatalog.forLanguage(.english, .live), ModelCatalog.englishLive)
        XCTAssertEqual(ModelCatalog.forLanguage(.english, .standard), ModelCatalog.englishFast)
        XCTAssertEqual(ModelCatalog.forLanguage(.english, .accurate), ModelCatalog.englishAccurate)
        // Hindi + English has no streaming model: its live tier is the standard model.
        XCTAssertEqual(ModelCatalog.forLanguage(.hinglish, .live), ModelCatalog.hinglish)
        XCTAssertEqual(ModelCatalog.forLanguage(.hinglish, .accurate), ModelCatalog.hinglishAccurate)
    }

    func testFilesAreFoundByName() {
        XCTAssertEqual(ModelCatalog.englishLive.bytes, 78_693_144)
        XCTAssertEqual(ModelCatalog.englishLive.file("tokens.txt").path, "kroko-en-live/tokens.txt")
        XCTAssertEqual(ModelCatalog.hinglish.files[0].name, "ggml-hinglish-swift-q8_0.bin")
        XCTAssertTrue(ModelCatalog.knownPaths.contains(ModelCatalog.vad.path))
        XCTAssertEqual(Set(ModelCatalog.all.map(\.id)).count, ModelCatalog.all.count)
    }
}
