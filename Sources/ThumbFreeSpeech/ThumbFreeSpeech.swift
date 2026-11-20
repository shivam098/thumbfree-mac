import ThumbFreeCore

/// The speech engines (sherpa-onnx, whisper.cpp), the recognizers and the model store. When the chosen model uses
/// Silero or Whisper (Parakeet, or Hindi + English), call `warmUp()` at launch, and again when the user switches to
/// such a model, so its first dictation doesn't wait for whisper.cpp's setup. English Live (Kroko) uses neither: don't
/// warm up for it, since the warm-up compiles all of ggml's Metal shaders and keeps them in memory.
public enum ThumbFreeSpeech {
    public static let coreVersion = ThumbFreeCore.version

    /// The engines linked in, for logs: "sherpa-onnx 2.0.1 (onnxruntime 1.28.2), whisper.cpp 1.9.5".
    public static var engines: String {
        "sherpa-onnx \(Sherpa.version) (onnxruntime \(Sherpa.onnxruntimeVersion)), "
            + "whisper.cpp \(WhisperRecognizer.version)"
    }
}
