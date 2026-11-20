# Shared by the engine build scripts (sourced, not run).

# The toolchain the released engines are built with: another Xcode or CMake makes other bytes. engines.yml selects
# this Xcode and installs this CMake (install-cmake.sh); the build scripts refuse others.
xcode_version=16.4
xcode_build=16F6
cmake_version=4.4.5
cmake_sha256=679e77a96b9ef9484cc6c1445255fc4f84206b48a65420efbedf16bdab55fbff

# The onnxruntime in sherpa-onnx's static libraries: release v1.28.2 of csukuangfj/onnxruntime-libs, built from ONNX
# Runtime's tag. The same release's package for macOS has its license and third-party notices (for CSherpaOnnx's
# notice) and its C API header (for the smoke test).
onnxruntime_version=1.28.2
onnxruntime_commit=33ca9628233dc8f002435e868d4c2e9f82766ca1
onnxruntime_release=https://github.com/csukuangfj/onnxruntime-libs/releases/download/v$onnxruntime_version
onnxruntime_package=onnxruntime-osx-arm64-$onnxruntime_version
onnxruntime_package_sha256=d9e5c0c79929e201f5b8eb095e6809a91ce78be9866a1bca0dfab7e20b40ae40

# The toolchain, for the notices.
toolchain() {
  echo "Xcode $xcode_version ($xcode_build) and CMake $cmake_version"
}

# Fails unless the selected Xcode is the pinned one, and with "cmake", unless the CMake on PATH is too.
check_toolchain() {
  local xcode cmake
  xcode=$(xcodebuild -version | tr '\n' ' ')
  if [ "$xcode" != "Xcode $xcode_version Build version $xcode_build " ]; then
    echo "::error::The engines are built with Xcode $xcode_version ($xcode_build), but $(xcode-select -p) is" \
      "$xcode. Select it with: sudo xcode-select -s /Applications/Xcode_$xcode_version.app"
    return 1
  fi

  if [ "${1:-}" = cmake ]; then
    cmake=$(cmake --version 2> /dev/null || true)
    cmake=${cmake%%$'\n'*}
    if [ "$cmake" != "cmake version $cmake_version" ]; then
      echo "::error::The engines are built with CMake $cmake_version, but the cmake on PATH is" \
        "'${cmake:-missing}'. Install it with scripts/engines/install-cmake.sh and put its folder first on PATH."
      return 1
    fi
  fi
}

# Downloads $1 to $2 and checks it against the SHA-256 $3.
fetch() {
  curl --fail --location --silent --show-error --retry 5 --retry-all-errors --output "$2" "$1"
  check_sha256 "$2" "$3" "$1"
}

# Fails unless the file $1 (from $3, for the message) has the SHA-256 $2.
check_sha256() {
  if ! echo "$2  $1" | shasum -a 256 --check --status; then
    echo "::error::$1${3:+ from $3} has SHA-256 $(shasum -a 256 "$1" | cut -d ' ' -f 1), expected $2"
    return 1
  fi
}

# Merges the static libraries or objects $2... into $1 (each architecture of universal inputs separately). ZERO_AR_DATE
# and -D give objects fixed dates, owners and modes in the archive; members of input archives keep their headers.
merge_static() {
  local output=$1
  shift
  # libtool warns about object files with the same name in different libraries; it keeps both, as it should.
  if ! ZERO_AR_DATE=1 libtool -static -D -o "$output" "$@" 2> "$output.log"; then
    cat "$output.log" >&2
    return 1
  fi
  echo "$output: $(grep -c 'same member name' "$output.log" || true) duplicate object names (all kept)"
}

# Makes $4/$1.xcframework from the universal static library $2 and the headers folder $3, and zips it with its notice
# $4/$1-NOTICE.txt, both at the root of the zip (SwiftPM finds the xcframework there). Fixed file times, no extra
# attributes and sorted entries make the zip the same for the same inputs.
package_xcframework() {
  local name=$1 library=$2 headers=$3 out=$4
  lipo "$library" -verify_arch arm64 x86_64
  if [ ! -s "$out/$name-NOTICE.txt" ]; then
    echo "::error::$out/$name-NOTICE.txt is missing: the notice goes into the zip"
    return 1
  fi

  rm -rf "${out:?}/$name.xcframework" "$out/$name.xcframework.zip"
  xcodebuild -create-xcframework -library "$library" -headers "$headers" -output "$out/$name.xcframework"
  (
    cd "$out"
    find "$name.xcframework" "$name-NOTICE.txt" -exec touch -h -t 200001010000 {} +
    find "$name.xcframework" "$name-NOTICE.txt" | LC_ALL=C sort | zip -X -q -@ "$name.xcframework.zip"
  )
  ls -l "$out/$name.xcframework.zip"
  echo "$name: library SHA-256 $(shasum -a 256 "$library" | cut -d ' ' -f 1)"
}

# A heading in a notice.
section() {
  local rule=================================================================================
  printf '\n%s\n%s\n%s\n\n' "$rule" "$1" "$rule"
}
