import Foundation
import XCTest

/// A temporary folder per test, deleted afterwards (the Windows tests' TempFolder).
final class TempFolder {
    let path: String

    init() {
        let name = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        path = FileManager.default.temporaryDirectory.appendingPathComponent("thumbfree-app-tests/\(name)").path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> String { (path as NSString).appendingPathComponent(name) }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Files as the tests write and read them.
enum TestFiles {
    static func write(_ path: String, _ text: String) {
        write(path, bytes: Array(text.utf8))
    }

    static func write(_ path: String, bytes: [UInt8]) {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        XCTAssertNoThrow(try Data(bytes).write(to: URL(fileURLWithPath: path)))
    }

    static func text(_ path: String) -> String { String(decoding: bytes(path), as: UTF8.self) }

    static func bytes(_ path: String) -> [UInt8] {
        (try? Data(contentsOf: URL(fileURLWithPath: path))).map { Array($0) } ?? []
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// The folders in `path`, by name.
    static func folders(_ path: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { name in
            var isFolder: ObjCBool = false
            let found = FileManager.default.fileExists(
                atPath: (path as NSString).appendingPathComponent(name), isDirectory: &isFolder)
            return found && isFolder.boolValue
        }.sorted()
    }

    /// A JSON file read by Foundation, as JSON5 so comments and trailing commas are fine: a reader other than
    /// ThumbFree's own, as the Windows tests read the file with JsonNode.
    static func json(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any])
    }

    /// Runs a command-line tool and returns its exit status and output.
    static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}

/// An error with a message of its own, like the exceptions the Windows tests throw.
struct TestError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

/// A value several threads write and read.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Value

    init(_ value: Value) {
        current = value
    }

    var value: Value { lock.withLock { current } }

    func update(_ change: (inout Value) -> Void) {
        lock.withLock { change(&current) }
    }
}

/// Text with the characters that files escape, or that a writer might: quotes, backslashes, line breaks, tabs, a
/// control character, an emoji, a no-break space, "é", a line separator, a soft hyphen, "<>&'+`", a byte order mark
/// and a private-use character.
let trickyText = "a\"b\\c\nd\te\u{1}f😀g\u{A0}hé\u{2028}i\u{AD}j<>&'+`\u{FEFF}k\u{E000}l\r"

/// 2026-11-19 18:00 in India, the Windows tests' start time.
let testStart = Date(timeIntervalSince1970: 1_795_091_400)

let india = TimeZone(secondsFromGMT: 19_800) ?? .current
