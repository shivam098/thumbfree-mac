import Foundation
import ThumbFreeCore
import ThumbFreeMac

/// ThumbFree's settings, kept in settings.json in the Windows app's format (thumbfree-windows `AppSettings`): the same
/// keys, values and defaults, so the file can move between the two. Settings that the app window shows are saved
/// through `SettingsStore`, which writes only what changed; everything else in the file is edited by hand. A few
/// settings only Windows uses are kept, with their Windows defaults, so the file is the same: the model file names,
/// the hotkeys, `audioContextSize`, `vocabularyPrompt` and `microphoneDevice`. The Mac adds `dictationKey`, which
/// Windows ignores and keeps.
public struct AppSettings: Sendable {
    /// Voice Dictation's model, kept from its settings; ThumbFree picks its models from `language` and the tiers.
    public var modelFile = "ggml-small.en-q8_0.bin"

    /// Silero voice-activity model, as Voice Dictation named it (Windows only).
    public var vadModelFile = "ggml-silero-v6.2.0.bin"

    /// Voice Dictation's Hindi + English model (Windows only).
    public var hinglishModelFile = "ggml-hinglish-swift-q8_0.bin"

    /// Voice Dictation's larger Hindi + English model (Windows only).
    public var hinglishAccurateModelFile = "ggml-hinglish-apex-q8_0.bin"

    /// Switches the dictation language on Windows (the Mac switches it from the menu bar).
    public var dictationLanguageHotkey = "Alt+Shift+H"

    /// Pastes the last dictation again on Windows.
    public var pasteLastHotkey = "Alt+Shift+Z"

    /// Decoding threads for the speech models.
    public var threads = AppSettings.defaultThreads

    /// Whisper's encoder window as Voice Dictation set it (Windows only): 768 tokens cover 15.36 s of audio.
    public var audioContextSize = 768

    /// Voice Dictation's vocabulary hint (Windows only); "Words I use often" is `vocabulary`.
    public var vocabularyPrompt: String?

    /// Windows' recording device; -1 is the default one. The Mac always uses the input chosen in System Settings.
    public var microphoneDevice = -1

    /// "Paste": through the clipboard (reliable everywhere; your copy is put back). "Type": key events (some apps
    /// drop characters).
    public var insertMethod = "Paste"

    /// Short sounds when recording starts and ends ("Sounds" in Settings).
    public var soundFeedback = true

    /// Live typing: words appear as you speak (typed at each pause, the phrase still being spoken in the pill). Off,
    /// they show only in the pill, and the models that re-read the audio stop doing so. Voice Dictation called it
    /// "livePreview", which an older file still carries over.
    public var liveTyping = true

    /// A recording still going after this many seconds is finished and typed, so the microphone can't stay on by
    /// mistake. 0 turns the limit off.
    public var maxDictationSeconds = 600

    public var removeFillerWords = true

    public var spokenPunctuation = true

    /// Whole-word fixes applied to dictated text (the personal dictionary), such as "git hub" → "GitHub".
    public var replacements: SettingsDictionary = ["git hub": "GitHub", "co-pilot": "Copilot", "co pilot": "Copilot"]

    /// Say the trigger (or "insert <trigger>") to type the text, such as "my signature" → "Thanks,\nShivam".
    public var snippets = SettingsDictionary()

    /// The keys pressed for "new line" in each app, by its name as macOS shows it (Windows: its process name). Apps
    /// not listed get Shift+Enter, which chat apps treat as a new line rather than "send". Windows lists Notepad, Word,
    /// VS Code and Visual Studio; the Mac lists their Mac counterparts.
    public var newLineKeys: SettingsDictionary = [
        "TextEdit": "Enter", "Microsoft Word": "Enter", "Code": "Enter", "Xcode": "Enter",
    ]

    /// Dictation language: the menu bar and Settings switch it.
    public var language = Language.english

    /// English model: Live (types as you speak; the default), Standard or Accurate.
    public var englishTier = Tier.live

    /// Hindi + English model: Standard or Accurate. There's no live model for it yet.
    public var hinglishTier = Tier.standard

    /// Smart formatting: emails laid out, spoken lists made into lists, "3 pm… actually 4 pm" → "4 pm".
    public var smartFormatting = true

    /// "Words I use often": names and jargon, one per line, written the way they're listed. Only the first
    /// `Vocabulary.maxEntries` are used.
    public var vocabulary = ""

    /// "What do you do?": the field picked last (its words were added to `vocabulary`). Stays on this Mac.
    public var profession: String?

    /// History: keep the text of each dictation on this Mac for 30 days. Turning it off deletes History.
    public var keepHistory = true

    /// "Help improve ThumbFree": keep each dictation's audio and text on this Mac, to share only by hand.
    public var saveSamples = false

    /// The first-run guide was finished, skipped or closed.
    public var guideDone = false

    /// The key that starts and finishes dictation: Fn (🌐), or Right Option. Mac only.
    public var dictationKey = FnTapKeys.TapKey.fn

    /// What couldn't be used in the file when it was read (those settings kept their defaults).
    var loadProblems = SettingsProblems()

    public init() {}

    /// Two thirds of the processors, 2 to 8, as on Windows.
    public static var defaultThreads: Int { min(max(ProcessInfo.processInfo.activeProcessorCount * 2 / 3, 2), 8) }

    public func tier(for language: Language) -> Tier { language == .hinglish ? hinglishTier : englishTier }

    /// The model chosen for `language`.
    public func model(for language: Language) -> ModelSpec { ModelCatalog.forLanguage(language, tier(for: language)) }

    /// The model dictation uses now: the chosen tier of the current language.
    public var selectedModel: ModelSpec { model(for: language) }

    /// What the formatter does, with the replacements and snippets in the file's order, which decides which of two
    /// wins (see `DictationOptions`).
    public var dictationOptions: DictationOptions {
        DictationOptions(
            removeFillerWords: removeFillerWords, spokenPunctuation: spokenPunctuation,
            replacements: replacements.pairs, snippets: snippets.pairs)
    }
}

extension AppSettings {
    /// A setting, by its key in settings.json, in the order a new file lists them (Windows' order, then the Mac's).
    public enum Key: String, CaseIterable, Sendable {
        case modelFile, vadModelFile, hinglishModelFile, hinglishAccurateModelFile, dictationLanguageHotkey
        case pasteLastHotkey, threads, audioContextSize, vocabularyPrompt, microphoneDevice, insertMethod
        case soundFeedback, liveTyping, maxDictationSeconds, removeFillerWords, spokenPunctuation, replacements
        case snippets, newLineKeys, language, englishTier, hinglishTier, smartFormatting, vocabulary, profession
        case keepHistory, saveSamples, guideDone
        case dictationKey
    }

    /// Settings read only when ThumbFree starts: a change to them (by hand in the file) needs a restart. Everything the
    /// Settings page changes applies without one, through `SettingsStore.observe`.
    public static let readAtStart: Set<Key> = [
        .modelFile, .vadModelFile, .hinglishModelFile, .hinglishAccurateModelFile, .dictationLanguageHotkey,
        .pasteLastHotkey, .threads, .audioContextSize, .vocabularyPrompt, .microphoneDevice, .insertMethod, .snippets,
        .newLineKeys,
    ]

    /// Reads settings.json at `path`, never throwing (thumbfree-windows `AppSettings.Load`). Keys this version doesn't
    /// know are ignored (and kept in the file), missing ones take their defaults, a key written twice takes its last
    /// value, and a value of the wrong kind keeps that one setting's default (see `SettingsStore.lastError`). A file
    /// with a mistake gives the defaults and is never overwritten. Only a new (or empty) file is written. Windows also
    /// copies Voice Dictation's settings and reads its old flag files first; there's no Voice Dictation for the Mac.
    public static func load(from path: String) -> AppSettings {
        let file: [UInt8]?
        do {
            file = try contents(of: path)
        } catch {
            Log.warn("settings unreadable, using defaults: \(Log.kind(of: error))")
            var unreadable = AppSettings()
            unreadable.loadProblems[nil] = "ThumbFree couldn't read settings.json (\(error.localizedDescription)), so "
                + "it's using its default settings and won't change the file until it restarts."
            return unreadable
        }

        if let file, !SettingsJSON.isBlank(file) {
            return fromFile(file)
        }

        var settings = AppSettings()
        settings.migrate([:])
        do {
            try settings.save(to: path)
        } catch {
            Log.warn("couldn't write default settings: \(Log.kind(of: error))")
        }

        return settings
    }

    /// Writes every setting to a new file. Changes to an existing file go through `SettingsStore`, which keeps the
    /// rest of it.
    public func save(to path: String) throws {
        try SettingsStore.writeAtomically(path, Array(fileText.utf8))
    }

    /// A new settings.json: every setting with a value, indented, in `Key` order, as System.Text.Json writes the
    /// Windows app's (with \n line ends, as it writes them on a Mac).
    var fileText: String {
        let members = Self.fields.filter { !$0.isNull(self) }.map { (key: $0.key.rawValue, json: $0.json(self, true)) }
        return SettingsJSON.object(members, indented: true)
    }

    /// A file's bytes; nil when there's none (a folder counts as none, as File.Exists says).
    static func contents(of path: String) throws -> [UInt8]? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue else {
            return nil
        }

        return Array(try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// "settings.json has a mistake near line 3…" for a file that can't be read as JSON.
    static func mistake(_ mistake: SettingsJSON.Mistake) -> String {
        let fix = "won't change the file. Fix it (Settings › Advanced › Open settings file) and restart ThumbFree, or "
            + "delete it to start again."
        guard let line = mistake.line else {
            return "\(mistake.message) ThumbFree is using its default settings and \(fix)"
        }

        return "settings.json has a mistake near line \(line + 1), so ThumbFree is using its default settings and "
            + fix
    }

    /// "In settings.json, “threads” should be a whole number…": the message for a value of the wrong kind.
    static func wrongValue(_ key: Key, _ expected: String) -> String {
        "In settings.json, “\(key.rawValue)” should be \(expected), so ThumbFree uses its default for it."
    }

    /// Each known key on its own: one value of the wrong kind costs only that setting, never the rest.
    private static func fromFile(_ file: [UInt8]) -> AppSettings {
        var settings = AppSettings()
        let values: [String: SettingsJSON.Value]
        do {
            values = try SettingsJSON.values(file)
        } catch {
            Log.warn("settings.json has a syntax error, using defaults")
            let mistake = error as? SettingsJSON.Mistake ?? SettingsJSON.Mistake(message: "\(error)", line: nil)
            settings.loadProblems[nil] = Self.mistake(mistake)
            return settings
        }

        for field in fields {
            if let value = values[field.key.rawValue], let problem = field.read(&settings, value) {
                settings.loadProblems[field.key] = problem
            }
        }

        settings.normalize()
        settings.migrate(values)
        return settings
    }

    /// Repairs what a hand-edited or older file can leave behind: a live Hindi + English tier. (The dictionaries
    /// already ignore case, and nothing here can be null.)
    private mutating func normalize() {
        if hinglishTier == .live {
            hinglishTier = .standard
        }
    }

    /// Carries Voice Dictation's "livePreview" over when the file doesn't have "liveTyping" yet.
    private mutating func migrate(_ file: [String: SettingsJSON.Value]) {
        if file["liveTyping"] == nil, case .bool(let preview)? = file["livePreview"] {
            liveTyping = preview
        }
    }
}

extension AppSettings {
    /// One setting as settings.json holds it: how its value is read (with the problem to report when it can't be
    /// used) and written, the C# app's reflection over AppSettings' properties spelled out.
    struct Field {
        let key: Key
        /// Reads the file's value into the settings; the problem when it can't be used (the setting keeps its value).
        let read: (inout AppSettings, SettingsJSON.Value) -> String?
        /// The value's JSON: on one line, or indented as a new file writes it.
        let json: (AppSettings, _ indented: Bool) -> String
        /// A new file leaves the setting out: it has no value (System.Text.Json's WhenWritingNull).
        let isNull: (AppSettings) -> Bool
        /// The JSON on one line of what a value in the file reads as; nil when it doesn't read.
        let readBack: (SettingsJSON.Value) -> String?
    }

    static let fields: [Field] = Key.allCases.map { AppSettings.field($0) }

    static func field(_ key: Key) -> Field {
        switch key {
        case .modelFile: return text(key, \.modelFile)
        case .vadModelFile: return text(key, \.vadModelFile)
        case .hinglishModelFile: return text(key, \.hinglishModelFile)
        case .hinglishAccurateModelFile: return text(key, \.hinglishAccurateModelFile)
        case .dictationLanguageHotkey: return text(key, \.dictationLanguageHotkey)
        case .pasteLastHotkey: return text(key, \.pasteLastHotkey)
        case .threads: return number(key, \.threads)
        case .audioContextSize: return number(key, \.audioContextSize)
        case .vocabularyPrompt: return optionalText(key, \.vocabularyPrompt)
        case .microphoneDevice: return number(key, \.microphoneDevice)
        case .insertMethod: return text(key, \.insertMethod)
        case .soundFeedback: return flag(key, \.soundFeedback)
        case .liveTyping: return flag(key, \.liveTyping)
        case .maxDictationSeconds: return number(key, \.maxDictationSeconds)
        case .removeFillerWords: return flag(key, \.removeFillerWords)
        case .spokenPunctuation: return flag(key, \.spokenPunctuation)
        case .replacements: return dictionary(key, \.replacements)
        case .snippets: return dictionary(key, \.snippets)
        case .newLineKeys: return dictionary(key, \.newLineKeys)
        case .language: return choice(key, \.language)
        case .englishTier: return choice(key, \.englishTier)
        case .hinglishTier: return choice(key, \.hinglishTier)
        case .smartFormatting: return flag(key, \.smartFormatting)
        case .vocabulary: return text(key, \.vocabulary)
        case .profession: return optionalText(key, \.profession)
        case .keepHistory: return flag(key, \.keepHistory)
        case .saveSamples: return flag(key, \.saveSamples)
        case .guideDone: return flag(key, \.guideDone)
        case .dictationKey: return choice(key, \.dictationKey)
        }
    }

    /// A setting that is one JSON value. Text that isn't UTF-8 is reported as such, whatever the setting; anything
    /// else that doesn't read keeps the default and says what it should be.
    private static func single<Value>(
        _ key: Key,
        _ path: WritableKeyPath<AppSettings, Value>,
        expected: String,
        decode: @escaping (SettingsJSON.Value) -> Value?,
        encode: @escaping (Value) -> String
    ) -> Field {
        Field(
            key: key,
            read: { settings, json in
                if case .string(.none) = json {
                    return notUTF8("“\(key.rawValue)”", "so ThumbFree uses its default for it")
                }

                guard let value = decode(json) else { return wrongValue(key, expected) }
                settings[keyPath: path] = value
                return nil
            },
            json: { settings, _ in encode(settings[keyPath: path]) },
            isNull: { _ in false },
            readBack: { json in decode(json).map(encode) })
    }

    private static func text(_ key: Key, _ path: WritableKeyPath<AppSettings, String>) -> Field {
        single(key, path, expected: "text in quotes", decode: { json in
            if case .string(let text?) = json { return text }
            return nil
        }, encode: SettingsJSON.quote)
    }

    /// Text that may be null (C#'s `string?`): null clears it, and a new file leaves it out.
    private static func optionalText(_ key: Key, _ path: WritableKeyPath<AppSettings, String?>) -> Field {
        Field(
            key: key,
            read: { settings, json in
                switch json {
                case .string(let text?):
                    settings[keyPath: path] = text
                case .string(.none):
                    return notUTF8("“\(key.rawValue)”", "so ThumbFree uses its default for it")
                case .null:
                    settings[keyPath: path] = nil
                default:
                    return wrongValue(key, "text in quotes")
                }

                return nil
            },
            json: { settings, _ in settings[keyPath: path].map(SettingsJSON.quote) ?? "null" },
            isNull: { $0[keyPath: path] == nil },
            readBack: { json in
                switch json {
                case .string(let text?): return SettingsJSON.quote(text)
                case .null: return "null"
                default: return nil
                }
            })
    }

    /// A whole number in C#'s `int` range, written without a fraction or an exponent.
    private static func number(_ key: Key, _ path: WritableKeyPath<AppSettings, Int>) -> Field {
        single(key, path, expected: "a whole number", decode: { json in
            if case .number(let text) = json, let number = Int32(text) { return Int(number) }
            return nil
        }, encode: { String($0) })
    }

    private static func flag(_ key: Key, _ path: WritableKeyPath<AppSettings, Bool>) -> Field {
        single(key, path, expected: "true or false", decode: { json in
            if case .bool(let value) = json { return value }
            return nil
        }, encode: { $0 ? "true" : "false" })
    }

    /// One of a choice's names, in any case, with spaces around it: anything else is a mistake reported for that one
    /// setting, such as names joined by a comma, which .NET's enum parsing would combine ("Live, Accurate").
    private static func choice<Choice: SettingsChoice>(_ key: Key, _ path: WritableKeyPath<AppSettings, Choice>)
        -> Field
    {
        let names = Choice.allCases.map(\.settingsName)
        let expected = names.dropLast().joined(separator: ", ") + " or " + (names.last ?? "")
        return single(key, path, expected: expected, decode: { json in
            guard case .string(let text?) = json else { return nil }
            let name = DotNet.trim(text)
            return Choice.allCases.first { DotNet.equalsOrdinalIgnoreCase($0.settingsName, name) }
        }, encode: { SettingsJSON.quote($0.settingsName) })
    }

    /// A { } of text by text. Its entries are read one by one: one that isn't text costs only itself.
    private static func dictionary(_ key: Key, _ path: WritableKeyPath<AppSettings, SettingsDictionary>) -> Field {
        Field(
            key: key,
            read: { settings, json in
                guard case .object(let members) = json else {
                    return wrongValue(key, "a { } list of “what”: “text” pairs")
                }

                var entries = SettingsDictionary()
                var problem: String?
                for member in members {
                    guard let name = member.name else {
                        problem = notUTF8("an entry in “\(key.rawValue)”", "so that entry is left out")
                        continue
                    }

                    switch member.value {
                    case .string(let text?):
                        entries[name] = text
                    case .string(.none):
                        problem = notUTF8("an entry in “\(key.rawValue)”", "so that entry is left out")
                    default:
                        problem = "In settings.json, “\(key.rawValue)” should have text in quotes for “\(name)”, so "
                            + "that entry is left out."
                    }
                }

                settings[keyPath: path] = entries
                return problem
            },
            json: { settings, indented in dictionaryJSON(settings[keyPath: path], indented: indented) },
            isNull: { _ in false },
            readBack: { json in
                guard case .object(let members) = json else { return nil }
                var entries = SettingsDictionary()
                for member in members {
                    guard let name = member.name, case .string(let text?) = member.value else { return nil }
                    entries[name] = text
                }

                return dictionaryJSON(entries, indented: false)
            })
    }

    private static func dictionaryJSON(_ entries: SettingsDictionary, indented: Bool) -> String {
        SettingsJSON.object(entries.pairs.map { (key: $0.key, json: SettingsJSON.quote($0.value)) }, indented: indented)
    }

    /// "…has text that isn't UTF-8": a file saved in another encoding turns "café" into a byte that isn't text.
    private static func notUTF8(_ what: String, _ consequence: String) -> String {
        "In settings.json, \(what) has text that isn't UTF-8 (the file may have been saved in another encoding), "
            + "\(consequence)."
    }
}

/// A { } of text by text in settings.json (replacements, snippets, new-line keys), in the file's order, which decides
/// which of two replacements or two snippets wins. Keys ignore case, as Windows' do (StringComparer.OrdinalIgnoreCase):
/// of two that differ only in case, the first keeps its place and its spelling, and the last its value.
public struct SettingsDictionary: Sendable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var pairs: [(key: String, value: String)] = []

    public init() {}

    public init(_ pairs: [(key: String, value: String)]) {
        for (key, value) in pairs {
            self[key] = value
        }
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        for (key, value) in elements {
            self[key] = value
        }
    }

    public var count: Int { pairs.count }

    public var isEmpty: Bool { pairs.isEmpty }

    /// The value for `key`, in any case. A new key goes at the end; nil removes the key.
    public subscript(key: String) -> String? {
        get { index(of: key).map { pairs[$0].value } }
        set {
            if let i = index(of: key) {
                if let newValue {
                    pairs[i].value = newValue
                } else {
                    pairs.remove(at: i)
                }
            } else if let newValue {
                pairs.append((key: key, value: newValue))
            }
        }
    }

    public func makeIterator() -> IndexingIterator<[(key: String, value: String)]> { pairs.makeIterator() }

    private func index(of key: String) -> Int? {
        let wanted = DotNet.ordinalIgnoreCase(key)
        return pairs.firstIndex { DotNet.ordinalIgnoreCase($0.key) == wanted }
    }
}

extension SettingsDictionary: Equatable {
    /// The same entries in the same order, compared as C# compares text (ordinal).
    public static func == (lhs: SettingsDictionary, rhs: SettingsDictionary) -> Bool {
        lhs.pairs.count == rhs.pairs.count && zip(lhs.pairs, rhs.pairs).allSatisfy { a, b in
            DotNet.ordinalEquals(a.key, b.key) && DotNet.ordinalEquals(a.value, b.value)
        }
    }
}

/// What couldn't be used in settings.json: a message per key, or for the whole file (nil), in the order found. A key
/// keeps its place when its message changes.
struct SettingsProblems: Sendable {
    private(set) var entries: [(key: AppSettings.Key?, message: String)] = []

    var isEmpty: Bool { entries.isEmpty }

    subscript(key: AppSettings.Key?) -> String? {
        get { entries.first { $0.key == key }?.message }
        set {
            if let i = entries.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    entries[i].message = newValue
                } else {
                    entries.remove(at: i)
                }
            } else if let newValue {
                entries.append((key: key, message: newValue))
            }
        }
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

/// A choice settings.json writes by name, as the Windows app writes its enums ("English", "Live").
protocol SettingsChoice: CaseIterable, Equatable {
    var settingsName: String { get }
}

extension Language: SettingsChoice {
    var settingsName: String {
        switch self {
        case .english: return "English"
        case .hinglish: return "Hinglish"
        }
    }
}

extension Tier: SettingsChoice {
    var settingsName: String {
        switch self {
        case .live: return "Live"
        case .standard: return "Standard"
        case .accurate: return "Accurate"
        }
    }
}

extension FnTapKeys.TapKey: SettingsChoice {
    var settingsName: String {
        switch self {
        case .fn: return "Fn"
        case .rightOption: return "RightOption"
        }
    }
}

extension PersonalDictionary {
    /// The personal dictionary as Settings shows it (thumbfree-windows App's `PersonalDictionary`): one "what it hears
    /// = what to type" per line, a line break inside what to type written \n and a backslash \\. settings.json keeps
    /// it as `AppSettings.replacements`.
    public static func format(_ entries: SettingsDictionary) -> String {
        entries.pairs.map { "\($0.key) = \(escape($0.value))" }.joined(separator: "\n")
    }

    /// The box's lines as entries (keys that ignore case: the last of two that differ only in case wins), and a
    /// message naming the first line that isn't "heard = typed"; the entries then stop before it.
    public static func tryParse(_ text: String) -> (entries: SettingsDictionary, mistake: String?) {
        var entries = SettingsDictionary()
        for (i, piece) in DotNet.split(text, ["\n"]).enumerated() {
            let line = DotNet.trim(piece)
            if line.isEmpty {
                continue
            }

            guard let eq = line.unicodeScalars.firstIndex(of: "=") else {
                let mistake = "Line \(i + 1) needs an “=” between what it hears and what to type (journals = genres)."
                return (entries, mistake)
            }

            let heard = DotNet.trim(String(line[..<eq]))
            if heard.isEmpty {
                return (entries, "Line \(i + 1) needs what it hears before the “=”.")
            }

            entries[heard] = unescape(DotNet.trim(String(line[line.unicodeScalars.index(after: eq)...])))
        }

        return (entries, nil)
    }

    private static func escape(_ value: String) -> String {
        DotNet.replace(DotNet.replace(DotNet.replace(value, "\\", "\\\\"), "\r\n", "\\n"), "\n", "\\n")
    }

    private static func unescape(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            if scalars[i] == "\\" && i + 1 < scalars.count && (scalars[i + 1] == "\\" || scalars[i + 1] == "n") {
                out.append(scalars[i + 1] == "n" ? "\n" : "\\")
                i += 2
            } else {
                out.append(scalars[i])
                i += 1
            }
        }

        return String(out)
    }
}
