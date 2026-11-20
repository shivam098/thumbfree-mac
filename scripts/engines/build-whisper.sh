#!/bin/bash
# Builds CWhisper.xcframework.zip for Package.swift's CWhisper binary target: whisper.cpp with ggml (Metal, with its
# shaders built in, plus Accelerate) for macOS on Apple silicon and Intel, as one static library with whisper.h, the
# ggml headers it includes, and a module map.
#
# whisper.cpp has no prebuilt xcframework for a release. Its build-xcframework.sh builds a dynamic framework for every
# Apple platform, with one CMake build for both Mac architectures, which leaves ggml without its NEON and AVX2 code
# (ggml picks those per architecture). This builds only the Mac, with the same options, once per architecture, and
# merges the static libraries. CWhisper-NOTICE.txt, with the license, goes next to the xcframework in the zip.
#
# On a Mac with Xcode and CMake (common.sh pins both): scripts/engines/build-whisper.sh [output folder, default
# build/engines/out]
set -euo pipefail

version=1.9.5
commit=d1be6fde11ac6e0407606b4e42fe72d34add8037

root=$(cd "$(dirname "$0")/../.." && pwd)
source "$root/scripts/engines/common.sh"
check_toolchain cmake
mkdir -p "${1:-$root/build/engines/out}"
out=$(cd "${1:-$root/build/engines/out}" && pwd)
work=$root/build/engines/whisper

rm -rf "$work"
mkdir -p "$work"
git -c init.defaultBranch=main init --quiet "$work/src"
git -C "$work/src" fetch --quiet --depth 1 https://github.com/ggml-org/whisper.cpp "refs/tags/v$version"
git -C "$work/src" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
if [ "$(git -C "$work/src" rev-parse HEAD)" != "$commit" ]; then
  echo "::error::whisper.cpp v$version is $(git -C "$work/src" rev-parse HEAD), expected $commit"
  exit 1
fi

options=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
  -DBUILD_SHARED_LIBS=OFF
  -DWHISPER_BUILD_IS_DEV=OFF
  -DWHISPER_BUILD_EXAMPLES=OFF
  -DWHISPER_BUILD_TESTS=OFF
  -DWHISPER_BUILD_SERVER=OFF
  -DWHISPER_COREML=OFF
  -DGGML_METAL=ON
  -DGGML_METAL_EMBED_LIBRARY=ON
  -DGGML_BLAS=ON
  -DGGML_ACCELERATE=ON
  -DGGML_NATIVE=OFF
  -DGGML_OPENMP=OFF
  -DGGML_CCACHE=OFF
)

# One build per architecture. arm64 gets the compiler's default for Macs (Apple M1: NEON, dot product, fp16); x86_64
# gets AVX2, FMA and F16C, which every Intel Mac that runs macOS 13 has.
build() {
  local arch=$1
  shift
  local dir=$work/build-$arch
  if ! cmake -S "$work/src" -B "$dir" -G "Unix Makefiles" "${options[@]}" -DCMAKE_OSX_ARCHITECTURES="$arch" "$@" \
      > "$dir.log" 2>&1; then
    cat "$dir.log"
    return 1
  fi
  grep -E "GGML_SYSTEM_ARCH|detected|framework found|Including|BLAS found" "$dir.log" || true
  if ! cmake --build "$dir" --target whisper -j "$(sysctl -n hw.ncpu)" > "$dir.build.log" 2>&1; then
    tail -n 100 "$dir.build.log"
    return 1
  fi

  # ggml's Metal source is embedded through generated assembly without .subsections_via_symbols, which Xcode's build
  # system can't prelink with Swift (subsections.py says why). Each ..._end label becomes an alternate entry inside the
  # data (before one more zero byte, which the length ggml computes leaves out), the file gets the directive, and the
  # objects are assembled again.
  local asm count=0
  while IFS= read -r asm; do
    if ! awk '/^_ggml_metallib_[A-Za-z0-9_]*_end:$/ {
               print ".alt_entry " substr($0, 1, length($0) - 1); print; print ".byte 0"; ends++; next
             }
             { print }
             END { print ".subsections_via_symbols"; exit (ends == 1 ? 0 : 1) }' "$asm" > "$asm.new"; then
      echo "::error::$asm doesn't have exactly one _ggml_metallib_..._end label"
      return 1
    fi
    mv "$asm.new" "$asm"
    count=$((count + 1))
  done < <(find "$dir" -name 'ggml-metal-embed*.s' | LC_ALL=C sort)
  if [ "$count" -eq 0 ]; then
    echo "::error::No embedded Metal source (ggml-metal-embed*.s) in $dir"
    return 1
  fi

  echo "$arch: $count embedded Metal sources assembled with .subsections_via_symbols"
  if ! cmake --build "$dir" --target whisper -j "$(sysctl -n hw.ncpu)" > "$dir.build2.log" 2>&1; then
    tail -n 100 "$dir.build2.log"
    return 1
  fi

  # The objects of whisper and the ggml libraries it links. CMake's archives keep each object's build time, which
  # libtool copies, so the objects themselves are merged, with a fixed time: the same sources give the same bytes.
  local objects=() expected=0 target folder object library
  for target in whisper ggml ggml-base ggml-cpu ggml-metal ggml-blas; do
    folder=$(find "$dir" -type d -name "$target.dir" | head -n 1)
    if [ -z "$folder" ]; then
      echo "::error::No objects for $target in $dir"
      return 1
    fi

    while IFS= read -r object; do
      objects+=("$object")
    done < <(find "$folder" -name '*.o' | LC_ALL=C sort)
  done

  for library in src/libwhisper.a ggml/src/libggml.a ggml/src/libggml-base.a ggml/src/libggml-cpu.a \
      ggml/src/ggml-metal/libggml-metal.a ggml/src/ggml-blas/libggml-blas.a; do
    expected=$((expected + $(ar -t "$dir/$library" | grep -vc SYMDEF || true)))
  done

  if [ "${#objects[@]}" -ne "$expected" ]; then
    echo "::error::$arch: ${#objects[@]} objects found, CMake's libraries have $expected"
    return 1
  fi

  touch -t 200001010000 "${objects[@]}"
  merge_static "$work/libCWhisper-$arch.a" "${objects[@]}"
}

build arm64
build x86_64 -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_BMI2=ON -DGGML_FMA=ON -DGGML_F16C=ON
lipo -create -output "$work/libCWhisper.a" "$work/libCWhisper-arm64.a" "$work/libCWhisper-x86_64.a"
python3 "$root/scripts/engines/subsections.py" --check "$work/libCWhisper.a"

headers=$work/Headers/CWhisper
mkdir -p "$headers"
cp "$work/src/include/whisper.h" "$work/src/ggml/include/ggml.h" "$work/src/ggml/include/ggml-alloc.h" \
  "$work/src/ggml/include/ggml-backend.h" "$work/src/ggml/include/ggml-cpu.h" "$headers/"
cat > "$headers/module.modulemap" <<'EOF'
module CWhisper [system] {
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-cpu.h"
    header "whisper.h"
    link "c++"
    link framework "Accelerate"
    link framework "Foundation"
    link framework "Metal"
    link framework "MetalKit"
    export *
}
EOF

notice=$out/CWhisper-NOTICE.txt
{
  echo "CWhisper.xcframework: whisper.cpp $version (https://github.com/ggml-org/whisper.cpp, commit $commit),"
  echo "with ggml, as one static library. Built by scripts/engines/build-whisper.sh in"
  echo "https://github.com/shivam098/thumbfree-mac, with $(toolchain). whisper.cpp and ggml are"
  echo "used unmodified, under the license that follows, except that the assembly embedding ggml's Metal source"
  echo "marks its end label for Xcode's linker (.subsections_via_symbols, .alt_entry) and adds a zero byte after it."
  section "whisper.cpp and ggml"
  cat "$work/src/LICENSE"
} > "$notice"

(cd "$work" && python3 "$root/scripts/engines/check-notice.py" libCWhisper.a "$notice" \
  "$root/scripts/engines/CWhisper.claims")

package_xcframework CWhisper "$work/libCWhisper.a" "$work/Headers" "$out"
