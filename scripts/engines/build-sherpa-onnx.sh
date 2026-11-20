#!/bin/bash
# Builds CSherpaOnnx.xcframework.zip for Package.swift's CSherpaOnnx binary target: sherpa-onnx's C API with its
# onnxruntime, for macOS on Apple silicon and Intel, as one static library with c-api.h and a module map, and next to
# it in the zip, CSherpaOnnx-NOTICE.txt with the license of everything linked in.
#
# The libraries are sherpa-onnx's own release build of the version the Windows app's NuGet package has (2.0.1): the
# universal2 static libraries without text-to-speech, which ThumbFree doesn't use. This merges them into one library,
# marks ONNX Runtime's assembly kernels so Xcode's build system can prelink them (subsections.py), and adds the C API
# header from the same release tag. Every download is checked against a pinned SHA-256, and the notice against every
# symbol in the library (check-notice.py, CSherpaOnnx.claims).
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

# The versions sherpa-onnx 2.0.1's build uses (its cmake folder, and kaldi-decoder's for kaldifst) of the libraries it
# links in, for the notice and their license files.
kissfft_commit=febd4caeed32e33ad8b2e0bb5ea77542c40f18ec
darts_clone_commit=87b71afd6cf784953e3c08f24c64203397f3b724
threadpool_commit=9a42ec1329f259a5f4881a291db1dcb8f2ad9040
hclust_cpp_version=2026-02-25
utf8proc_version=2.12.0
json_version=3.12.0
eigen_version=5.0.1
kaldi_native_fbank_version=1.22.4
kaldi_decoder_version=0.3.0
kaldifst_version=1.8.0
openfst_version=1.8.5-2026-07-09
simple_sentencepiece_version=0.7

# The Eigen that ONNX Runtime 1.28.2 builds in: its build of that static library (csukuangfj/onnxruntime-build run
# 33741118112, which uploaded it to onnxruntime-libs v1.28.2) logs "Fetch Eigen3 from" this commit, "Eigen 3.4.90".
onnxruntime_eigen_commit=1d8b82b0740839c0de7f1242a3585e3390ff5f33
eigen_archive=https://gitlab.com/libeigen/eigen/-/archive
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
fetch "$github/progschj/ThreadPool/$threadpool_commit/COPYING" threadpool-COPYING \
  8afbc5160151ecc1fc27dce6cb03e4af8fb1033d59848107ce7561161242b0c7
fetch "$github/csukuangfj/hclust-cpp/$hclust_cpp_version/LICENSE" hclust-cpp-LICENSE \
  e361d842da1d290351860ad6dcce2673a1e42e4f873a3ae1ff4eb92c6adaa882
fetch "$github/JuliaStrings/utf8proc/v$utf8proc_version/LICENSE.md" utf8proc-LICENSE.md \
  3b510150d34f248a221bb88e1d811238d6c6c18b51231822c42974c39bb07256
fetch "$github/nlohmann/json/v$json_version/LICENSE.MIT" json-LICENSE.MIT \
  46a65cffd1ea955132d95a8dd921640714a8d6b537d2e4e482d31145ae95b603
fetch "$github/csukuangfj/kaldi-native-fbank/v$kaldi_native_fbank_version/LICENSE" kaldi-native-fbank-LICENSE \
  "$license_sha256"
fetch "$github/k2-fsa/kaldi-decoder/v$kaldi_decoder_version/LICENSE" kaldi-decoder-LICENSE "$license_sha256"
fetch "$github/k2-fsa/kaldifst/v$kaldifst_version/LICENSE" kaldifst-LICENSE \
  a682d6efd1ee5dee08a8e405c233c2c198ea70ae0718129daa83ab58cfe31c5d
fetch "$github/csukuangfj/openfst/v$openfst_version/COPYING" openfst-COPYING \
  4300529197035fd3452350718a0b8cee984e9412c9932d7f35fcde849fc97a4b
fetch "$github/pkufool/simple-sentencepiece/v$simple_sentencepiece_version/LICENSE" simple-sentencepiece-LICENSE \
  c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4
# Both Eigens have the same license file (from the GitHub mirror of Eigen's repository that ONNX Runtime uses).
fetch "$github/eigen-mirror/eigen/$eigen_version/COPYING.MPL2" eigen-COPYING.MPL2 \
  66a3107d5ad6a058aab753eaac2047ccb2ed0e39465dd0fe5844da3e300d5172
fetch "$github/eigen-mirror/eigen/$onnxruntime_eigen_commit/COPYING.MPL2" onnxruntime-eigen-COPYING.MPL2 \
  66a3107d5ad6a058aab753eaac2047ccb2ed0e39465dd0fe5844da3e300d5172

# Everything the C API needs, onnxruntime included. The C++ API and PortAudio (for sherpa-onnx's own tools) stay out.
inputs=()
for name in sherpa-onnx-c-api sherpa-onnx-core sherpa-onnx-fst sherpa-onnx-fstfar sherpa-onnx-kaldifst-core \
    kaldi-decoder-core kaldi-native-fbank-core kissfft-float ssentencepiece_core utf8proc onnxruntime; do
  inputs+=("$package/lib/lib$name.a")
done
merge_static libCSherpaOnnx.a "${inputs[@]}"

# ONNX Runtime's MLAS kernels are assembly without MH_SUBSECTIONS_VIA_SYMBOLS, which Xcode's build system can't prelink
# with Swift (subsections.py says why). They get the flag, with no symbol in them starting a new piece.
python3 "$root/scripts/engines/subsections.py" libCSherpaOnnx.a
python3 "$root/scripts/engines/subsections.py" --check libCSherpaOnnx.a

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
  echo "The code is used unmodified, except that ONNX Runtime's MLAS assembly kernels are marked for Xcode's linker"
  echo "(the MH_SUBSECTIONS_VIA_SYMBOLS flag, with their inner labels as alternate entries); no instruction or data"
  echo "changed. Inside, under the licenses that follow, each from the library's own repository at the version used:"
  echo "- Apache License 2.0: sherpa-onnx $version, and kaldi-native-fbank $kaldi_native_fbank_version, kaldi-decoder" \
    "$kaldi_decoder_version and"
  echo "  simple-sentencepiece $simple_sentencepiece_version, which have the same license file; kaldifst" \
    "$kaldifst_version (in kaldi-decoder) and OpenFst ${openfst_version%%-*},"
  echo "  with their own."
  echo "- KISS FFT (commit $kissfft_commit, in kaldi-native-fbank): BSD 3-Clause."
  echo "- darts-clone (in simple-sentencepiece): BSD 2-Clause."
  echo "- ThreadPool by Jakob Progsch and Vaclav Zeman (in simple-sentencepiece): zlib License."
  echo "- hclust-cpp with fastcluster ($hclust_cpp_version): BSD 2-Clause."
  echo "- utf8proc $utf8proc_version: MIT, with the Unicode data license."
  echo "- nlohmann/json $json_version: MIT."
  echo "- Eigen: Mozilla Public License 2.0. Eigen is used unmodified, in two versions, whose source code is at:"
  echo "  - Eigen $eigen_version, in kaldi-decoder:"
  echo "    $eigen_archive/$eigen_version/eigen-$eigen_version.tar.gz"
  echo "  - Eigen 3.4.90 at commit $onnxruntime_eigen_commit, in ONNX Runtime:"
  echo "    $eigen_archive/$onnxruntime_eigen_commit/eigen-$onnxruntime_eigen_commit.tar.gz"
  echo "- ONNX Runtime $onnxruntime_version (commit $onnxruntime_commit), with its MLAS kernels: MIT."
  echo "  ONNX Runtime builds in other open source software, listed with their licenses in its third-party"
  echo "  notices below: of those, this library has protobuf, abseil, re2, flatbuffers, ONNX, SafeInt, GSL, date,"
  echo "  nlohmann/json, Boost and MurmurHash3. Those notices come from"
  echo "  onnxruntime-osx-arm64-$onnxruntime_version.zip in"
  echo "  https://github.com/csukuangfj/onnxruntime-libs/releases/tag/v$onnxruntime_version, the release this"
  echo "  library's static ONNX Runtime comes from: ONNX Runtime's own repository is no longer online."
  section "Apache License 2.0: sherpa-onnx, kaldi-native-fbank, kaldi-decoder, simple-sentencepiece, OpenFst"
  cat LICENSE
  section "kaldifst"
  cat kaldifst-LICENSE
  section "OpenFst"
  cat openfst-COPYING
  section "KISS FFT"
  cat kissfft-COPYING
  echo
  cat kissfft-BSD-3-Clause
  section "darts-clone"
  cat darts-clone-COPYING.md
  section "ThreadPool"
  cat threadpool-COPYING
  section "hclust-cpp (fastcluster)"
  cat hclust-cpp-LICENSE
  section "utf8proc"
  cat utf8proc-LICENSE.md
  section "nlohmann/json"
  cat json-LICENSE.MIT
  section "Eigen"
  cat eigen-COPYING.MPL2
  section "ONNX Runtime"
  cat onnxruntime/LICENSE
  section "ONNX Runtime: third-party notices"
  cat onnxruntime/ThirdPartyNotices.txt
} > "$notice"

python3 "$root/scripts/engines/check-notice.py" libCSherpaOnnx.a "$notice" "$root/scripts/engines/CSherpaOnnx.claims"

package_xcframework CSherpaOnnx libCSherpaOnnx.a Headers "$out"
