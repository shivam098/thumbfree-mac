#!/bin/bash
# Links both engine xcframeworks into one Swift program through SwiftPM, as Package.swift will, and runs it: the module
# maps import, the static libraries link together without clashes, and the versions are the ones pinned.
#
# scripts/engines/smoke-test.sh [folder with CSherpaOnnx.xcframework and CWhisper.xcframework, default build/engines/out]
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
out=$(cd "${1:-$root/build/engines/out}" && pwd)
work=$root/build/engines/smoke

rm -rf "$work"
mkdir -p "$work/Sources/EngineSmoke"
cp -R "$out/CSherpaOnnx.xcframework" "$out/CWhisper.xcframework" "$work/"

cat > "$work/Package.swift" <<'EOF'
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EngineSmoke",
    platforms: [.macOS(.v13)],
    targets: [
        .binaryTarget(name: "CSherpaOnnx", path: "CSherpaOnnx.xcframework"),
        .binaryTarget(name: "CWhisper", path: "CWhisper.xcframework"),
        .executableTarget(name: "EngineSmoke", dependencies: ["CSherpaOnnx", "CWhisper"]),
    ]
)
EOF

cat > "$work/Sources/EngineSmoke/main.swift" <<'EOF'
import CSherpaOnnx
import CWhisper

let sherpa = String(cString: SherpaOnnxGetVersionStr())
let onnxruntime = String(cString: SherpaOnnxGetOnnxruntimeVersionStr())
print("sherpa-onnx \(sherpa) (\(String(cString: SherpaOnnxGetGitSha1()))), onnxruntime \(onnxruntime)")
precondition(sherpa == "2.0.1", "sherpa-onnx \(sherpa)")

// An empty configuration is rejected with NULL (this links the whole C API).
var config = SherpaOnnxOfflineRecognizerConfig()
precondition(SherpaOnnxCreateOfflineRecognizer(&config) == nil)

let whisper = String(cString: whisper_version())
print("whisper.cpp \(whisper): \(String(cString: whisper_print_system_info()))")
precondition(whisper == "1.9.5", "whisper.cpp \(whisper)")
for i in 0..<ggml_backend_dev_count() {
    let device = ggml_backend_dev_get(i)
    print("ggml device \(i): \(String(cString: ggml_backend_dev_name(device))), " +
        String(cString: ggml_backend_dev_description(device)))
}

precondition(whisper_vad_init_from_file_with_params("/nonexistent.bin", whisper_vad_default_context_params()) == nil)
print("ok")
EOF

cd "$work"
swift build -c release 2>&1 | tee build.log
if grep -q "warning:" build.log; then
  grep "warning:" build.log | sort -u | sed 's/^/::warning::/'
fi
"$(swift build -c release --show-bin-path)/EngineSmoke"
