#!/bin/bash
# Installs the CMake the engines are built with (common.sh pins its version and SHA-256), Kitware's own build for
# macOS, into a folder, and prints the folder its programs are in, for PATH.
#
# scripts/engines/install-cmake.sh [folder, default build/engines/cmake]
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
source "$root/scripts/engines/common.sh"
mkdir -p "${1:-$root/build/engines/cmake}"
folder=$(cd "${1:-$root/build/engines/cmake}" && pwd)
name=cmake-$cmake_version-macos-universal

cd "$folder"
rm -rf "$name"
fetch "https://github.com/Kitware/CMake/releases/download/v$cmake_version/$name.tar.gz" "$name.tar.gz" \
  "$cmake_sha256" >&2
tar -xzf "$name.tar.gz"
rm "$name.tar.gz"
"$folder/$name/CMake.app/Contents/bin/cmake" --version >&2
echo "$folder/$name/CMake.app/Contents/bin"
