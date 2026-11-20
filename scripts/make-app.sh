#!/usr/bin/env bash
# Builds ThumbFree.app, a universal (Apple silicon and Intel) release build signed ad hoc, and ThumbFree-<version>.dmg
# with the app and a link to Applications, both in dist/. The app's Contents/Resources has the licenses of what's
# linked in: THIRD-PARTY-NOTICES.md and the speech engines' notices. Needs a Mac with Xcode.
#
#   scripts/make-app.sh [version]
#
# The version is a number such as 0.1.0: by default the latest v* tag's, else 0.1.0. An ad-hoc signature is enough to
# test on a Mac: the first time, try to open the app, then choose System Settings › Privacy & Security › Open Anyway.
# A normal install needs Developer ID signing (docs/mac.md).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

version="${1:-}"
if [[ -z "$version" ]]; then
  version="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
  version="${version#v}"
fi
version="${version:-0.1.0}"
if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "error: the version must be a number such as 0.1.0, not '$version'" >&2
  exit 1
fi

dist="$root/dist"
app="$dist/ThumbFree.app"
dmg="$dist/ThumbFree-$version.dmg"
work="$root/.build/make-app"
volume="$work/volume"
rm -rf "$app" "$dmg" "$work"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$work"

# The icon set, the image's staging folder and its mount point go, whether or not the build gets that far.
cleanup() {
  if [[ -d "$volume" ]]; then
    hdiutil detach "$volume" -quiet 2>/dev/null || true
  fi
  rm -rf "$work" || true
}
trap cleanup EXIT

echo "== Building ThumbFree $version for arm64 and x86_64"
swift build -c release --arch arm64 --arch x86_64 --product ThumbFree
binary="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ThumbFree"
lipo "$binary" -verify_arch arm64 x86_64
echo "Architectures: $(lipo -archs "$binary")"

# The app carries no libraries of its own (the speech engines are linked in statically), so a binary may link only the
# system's. Prints what it links.
check_links() {
  local libraries
  libraries="$(otool -L "$1" | awk '/^\t/ { print $1 }' | sort -u)"
  echo "$1 links:"
  echo "$libraries" | sed 's/^/  /'
  if grep -vE '^(/usr/lib/|/System/Library/)' <<<"$libraries"; then
    echo "error: ThumbFree links the libraries above, which the app doesn't carry" >&2
    exit 1
  fi
}
check_links "$binary"

echo "== Assembling ThumbFree.app"
cp "$binary" "$app/Contents/MacOS/ThumbFree"

cat >"$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>ThumbFree</string>
	<key>CFBundleExecutable</key>
	<string>ThumbFree</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>app.thumbfree.mac</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>ThumbFree</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$version</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>ThumbFree listens only while you dictate, and turns your speech into text on this Mac.</string>
</dict>
</plist>
PLIST
plutil -lint "$app/Contents/Info.plist"

# The icon, from the 512-point logo every ThumbFree app uses (thumbfree-windows assets/logo.png): 16 to 512 points,
# each at 1x and 2x, except 512 at 2x, which would only be the logo enlarged.
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" assets/logo.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  if ((size * 2 <= 512)); then
    sips -z $((size * 2)) $((size * 2)) assets/logo.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  fi
done
iconutil --convert icns --output "$app/Contents/Resources/AppIcon.icns" "$iconset"

# The licenses of what's linked in: the repository's list, and each speech engine's notice, which SwiftPM unpacks from
# the engine's zip next to its xcframework (.build/artifacts/<package>/<engine>/).
cp THIRD-PARTY-NOTICES.md "$app/Contents/Resources/"
for engine in CSherpaOnnx CWhisper; do
  notice="$(find "$root/.build/artifacts" -path "*/$engine/$engine-NOTICE.txt" 2>/dev/null || true)"
  if [[ -z "$notice" || "$notice" == *$'\n'* ]]; then
    echo "error: expected one $engine-NOTICE.txt in .build/artifacts, unpacked from $engine.xcframework.zip, but" \
      "found ${notice:-none}" >&2
    exit 1
  fi
  cp "$notice" "$app/Contents/Resources/"
done
echo "Notices: $(cd "$app/Contents/Resources" && ls -- *NOTICE* | tr '\n' ' ')"

echo "== Signing (ad hoc)"
codesign --force --sign - "$app"
codesign --verify --deep --strict --verbose=2 "$app"
signature="$(codesign --display --verbose=2 "$app" 2>&1)"
echo "$signature" | grep -E '^(Identifier|Format|Signature)=' || true
if ! grep -q '^Signature=adhoc' <<<"$signature"; then
  echo "error: ThumbFree.app isn't signed ad hoc" >&2
  exit 1
fi

echo "== Making $(basename "$dmg")"
staging="$work/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/ThumbFree.app"
ln -s /Applications "$staging/Applications"
# hdiutil sometimes finds the image busy on CI runners: it gets three tries.
for attempt in 1 2 3; do
  if hdiutil create -volname ThumbFree -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"; then
    break
  fi
  if ((attempt == 3)); then
    echo "error: hdiutil couldn't make the disk image" >&2
    exit 1
  fi
  echo "hdiutil failed; trying again" >&2
  sleep 5
done
hdiutil verify "$dmg"

# The app in the image is signed too, links only the system's libraries and has the notices.
mkdir -p "$volume"
hdiutil attach -nobrowse -readonly -mountpoint "$volume" "$dmg" >/dev/null
codesign --verify --deep --strict "$volume/ThumbFree.app"
test -L "$volume/Applications"
check_links "$volume/ThumbFree.app/Contents/MacOS/ThumbFree"
for file in THIRD-PARTY-NOTICES.md CSherpaOnnx-NOTICE.txt CWhisper-NOTICE.txt; do
  if [[ ! -s "$volume/ThumbFree.app/Contents/Resources/$file" ]]; then
    echo "error: the app in the image has no Contents/Resources/$file" >&2
    exit 1
  fi
done
hdiutil detach "$volume" >/dev/null

echo "== Done"
plutil -p "$app/Contents/Info.plist"
ls -l "$dmg"
shasum -a 256 "$dmg"
