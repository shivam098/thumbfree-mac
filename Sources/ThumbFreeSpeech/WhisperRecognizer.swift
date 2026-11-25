import CWhisper
import Foundation

/// How a Whisper model runs. What isn't set here keeps whisper.cpp's own value.
public struct RecognizerOptions: Equatable, Sendable {
    /// Decoding threads.
    public var threads: Int

    /// Whisper encoder context (0 = model default, 1500 = 30 s). Smaller is faster but caps utterance length.
    public var audioContextSize: Int

    /// Optional vocabulary hint. Keep short: Whisper can echo prompts on near-silent input.
    public var prompt: String?

    /// Stop after this many tokens (whisper.cpp's max_tokens; 0 = no limit). A check that needs only the first words,
    /// such as Jarvis's standby check for "Hey Jarvis", costs less with a few.
    public var maxTokens: Int

    /// Decode again at higher temperatures when the first attempt looks unreliable: whisper.cpp's default, up to five
    /// more passes. Off, each call decodes once (whisper.cpp's temperature_inc 0, which Whisper.net's
    /// WithTemperatureInc(0) sets on Windows): for unclear background speech, where retries cost most and help least.
    public var temperatureFallback: Bool

    public init(
        threads: Int = RecognizerOptions.defaultThreads,
        audioContextSize: Int = 0,
        prompt: String? = nil,
        maxTokens: Int = 0,
        temperatureFallback: Bool = true
    ) {
        self.threads = threads
        self.audioContextSize = audioContextSize
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperatureFallback = temperatureFallback
    }

    /// Half the processors, 2 to 8.
    public static var defaultThreads: Int { min(max(ProcessInfo.processInfo.activeProcessorCount / 2, 2), 8) }
}

public struct TranscriptionResult: Equatable, Sendable {
    public let text: String

    /// The mean token probability of the segments.
    public let probability: Float

    /// Seconds.
    public let elapsed: TimeInterval
}

/// OpenAI Whisper through whisper.cpp (with Metal), the engine for Hindi + English. Usable directly
/// (`transcribeResult`) or as a `Recognizer` like the sherpa-onnx engines. Set up as Windows sets it up through
/// Whisper.net: English, greedy, no context from earlier calls, one segment, a fresh decoding state for each call.
///
/// `withOptions` runs the same loaded model with other options, without loading it again (Whisper.net's
/// WithOptions). The model stays loaded until every recognizer sharing it is closed or released, in any order. Calls
/// on one recognizer run one at a time; recognizers sharing a model may run at the same time, since each call has its
/// own whisper.cpp state and only reads the model (whisper.cpp's own whisper_full_parallel runs one model on several
/// threads that way).
public final class WhisperRecognizer: Recognizer, @unchecked Sendable {
    public static let sampleRate = 16000

    /// whisper.cpp's version ("1.9.5").
    public static var version: String { String(cString: whisper_version()) }

    /// How many Whisper models are loaded now, a model shared by several recognizers counting once (for the tests).
    static var loadedModels: Int { LoadedModel.count.value }

    // whisper.cpp refuses input shorter than 1000 ms, which would drop one-word commands like "send".
    private static let minSamples = sampleRate * 11 / 10

    private let options: RecognizerOptions
    private let gate = NSLock()
    private let aborted = Flag()

    /// The loaded model, shared with the recognizers `withOptions` makes; nil once this one is closed.
    private var model: LoadedModel?

    /// Loads a Whisper model (a ggml file). Waits for ggml's warm-up first (`ThumbFreeSpeech.warmUp`), starting it if
    /// nothing has, so the first whisper.cpp object in a process takes seconds longer unless the warm-up has run: ggml
    /// compiles its Metal shaders then.
    public init(modelPath: String, options: RecognizerOptions = RecognizerOptions()) throws {
        guard Files.isFile(modelPath) else { throw SpeechError.notFound("Speech model not found.", modelPath) }
        Ggml.wait()
        _ = quietWhisperLogs

        // Whisper.net's defaults: the GPU (Metal), without flash attention.
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = false
        guard let context = whisper_init_from_file_with_params_no_state(modelPath, params) else {
            throw SpeechError.invalidData("Failed to load the whisper model.")
        }

        self.options = options
        model = LoadedModel(context)
    }

    /// Another recognizer of `model`, with `options`.
    private init(model: LoadedModel, options: RecognizerOptions) {
        self.options = options
        self.model = model
    }

    /// The same loaded model with `options` instead, without loading it again (Whisper.net's WithOptions): Jarvis's
    /// standby check runs its model with 2 threads, a 256 audio context, 8 tokens and no temperature fallback. The new
    /// recognizer has its own options, abort and close. Waits for a call in progress on this one; throws
    /// `SpeechError.closed` once this one is closed.
    public func withOptions(_ options: RecognizerOptions) throws -> WhisperRecognizer {
        gate.lock()
        defer { gate.unlock() }
        guard let model else { throw SpeechError.closed }
        return WhisperRecognizer(model: model, options: options)
    }

    /// The text of `samples` with the options' prompt, its probability and how long it took (C#'s TranscribeAsync).
    /// Throws `SpeechError.closed` once the recognizer is closed.
    public func transcribeResult(_ samples: [Float]) throws -> TranscriptionResult {
        gate.lock()
        defer { gate.unlock() }
        guard let model else { throw SpeechError.closed }
        return try run(model, samples, prompt: Self.isBlank(options.prompt) ? nil : options.prompt)
    }

    /// Runs to the end once started, as on Windows (Whisper.net keeps running natively after a cancel): `abort` throws
    /// the result away instead. A `prompt` other than the options' prompt is used for this call. `preview` is ignored:
    /// the audio context is fixed when the recognizer is made.
    public func transcribe(_ samples16k: [Float], preview: Bool, prompt: String?) throws -> String? {
        if aborted.isSet {
            return nil
        }

        gate.lock()
        defer { gate.unlock() }
        guard !aborted.isSet, let model else { return nil }
        let result = try run(model, samples16k, prompt: promptFor(prompt))
        return aborted.isSet ? nil : result.text
    }

    public func abort() { aborted.set(true) }

    public func resume() { aborted.set(false) }

    /// Waits up to 5 s for a transcription in progress, then lets go of the model, which is freed once no recognizer
    /// sharing it holds it. If it's still running then, this returns without waiting longer (the caller may be the main
    /// thread), and the recognizer lets go of the model when it's released. Safe to call twice.
    public func close() {
        aborted.set(true)
        guard gate.lock(before: Date(timeIntervalSinceNow: 5)) else { return }
        defer { gate.unlock() }
        model = nil
    }

    /// whisper.cpp's settings for a call with `options`, but for the language and the prompt, which `run` adds:
    /// greedy, no context from earlier calls, one segment, and whisper.cpp's own values for what the options leave
    /// alone.
    static func parameters(_ options: RecognizerOptions) -> whisper_full_params {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(options.threads)
        params.no_context = true
        params.single_segment = true
        params.print_progress = false
        if options.audioContextSize > 0 {
            params.audio_ctx = Int32(options.audioContextSize)
        }

        if options.maxTokens > 0 {
            params.max_tokens = Int32(clamping: options.maxTokens)
        }

        // One pass, at the first temperature: what Whisper.net's WithTemperatureInc(0) sets.
        if !options.temperatureFallback {
            params.temperature_inc = 0
        }

        return params
    }

    /// The prompt a call runs with (C#'s ProcessorFor): `prompt` unless it's blank, else the options' prompt.
    private func promptFor(_ prompt: String?) -> String? {
        let chosen = Self.isBlank(prompt) || prompt == options.prompt ? options.prompt : prompt
        return Self.isBlank(chosen) ? nil : chosen
    }

    /// One call, with a decoding state of its own. `model` stays loaded until it returns: the caller holds it.
    private func run(_ model: LoadedModel, _ samples: [Float], prompt: String?) throws -> TranscriptionResult {
        let context = model.context
        var input = samples
        if input.count < Self.minSamples {
            input.append(contentsOf: repeatElement(0, count: Self.minSamples - input.count))
        }

        let started = DispatchTime.now().uptimeNanoseconds
        guard let state = whisper_init_state(context) else {
            throw SpeechError.invalidData("whisper.cpp couldn't start a transcription.")
        }

        defer { whisper_free_state(state) }
        var params = Self.parameters(options)
        let status = "en".withCString { language -> Int32 in
            params.language = language
            return Self.withCString(prompt) { initialPrompt in
                params.initial_prompt = initialPrompt
                return input.withUnsafeBufferPointer {
                    whisper_full_with_state(context, state, params, $0.baseAddress, Int32($0.count))
                }
            }
        }

        if status != 0 {
            throw SpeechError.invalidData("whisper.cpp couldn't transcribe the audio (error \(status)).")
        }

        // Each segment with text, and the mean probability of its tokens, as Whisper.net reports them.
        var text = ""
        var probability: Float = 0
        var segments = 0
        for segment in 0..<whisper_full_n_segments_from_state(state) {
            guard let part = whisper_full_get_segment_text_from_state(state, segment).map({ String(cString: $0) }),
                  !part.isEmpty
            else { continue }

            let tokens = whisper_full_n_tokens_from_state(state, segment)
            var sum = 0.0
            for token in 0..<tokens {
                sum += Double(whisper_full_get_token_p_from_state(state, segment, token))
            }

            text += part
            probability += Float(sum / Double(tokens))
            segments += 1
        }

        return TranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            probability: segments == 0 ? 0 : probability / Float(segments),
            elapsed: Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
    }

    private static func isBlank(_ text: String?) -> Bool {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    private static func withCString<Result>(_ text: String?, _ body: (UnsafePointer<CChar>?) -> Result) -> Result {
        guard let text else { return body(nil) }
        return text.withCString { body($0) }
    }
}

/// A loaded Whisper model: whisper.cpp's context, which holds the weights and no decoding state, shared by the
/// recognizers made from one load. Freed when the last of them lets go of it, after their calls' states.
private final class LoadedModel: @unchecked Sendable {
    /// How many are loaded now.
    static let count = Count()

    let context: OpaquePointer

    init(_ context: OpaquePointer) {
        self.context = context
        LoadedModel.count.add(1)
    }

    deinit {
        whisper_free(context)
        LoadedModel.count.add(-1)
    }
}

/// whisper.cpp and ggml log to stderr; Whisper.net drops their logs by default, and so does this. Read it once before
/// using whisper.cpp (the warm-up does).
let quietWhisperLogs: Void = whisper_log_set({ _, _, _ in }, nil)
