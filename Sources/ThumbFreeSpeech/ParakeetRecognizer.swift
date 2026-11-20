import CSherpaOnnx
import Foundation
import ThumbFreeCore

/// NVIDIA Parakeet TDT through sherpa-onnx (the Android app's ParakeetRecognizer). Greedy decoding; the output already
/// has punctuation and capitals. A decode can't be interrupted, but it takes a fraction of the audio's length, and an
/// aborted result is thrown away.
public final class ParakeetRecognizer: Recognizer, @unchecked Sendable {
    private let recognizer: OpaquePointer
    private let gate = NSLock()
    private let aborted = Flag()
    private var closed = false

    private init(_ recognizer: OpaquePointer) {
        self.recognizer = recognizer
    }

    deinit {
        close()
    }

    /// Loads encoder/decoder/joiner/tokens from `directory`; throws if they can't be read.
    public static func load(_ directory: String, threads: Int) throws -> ParakeetRecognizer {
        precondition(threads >= 1, "threads must be at least 1")
        let paths = try Sherpa.requireFiles(
            directory, ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"])
        let recognizer = try CStrings.with { text -> OpaquePointer in
            var config = SherpaOnnxOfflineRecognizerConfig()
            config.feat_config.sample_rate = Int32(Decoding.sampleRate)
            config.feat_config.feature_dim = 80
            config.model_config.transducer.encoder = text(paths[0])
            config.model_config.transducer.decoder = text(paths[1])
            config.model_config.transducer.joiner = text(paths[2])
            config.model_config.tokens = text(paths[3])
            config.model_config.model_type = text("nemo_transducer")
            config.model_config.num_threads = Int32(threads)
            config.model_config.provider = text("cpu")
            config.decoding_method = text("greedy_search")
            return try Sherpa.created(SherpaOnnxCreateOfflineRecognizer(&config), "Parakeet model")
        }

        return ParakeetRecognizer(recognizer)
    }

    /// `preview` and `prompt` are ignored: Parakeet is fast enough for both, and its hotwords made results worse.
    public func transcribe(_ samples16k: [Float], preview: Bool, prompt: String?) -> String? {
        recognize(samples16k)?.text
    }

    /// sherpa-onnx's whole result (tokens with start times and durations), or nil if aborted. For benchmarks.
    func recognize(_ samples16k: [Float]) -> OfflineResult? {
        gate.lock()
        defer { gate.unlock() }
        if aborted.isSet || closed {
            return nil
        }

        // Very short clips confuse the encoder; pad to a second.
        var input = samples16k
        if input.count < Decoding.sampleRate {
            input.append(contentsOf: repeatElement(0, count: Decoding.sampleRate - input.count))
        }

        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return nil }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        input.withUnsafeBufferPointer {
            SherpaOnnxAcceptWaveformOffline(stream, Int32(Decoding.sampleRate), $0.baseAddress, Int32($0.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        if aborted.isSet {
            return nil
        }

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return OfflineResult() }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        return OfflineResult(result.pointee)
    }

    public func abort() { aborted.set(true) }

    public func resume() { aborted.set(false) }

    /// Waits for a decode in progress (a fraction of a second), then frees the model. Safe to call twice.
    public func close() {
        aborted.set(true)
        gate.lock()
        defer { gate.unlock() }
        if !closed {
            closed = true
            SherpaOnnxDestroyOfflineRecognizer(recognizer)
        }
    }
}

/// What sherpa-onnx's offline recognizer found: the text and, per token, its start time and duration in seconds.
struct OfflineResult: Equatable {
    var text = ""
    var tokens: [String] = []
    var timestamps: [Float] = []
    var durations: [Float] = []

    init() {}

    init(_ result: SherpaOnnxOfflineRecognizerResult) {
        text = Sherpa.string(result.text)
        let count = Int(max(result.count, 0))
        if let tokens = result.tokens_arr {
            self.tokens = (0..<count).map { Sherpa.string(tokens[$0]) }
        }

        if let timestamps = result.timestamps {
            self.timestamps = Array(UnsafeBufferPointer(start: timestamps, count: count))
        }

        if let durations = result.durations {
            self.durations = Array(UnsafeBufferPointer(start: durations, count: count))
        }
    }
}
