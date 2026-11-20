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
        .executableTarget(name: "ThumbFree", dependencies: ["ThumbFreeCore", "ThumbFreeSpeech", "ThumbFreeMac"]),
        // Next to the shared test data in tests/vectors and tests/audio (lowercase, as in every ThumbFree repo).
        .testTarget(name: "ThumbFreeCoreTests", dependencies: ["ThumbFreeCore"], path: "tests/ThumbFreeCoreTests"),
        .testTarget(
            name: "ThumbFreeSpeechTests",
            dependencies: ["ThumbFreeSpeech", "CSherpaOnnx"],
            path: "tests/ThumbFreeSpeechTests"),
        .testTarget(name: "ThumbFreeMacTests", dependencies: ["ThumbFreeMac"], path: "tests/ThumbFreeMacTests"),
        // The speech engines as static libraries with their C headers, linked into the app: sherpa-onnx 2.0.1 with
        // onnxruntime, and whisper.cpp 1.9.5 with ggml (Metal). .github/workflows/engines.yml builds them from the
        // pinned inputs in scripts/engines; the zips, each with its notice, are this repo's release assets. New bytes
        // get a new release tag, since SwiftPM caches what it downloads by URL.
        .binaryTarget(
            name: "CSherpaOnnx",
            url: "\(engines)/engines-sherpa-onnx-2.0.1-2/CSherpaOnnx.xcframework.zip",
            checksum: "5946bf62376d667719db941a797570b875152bac08fd1b6ec0f7bc592d1cd637"),
        .binaryTarget(
            name: "CWhisper",
            url: "\(engines)/engines-whisper-1.9.5-2/CWhisper.xcframework.zip",
            checksum: "e0ffe943d2b81dd6a8fde88ca08ba64d52999bedf03f7a35d71e722433b97105"),
    ]
)
