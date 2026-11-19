import Foundation

/// The shared test data at the repository root: tests/vectors (how each test sentence must come out) and tests/audio
/// (speech recordings). They're the same files in every ThumbFree repo.
enum TestData {
    /// The repository root, found from this file's path: tests/<target>/TestData.swift.
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func vectors(_ name: String) -> URL { root.appendingPathComponent("tests/vectors/\(name)") }

    static func audio(_ name: String) -> URL { root.appendingPathComponent("tests/audio/\(name)") }
}
