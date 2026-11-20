import XCTest
@testable import ThumbFreeApp

/// The log has no tests on Windows; these cover where the Mac writes it, what a line holds, and that an error is
/// logged by its kind.
final class LogTests: XCTestCase {
    func testLinesGoToTheDaysFileAndLogsOlderThanAWeekGo() throws {
        let folder = TempFolder()
        defer {
            Log.stop()
            folder.remove()
        }

        let now = Date()
        let old = folder.file("20000101.log")
        let recent = folder.file("20000102.log")
        let other = folder.file("notes.txt")
        for (path, age) in [(old, 8.0), (recent, 6.0), (other, 30.0)] {
            TestFiles.write(path, "x\n")
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-age * 24 * 60 * 60)], ofItemAtPath: path)
        }

        Log.start(in: folder.path, now: now)
        Log.info("model en-kroko-live loaded in 812 ms")
        Log.warn("history not saved: NSCocoaErrorDomain 640")
        Log.error("typing failed")

        XCTAssertFalse(TestFiles.exists(old))
        XCTAssertTrue(TestFiles.exists(recent))
        XCTAssertTrue(TestFiles.exists(other))
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyyMMdd"
        let file = try XCTUnwrap(Log.file)
        XCTAssertEqual(file, folder.file(day.string(from: now) + ".log"))
        let lines = TestFiles.text(file).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        let expected = [
            "INFO model en-kroko-live loaded in 812 ms", "WARN history not saved: NSCocoaErrorDomain 640",
            "ERROR typing failed",
        ]
        for (line, message) in zip(lines, expected) {
            XCTAssertNotNil(line.range(of: #"^\d\d:\d\d:\d\d\.\d\d\d "#, options: .regularExpression), line)
            XCTAssertTrue(line.hasSuffix(" " + message), line)
        }
    }

    func testAnErrorIsLoggedByItsKindNeverItsMessage() {
        let path = "/Users/ren/Documents/secret.txt"
        let error = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [NSFilePathErrorKey: path])

        XCTAssertEqual(Log.kind(of: error), "NSCocoaErrorDomain 513")
        XCTAssertFalse(Log.kind(of: TestError("Thanks, Ren")).contains("Ren"))
    }
}
