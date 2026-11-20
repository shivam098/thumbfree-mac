#!/bin/bash
# Builds CSherpaOnnx.xcframework.zip for Package.swift's CSherpaOnnx binary target: sherpa-onnx's C API with its
# onnxruntime, for macOS on Apple silicon and Intel, as one static library with c-api.h and a module map, and next to
# it in the zip, CSherpaOnnx-NOTICE.txt with the license of everything linked in.
#
# The libraries are sherpa-onnx's own release build of the version the Windows app's NuGet package has (2.0.1): the
# universal2 static libraries without text-to-speech, which ThumbFree doesn't use. This merges them into one library
# and adds the C API header from the same release tag. Every download is checked against a pinned SHA-256.
#
# On a Mac with the Xcode common.sh pins: scripts/engines/build-sherpa-onnx.sh [output folder, default
# build/engines/out]
set -euo pipefail

version=2.0.1
package=sherpa-onnx-v$version-osx-universal2-static-no-tts-lib
package_sha256=bd4cdc1c4122d249c46187fb36528733186f7bf52e8ceae716bd37255550a567
header_sha256=5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f
license_sha256=cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30

# The onnxruntime in sherpa-onnx's static libraries: release v1.28.2 of csukuangfj/onnxruntime-libs, built from ONNX
# Runtime's tag. Its license and third-party notices come from the same release's package for macOS.
onnxruntime_version=1.28.2
onnxruntime_commit=33ca9628233dc8f002435e868d4c2e9f82766ca1
onnxruntime_package=onnxruntime-osx-arm64-$onnxruntime_version
onnxruntime_package_sha256=d9e5c0c79929e201f5b8eb095e6809a91ce78be9866a1bca0dfab7e20b40ae40
onnxruntime_license_sha256=2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c
onnxruntime_notices_sha256=0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2

# The versions sherpa-onnx 2.0.1's build uses (its cmake folder) of the libraries it links in that have their own
# licenses, and of the Apache-2.0 ones, for the notice.
kissfft_commit=febd4caeed32e33ad8b2e0bb5ea77542c40f18ec
darts_clone_commit=87b71afd6cf784953e3c08f24c64203397f3b724
hclust_cpp_version=2026-02-25
utf8proc_version=2.12.0
json_version=3.12.0
eigen_version=5.0.1
apache="kaldi-native-fbank 1.22.4, kaldi-decoder 0.3.0 with kaldifst, OpenFst 1.8.5 and simple-sentencepiece 0.7"
github=https://raw.githubusercontent.com

root=$(cd "$(dirname "$0")/../.." && pwd)
source "$root/scripts/engines/common.sh"
check_toolchain
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

# The license texts for the notice, each pinned.
release=https://github.com/csukuangfj/onnxruntime-libs/releases/download/v$onnxruntime_version
fetch "$release/$onnxruntime_package.zip" "$onnxruntime_package.zip" "$onnxruntime_package_sha256"
unzip -q -j -d onnxruntime "$onnxruntime_package.zip" "$onnxruntime_package/LICENSE" \
  "$onnxruntime_package/ThirdPartyNotices.txt" "$onnxruntime_package/VERSION_NUMBER" \
  "$onnxruntime_package/GIT_COMMIT_ID"
check_sha256 onnxruntime/LICENSE "$onnxruntime_license_sha256"
check_sha256 onnxruntime/ThirdPartyNotices.txt "$onnxruntime_notices_sha256"
if [ "$(cat onnxruntime/VERSION_NUMBER)" != "$onnxruntime_version" ] \
    || [ "$(cat onnxruntime/GIT_COMMIT_ID)" != "$onnxruntime_commit" ]; then
  echo "::error::$onnxruntime_package.zip is ONNX Runtime $(cat onnxruntime/VERSION_NUMBER) at" \
    "$(cat onnxruntime/GIT_COMMIT_ID), expected $onnxruntime_version at $onnxruntime_commit"
  exit 1
fi

fetch "$github/mborgerding/kissfft/$kissfft_commit/COPYING" kissfft-COPYING \
  a2840585f8411be8e6826a31ef15ae65c950bd74a2437a73b013398a934ad0c6
fetch "$github/mborgerding/kissfft/$kissfft_commit/LICENSES/BSD-3-Clause" kissfft-BSD-3-Clause \
  4d6bcab46f27d6d0c878e8305d4bdcfe040d52bf6656b9771f04c9fb9902c0ed
fetch "$github/s-yata/darts-clone/$darts_clone_commit/COPYING.md" darts-clone-COPYING.md \
  c6ab19db56ed127201dfb05346ea702ab53c4e387f43eafc343a7f4c2f2ae91e
fetch "$github/csukuangfj/hclust-cpp/$hclust_cpp_version/LICENSE" hclust-cpp-LICENSE \
  e361d842da1d290351860ad6dcce2673a1e42e4f873a3ae1ff4eb92c6adaa882
fetch "$github/JuliaStrings/utf8proc/v$utf8proc_version/LICENSE.md" utf8proc-LICENSE.md \
  3b510150d34f248a221bb88e1d811238d6c6c18b51231822c42974c39bb07256
fetch "$github/nlohmann/json/v$json_version/LICENSE.MIT" json-LICENSE.MIT \
  46a65cffd1ea955132d95a8dd921640714a8d6b537d2e4e482d31145ae95b603

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

notice=$out/CSherpaOnnx-NOTICE.txt
{
  echo "CSherpaOnnx.xcframework: sherpa-onnx $version (https://github.com/k2-fsa/sherpa-onnx), its C API with the"
  echo "libraries its build links in, and ONNX Runtime $onnxruntime_version (https://onnxruntime.ai), as one static"
  echo "library. Made from sherpa-onnx's release build $package.tar.bz2"
  echo "(SHA-256 $package_sha256) by scripts/engines/build-sherpa-onnx.sh in"
  echo "https://github.com/shivam098/thumbfree-mac, with $(toolchain) (CMake builds only CWhisper)."
  echo
  echo "Inside, used unmodified, under the licenses that follow:"
  echo "- sherpa-onnx $version: Apache License 2.0."
  echo "- $apache,"
  echo "  from sherpa-onnx's build: Apache License 2.0, the same license as sherpa-onnx."
  echo "- KISS FFT (commit $kissfft_commit, in kaldi-native-fbank): BSD 3-Clause."
  echo "- darts-clone (in simple-sentencepiece): BSD 2-Clause."
  echo "- hclust-cpp with fastcluster ($hclust_cpp_version): BSD 2-Clause."
  echo "- utf8proc $utf8proc_version: MIT, with the Unicode data license."
  echo "- nlohmann/json $json_version: MIT."
  echo "- Eigen $eigen_version (in kaldi-decoder): Mozilla Public License 2.0, whose text is in ONNX Runtime's notices"
  echo "  below. Its source code:"
  echo "  https://gitlab.com/libeigen/eigen/-/archive/$eigen_version/eigen-$eigen_version.tar.gz"
  echo "- ONNX Runtime $onnxruntime_version (commit $onnxruntime_commit): MIT. It builds in other"
  echo "  open source software, listed with their licenses in its third-party notices below, among them protobuf,"
  echo "  abseil, re2, flatbuffers, ONNX, SafeInt, GSL, nlohmann/json, date, Boost, and Eigen (Mozilla Public License"
  echo "  2.0; its source code is at https://gitlab.com/libeigen/eigen, at the commit ONNX Runtime's cmake/deps.txt"
  echo "  gives)."
  section "Apache License 2.0: sherpa-onnx, kaldi-native-fbank, kaldi-decoder, kaldifst, OpenFst, simple-sentencepiece"
  cat LICENSE
  section "KISS FFT"
  cat kissfft-COPYING
  echo
  cat kissfft-BSD-3-Clause
  section "darts-clone"
  cat darts-clone-COPYING.md
  section "hclust-cpp (fastcluster)"
  cat hclust-cpp-LICENSE
  section "utf8proc"
  cat utf8proc-LICENSE.md
  section "nlohmann/json"
  cat json-LICENSE.MIT
  section "ONNX Runtime"
  cat onnxruntime/LICENSE
  section "ONNX Runtime: third-party notices"
  cat onnxruntime/ThirdPartyNotices.txt
} > "$notice"

check_notice libCSherpaOnnx.a "$notice" \
  "N11sherpa_onnx|sherpa-onnx|Apache License" \
  "N3knf|kaldi-native-fbank|kaldi-native-fbank" \
  "13kaldi_decoder|kaldi-decoder|kaldi-decoder" \
  "8kaldifst|kaldifst|kaldifst" \
  "N3fst|OpenFst|OpenFst" \
  "14ssentencepiece|simple-sentencepiece|simple-sentencepiece" \
  "_kiss_fft|KISS FFT|Mark Borgerding" \
  "5Darts|darts-clone|Susumu Yata" \
  "14fastclustercpp|fastcluster|Christoph Dalitz" \
  "_utf8proc_|utf8proc|Unicode data license" \
  "8nlohmann|nlohmann/json|Copyright (c) 2013-2025 Niels Lohmann" \
  "5Eigen|Eigen|Mozilla Public License Version 2.0" \
  "N11onnxruntime|ONNX Runtime|Copyright (c) Microsoft Corporation" \
  "6google8protobuf|protobuf|Copyright 2008 Google Inc." \
  "4absl|abseil|abseil-cpp" \
  "N3re2|re2|The RE2 Authors" \
  "11flatbuffers|flatbuffers|google/flatbuffers" \
  "N4onnx|ONNX|Open Neural Network Exchange" \
  "7SafeInt|SafeInt|dcleblanc/SafeInt" \
  "N3gsl|GSL|Microsoft GSL" \
  "N4date|date|HowardHinnant/date" \
  "5boost|Boost|Boost Software License" \
  "_cpuinfo_|cpuinfo|pytorch/cpuinfo" \
  "_kai_|KleidiAI|KleidiAI" \
  "_xnn_|XNNPACK|google/XNNPACK"

package_xcframework CSherpaOnnx libCSherpaOnnx.a Headers "$out"
