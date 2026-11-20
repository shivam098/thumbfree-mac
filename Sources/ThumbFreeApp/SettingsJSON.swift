import Foundation
import ThumbFreeCore

/// settings.json the way people write it, read and written as ThumbFree for Windows does (thumbfree-windows
/// `SettingsJson`, on System.Text.Json): comments, trailing commas, a key written twice (the last one counts), objects
/// in the file's order. Writing replaces only the text of the values that changed, so comments, formatting and every
/// other key stay exactly as they were. Foundation's JSON reader keeps neither comments nor order, so this one is its
/// own, held to System.Text.Json's rules: what it rejects, the line it names, and which text it can't read (bytes that
/// aren't UTF-8, half a UTF-16 character).
enum SettingsJSON {
    /// A mistake in the file, with the line it's on (from 0, as JsonException's LineNumber), or no line when the file
    /// isn't one { … } object.
    struct Mistake: Error, Equatable {
        let message: String
        let line: Int?
    }

    /// A value as the file has it.
    indirect enum Value: Equatable {
        case object([Member])
        case array([Value])
        /// The text; nil when it isn't UTF-8 or holds half a UTF-16 character (C#'s GetString throws).
        case string(String?)
        /// The number as written.
        case number(String)
        case bool(Bool)
        case null
    }

    /// A member of an object: its name (nil when it isn't UTF-8), its value, and where in the file its name starts
    /// and its value starts and ends.
    struct Member: Equatable {
        let name: String?
        let value: Value
        let nameStart: Int
        let valueStart: Int
        let valueEnd: Int
    }

    /// A new value for one key: on one line, and indented for files written over several lines.
    struct Edit: Equatable {
        let key: String
        let compact: String
        let indented: String
    }

    static let notAnObject = "settings.json isn't one { … } object."

    /// Nothing but white space (an empty file is treated like a missing one).
    static func isBlank(_ file: [UInt8]) -> Bool {
        file[bom(file)...].allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D || $0 == 0x0A }
    }

    /// The top-level values by key, the last one for a key written twice; a key that isn't UTF-8 can't be one of
    /// ThumbFree's, so it's left out. Throws a `Mistake` for a mistake in the file or when it isn't one { … } object.
    static func values(_ file: [UInt8]) throws -> [String: Value] {
        var reader = Reader(Array(file[bom(file)...]))
        guard case .object(let members) = try reader.document() else {
            throw Mistake(message: notAnObject, line: nil)
        }

        var values: [String: Value] = [:]
        for member in members {
            if let name = member.name {
                values[name] = member.value
            }
        }

        return values
    }

    /// The file with each changed key's value replaced (every occurrence of a key written twice), and keys it didn't
    /// have added before the closing brace with the file's own indentation and line ends. Nothing else changes.
    static func splice(_ file: [UInt8], _ changes: [Edit]) throws -> [UInt8] {
        let start = bom(file)
        let json = Array(file[start...])
        var reader = Reader(json)
        let (properties, open, close) = try reader.topLevel()
        let newline = contains(json, [0x0D, 0x0A]) ? "\r\n" : "\n"
        var edits: [(start: Int, end: Int, text: String)] = []
        var missing: [Edit] = []
        for change in changes {
            let found = properties.filter { $0.name == change.key }
            if found.isEmpty {
                missing.append(change)
                continue
            }

            for property in found {
                let indent = lineIndent(json, property.nameStart)
                let text = indent.map { reindent(change.indented, $0, newline) } ?? change.compact
                edits.append((start: property.valueStart, end: property.valueEnd, text: text))
            }
        }

        if !missing.isEmpty {
            addMissing(json, properties, open, close, newline, missing, &edits)
        }

        var output = Array(file[..<start])
        var at = 0
        for edit in DotNet.orderBy(edits, { $0.start }) {
            // Edits never overlap; were they to, nothing is written (C# throws there too).
            guard edit.start >= at else { throw SpliceFailure() }
            output += json[at..<edit.start]
            output += Array(edit.text.utf8)
            at = edit.end
        }

        output += json[at...]
        return output
    }

    /// Edits that overlap, which `splice` never makes.
    struct SpliceFailure: Error {}

    // MARK: Writing

    /// `text` as a JSON string, escaped as System.Text.Json escapes it with UnsafeRelaxedJsonEscaping, the Windows
    /// app's encoder: quotes, backslashes and control characters; spaces other than U+0020, line and paragraph
    /// separators, the byte order mark, private-use and unassigned characters as \uXXXX; and every character outside
    /// the Basic Multilingual Plane (most emoji) as its UTF-16 pair. Everything else is written as it is.
    static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{8}": out += "\\b"
            case "\u{C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if escapes(scalar) {
                    for unit in String(scalar).utf16 {
                        let hex = String(unit, radix: 16, uppercase: true)
                        out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }

        return out + "\""
    }

    /// A JSON object of `members` (each a key and its value's JSON), on one line or indented by two spaces with `\n`
    /// line ends, as System.Text.Json writes them (on a Mac); `{}` when empty.
    static func object(_ members: [(key: String, json: String)], indented: Bool) -> String {
        if members.isEmpty {
            return "{}"
        }

        if !indented {
            return "{" + members.map { quote($0.key) + ":" + $0.json }.joined(separator: ",") + "}"
        }

        let lines = members.map { "  " + quote($0.key) + ": " + reindent($0.json, "  ", "\n") }
        return "{\n" + lines.joined(separator: ",\n") + "\n}"
    }

    /// A number as System.Text.Json writes a double: the shortest digits that read back the same, without ".0".
    static func number(_ value: Double) -> String {
        let text = "\(value)"
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    /// UnsafeRelaxedJsonEscaping's choice for one character (other than the ones with a short escape), found by
    /// asking it about every one: control characters (Cc), spaces other than U+0020 (Zs), U+2028 and U+2029, the byte
    /// order mark, private-use and unassigned characters, and everything outside the Basic Multilingual Plane.
    private static func escapes(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value >= 0x10000 || scalar.value == 0xFEFF {
            return true
        }

        switch scalar.properties.generalCategory {
        case .spaceSeparator:
            return scalar != " "
        case .control, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
            return true
        default:
            return false
        }
    }

    // MARK: Splicing

    /// New keys go just before the closing brace, after a comma if the last value has none, indented like the others.
    private static func addMissing(
        _ json: [UInt8],
        _ properties: [Member],
        _ open: Int,
        _ close: Int,
        _ newline: String,
        _ missing: [Edit],
        _ edits: inout [(start: Int, end: Int, text: String)]
    ) {
        let lastEnd = properties.last?.valueEnd
        let comma = lastEnd.map { !hasComma(json[$0..<close]) } ?? false
        if !json[open..<close].contains(0x0A) {
            // An object on one line stays on one line: right after the last value, or before the brace after a
            // trailing comma.
            let inline = missing.map { quote($0.key) + ":" + $0.compact }.joined(separator: ",")
            if comma, let lastEnd {
                edits.append((start: lastEnd, end: lastEnd, text: "," + inline))
            } else {
                edits.append((start: close, end: close, text: inline))
            }

            return
        }

        if comma, let lastEnd {
            edits.append((start: lastEnd, end: lastEnd, text: ","))
        }

        let indent = properties.reversed().lazy.compactMap { lineIndent(json, $0.nameStart) }.first ?? "  "
        let block = missing.map { indent + quote($0.key) + ": " + reindent($0.indented, indent, newline) }
            .joined(separator: "," + newline)
        var lineStart = close
        while lineStart > 0 && (json[lineStart - 1] == 0x20 || json[lineStart - 1] == 0x09) {
            lineStart -= 1
        }

        if lineStart == 0 || json[lineStart - 1] == 0x0A {
            edits.append((start: lineStart, end: lineStart, text: block + newline))
        } else {
            edits.append((start: close, end: close, text: newline + block + newline))
        }
    }

    /// The white space before a key when the key starts its line; nil when something else comes first on the line.
    private static func lineIndent(_ json: [UInt8], _ at: Int) -> String? {
        var start = at
        while start > 0 && (json[start - 1] == 0x20 || json[start - 1] == 0x09) {
            start -= 1
        }

        guard start == 0 || json[start - 1] == 0x0A else { return nil }
        return String(decoding: json[start..<at], as: UTF8.self)
    }

    /// A value written on several lines, its later lines indented under its key.
    private static func reindent(_ indented: String, _ indent: String, _ newline: String) -> String {
        DotNet.replace(DotNet.replace(indented, "\r\n", "\n"), "\n", newline + indent)
    }

    /// A comma among white space and comments (a trailing comma after the last value).
    private static func hasComma(_ between: ArraySlice<UInt8>) -> Bool {
        let bytes = Array(between)
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: ",") {
                return true
            }

            if bytes[i] == UInt8(ascii: "/") && i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "/") {
                // A line comment ends at a line feed or a carriage return, as the reader reads it.
                i = bytes[i...].firstIndex { $0 == 0x0A || $0 == 0x0D } ?? bytes.count
            } else if bytes[i] == UInt8(ascii: "/") && i + 1 < bytes.count && bytes[i + 1] == UInt8(ascii: "*") {
                i = (find(bytes, [UInt8(ascii: "*"), UInt8(ascii: "/")], from: i + 2) ?? bytes.count) + 1
            }

            i += 1
        }

        return false
    }

    /// 3 when the file starts with a UTF-8 byte order mark, else 0.
    private static func bom(_ file: [UInt8]) -> Int {
        file.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
    }

    private static func contains(_ bytes: [UInt8], _ part: [UInt8]) -> Bool { find(bytes, part, from: 0) != nil }

    /// Where `part` first starts in `bytes` at or after `from`.
    static func find(_ bytes: [UInt8], _ part: [UInt8], from: Int) -> Int? {
        guard !part.isEmpty, bytes.count >= part.count, from <= bytes.count - part.count else { return nil }
        return (from...(bytes.count - part.count)).first { bytes[$0..<($0 + part.count)].elementsEqual(part) }
    }
}

extension SettingsJSON {
    /// Reads JSON as System.Text.Json's Utf8JsonReader does with comments skipped and trailing commas allowed:
    /// comments wherever white space may be except between a name and its colon, at most 64 objects and arrays deep,
    /// and strings that may hold bytes that aren't UTF-8 (the text is then unreadable, not the file).
    struct Reader {
        static let maxDepth = 64

        private static let unfinishedString = "Expected end of string, but instead reached end of data."

        private let bytes: [UInt8]
        private var at = 0
        private var depth = 0

        /// Where line comments ended at a carriage return with no line feed after it: System.Text.Json counts a line
        /// there, though a carriage return elsewhere doesn't count.
        private var commentLineEnds: [Int] = []

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        /// The one value the file holds (JsonDocument.Parse).
        mutating func document() throws -> Value {
            try skipSpace()
            let root = try value()
            try end()
            return root
        }

        /// The top-level members of the file's object and where its braces are: SettingsJson's Scan, which says the
        /// file isn't an object before reading on.
        mutating func topLevel() throws -> (members: [Member], open: Int, close: Int) {
            try skipSpace()
            guard at < bytes.count, bytes[at] == UInt8(ascii: "{") else {
                throw Mistake(message: notAnObject, line: nil)
            }

            let open = at
            let members = try object()
            let close = at - 1
            try end()
            return (members, open, close)
        }

        /// Only white space and comments may follow the value.
        private mutating func end() throws {
            try skipSpace()
            if at < bytes.count {
                throw mistake("'\(shown(bytes[at]))' is invalid after a single JSON value. Expected end of data.")
            }
        }

        private mutating func value() throws -> Value {
            guard at < bytes.count else { throw mistake("Expected a value, but instead reached end of data.") }
            switch bytes[at] {
            case UInt8(ascii: "{"):
                return .object(try object())
            case UInt8(ascii: "["):
                return .array(try array())
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return .number(try number())
            case UInt8(ascii: "t"):
                try literal("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try literal("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try literal("null")
                return .null
            default:
                throw mistake("'\(shown(bytes[at]))' is an invalid start of a value.")
            }
        }

        /// From its "{" to just after its "}".
        private mutating func object() throws -> [Member] {
            try enter()
            at += 1
            var members: [Member] = []
            try skipSpace()
            if try next() == UInt8(ascii: "}") {
                at += 1
                depth -= 1
                return members
            }

            while true {
                guard try next() == UInt8(ascii: "\"") else {
                    throw mistake("'\(shown(bytes[at]))' is an invalid start of a property name. Expected a '\"'.")
                }

                let nameStart = at
                let name = try string()

                // Only white space between a name and its colon: System.Text.Json takes no comment there.
                while at < bytes.count && Self.isSpace(bytes[at]) {
                    at += 1
                }

                guard try next() == UInt8(ascii: ":") else {
                    throw mistake("'\(shown(bytes[at]))' is invalid after a property name. Expected a ':'.")
                }

                at += 1
                try skipSpace()
                let valueStart = at
                let found = try value()
                members.append(
                    Member(name: name, value: found, nameStart: nameStart, valueStart: valueStart, valueEnd: at))
                try skipSpace()
                let after = try next()
                if after == UInt8(ascii: ",") {
                    at += 1
                    try skipSpace()
                    if try next() == UInt8(ascii: "}") {
                        break
                    }
                } else if after == UInt8(ascii: "}") {
                    break
                } else {
                    throw mistake("'\(shown(after))' is invalid after a value. Expected either ',', '}', or ']'.")
                }
            }

            at += 1
            depth -= 1
            return members
        }

        private mutating func array() throws -> [Value] {
            try enter()
            at += 1
            var values: [Value] = []
            try skipSpace()
            if try next() == UInt8(ascii: "]") {
                at += 1
                depth -= 1
                return values
            }

            while true {
                values.append(try value())
                try skipSpace()
                let after = try next()
                if after == UInt8(ascii: ",") {
                    at += 1
                    try skipSpace()
                    if try next() == UInt8(ascii: "]") {
                        break
                    }
                } else if after == UInt8(ascii: "]") {
                    break
                } else {
                    throw mistake("'\(shown(after))' is invalid after a value. Expected either ',', '}', or ']'.")
                }
            }

            at += 1
            depth -= 1
            return values
        }

        /// An object or array starting here, one level deeper.
        private mutating func enter() throws {
            depth += 1
            if depth > Self.maxDepth {
                throw mistake("The maximum configured depth of \(Self.maxDepth) has been exceeded.")
            }
        }

        /// The byte here; a mistake at the end of the data, where something more was expected.
        private func next() throws -> UInt8 {
            guard at < bytes.count else {
                throw mistake(
                    "Expected depth to be zero at the end of the JSON payload. There is an open JSON object or array "
                        + "that should be closed.")
            }

            return bytes[at]
        }

        /// From its opening quote to just after its closing one. Its text is nil when a byte isn't UTF-8 or an
        /// escape leaves half a UTF-16 character: the reader takes those, only reading them as text fails.
        private mutating func string() throws -> String? {
            at += 1
            var units: [UInt16] = []
            var readable = true
            while true {
                guard at < bytes.count else { throw mistake(Self.unfinishedString) }
                let byte = bytes[at]
                switch byte {
                case UInt8(ascii: "\""):
                    at += 1
                    return readable ? Self.text(units) : nil
                case 0..<0x20:
                    throw mistake("'0x\(String(byte, radix: 16, uppercase: true))' is invalid within a JSON string.")
                case UInt8(ascii: "\\"):
                    units.append(try escape())
                case 0x20..<0x80:
                    units.append(UInt16(byte))
                    at += 1
                default:
                    if let decoded = Self.scalar(bytes, at) {
                        units += String(decoded.scalar).utf16
                        at += decoded.length
                    } else {
                        readable = false
                        at += 1
                    }
                }
            }
        }

        /// The UTF-16 unit an escape stands for, from its backslash to just after it.
        private mutating func escape() throws -> UInt16 {
            guard at + 1 < bytes.count else { throw mistake(Self.unfinishedString) }
            let escaped = bytes[at + 1]
            let simple: UInt16?
            switch escaped {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): simple = UInt16(escaped)
            case UInt8(ascii: "b"): simple = 0x08
            case UInt8(ascii: "f"): simple = 0x0C
            case UInt8(ascii: "n"): simple = 0x0A
            case UInt8(ascii: "r"): simple = 0x0D
            case UInt8(ascii: "t"): simple = 0x09
            default: simple = nil
            }

            if let simple {
                at += 2
                return simple
            }

            guard escaped == UInt8(ascii: "u") else {
                at += 1
                throw mistake("'\(shown(escaped))' is an invalid escapable character within a JSON string.")
            }

            var unit: UInt16 = 0
            for i in 2..<6 {
                guard at + i < bytes.count else {
                    at = bytes.count
                    throw mistake(Self.unfinishedString)
                }

                guard let digit = Self.hexDigit(bytes[at + i]) else {
                    at += i
                    throw mistake("'\(shown(bytes[at]))' is not a hex digit following '\\u' within a JSON string.")
                }

                unit = unit << 4 | UInt16(digit)
            }

            at += 6
            return unit
        }

        /// From its first byte to just after its last: -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?. What follows it
        /// is the caller's to judge.
        private mutating func number() throws -> String {
            let start = at
            if bytes[at] == UInt8(ascii: "-") {
                at += 1
            }

            if at < bytes.count && bytes[at] == UInt8(ascii: "0") {
                at += 1
            } else {
                try digits()
            }

            if at < bytes.count && bytes[at] == UInt8(ascii: ".") {
                at += 1
                try digits()
            }

            if at < bytes.count && (bytes[at] == UInt8(ascii: "e") || bytes[at] == UInt8(ascii: "E")) {
                at += 1
                if at < bytes.count && (bytes[at] == UInt8(ascii: "+") || bytes[at] == UInt8(ascii: "-")) {
                    at += 1
                }

                try digits()
            }

            return String(decoding: bytes[start..<at], as: UTF8.self)
        }

        /// At least one digit.
        private mutating func digits() throws {
            guard at < bytes.count, Self.isDigit(bytes[at]) else {
                throw mistake("Expected a digit ('0'-'9').")
            }

            while at < bytes.count && Self.isDigit(bytes[at]) {
                at += 1
            }
        }

        private mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard bytes.count - at >= expected.count, bytes[at..<(at + expected.count)].elementsEqual(expected) else {
                throw mistake("An invalid JSON literal. Expected the literal '\(word)'.")
            }

            at += expected.count
        }

        /// White space and comments. A comment that isn't closed, or a line comment with a line or paragraph
        /// separator in it, is a mistake where the comment starts, as is a "/" that doesn't start one.
        private mutating func skipSpace() throws {
            while at < bytes.count {
                if Self.isSpace(bytes[at]) {
                    at += 1
                    continue
                }

                guard bytes[at] == UInt8(ascii: "/") else { return }
                let start = at
                if at + 1 < bytes.count && bytes[at + 1] == UInt8(ascii: "/") {
                    at += 2
                    while at < bytes.count && bytes[at] != 0x0A && bytes[at] != 0x0D {
                        // U+2028 and U+2029, which end a line in JavaScript.
                        if bytes[at] == 0xE2 && at + 2 < bytes.count && bytes[at + 1] == 0x80
                            && (bytes[at + 2] == 0xA8 || bytes[at + 2] == 0xA9) {
                            at = start
                            throw mistake(
                                "Found invalid line or paragraph separator character while reading a comment.")
                        }

                        at += 1
                    }

                    if at < bytes.count && bytes[at] == 0x0D && (at + 1 == bytes.count || bytes[at + 1] != 0x0A) {
                        commentLineEnds.append(at)
                    }
                } else if at + 1 < bytes.count && bytes[at + 1] == UInt8(ascii: "*") {
                    guard let close = SettingsJSON.find(bytes, [UInt8(ascii: "*"), UInt8(ascii: "/")], from: at + 2)
                    else { throw mistake("Expected end of comment, but instead reached end of data.") }
                    at = close + 2
                } else {
                    throw mistake("'/' is an invalid start of a value.")
                }
            }
        }

        /// A mistake here: the line is the number of line feeds before it, as System.Text.Json counts lines, and of
        /// line comments that ended at a carriage return alone, which it counts too.
        private func mistake(_ message: String) -> Mistake {
            let feeds = bytes[..<min(at, bytes.count)].lazy.filter { $0 == 0x0A }.count
            return Mistake(message: message, line: feeds + commentLineEnds.filter { $0 < at }.count)
        }

        private func shown(_ byte: UInt8) -> String {
            byte >= 0x20 && byte < 0x7F ? String(UnicodeScalar(byte)) : "0x" + String(byte, radix: 16, uppercase: true)
        }

        /// JSON's white space: space, tab, line feed and carriage return.
        private static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        private static func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

        private static func hexDigit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
            default: return nil
            }
        }

        /// The well-formed UTF-8 character of 2 to 4 bytes at `at` and its length (Unicode's table 3-7: no overlong
        /// forms, no surrogates, nothing past U+10FFFF), or nil.
        private static func scalar(_ bytes: [UInt8], _ at: Int) -> (scalar: Unicode.Scalar, length: Int)? {
            let lead = bytes[at]
            let length: Int
            var low: UInt8 = 0x80
            var high: UInt8 = 0xBF
            switch lead {
            case 0xC2...0xDF: length = 2
            case 0xE0: length = 3; low = 0xA0
            case 0xE1...0xEC, 0xEE...0xEF: length = 3
            case 0xED: length = 3; high = 0x9F
            case 0xF0: length = 4; low = 0x90
            case 0xF1...0xF3: length = 4
            case 0xF4: length = 4; high = 0x8F
            default: return nil
            }

            guard at + length <= bytes.count, bytes[at + 1] >= low, bytes[at + 1] <= high,
                  bytes[(at + 2)..<(at + length)].allSatisfy({ $0 >= 0x80 && $0 <= 0xBF }) else { return nil }
            var value = UInt32(lead) & (length == 2 ? 0x1F : length == 3 ? 0x0F : 0x07)
            for byte in bytes[(at + 1)..<(at + length)] {
                value = value << 6 | UInt32(byte & 0x3F)
            }

            return Unicode.Scalar(value).map { (scalar: $0, length: length) }
        }

        /// The text of UTF-16 units, or nil when a surrogate isn't paired.
        private static func text(_ units: [UInt16]) -> String? {
            var i = 0
            while i < units.count {
                if UTF16.isLeadSurrogate(units[i]) {
                    guard i + 1 < units.count, UTF16.isTrailSurrogate(units[i + 1]) else { return nil }
                    i += 2
                } else if UTF16.isTrailSurrogate(units[i]) {
                    return nil
                } else {
                    i += 1
                }
            }

            return String(decoding: units, as: UTF16.self)
        }
    }
}
