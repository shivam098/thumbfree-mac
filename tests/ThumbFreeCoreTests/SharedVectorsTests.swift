import XCTest
@testable import ThumbFreeCore

/// The shared vectors every ThumbFree platform must pass (tests/vectors at the repository root, the same files in every
/// ThumbFree repo). formatter.tsv was generated from the C# formatter; Android and Windows run the same rows, so a
/// difference here means the platforms drifted. Ported from thumbfree-windows tests/ThumbFree.Core.Tests.
final class SharedVectorsTests: XCTestCase {
    func testFormatterMatchesTheSharedVectors() throws {
        let formatter = DictationFormatter(DictationOptions(
            replacements: [("git hub", "GitHub"), ("kube", "Kubernetes")],
            snippets: [("my signature", "Thanks,\nShivam")]))
        let rows = try Vectors.rows("formatter.tsv")
        XCTAssertGreaterThan(rows.count, 100, "expected the vector file, found \(rows.count) rows")

        var failures: [String] = []
        for row in rows {
            let cells = DotNet.split(row, ["\t"])
            guard cells.count == 4 else {
                XCTFail("bad row: \(row)")
                continue
            }

            let input = Vectors.unescape(cells[2])
            let actual = formatter.format(input, continuesSentence: cells[0] == "1", searchField: cells[1] == "1")
            if !DotNet.ordinalEquals(actual, Vectors.unescape(cells[3])) {
                failures.append(failure(cells[0] + cells[1], cells[2], cells[3], actual))
            }
        }

        let shown = failures.prefix(25).joined(separator: "\n")
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(rows.count) vectors differ:\n" + shown)
    }

    /// The same path as the Android keyboard: the formatter (default options), then layout.
    func testLayoutMatchesTheSharedVectors() throws {
        let formatter = DictationFormatter()
        let rows = try Vectors.rows("layout.tsv")
        XCTAssertGreaterThan(rows.count, 20, "expected the layout vectors, found \(rows.count) rows")

        var failures: [String] = []
        for row in rows {
            let cells = DotNet.split(row, ["\t"])
            guard cells.count == 3 else {
                XCTFail("bad row: \(row)")
                continue
            }

            let flags = cells[0].unicodeScalars
            let context = LayoutContext(
                multiLine: flags.contains("m"), atStart: flags.contains("s"), email: flags.contains("e"))
            let actual = DictationLayout.apply(formatter.format(Vectors.unescape(cells[1])), context)
            if !DotNet.ordinalEquals(actual, Vectors.unescape(cells[2])) {
                failures.append(failure(cells[0], cells[1], cells[2], actual))
            }
        }

        let shown = failures.joined(separator: "\n")
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(rows.count) layout vectors differ:\n" + shown)
    }

    private func failure(_ flags: String, _ input: String, _ expected: String, _ actual: String) -> String {
        "  [\(flags)] \(input)\n     expected: \(expected)\n     actual:   \(Vectors.escape(actual))"
    }
}

/// Reads tests/vectors/*.tsv (one row per line, # comments, backslash escapes), as the C# tests do.
enum Vectors {
    static func rows(_ file: String) throws -> [String] {
        let text = try String(contentsOf: TestData.vectors(file), encoding: .utf8)
        return DotNet.lines(text).filter { !$0.isEmpty && $0.unicodeScalars.first != "#" }
    }

    static func unescape(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == "\\" && i + 1 < scalars.count {
                switch scalars[i + 1] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append(scalars[i + 1])
                }

                i += 2
            } else {
                out.append(scalars[i])
                i += 1
            }
        }

        return String(out)
    }

    static func escape(_ s: String) -> String {
        let backslashes = DotNet.replace(s, "\\", "\\\\")
        return DotNet.replace(DotNet.replace(DotNet.replace(backslashes, "\t", "\\t"), "\r", "\\r"), "\n", "\\n")
    }
}
