#!/bin/bash
# Links both engines into one Swift program through SwiftPM, from their zips as Package.swift gets them, and runs it:
# the zips unpack with their notices, the module maps import, the static libraries link together without clashes, and
# the versions are the ones pinned. It's built for each slice, and then as the app is, for both at once through
# Xcode's build system with the engines behind a Swift library target. The x86_64 builds run through Rosetta on Apple
# silicon (Rosetta translates AVX2, the most ggml's Intel code uses).
#
# scripts/engines/smoke-test.sh [folder with both zips, default build/engines/out]
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
out=$(cd "${1:-$root/build/engines/out}" && pwd)
work=$root/build/engines/smoke

rm -rf "$work"
mkdir -p "$work/Sources/EngineSmoke"
cp "$out/CSherpaOnnx.xcframework.zip" "$out/CWhisper.xcframework.zip" "$work/"

cat > "$work/Package.swift" <<'EOF'
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EngineSmoke",
    platforms: [.macOS(.v13)],
    targets: [
        .binaryTarget(name: "CSherpaOnnx", path: "CSherpaOnnx.xcframework.zip"),
        .binaryTarget(name: "CWhisper", path: "CWhisper.xcframework.zip"),
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
precondition(onnxruntime == "1.28.2", "onnxruntime \(onnxruntime): the notice is for 1.28.2")

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

# SwiftPM keeps what's next to the xcframework in the zip: the app can take the notices from there.
for name in CSherpaOnnx CWhisper; do
  notices=(.build/artifacts/*/"$name/$name-NOTICE.txt")
  if [ ! -s "${notices[0]}" ]; then
    echo "::error::$name.xcframework.zip unpacked without $name-NOTICE.txt"
    exit 1
  fi
  echo "${notices[0]}: $(wc -c < "${notices[0]}" | tr -d ' ') bytes"
done

# The app is built for both architectures at once through Xcode's build system (scripts/make-app.sh), which prelinks
# each library target with the static libraries it uses into one object, and then reads the Swift classes' metadata in
# it. The same shape here: a library target with a Swift class that uses both engines, and a program that uses it.
universal=$work/universal
mkdir -p "$universal/Sources/Engines" "$universal/Sources/EngineSmoke"
cp "$out/CSherpaOnnx.xcframework.zip" "$out/CWhisper.xcframework.zip" "$universal/"
cat > "$universal/Package.swift" <<'EOF'
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EngineSmokeUniversal",
    platforms: [.macOS(.v13)],
    targets: [
        .binaryTarget(name: "CSherpaOnnx", path: "CSherpaOnnx.xcframework.zip"),
        .binaryTarget(name: "CWhisper", path: "CWhisper.xcframework.zip"),
        .target(name: "Engines", dependencies: ["CSherpaOnnx", "CWhisper"]),
        .executableTarget(name: "EngineSmoke", dependencies: ["Engines"]),
    ]
)
EOF

cat > "$universal/Sources/Engines/Engines.swift" <<'EOF'
import CSherpaOnnx
import CWhisper

/// A Swift class, as ThumbFreeSpeech has, linked with both engines.
public final class Engines {
    public init() {}

    public var versions: String {
        "sherpa-onnx \(String(cString: SherpaOnnxGetVersionStr())), whisper.cpp \(String(cString: whisper_version()))"
    }
}
EOF

cat > "$universal/Sources/EngineSmoke/main.swift" <<'EOF'
import Engines

let versions = Engines().versions
print(versions)
precondition(versions == "sherpa-onnx 2.0.1, whisper.cpp 1.9.5", versions)
EOF

cd "$universal"
echo "::group::arm64 and x86_64 at once, through Xcode's build system"
swift build -c release --arch arm64 --arch x86_64 2>&1 | tee build.log
if grep -q "warning:" build.log; then
  grep "warning:" build.log | sort -u | sed 's/^/::warning::/'
fi

program="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/EngineSmoke"
lipo "$program" -verify_arch arm64 x86_64
for arch in arm64 x86_64; do
  if /usr/bin/arch "-$arch" /usr/bin/true 2> /dev/null; then
    /usr/bin/arch "-$arch" "$program"
  else
    echo "::warning::This Mac can't run $arch code (no Rosetta?): the universal build's $arch half wasn't run."
  fi
done
echo "::endgroup::"
