import CWhisper
import Foundation

public struct RecognizerOptions: Equatable, Sendable {
    public var threads: Int

    /// Whisper encoder context (0 = model default, 1500 = 30 s). Smaller is faster but caps utterance length.
    public var audioContextSize: Int

    /// Optional vocabulary hint. Keep short: Whisper can echo prompts on near-silent input.
    public var prompt: String?

    public init(threads: Int = RecognizerOptions.defaultThreads, audioContextSize: Int = 0, prompt: String? = nil) {
        self.threads = threads
        self.audioContextSize = audioContextSize
        self.prompt = prompt
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
public final class WhisperRecognizer: Recognizer, @unchecked Sendable {
    public static let sampleRate = 16000

    /// whisper.cpp's version ("1.9.5").
    public static var version: String { String(cString: whisper_version()) }

    // whisper.cpp refuses input shorter than 1000 ms, which would drop one-word commands like "send".
    private static let minSamples = sampleRate * 11 / 10

    private let options: RecognizerOptions
    private let context: OpaquePointer
    private let gate = NSLock()
    private let aborted = Flag()
    private var closed = false

    public init(modelPath: String, options: RecognizerOptions = RecognizerOptions()) throws {
        guard Files.isFile(modelPath) else { throw SpeechError.notFound("Speech model not found.", modelPath) }
        _ = quietWhisperLogs

        // Whisper.net's defaults: the GPU (Metal), without flash attention.
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = false
        guard let context = whisper_init_from_file_with_params_no_state(modelPath, params) else {
            throw SpeechError.invalidData("Failed to load the whisper model.")
        }

        self.options = options
        self.context = context
    }

    deinit {
        if !closed {
            whisper_free(context)
        }
    }

    /// The text of `samples` with the options' prompt, its probability and how long it took (C#'s TranscribeAsync).
    /// Throws `SpeechError.closed` once the recognizer is closed.
    public func transcribeResult(_ samples: [Float]) throws -> TranscriptionResult {
        gate.lock()
        defer { gate.unlock() }
        if closed {
            throw SpeechError.closed
        }

        return try run(samples, prompt: Self.isBlank(options.prompt) ? nil : options.prompt)
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
        if aborted.isSet || closed {
            return nil
        }

        let result = try run(samples16k, prompt: promptFor(prompt))
        return aborted.isSet ? nil : result.text
    }

    public func abort() { aborted.set(true) }

    public func resume() { aborted.set(false) }

    /// Waits up to 5 s for a transcription in progress, then frees the model. If it's still running then, this returns
    /// without waiting longer (the caller may be the main thread), and the model is freed with the recognizer. Safe to
    /// call twice.
    public func close() {
        aborted.set(true)
        guard gate.lock(before: Date(timeIntervalSinceNow: 5)) else { return }
        defer { gate.unlock() }
        if !closed {
            closed = true
            whisper_free(context)
        }
    }

    /// The prompt a call runs with (C#'s ProcessorFor): `prompt` unless it's blank, else the options' prompt.
    private func promptFor(_ prompt: String?) -> String? {
        let chosen = Self.isBlank(prompt) || prompt == options.prompt ? options.prompt : prompt
        return Self.isBlank(chosen) ? nil : chosen
    }

    private func run(_ samples: [Float], prompt: String?) throws -> TranscriptionResult {
        var input = samples
        if input.count < Self.minSamples {
            input.append(contentsOf: repeatElement(0, count: Self.minSamples - input.count))
        }

        let started = DispatchTime.now().uptimeNanoseconds
        guard let state = whisper_init_state(context) else {
            throw SpeechError.invalidData("whisper.cpp couldn't start a transcription.")
        }

        defer { whisper_free_state(state) }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(options.threads)
        params.no_context = true
        params.single_segment = true
        params.print_progress = false
        if options.audioContextSize > 0 {
            params.audio_ctx = Int32(options.audioContextSize)
        }

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

/// whisper.cpp and ggml log to stderr; Whisper.net drops their logs by default, and so does this. Read it once before
/// using whisper.cpp.
let quietWhisperLogs: Void = whisper_log_set({ _, _, _ in }, nil)
