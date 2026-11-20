import Foundation

/// A regular expression in .NET's syntax, matched with .NET's rules, for code ported from C# (the ThumbFree and Jarvis
/// cores). NSRegularExpression (ICU) does the matching, so the pattern is first translated where the two engines differ
/// (`translate`):
/// - `\w`, `\s`, `\d` and `\b` are .NET's sets, spelled out. ICU's `\w` also takes spacing marks (Devanagari's vowel
///   signs), and its `\b` skips combining marks;
/// - `\v` is the vertical tab (to ICU it's any vertical whitespace);
/// - look-behinds are bounded, as ICU needs: a `*` or `+` in one repeats at most `lookBehindLimit` times;
/// - only `\n` ends a line for `$` and `.` (ICU also takes \r, \u{2028} and others).
/// Replacements use .NET's `$` syntax. Still different, for text no recognizer writes: ICU matches case-insensitively
/// with full case folding ("ﬁrst" matches "first", "ß" matches "ss"), and to ICU a letter outside the Basic
/// Multilingual Plane ("𝐀") is a letter, where .NET sees two UTF-16 halves that aren't. `RegexOptions.RightToLeft`
/// isn't supported; for a pattern that matches a single character, the last match is the one it would find. Groups are
/// numbered left to right, named ones too, where .NET numbers named groups after the others: in a pattern with both,
/// read named groups by name.
public struct NetRegex: @unchecked Sendable {
    /// `RegexOptions`. `CultureInvariant` needs none: matching here never depends on the user's language.
    public struct Options: OptionSet, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// `RegexOptions.IgnoreCase`.
        public static let ignoreCase = Options(rawValue: 1 << 0)

        /// `RegexOptions.Singleline`: `.` matches `\n` too.
        public static let singleline = Options(rawValue: 1 << 1)
    }

    /// The most a `*` or `+` in a look-behind repeats (.NET has no limit). ICU tries every length up to it at each
    /// position, so it's small. The core's look-behinds skip the spaces left where fillers were taken out, two per
    /// filler: 15 fillers in a row fit.
    public static let lookBehindLimit = 32

    private let regex: NSRegularExpression

    /// `pattern` is in .NET's syntax. Traps on a bad pattern, so it's for constant ones; for a pattern built at run
    /// time, `NetRegex(icu: NetRegex.translate(pattern), options)` returns nil instead.
    public init(_ pattern: String, _ options: Options = []) {
        guard let regex = NetRegex(icu: NetRegex.translate(pattern), options) else {
            preconditionFailure("Bad pattern: \(pattern)")
        }

        self = regex
    }

    /// `pattern` is already in ICU's syntax (from `translate`); nil if ICU rejects it.
    public init?(icu pattern: String, _ options: Options = []) {
        var icuOptions: NSRegularExpression.Options = [.useUnixLineSeparators]
        if options.contains(.ignoreCase) {
            icuOptions.insert(.caseInsensitive)
        }

        if options.contains(.singleline) {
            icuOptions.insert(.dotMatchesLineSeparators)
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: icuOptions) else { return nil }
        self.regex = regex
    }

    /// `(?<![\w])text(?![\w])`, case-insensitive: `text` as a whole word (C#'s `Regex.Escape` between those).
    public static func wholeWord(_ text: String) -> NetRegex? {
        NetRegex(icu: translate(#"(?<![\w])"#) + escape(text) + translate(#"(?![\w])"#), .ignoreCase)
    }

    /// `Regex.Match`: the first match, or nil.
    public func match(_ text: String) -> NetMatch? {
        regex.firstMatch(in: text, options: [], range: Self.whole(text)).map { NetMatch(text, $0) }
    }

    /// `Regex.Matches`, left to right.
    public func matches(_ text: String) -> [NetMatch] {
        regex.matches(in: text, options: [], range: Self.whole(text)).map { NetMatch(text, $0) }
    }

    /// `Regex.IsMatch`.
    public func isMatch(_ text: String) -> Bool {
        regex.firstMatch(in: text, options: [], range: Self.whole(text)) != nil
    }

    private static func whole(_ text: String) -> NSRange { NSRange(location: 0, length: text.utf16.count) }

    /// `Regex.Replace` with a `MatchEvaluator`.
    public func replace(_ text: String, _ evaluator: (NetMatch) -> String) -> String {
        let found = matches(text)
        if found.isEmpty {
            return text
        }

        var result = ""
        var copied = text.startIndex
        for match in found {
            result.append(contentsOf: text[copied..<match.range.lowerBound])
            result.append(evaluator(match))
            copied = match.range.upperBound
        }

        result.append(contentsOf: text[copied...])
        return result
    }

    /// `Regex.Replace` with a replacement pattern in .NET's syntax: `$1` or `${1}`, `$&`, `` $` ``, `$'`, `$+`, `$_`
    /// and `$$`. Anything else is literal, a backslash too, and so is `${name}`: named groups aren't substituted.
    public func replace(_ text: String, _ replacement: String) -> String {
        let groups = regex.numberOfCaptureGroups
        let parts = NetRegex.parseReplacement(replacement, groups: groups)
        return replace(text) { match in
            var result = ""
            for part in parts {
                switch part {
                case .literal(let literal): result.append(literal)
                case .group(let index): result.append(match.group(index))
                case .before: result.append(contentsOf: text[..<match.range.lowerBound])
                case .after: result.append(contentsOf: text[match.range.upperBound...])
                case .lastGroup: result.append(match.group(groups))
                case .input: result.append(text)
                }
            }

            return result
        }
    }

    /// `Regex.Split` (for patterns without capture groups): the pieces between matches, empty ones included.
    public func split(_ text: String) -> [String] {
        var pieces: [String] = []
        var copied = text.startIndex
        for match in matches(text) {
            pieces.append(String(text[copied..<match.range.lowerBound]))
            copied = match.range.upperBound
        }

        pieces.append(String(text[copied...]))
        return pieces
    }

    // MARK: Translation

    // .NET's \w: letters, non-spacing marks, decimal digits and connectors.
    private static let word = #"\p{L}\p{Mn}\p{Nd}\p{Pc}"#

    // .NET's \s: Unicode's White_Space.
    private static let space = #"\t-\r\x{85}\p{Z}"#

    // What .NET's \b counts as word characters: \w and the zero-width non-joiner and joiner.
    private static let boundaryWord = word + #"\x{200C}\x{200D}"#

    /// `pattern`, in .NET's syntax, in ICU's syntax with .NET's meaning.
    public static func translate(_ pattern: String) -> String {
        let p = Array(pattern.unicodeScalars)
        var out = String.UnicodeScalarView()
        var outer: [Bool] = []
        var lookBehind = false
        var i = 0
        while i < p.count {
            let c = p[i]
            if c == "\\" && i + 1 < p.count {
                if let close = property(p, i) {
                    out.append(contentsOf: p[i...close])
                    i = close + 1
                    continue
                }

                if let spelled = shorthand(p[i + 1], inClass: false) {
                    out.append(contentsOf: spelled.unicodeScalars)
                } else {
                    out.append(contentsOf: p[i...(i + 1)])
                }

                i += 2
            } else if c == "[" {
                i = translateClass(p, i, &out)
            } else if c == "(" {
                outer.append(lookBehind)
                if i + 3 < p.count && p[i + 1] == "?" && p[i + 2] == "<" && (p[i + 3] == "=" || p[i + 3] == "!") {
                    lookBehind = true
                }

                out.append(c)
                i += 1
            } else if c == ")" {
                lookBehind = outer.popLast() ?? false
                out.append(c)
                i += 1
            } else if lookBehind && (c == "*" || c == "+") {
                out.append(contentsOf: (c == "*" ? "{0,\(lookBehindLimit)}" : "{1,\(lookBehindLimit)}").unicodeScalars)
                i += 1
            } else if lookBehind && c == "{", let close = p[i...].firstIndex(of: "}") {
                // {n,} gets the limit; {n} and {n,m} are bounded already.
                out.append(contentsOf: p[i..<close])
                if p[close - 1] == "," {
                    out.append(contentsOf: String(lookBehindLimit).unicodeScalars)
                }

                out.append("}")
                i = close + 1
            } else {
                out.append(c)
                i += 1
            }
        }

        return String(out)
    }

    /// The character class at `p[start]` (its `[`), translated into `out`. Returns the index after its `]`.
    private static func translateClass(
        _ p: [Unicode.Scalar],
        _ start: Int,
        _ out: inout String.UnicodeScalarView
    ) -> Int {
        var i = start + 1
        out.append("[")
        if i < p.count && p[i] == "^" {
            out.append("^")
            i += 1
        }

        var first = true
        while i < p.count {
            let c = p[i]
            if c == "]" && !first {
                out.append("]")
                return i + 1
            }

            if c == "\\" && i + 1 < p.count {
                if let close = property(p, i) {
                    out.append(contentsOf: p[i...close])
                    i = close + 1
                    first = false
                    continue
                }

                if let spelled = shorthand(p[i + 1], inClass: true) {
                    out.append(contentsOf: spelled.unicodeScalars)
                } else {
                    out.append(contentsOf: p[i...(i + 1)])
                }

                i += 2
            } else if c == "-" && (first || (i + 1 < p.count && p[i + 1] == "]")) {
                // A hyphen that .NET reads literally, at either end.
                out.append(contentsOf: #"\-"#.unicodeScalars)
                i += 1
            } else if c == "[" || c == "]" || c == "&" {
                // ICU nests sets with [ and intersects them with &&.
                out.append("\\")
                out.append(c)
                i += 1
            } else if c == " " {
                out.append(contentsOf: #"\x{20}"#.unicodeScalars)
                i += 1
            } else {
                out.append(c)
                i += 1
            }

            first = false
        }

        return i
    }

    /// The index of the `}` that ends `\p{…}` or `\P{…}` at `p[i]`, or nil if it's another escape.
    private static func property(_ p: [Unicode.Scalar], _ i: Int) -> Int? {
        guard p[i + 1] == "p" || p[i + 1] == "P" else { return nil }
        return p[i...].firstIndex(of: "}")
    }

    /// The ICU spelling of a .NET escape whose meaning differs, or nil for one ICU reads the same way.
    private static func shorthand(_ escaped: Unicode.Scalar, inClass: Bool) -> String? {
        switch escaped {
        case "w": return inClass ? word : "[\(word)]"
        case "W": return "[^\(word)]"
        case "s": return inClass ? space : "[\(space)]"
        case "S": return "[^\(space)]"
        case "d": return #"\p{Nd}"#
        case "D": return #"\P{Nd}"#
        case "v": return #"\x{0B}"#
        case "b":
            if inClass {
                return #"\x{08}"#
            }

            return "(?:(?<=[\(boundaryWord)])(?![\(boundaryWord)])|(?<![\(boundaryWord)])(?=[\(boundaryWord)]))"
        case "B":
            if inClass {
                return nil
            }

            return "(?:(?<=[\(boundaryWord)])(?=[\(boundaryWord)])|(?<![\(boundaryWord)])(?![\(boundaryWord)]))"
        default: return nil
        }
    }

    /// `text` matched literally, in .NET's or ICU's syntax (`Regex.Escape`): a backslash before each ASCII symbol and
    /// punctuation mark.
    public static func escape(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for c in text.unicodeScalars {
            let v = c.value
            let letterOrDigit = (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
            if v > 0x20 && v < 0x80 && !letterOrDigit {
                out.append("\\")
            }

            out.append(c)
        }

        return String(out)
    }

    // MARK: Replacements

    private enum Part {
        case literal(String)
        case group(Int)
        case before
        case after
        case lastGroup
        case input
    }

    /// A replacement pattern as .NET's parser reads it, for a pattern with `groups` numbered capture groups and no
    /// named ones. A group number too big for `int` is literal (.NET throws).
    private static func parseReplacement(_ replacement: String, groups: Int) -> [Part] {
        let s = Array(replacement.unicodeScalars)
        var parts: [Part] = []
        var literal = String.UnicodeScalarView()
        func add(_ part: Part) {
            if !literal.isEmpty {
                parts.append(.literal(String(literal)))
                literal = String.UnicodeScalarView()
            }

            parts.append(part)
        }

        var i = 0
        while i < s.count {
            let c = s[i]
            i += 1
            if c != "$" || i == s.count {
                literal.append(c)
                continue
            }

            let back = i
            var ch = s[i]
            var angled = false
            if ch == "{" && i + 1 < s.count {
                angled = true
                i += 1
                ch = s[i]
            }

            if let first = digit(ch) {
                var number = first
                var overflow = false
                i += 1
                while i < s.count, let next = digit(s[i]) {
                    i += 1
                    if number > (Int(Int32.max) - next) / 10 {
                        overflow = true
                    } else {
                        number = number * 10 + next
                    }
                }

                let closed = !angled || (i < s.count && s[i] == "}")
                if !overflow && closed && number <= groups {
                    i += angled ? 1 : 0
                    add(.group(number))
                    continue
                }
            } else if !angled {
                let part: Part?
                switch ch {
                case "$": part = .literal("$")
                case "&": part = .group(0)
                case "`": part = .before
                case "'": part = .after
                case "+": part = .lastGroup
                case "_": part = .input
                default: part = nil
                }

                if let part {
                    i += 1
                    add(part)
                    continue
                }
            }

            // Not a substitution (or a named group, which these patterns don't have): the $ is literal.
            i = back
            literal.append("$")
        }

        if !literal.isEmpty {
            parts.append(.literal(String(literal)))
        }

        return parts
    }

    /// An ASCII digit's value (.NET reads only those in a group number).
    private static func digit(_ c: Unicode.Scalar) -> Int? {
        (0x30...0x39).contains(c.value) ? Int(c.value) - 0x30 : nil
    }
}

/// A match of a `NetRegex` (.NET's `Match`), with positions as `String.Index`es in `text`. A match may start or end
/// inside a `Character` (before a combining mark, or between \r and \n), as it does in C#: its bounds are always
/// between Unicode scalars, so slicing `text` with them keeps every scalar.
public struct NetMatch {
    /// The text that was searched.
    public let text: String

    /// Where the whole match is.
    public let range: Range<String.Index>

    private let result: NSTextCheckingResult

    init(_ text: String, _ result: NSTextCheckingResult) {
        self.text = text
        self.result = result
        range = NetMatch.bounds(result.range, in: text)
    }

    /// `Match.Value`.
    public var value: String { String(text[range]) }

    /// Where group `index` matched, or nil if it took no part in the match or the pattern has no such group.
    public func groupRange(_ index: Int) -> Range<String.Index>? {
        guard index >= 0 && index < result.numberOfRanges else { return nil }
        let found = result.range(at: index)
        return found.location == NSNotFound ? nil : NetMatch.bounds(found, in: text)
    }

    /// `Groups[index].Value`: "" for a group that took no part, or that the pattern doesn't have.
    public func group(_ index: Int) -> String { groupRange(index).map { String(text[$0]) } ?? "" }

    /// `Groups[name].Value`, for a group the pattern names: "" if it took no part.
    public func group(named name: String) -> String {
        let found = result.range(withName: name)
        return found.location == NSNotFound ? "" : String(text[NetMatch.bounds(found, in: text)])
    }

    /// The UTF-16 range ICU reports, as indices. (`Range(_:in:)` would be nil for bounds that aren't `Character`
    /// boundaries.)
    private static func bounds(_ range: NSRange, in text: String) -> Range<String.Index> {
        let start = text.utf16.index(text.startIndex, offsetBy: range.location)
        return start..<text.utf16.index(start, offsetBy: range.length)
    }
}
