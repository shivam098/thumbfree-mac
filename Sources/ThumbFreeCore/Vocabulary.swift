/// "Words I use often" (names, jargon): written the way they're listed, and given to the accurate Hindi + English model
/// as a prompt. Whisper can repeat its prompt on near-silent audio, so a transcript made only of list entries is
/// dropped (but a single entry on its own is kept: that's indistinguishable from saying the word). Same rules as the
/// Android and Windows apps.
public enum Vocabulary {
    public static let maxEntries = 40

    private static let endings = Set(["s", "es", "ed", "d", "ing"].map(DotNet.ordinal))

    /// One entry per line or comma.
    public static func parse(_ text: String?) -> [String] {
        var seen = Set<[Unicode.Scalar]>()
        var entries: [String] = []
        for piece in DotNet.split(text ?? "", ["\n", ","]) {
            let entry = DotNet.trim(piece)
            if entry.isEmpty || !seen.insert(DotNet.ordinal(DotNet.lowerInvariant(entry))).inserted {
                continue
            }

            entries.append(entry)
            if entries.count == maxEntries {
                break
            }
        }

        return entries
    }

    public static func prompt(_ entries: [String]) -> String? {
        entries.isEmpty ? nil : entries.joined(separator: ", ")
    }

    public static func isEcho(_ text: String, _ entries: [String]) -> Bool {
        let heard = TranscriptText.normalize(text)
        if heard.isEmpty {
            return false
        }

        let normalized = entries.map { TranscriptText.normalize($0) }.filter { !$0.isEmpty }
        let padded = " \(heard) "
        if !DotNet.contains(" \(normalized.joined(separator: " ")) ", padded) {
            return false
        }

        return normalized.filter { DotNet.contains(padded, " \($0) ") }.count >= 2
    }

    /// Writes listed words the way they're listed when the recognizer got them nearly right: spacing and case ("git hub
    /// co-pilot" → "GitHub Copilot") for any entry, and small misspellings ("Kubirnets" → "Kubernetes") for entries of
    /// 8+ letters, at most one edit per 5 letters, same first letter. Never across punctuation, never changing a number
    /// ("Windows 10" stays with "Windows 11" listed) and never dropping or adding an ending ("Priyanka's",
    /// "Chromebooks"). Short entries are only matched exactly, so "genre" never turns into "genres".
    public static func correct(_ text: String, _ entries: [String]) -> String {
        if entries.isEmpty || text.isEmpty {
            return text
        }

        let compacted = entries.map { (entry: $0, target: Array(TranscriptText.compact($0).unicodeScalars)) }
        let targets = DotNet.orderByDescending(compacted.filter { $0.target.count >= 3 }) { $0.target.count }
        if targets.isEmpty {
            return text
        }

        let words = wordRegex.matches(text)
        var result = ""
        var copied = text.startIndex
        var i = 0
        while i < words.count {
            // Words from i that are separated only by spaces (a match never swallows punctuation).
            var joinable = 1
            while i + joinable < words.count
                && DotNet.isNullOrWhiteSpace(between(words[i + joinable - 1], words[i + joinable])) {
                joinable += 1
            }

            var best: (words: Int, replacement: String, edits: Int)?
            for (entry, target) in targets {
                let allowed = target.count >= 8 ? target.count / 5 : 0
                let entryWords = DotNet.words(DotNet.trim(entry)).count
                for n in stride(from: max(1, entryWords - 1), through: min(entryWords + 2, joinable), by: 1) {
                    let spoken = words[i..<(i + n)].map { $0.value }.joined(separator: " ")
                    let heard = Array(TranscriptText.compact(spoken).unicodeScalars)
                    if abs(heard.count - target.count) > allowed || heard.isEmpty || heard[0] != target[0] {
                        continue
                    }

                    let edits = distance(heard, target, allowed)
                    if edits > allowed || (edits > 0 && !plausibleTypo(heard, target)) {
                        continue
                    }

                    if best == nil || edits < best!.edits || (edits == best!.edits && n > best!.words) {
                        best = (n, DotNet.trim(entry), edits)
                    }
                }
            }

            guard let match = best else {
                i += 1
                continue
            }

            result.append(contentsOf: text[copied..<words[i].range.lowerBound])
            result.append(match.replacement)
            copied = words[i + match.words - 1].range.upperBound
            i += match.words
        }

        result.append(contentsOf: text[copied...])
        return result
    }

    private static func between(_ a: NetMatch, _ b: NetMatch) -> String {
        String(a.text[a.range.upperBound..<b.range.lowerBound])
    }

    /// A misspelling, not a different number or the same word with another ending.
    private static func plausibleTypo(_ heard: [Unicode.Scalar], _ target: [Unicode.Scalar]) -> Bool {
        if heard.filter({ DotNet.isDigit($0) }) != target.filter({ DotNet.isDigit($0) }) {
            return false
        }

        let (longer, shorter) = heard.count >= target.count ? (heard, target) : (target, heard)
        return !(longer.starts(with: shorter) && endings.contains(Array(longer[shorter.count...])))
    }

    /// Levenshtein distance, or limit + 1 once it's certainly above `limit`.
    private static func distance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], _ limit: Int) -> Int {
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for x in stride(from: 1, through: a.count, by: 1) {
            current[0] = x
            var rowMin = current[0]
            for y in stride(from: 1, through: b.count, by: 1) {
                current[y] = min(previous[y] + 1, current[y - 1] + 1, previous[y - 1] + (a[x - 1] == b[y - 1] ? 0 : 1))
                rowMin = min(rowMin, current[y])
            }

            if rowMin > limit {
                return limit + 1
            }

            swap(&previous, &current)
        }

        return previous[b.count]
    }

    private static let wordRegex = NetRegex(#"[\p{L}\p{Mn}\p{Nd}][\p{L}\p{Mn}\p{Nd}'’-]*"#)
}

/// "What do you do?" from the first-run guide. Used only on this computer: picking a role adds that field's names and
/// jargon to "Words I use often", so they're spelled right from the first dictation. Entries are proper nouns, brands
/// and acronyms. Never ordinary words that are also names (Notion, Excel, Medium): listed words are written exactly as
/// listed, so "excel at" would become "Excel at". And no ordinary words of 8+ letters, which the near-miss correction
/// could reach from other words ("escalating" → "escalation"). Same lists as the Android and Windows apps.
public enum Professions {
    public static let all: [(role: String, words: [String])] = [
        ("Developer", [
            "GitHub", "GitHub Copilot", "pull request", "Kubernetes", "Docker", "API", "JSON", "TypeScript",
            "JavaScript", "Python", "PostgreSQL", "VS Code",
        ]),
        ("Product", ["roadmap", "OKR", "KPI", "PRD", "Jira", "Figma", "go-to-market"]),
        ("Founder / CEO", ["OKR", "KPI", "ARR", "go-to-market", "term sheet", "LinkedIn"]),
        ("Sales", ["CRM", "Salesforce", "HubSpot", "LinkedIn"]),
        ("Marketing", ["SEO", "LinkedIn", "Instagram", "YouTube", "HubSpot", "Google Analytics", "CTA"]),
        ("Customer support", ["Zendesk", "Freshdesk", "SLA"]),
        ("Healthcare", ["MRI", "CT scan", "ECG", "ibuprofen", "paracetamol", "amoxicillin", "BP", "OPD"]),
        ("Educator", ["Google Classroom", "syllabus", "rubric", "PTM", "CBSE"]),
        ("Student", ["Google Classroom", "syllabus", "GPA", "CGPA"]),
        ("Writer / creator", ["Substack", "YouTube", "Instagram"]),
        ("Recruiting", ["LinkedIn", "Naukri", "CTC"]),
        ("Legal", ["NDA", "affidavit", "indemnity", "plaintiff", "defendant"]),
        ("Data analysis", ["SQL", "Power BI", "Tableau", "pandas", "Jupyter"]),
        ("Operations", ["SOP", "KPI", "SAP Ariba"]),
        ("Real estate", ["RERA", "EMI", "escrow"]),
        ("Other", []),
    ]

    /// `current` word list with `role`'s words added (case-insensitive, nothing removed, order kept).
    public static func addTo(_ current: String, _ role: String) -> String {
        var existing = Set(Vocabulary.parse(current).map { DotNet.ordinal(DotNet.lowerInvariant($0)) })
        let words = all.first { DotNet.ordinalEquals($0.role, role) }?.words ?? []
        let added = words.filter { existing.insert(DotNet.ordinal(DotNet.lowerInvariant($0))).inserted }
        if added.isEmpty {
            return current
        }

        let base = DotNet.trimEnd(current)
        return (base.isEmpty ? "" : base + "\n") + added.joined(separator: "\n")
    }
}
