/// Raw recognizer output: cleaned for typing, or normalized for comparing. Same rules as the Android and Windows apps.
public enum TranscriptText {
    /// Removes Whisper annotations such as "[BLANK_AUDIO]" or "(music)" and speaker-change dashes.
    public static func clean(_ transcript: String?) -> String {
        guard let transcript, !DotNet.isNullOrWhiteSpace(transcript) else { return "" }
        var text = annotationRegex.replace(transcript, " ")
        text = DotNet.trim(whitespaceRegex.replace(text, " "))
        text = DotNet.trimStart(text, ["-", ">", " "])
        return text.unicodeScalars.contains { DotNet.isLetterOrDigit($0) } ? text : ""
    }

    /// Lowercase, punctuation-free form used only for command matching ("Co-Pilot." -> "copilot").
    public static func normalize(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        var normalized = String.UnicodeScalarView()
        for c in DotNet.lowerInvariant(text).unicodeScalars {
            if DotNet.isLetterOrDigit(c) {
                normalized.append(c)
            } else if c == "-" || c == "'" || c == "\u{2019}" {
                // Join hyphenated/apostrophe words so "co-pilot" matches "copilot".
            } else {
                normalized.append(" ")
            }
        }

        return DotNet.trim(whitespaceRegex.replace(String(normalized), " "))
    }

    /// Space-free key so "git hub copilot" and "GitHub Copilot" compare equal.
    public static func compact(_ text: String?) -> String { DotNet.replace(normalize(text), " ", "") }

    private static let annotationRegex = NetRegex(#"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*"#)

    private static let whitespaceRegex = NetRegex(#"\s+"#)
}
