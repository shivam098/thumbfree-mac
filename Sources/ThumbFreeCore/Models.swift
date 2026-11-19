/// Dictation language. Hindi + English is typed in Roman letters.
public enum Language: String, Sendable, CaseIterable {
    case english
    case hinglish
}

/// The recognizer a model runs on.
public enum Engine: String, Sendable {
    /// OpenAI Whisper through whisper.cpp.
    case whisper

    /// NVIDIA Parakeet TDT transducer through sherpa-onnx (ONNX Runtime). Punctuates and capitalizes by itself.
    case parakeet

    /// A streaming transducer through sherpa-onnx's online recognizer: text arrives while you speak (live typing), with a
    /// small punctuation model on each finished phrase.
    case streaming
}

/// Speed/accuracy choice per language. `live` streams words as you speak; `accurate` is the biggest model.
public enum Tier: String, Sendable, CaseIterable {
    case live
    case standard
    case accurate
}

/// One downloadable file, pinned by SHA-256 (a mismatch deletes it). `path` is relative to the models folder, with "/".
public struct ModelFile: Hashable, Sendable {
    public let path: String
    public let url: String
    public let sha256: String
    public let bytes: Int64

    public init(_ path: String, _ url: String, _ sha256: String, _ bytes: Int64) {
        self.path = path
        self.url = url
        self.sha256 = sha256
        self.bytes = bytes
    }

    /// The file name without its folder ("tokens.txt").
    public var name: String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

/// A speech model: its files, engine and how it's used. The same ids, paths and hashes as the Android and Windows apps.
public struct ModelSpec: Hashable, Sendable {
    public let id: String
    public let label: String
    public let language: Language
    public let engine: Engine
    public let files: [ModelFile]

    /// Gets the "words I use often" list as a Whisper prompt (measured: it garbles the fast Hindi + English model).
    public let promptVocabulary: Bool

    /// Fast enough to re-transcribe while you speak.
    public let livePreview: Bool

    /// Memory below which the app warns before downloading.
    public let recommendedMemoryGb: Int

    public init(
        id: String,
        label: String,
        language: Language,
        engine: Engine,
        files: [ModelFile],
        promptVocabulary: Bool = false,
        livePreview: Bool = true,
        recommendedMemoryGb: Int = 0
    ) {
        self.id = id
        self.label = label
        self.language = language
        self.engine = engine
        self.files = files
        self.promptVocabulary = promptVocabulary
        self.livePreview = livePreview
        self.recommendedMemoryGb = recommendedMemoryGb
    }

    public var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    /// Longest piece transcribed in one call: Whisper's window is 30 s (14 s is used); Parakeet has no fixed window.
    public var maxPieceSamples: Int { engine == .whisper ? Decoding.maxPieceSamples : Decoding.sampleRate * 30 }

    /// Words arrive while you speak (no re-transcription for live text).
    public var streaming: Bool { engine == .streaming }

    /// The file called `name` (its name without the folder). Traps if the model has no such file: names are fixed here.
    public func file(_ name: String) -> ModelFile {
        guard let file = files.first(where: { $0.name == name }) else {
            preconditionFailure("\(id) has no file \(name)")
        }

        return file
    }
}

public enum ModelCatalog {
    private static let parakeet110M = "https://github.com/shivam098/thumbfree-mac/releases/download/models-parakeet-110m-1"
    private static let parakeet06B =
        "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8/resolve/84b478d541cdbf0c296a7ab5f1e20a6f8f998114"
    private static let krokoLive = "https://github.com/shivam098/thumbfree-mac/releases/download/models-kroko-en-live-1"

    /// Kroko ASR English streaming Zipformer (Banafo, CC BY-SA 4.0) + Edge-Punct-Casing punctuation (Apache-2.0): words
    /// appear as you say them.
    public static let englishLive = ModelSpec(
        id: "en-kroko-live",
        label: "English, live (types as you speak)",
        language: .english,
        engine: .streaming,
        files: [
            ModelFile("kroko-en-live/encoder.onnx", "\(krokoLive)/encoder.onnx", "d4881c57449d581e0770fd53fa66c2fdc6cd167d92ece7c715e603defc96d9d4", 70_092_599),
            ModelFile("kroko-en-live/decoder.onnx", "\(krokoLive)/decoder.onnx", "455ba38466fce8d5a57e7db68a323b684079ca4d9e1dd93a740d9b2429aae3b1", 617_488),
            ModelFile("kroko-en-live/joiner.onnx", "\(krokoLive)/joiner.onnx", "d406f616736350e2a7df3e39398b78eb2fc1a2ca6973a19d3853fa3227e25b52", 336_817),
            ModelFile("kroko-en-live/tokens.txt", "\(krokoLive)/tokens.txt", "396dbeb5f4858875690716084f54e90d339679d0ba3e6b5b584f3d7589254d2d", 6_310),
            ModelFile("kroko-en-live/punct.int8.onnx", "\(krokoLive)/punct.int8.onnx", "9d611f445fe4a46186080fe161be6059d87d72eb88d3a8cb00c1a06e83a6067e", 7_490_500),
            ModelFile("kroko-en-live/punct-bpe.vocab", "\(krokoLive)/punct-bpe.vocab", "e118b7ad88c54db562517df49e1cffd4836d166c34fb190fd311d7f34eb238f5", 149_430),
        ])

    /// NVIDIA parakeet-tdt_ctc-110m (CC BY 4.0), TDT head, int8 ONNX from sherpa-onnx.
    public static let englishFast = ModelSpec(
        id: "en-parakeet-110m",
        label: "English",
        language: .english,
        engine: .parakeet,
        files: [
            ModelFile("parakeet-tdt-110m/encoder.int8.onnx", "\(parakeet110M)/encoder.int8.onnx", "0f35509ddeb9b39002fb077d979a9fe74f06eb0bc4dd5c34f512f82e5111d657", 131_113_202),
            ModelFile("parakeet-tdt-110m/decoder.int8.onnx", "\(parakeet110M)/decoder.int8.onnx", "f7c331c5504c2e593c76ed22b728e3f554af6c4a383dde862e719ced08b1da19", 3_955_863),
            ModelFile("parakeet-tdt-110m/joiner.int8.onnx", "\(parakeet110M)/joiner.int8.onnx", "bf7dff69e9f2cdbe9943d70da358f38b361c115ba0105bae7e908e0d6ec782f6", 1_411_403),
            ModelFile("parakeet-tdt-110m/tokens.txt", "\(parakeet110M)/tokens.txt", "450e56bd2f036fe5b6aa821865838cc5aa9d8b0106134ce9a9ba0664abe6cd10", 9_953),
        ])

    /// NVIDIA parakeet-tdt-0.6b-v2 (CC BY 4.0), int8 ONNX from sherpa-onnx. Best English accuracy on the Open ASR leaderboard.
    public static let englishAccurate = ModelSpec(
        id: "en-parakeet-0.6b",
        label: "English, accurate (slower; needs 6 GB+ memory)",
        language: .english,
        engine: .parakeet,
        files: [
            ModelFile("parakeet-tdt-0.6b-v2/encoder.int8.onnx", "\(parakeet06B)/encoder.int8.onnx", "92a10bd9c23936ea0566c29f963bc57c2a5df4261b6a8921c39abea66557ca8b", 652_282_309),
            ModelFile("parakeet-tdt-0.6b-v2/decoder.int8.onnx", "\(parakeet06B)/decoder.int8.onnx", "4d097bae3bac5c96018d5293ba39f1b657296102b142affda40378f38b020f41", 7_257_753),
            ModelFile("parakeet-tdt-0.6b-v2/joiner.int8.onnx", "\(parakeet06B)/joiner.int8.onnx", "77a29f3e5ac7d37074e0af465391b80f314015d5b97f0f90c6c7767f1d56f428", 1_739_080),
            ModelFile("parakeet-tdt-0.6b-v2/tokens.txt", "\(parakeet06B)/tokens.txt", "ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d", 9_384),
        ],
        livePreview: false,
        recommendedMemoryGb: 6)

    /// Oriserve Whisper-Hindi2Hinglish-Swift (Apache-2.0, fine-tuned from Whisper base), q8.
    public static let hinglish = ModelSpec(
        id: "hinglish-swift",
        label: "Hindi + English (typed in Roman letters)",
        language: .hinglish,
        engine: .whisper,
        files: [
            ModelFile(
                "ggml-hinglish-swift-q8_0.bin",
                "https://github.com/shivam098/windows-voice-assistant/releases/download/models-hinglish-swift-1/ggml-hinglish-swift-q8_0.bin",
                "0cf6e7077971d9aa43963b04bf764a47600e873f7e0f3f0f9742323560171245",
                81_768_585),
        ])

    /// Oriserve Whisper-Hindi2Hinglish-Apex (Apache-2.0, fine-tuned from large-v3-turbo), q8. Best Hinglish, but big.
    public static let hinglishAccurate = ModelSpec(
        id: "hinglish-apex",
        label: "Hindi + English, accurate (much slower; needs 8 GB+ memory)",
        language: .hinglish,
        engine: .whisper,
        files: [
            ModelFile(
                "ggml-hinglish-apex-q8_0.bin",
                "https://github.com/shivam098/windows-voice-assistant/releases/download/models-hinglish-apex-1/ggml-hinglish-apex-q8_0.bin",
                "0b4324d2c1ad64f20883ee7fcd5d2bb0a8466287dc70d74bc47066200c28c719",
                874_188_075),
        ],
        promptVocabulary: true,
        livePreview: false,
        recommendedMemoryGb: 8)

    /// Silero voice-activity model (MIT) for whisper.cpp: tells speech from music and noise and splits long recordings at
    /// pauses, for Whisper and Parakeet. Downloaded with the first model that needs it.
    public static let vad = ModelFile(
        "ggml-silero-v6.2.0.bin",
        "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin",
        "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987",
        885_098)

    public static let all: [ModelSpec] = [englishFast, englishLive, hinglish, englishAccurate, hinglishAccurate]

    public static func byId(_ id: String?) -> ModelSpec? { all.first { $0.id == id } }

    /// Every file path any current model uses (anything else in the models folder is left over from older versions).
    public static let knownPaths: Set<String> = Set(all.flatMap { $0.files.map(\.path) } + [vad.path])

    /// The model for a language and tier. Hindi + English has no streaming model: its live tier is the standard model
    /// (live text then updates about every half second instead of word by word).
    public static func forLanguage(_ language: Language, _ tier: Tier) -> ModelSpec {
        switch (language, tier) {
        case (.hinglish, .accurate): return hinglishAccurate
        case (.hinglish, _): return hinglish
        case (.english, .live): return englishLive
        case (.english, .standard): return englishFast
        case (.english, .accurate): return englishAccurate
        }
    }
}

/// Decoding constants shared by the engines.
public enum Decoding {
    public static let sampleRate = 16_000

    /// Whisper pieces are at most 14 s: inside a 768-frame encoder window, ~3x faster than the full 30 s window.
    public static let maxPieceSamples = sampleRate * 14

    public static let finalAudioContext = 768
}
