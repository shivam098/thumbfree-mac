import Foundation
import ThumbFreeCore

/// A loaded speech model, the same contract as the Android app's Recognizer (the Windows app's IRecognizer).
/// `transcribe` runs on the speech thread, one call at a time; `abort` may be called from any thread, so a cancelled
/// dictation never waits for a result nobody wants.
public protocol Recognizer: AnyObject, Sendable {
    /// Raw text for 16 kHz mono audio, or nil if aborted (or closed). `preview` trades accuracy for speed where the
    /// engine can; `prompt` is a vocabulary hint only Whisper uses.
    func transcribe(_ samples16k: [Float], preview: Bool, prompt: String?) throws -> String?

    /// Stops the call in progress (or throws its result away); later calls return nil until `resume`.
    func abort()

    func resume()

    /// Frees the model (C#'s `Dispose`); later calls return nil. Safe to call twice.
    func close()
}

extension Recognizer {
    public func transcribe(_ samples16k: [Float], preview: Bool) throws -> String? {
        try transcribe(samples16k, preview: preview, prompt: nil)
    }
}

/// Loads the recognizer for a model, like the Android SpeechEngine: one class per `Engine`.
public enum Recognizers {
    /// Loads `spec` from `store` with `threads` decoding threads. Throws `SpeechError.notFound` if a file is missing
    /// (check `ModelStore.isInstalled(_:)` first).
    public static func load(_ spec: ModelSpec, from store: ModelStore, threads: Int) throws -> Recognizer {
        switch spec.engine {
        case .parakeet:
            return try ParakeetRecognizer.load(store.directoryOf(spec), threads: threads)
        case .streaming:
            return try StreamingRecognizer.load(store.directoryOf(spec), threads: threads)
        case .whisper:
            guard let path = store.pathOf(spec.files[0]) else {
                throw SpeechError.notFound("Speech model not found.", spec.files[0].name)
            }

            let options = RecognizerOptions(threads: threads, audioContextSize: Decoding.finalAudioContext)
            return try WhisperRecognizer(modelPath: path, options: options)
        }
    }
}

/// Why a model couldn't be loaded or run.
public enum SpeechError: Error, Equatable, LocalizedError {
    /// A file isn't there (C#'s FileNotFoundException): the message, and the path or name of the file.
    case notFound(String, String)

    /// An engine rejected a model, or a file isn't what it should be (C#'s InvalidDataException).
    case invalidData(String)

    /// The model was closed (C#'s ObjectDisposedException).
    case closed

    public var errorDescription: String? {
        switch self {
        case let .notFound(message, _), let .invalidData(message): return message
        case .closed: return "The speech model was closed."
        }
    }
}
