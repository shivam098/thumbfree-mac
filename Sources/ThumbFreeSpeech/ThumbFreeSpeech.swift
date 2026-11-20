import ThumbFreeCore

/// The speech engines (sherpa-onnx, whisper.cpp), the recognizers and the model store.
public enum ThumbFreeSpeech {
    public static let coreVersion = ThumbFreeCore.version

    /// The engines linked in, for logs: "sherpa-onnx 2.0.1 (onnxruntime 1.28.2), whisper.cpp 1.9.5".
    public static var engines: String {
        "sherpa-onnx \(Sherpa.version) (onnxruntime \(Sherpa.onnxruntimeVersion)), "
            + "whisper.cpp \(WhisperRecognizer.version)"
    }
}
