# Shared by the engine build scripts (sourced, not run).

# Downloads $1 to $2 and checks it against the SHA-256 $3.
fetch() {
  curl --fail --location --silent --show-error --retry 5 --retry-all-errors --output "$2" "$1"
  if ! echo "$3  $2" | shasum -a 256 --check --status; then
    echo "::error::$2 from $1 has SHA-256 $(shasum -a 256 "$2" | cut -d ' ' -f 1), expected $3"
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

# Makes $4/$1.xcframework from the universal static library $2 and the headers folder $3, and zips it with the
# xcframework at the root of the zip (as SwiftPM expects). Fixed file times, no extra attributes and sorted entries make
# the zip the same for the same inputs.
package_xcframework() {
  local name=$1 library=$2 headers=$3 out=$4
  lipo "$library" -verify_arch arm64 x86_64
  rm -rf "${out:?}/$name.xcframework" "$out/$name.xcframework.zip"
  xcodebuild -create-xcframework -library "$library" -headers "$headers" -output "$out/$name.xcframework"
  (
    cd "$out"
    find "$name.xcframework" -exec touch -h -t 200001010000 {} +
    find "$name.xcframework" | LC_ALL=C sort | zip -X -q -@ "$name.xcframework.zip"
  )
  ls -l "$out/$name.xcframework.zip"
}

# The MIT License with the copyright line $1.
mit_license() {
  cat <<EOF
MIT License

$1

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
}
