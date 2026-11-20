#!/bin/bash
# Links both engine xcframeworks into one Swift program through SwiftPM, as Package.swift will, and runs it: the module
# maps import, the static libraries link together without clashes, and the versions are the ones pinned. It's built
# for both slices; the x86_64 build runs through Rosetta on Apple silicon (Rosetta translates AVX2, the most ggml's
# Intel code uses).
#
# scripts/engines/smoke-test.sh [folder with both xcframeworks, default build/engines/out]
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
for arch in arm64 x86_64; do
  echo "::group::$arch"
  swift build -c release --arch "$arch" 2>&1 | tee "build-$arch.log"
  if grep -q "warning:" "build-$arch.log"; then
    grep "warning:" "build-$arch.log" | sort -u | sed 's/^/::warning::/'
  fi

  program="$(swift build -c release --arch "$arch" --show-bin-path)/EngineSmoke"
  lipo -info "$program"
  if /usr/bin/arch "-$arch" /usr/bin/true 2> /dev/null; then
    /usr/bin/arch "-$arch" "$program"
  else
    echo "::warning::This Mac can't run $arch code (no Rosetta?): the $arch build was linked but not run."
  fi
  echo "::endgroup::"
done
