// swift-tools-version: 5.10
import PackageDescription

// ThumbFree for Mac. The libraries are shared with Jarvis for Mac (mac-voice-assistant), which depends on this package.
let package = Package(
    name: "ThumbFree",
    platforms: [.macOS(.v13)],
    products: [
        // Formatting, emails, lists and corrections, live typing, field rules, the word list: a Swift port of the
        // Windows app's C# core (thumbfree-windows src/ThumbFree.Core), held to the shared test data in tests/vectors.
        .library(name: "ThumbFreeCore", targets: ["ThumbFreeCore"]),
        // The speech engines and their models: Kroko and Parakeet through sherpa-onnx, Hindi + English through
        // whisper.cpp, Silero to find pauses.
        .library(name: "ThumbFreeSpeech", targets: ["ThumbFreeSpeech"]),
        // The Mac side of dictation: the Fn hotkey, the microphone, reading the text box (Accessibility), typing into it
        // (pasteboard + ⌘V), the pill and the permissions. Jarvis for Mac uses it too.
        .library(name: "ThumbFreeMac", targets: ["ThumbFreeMac"]),
        .executable(name: "ThumbFree", targets: ["ThumbFree"]),
    ],
    targets: [
        .target(name: "ThumbFreeCore"),
        .target(name: "ThumbFreeSpeech", dependencies: ["ThumbFreeCore"]),
        .target(name: "ThumbFreeMac", dependencies: ["ThumbFreeCore"]),
        .executableTarget(name: "ThumbFree", dependencies: ["ThumbFreeCore", "ThumbFreeSpeech", "ThumbFreeMac"]),
        // Next to the shared test data in tests/vectors and tests/audio (lowercase, as in every ThumbFree repo).
        .testTarget(name: "ThumbFreeCoreTests", dependencies: ["ThumbFreeCore"], path: "tests/ThumbFreeCoreTests"),
        .testTarget(name: "ThumbFreeSpeechTests", dependencies: ["ThumbFreeSpeech"], path: "tests/ThumbFreeSpeechTests"),
        .testTarget(name: "ThumbFreeMacTests", dependencies: ["ThumbFreeMac"], path: "tests/ThumbFreeMacTests"),
    ]
)
