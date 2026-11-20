// swift-tools-version: 5.10
import PackageDescription

// Where the speech engines' binary targets (at the end) are downloaded from: this repo's releases.
let engines = "https://github.com/shivam098/thumbfree-mac/releases/download"

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
        .target(name: "ThumbFreeSpeech", dependencies: ["ThumbFreeCore", "CSherpaOnnx", "CWhisper"]),
        .target(name: "ThumbFreeMac", dependencies: ["ThumbFreeCore"]),
        // The app's own layer, ported from thumbfree-windows src/ThumbFree.App: settings, History, samples and the log,
        // in the same file formats as Windows, and the dictation host, the menu bar, the notifications and the model
        // downloads. The ThumbFree executable is a thin launcher for it.
        .target(name: "ThumbFreeApp", dependencies: ["ThumbFreeCore", "ThumbFreeMac", "ThumbFreeSpeech"]),
        .executableTarget(name: "ThumbFree", dependencies: ["ThumbFreeApp"]),
        // Next to the shared test data in tests/vectors and tests/audio (lowercase, as in every ThumbFree repo).
        .testTarget(name: "ThumbFreeCoreTests", dependencies: ["ThumbFreeCore"], path: "tests/ThumbFreeCoreTests"),
        .testTarget(
            name: "ThumbFreeSpeechTests",
            dependencies: ["ThumbFreeSpeech", "CSherpaOnnx"],
            path: "tests/ThumbFreeSpeechTests"),
        .testTarget(name: "ThumbFreeMacTests", dependencies: ["ThumbFreeMac"], path: "tests/ThumbFreeMacTests"),
        .testTarget(
            name: "ThumbFreeAppTests",
            dependencies: ["ThumbFreeApp", "ThumbFreeCore", "ThumbFreeMac", "ThumbFreeSpeech"],
            path: "tests/ThumbFreeAppTests"),
        // The speech engines as static libraries with their C headers, linked into the app: sherpa-onnx 2.0.1 with
        // onnxruntime, and whisper.cpp 1.9.5 with ggml (Metal). .github/workflows/engines.yml builds them from the
        // pinned inputs in scripts/engines; the zips, each with its notice, are this repo's release assets. New bytes
        // get a new release tag, since SwiftPM caches what it downloads by URL.
        .binaryTarget(
            name: "CSherpaOnnx",
            url: "\(engines)/engines-sherpa-onnx-2.0.1-3/CSherpaOnnx.xcframework.zip",
            checksum: "b2c70cbca97df58d8903b05533238381a46f0c157d8e2949aeaceaecf282c1aa"),
        .binaryTarget(
            name: "CWhisper",
            url: "\(engines)/engines-whisper-1.9.5-3/CWhisper.xcframework.zip",
            checksum: "3e2115f584fb47683e9cc16a46f3bb537e6438e33a88f3d8dbb17a7fa4db5b71"),
    ]
)
