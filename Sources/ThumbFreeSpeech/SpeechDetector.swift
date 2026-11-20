import CWhisper
import Foundation

/// A stretch of speech, in seconds from the start of the audio.
public struct SpeechRegion: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// Neural voice activity detection (Silero, via whisper.cpp). Distinguishes speech from music and noise, which an
/// energy threshold cannot do. Used to drop non-speech utterances and to split ones background sound merged together.
public final class SpeechDetector: @unchecked Sendable {
    private let context: OpaquePointer
    private let params: whisper_vad_params
    private let gate = NSLock()
    private var closed = false

    /// Loads the Silero model (whisper.cpp's ggml file). Waits for ggml's warm-up first (`ThumbFreeSpeech.warmUp`),
    /// starting it if nothing has, so the first whisper.cpp object in a process takes seconds longer unless the warm-up
    /// has run: ggml compiles its Metal shaders then.
    public init(modelPath: String, threshold: Float = 0.5) throws {
        guard Files.isFile(modelPath) else { throw SpeechError.notFound("Voice activity model not found.", modelPath) }
        Ggml.wait()
        _ = quietWhisperLogs
        var contextParams = whisper_vad_default_context_params()
        contextParams.n_threads = 2
        guard let context = whisper_vad_init_from_file_with_params(modelPath, contextParams) else {
            throw SpeechError.invalidData("Failed to load the whisper VAD model.")
        }

        var params = whisper_vad_default_params()
        params.threshold = threshold
        params.min_speech_duration_ms = 150
        params.min_silence_duration_ms = 250
        params.speech_pad_ms = 0
        self.context = context
        self.params = params
    }

    deinit {
        close()
    }

    /// The speech regions in `samples` (16 kHz mono), in order.
    public func detect(_ samples: [Float]) throws -> [SpeechRegion] {
        gate.lock()
        defer { gate.unlock() }
        if closed {
            throw SpeechError.closed
        }

        if samples.isEmpty {
            return []
        }

        let detected = samples.withUnsafeBufferPointer {
            whisper_vad_detect_speech(context, $0.baseAddress, Int32($0.count))
        }
        guard detected, let segments = whisper_vad_segments_from_probs(context, params) else {
            throw SpeechError.invalidData("whisper.cpp couldn't run the voice activity model.")
        }

        defer { whisper_vad_free_segments(segments) }

        // whisper.cpp gives the times in centiseconds.
        return (0..<whisper_vad_segments_n_segments(segments)).map { i in
            SpeechRegion(
                start: Double(whisper_vad_segments_get_segment_t0(segments, i)) / 100,
                end: Double(whisper_vad_segments_get_segment_t1(segments, i)) / 100)
        }
    }

    /// Frees the model. Safe to call twice.
    public func close() {
        gate.lock()
        defer { gate.unlock() }
        if !closed {
            closed = true
            whisper_vad_free(context)
        }
    }
}
