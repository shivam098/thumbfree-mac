#!/bin/bash
# Links both engines into one Swift program through SwiftPM, from their zips as Package.swift gets them, and runs it:
# the zips unpack with their notices, the module maps import, the static libraries link together without clashes, and
# the versions are the ones pinned. It's built for each slice, and then as the app is, for both at once through
# Xcode's build system with the engines behind a Swift library target; that build also starts ggml's Metal backend and
# multiplies two matrices in ONNX Runtime. The x86_64 builds run through Rosetta on Apple silicon (Rosetta translates
# AVX2, the most ggml's Intel code uses).
#
# scripts/engines/smoke-test.sh [folder with both zips, default build/engines/out]
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
source "$root/scripts/engines/common.sh"
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
# it. The same shape here: a library target with a Swift class that uses both engines, and a program that uses it. The
# program runs what the engines' linker marks keep in one piece, which a prelink that split a section would break:
# ggml's Metal backend, which compiles the Metal source embedded in CWhisper, and a matrix product in ONNX Runtime,
# which runs MLAS's assembly kernel. ONNX Runtime's C API is called from a C target, with the header from the package of
# the ONNX Runtime in CSherpaOnnx.
universal=$work/universal
mkdir -p "$universal/Sources/Engines" "$universal/Sources/EngineSmoke" "$universal/Sources/OnnxRuntimeCheck/include"
cp "$out/CSherpaOnnx.xcframework.zip" "$out/CWhisper.xcframework.zip" "$universal/"
fetch "$onnxruntime_release/$onnxruntime_package.zip" "$work/$onnxruntime_package.zip" "$onnxruntime_package_sha256"
unzip -q -j -d "$universal/Sources/OnnxRuntimeCheck" "$work/$onnxruntime_package.zip" \
  "$onnxruntime_package/include/onnxruntime_c_api.h" "$onnxruntime_package/include/onnxruntime_ep_c_api.h" \
  "$onnxruntime_package/include/onnxruntime_error_code.h"

cat > "$universal/Package.swift" <<'EOF'
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EngineSmokeUniversal",
    platforms: [.macOS(.v13)],
    targets: [
        .binaryTarget(name: "CSherpaOnnx", path: "CSherpaOnnx.xcframework.zip"),
        .binaryTarget(name: "CWhisper", path: "CWhisper.xcframework.zip"),
        // Only Engines links the engines, as ThumbFreeSpeech does: this target's OrtGetApiBase comes from there.
        .target(name: "OnnxRuntimeCheck"),
        .target(name: "Engines", dependencies: ["CSherpaOnnx", "CWhisper", "OnnxRuntimeCheck"]),
        .executableTarget(name: "EngineSmoke", dependencies: ["Engines"]),
    ]
)
EOF

cat > "$universal/Sources/OnnxRuntimeCheck/include/OnnxRuntimeCheck.h" <<'EOF'
#pragma once
#include <stddef.h>

/// Multiplies two 64 x 64 matrices with ONNX Runtime and checks the product: 0 if it's right, otherwise 1, with what
/// went wrong in message (size bytes).
int onnxruntime_check_matmul(char *message, size_t size);
EOF

cat > "$universal/Sources/OnnxRuntimeCheck/OnnxRuntimeCheck.c" <<'EOF'
#include "OnnxRuntimeCheck.h"

#include <math.h>
#include <stdio.h>

#include "onnxruntime_c_api.h"

// The model's matrices are SIDE x SIDE.
#define SIDE 64

// A model that multiplies A and B, two 64 x 64 float matrices, into C, in ONNX's protobuf format (IR version 8, opset
// 13). ONNX Runtime runs MatMul with MLAS's SGEMM kernel, which is assembly on both architectures.
static const unsigned char model[] = {
    0x08, 0x08, 0x3a, 0x55, 0x0a, 0x11, 0x0a, 0x01, 0x41, 0x0a, 0x01, 0x42, 0x12, 0x01, 0x43, 0x22,
    0x06, 0x4d, 0x61, 0x74, 0x4d, 0x75, 0x6c, 0x12, 0x01, 0x67, 0x5a, 0x13, 0x0a, 0x01, 0x41, 0x12,
    0x0e, 0x0a, 0x0c, 0x08, 0x01, 0x12, 0x08, 0x0a, 0x02, 0x08, 0x40, 0x0a, 0x02, 0x08, 0x40, 0x5a,
    0x13, 0x0a, 0x01, 0x42, 0x12, 0x0e, 0x0a, 0x0c, 0x08, 0x01, 0x12, 0x08, 0x0a, 0x02, 0x08, 0x40,
    0x0a, 0x02, 0x08, 0x40, 0x62, 0x13, 0x0a, 0x01, 0x43, 0x12, 0x0e, 0x0a, 0x0c, 0x08, 0x01, 0x12,
    0x08, 0x0a, 0x02, 0x08, 0x40, 0x0a, 0x02, 0x08, 0x40, 0x42, 0x02, 0x10, 0x0d,
};

// Ends the check with what failed, if the call returns an error.
#define CHECK(call)                                                                  \
    do {                                                                             \
        OrtStatus *status = (call);                                                  \
        if (status != NULL) {                                                        \
            snprintf(message, size, "%s: %s", #call, ort->GetErrorMessage(status));  \
            ort->ReleaseStatus(status);                                              \
            goto done;                                                               \
        }                                                                            \
    } while (0)

int onnxruntime_check_matmul(char *message, size_t size) {
    const OrtApi *ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (ort == NULL) {
        snprintf(message, size, "ONNX Runtime %s has no API version %d", OrtGetApiBase()->GetVersionString(),
                 ORT_API_VERSION);
        return 1;
    }

    // Small whole numbers, so the product is exact.
    static float a[SIDE * SIDE], b[SIDE * SIDE];
    for (int i = 0; i < SIDE * SIDE; i++) {
        a[i] = (float)((i * 7) % 11 - 5);
        b[i] = (float)((i * 5) % 13 - 6);
    }

    OrtEnv *env = NULL;
    OrtSessionOptions *options = NULL;
    OrtSession *session = NULL;
    OrtMemoryInfo *memory = NULL;
    OrtValue *inputs[2] = {NULL, NULL};
    OrtValue *output = NULL;
    const int64_t shape[] = {SIDE, SIDE};
    const char *input_names[] = {"A", "B"};
    const char *output_names[] = {"C"};
    float *c = NULL;
    int failed = 1;

    CHECK(ort->CreateEnv(ORT_LOGGING_LEVEL_WARNING, "EngineSmoke", &env));
    CHECK(ort->CreateSessionOptions(&options));
    CHECK(ort->SetIntraOpNumThreads(options, 1));
    CHECK(ort->CreateSessionFromArray(env, model, sizeof model, options, &session));
    CHECK(ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory));
    CHECK(ort->CreateTensorWithDataAsOrtValue(memory, a, sizeof a, shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                                              &inputs[0]));
    CHECK(ort->CreateTensorWithDataAsOrtValue(memory, b, sizeof b, shape, 2, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
                                              &inputs[1]));
    CHECK(ort->Run(session, NULL, input_names, (const OrtValue *const *)inputs, 2, output_names, 1, &output));
    CHECK(ort->GetTensorMutableData(output, (void **)&c));

    for (int i = 0; i < SIDE; i++) {
        for (int j = 0; j < SIDE; j++) {
            double expected = 0;
            for (int k = 0; k < SIDE; k++) {
                expected += (double)a[i * SIDE + k] * b[k * SIDE + j];
            }
            if (fabs(c[i * SIDE + j] - expected) > 1e-3) {
                snprintf(message, size, "C[%d][%d] is %g, not %g", i, j, c[i * SIDE + j], expected);
                goto done;
            }
        }
    }
    snprintf(message, size, "the product is right");
    failed = 0;

done:
    if (output != NULL) {
        ort->ReleaseValue(output);
    }
    for (int i = 0; i < 2; i++) {
        if (inputs[i] != NULL) {
            ort->ReleaseValue(inputs[i]);
        }
    }
    if (memory != NULL) {
        ort->ReleaseMemoryInfo(memory);
    }
    if (session != NULL) {
        ort->ReleaseSession(session);
    }
    if (options != NULL) {
        ort->ReleaseSessionOptions(options);
    }
    if (env != NULL) {
        ort->ReleaseEnv(env);
    }
    return failed;
}
EOF

cat > "$universal/Sources/Engines/Engines.swift" <<'EOF'
import CSherpaOnnx
import CWhisper
import OnnxRuntimeCheck

/// A Swift class, as ThumbFreeSpeech has, linked with both engines.
public final class Engines {
    public init() {}

    public var versions: String {
        "sherpa-onnx \(String(cString: SherpaOnnxGetVersionStr())), whisper.cpp \(String(cString: whisper_version()))"
    }

    /// Starts ggml's backend on its Metal device, which needs the Metal source embedded in CWhisper to compile: the
    /// device's name, or nil if there's no Metal device or its backend didn't start.
    public func startMetal() -> String? {
        for index in 0..<ggml_backend_dev_count() {
            let device = ggml_backend_dev_get(index)
            var props = ggml_backend_dev_props()
            ggml_backend_dev_get_props(device, &props)
            let name = String(cString: props.name)
            print("ggml device \(index): \(name), \(String(cString: props.description))")
            if props.type == GGML_BACKEND_DEVICE_TYPE_GPU, let backend = ggml_backend_dev_init(device, nil) {
                ggml_backend_free(backend)
                return name
            }
        }
        return nil
    }

    /// Multiplies two matrices with ONNX Runtime, which uses MLAS's assembly kernel: nil if the product is right,
    /// otherwise what went wrong.
    public func multiplyMatrices() -> String? {
        var message = [CChar](repeating: 0, count: 1024)
        let size = message.count
        let failed = onnxruntime_check_matmul(&message, size)
        return failed == 0 ? nil : message.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
EOF

cat > "$universal/Sources/EngineSmoke/main.swift" <<'EOF'
import Engines

let engines = Engines()
let versions = engines.versions
print(versions)
precondition(versions == "sherpa-onnx 2.0.1, whisper.cpp 1.9.5", versions)

guard let metal = engines.startMetal() else {
    fatalError("ggml's Metal backend didn't start: no Metal device, or its embedded Metal source didn't compile")
}
print("ggml's Metal backend started on \(metal)")

if let problem = engines.multiplyMatrices() {
    fatalError("ONNX Runtime's matrix product: \(problem)")
}
print("ONNX Runtime multiplied two 64 x 64 matrices right")
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
