#!/bin/bash
# Builds CSherpaOnnx.xcframework.zip for Package.swift's CSherpaOnnx binary target: sherpa-onnx's C API with its
# onnxruntime, for macOS on Apple silicon and Intel, as one static library with c-api.h and a module map.
#
# The libraries are sherpa-onnx's own release build of the version the Windows app's NuGet package has (2.0.1): the
# universal2 static libraries without text-to-speech, which ThumbFree doesn't use. This merges them into one library and
# adds the C API header from the same release tag. Every download is checked against a pinned SHA-256.
#
# On a Mac with Xcode: scripts/engines/build-sherpa-onnx.sh [output folder, default build/engines/out]
set -euo pipefail

version=2.0.1
package=sherpa-onnx-v$version-osx-universal2-static-no-tts-lib
package_sha256=bd4cdc1c4122d249c46187fb36528733186f7bf52e8ceae716bd37255550a567
header_sha256=5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f
license_sha256=cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30

root=$(cd "$(dirname "$0")/../.." && pwd)
source "$root/scripts/engines/common.sh"
mkdir -p "${1:-$root/build/engines/out}"
out=$(cd "${1:-$root/build/engines/out}" && pwd)
work=$root/build/engines/sherpa-onnx

rm -rf "$work"
mkdir -p "$work"
cd "$work"

fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$version/$package.tar.bz2" "$package.tar.bz2" \
  "$package_sha256"
fetch "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v$version/sherpa-onnx/c-api/c-api.h" c-api.h \
  "$header_sha256"
fetch "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v$version/LICENSE" LICENSE "$license_sha256"
tar -xjf "$package.tar.bz2"

# Everything the C API needs, onnxruntime included. The C++ API and PortAudio (for sherpa-onnx's own tools) stay out.
inputs=()
for name in sherpa-onnx-c-api sherpa-onnx-core sherpa-onnx-fst sherpa-onnx-fstfar sherpa-onnx-kaldifst-core \
    kaldi-decoder-core kaldi-native-fbank-core kissfft-float ssentencepiece_core utf8proc onnxruntime; do
  inputs+=("$package/lib/lib$name.a")
done
merge_static libCSherpaOnnx.a "${inputs[@]}"

mkdir -p Headers/CSherpaOnnx
cp c-api.h Headers/CSherpaOnnx/
cat > Headers/CSherpaOnnx/module.modulemap <<'EOF'
module CSherpaOnnx [system] {
    header "c-api.h"
    link "c++"
    link framework "CoreFoundation"
    link framework "Foundation"
    export *
}
EOF

package_xcframework CSherpaOnnx libCSherpaOnnx.a Headers "$out"

{
  echo "CSherpaOnnx.xcframework: sherpa-onnx $version (https://github.com/k2-fsa/sherpa-onnx) with ONNX Runtime"
  echo "1.28.2 (https://onnxruntime.ai) linked in statically. Made from $package.tar.bz2"
  echo "(SHA-256 $package_sha256) by scripts/engines/build-sherpa-onnx.sh in"
  echo "https://github.com/shivam098/thumbfree-mac."
  echo
  echo "Also inside, from sherpa-onnx's build: kaldi-native-fbank, kaldi-decoder, kaldifst, OpenFst and"
  echo "simple-sentencepiece (Apache-2.0), utf8proc (MIT) and KISS FFT (BSD-3-Clause). The repository's"
  echo "THIRD-PARTY-NOTICES.md links to each."
  echo
  echo "================================================================================"
  echo "sherpa-onnx"
  echo "================================================================================"
  cat LICENSE
  echo
  echo "================================================================================"
  echo "ONNX Runtime"
  echo "================================================================================"
  mit_license "Copyright (c) Microsoft Corporation"
} > "$out/CSherpaOnnx-NOTICE.txt"
