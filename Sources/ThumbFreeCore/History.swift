/// One dictation in History: when (Unix ms), which app it was for (may be empty) and the text.
public struct HistoryEntry: Equatable, Sendable {
    public var time: Int64
    public var app: String
    public var text: String

    public init(time: Int64, app: String, text: String) {
        self.time = time
        self.app = app
        self.text = text
    }
}

/// History is stored on the device as one line per dictation, `time<TAB>app<TAB>text`, with backslash, tab and line
/// breaks escaped. The same format and rules as the Android and Windows apps, so every platform reads and prunes it
/// alike. The clock is the caller's (`now`).
public enum History {
    /// Entries older than this are removed.
    public static let maxAgeMs: Int64 = 30 * 24 * 60 * 60 * 1000

    /// At most this many are kept (the newest).
    public static let maxEntries = 500

    public static func encode(_ entry: HistoryEntry) -> String {
        "\(entry.time)\t\(escape(entry.app))\t\(escape(entry.text))"
    }

    /// Nil for a damaged line (it's skipped, never fatal).
    public static func decode(_ line: String) -> HistoryEntry? {
        let parts = DotNet.split(line, ["\t"])
        guard parts.count == 3, let time = Int64(parts[0]) else { return nil }
        let text = unescape(parts[2])
        return DotNet.isNullOrWhiteSpace(text) ? nil : HistoryEntry(time: time, app: unescape(parts[1]), text: text)
    }

    /// Newest first, without expired entries, at most `maxEntries`.
    public static func prune(_ entries: [HistoryEntry], now: Int64) -> [HistoryEntry] {
        // C# subtracts without overflow checks; so does &-, where - would trap on a damaged time.
        let fresh = entries.filter { now &- $0.time <= maxAgeMs }
        return Array(DotNet.orderByDescending(fresh) { $0.time }.prefix(maxEntries))
    }

    /// Entries whose text contains every word of `query` (case-insensitive).
    public static func search(_ entries: [HistoryEntry], _ query: String) -> [HistoryEntry] {
        let words = DotNet.words(DotNet.lowerInvariant(DotNet.trim(query)))
        if words.isEmpty {
            return entries
        }

        return entries.filter { entry in
            let text = DotNet.lowerInvariant(entry.text)
            return words.allSatisfy { DotNet.contains(text, $0) }
        }
    }

    private static func escape(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for c in s.unicodeScalars {
            switch c {
            case "\\": out.append(contentsOf: #"\\"#.unicodeScalars)
            case "\t": out.append(contentsOf: #"\t"#.unicodeScalars)
            case "\n": out.append(contentsOf: #"\n"#.unicodeScalars)
            case "\r": out.append(contentsOf: #"\r"#.unicodeScalars)
            default: out.append(c)
            }
        }

        return String(out)
    }

    private static func unescape(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == "\\" && i + 1 < scalars.count {
                switch scalars[i + 1] {
                case "t": out.append("\t")
                case "n": out.append("\n")
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
}
