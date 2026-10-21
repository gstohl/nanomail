#!/bin/sh
# Builds zig-out/package/nanomail.app (and, with DMG=1, a disk image):
# a ReleaseFast build for macOS 13 and later on Apple silicon, its icon
# drawn by tools/icon.zig, signed with $CODESIGN_IDENTITY or ad hoc.
#
#   sh macos/package.sh            # the app
#   DMG=1 sh macos/package.sh      # and nanomail-macos-arm64.dmg
set -eu
cd "$(dirname "$0")/.."

app=nanomail
version="${VERSION:-$(sed -n 's/^ *\.version = "\(.*\)",/\1/p' build.zig.zon)}"
out=zig-out/package
bundle="$out/$app.app"
min_macos=13.0

zig build -Doptimize=ReleaseFast -Dtarget=aarch64-macos.$min_macos -Dcpu=apple_m1
zig build icon
rm -rf "$out"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$out/icon.iconset"
cp "zig-out/bin/$app" "$bundle/Contents/MacOS/$app"

# The icon at every size the iconset wants.
zig-out/bin/nanomail-icon "$out/icon-1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$out/icon-1024.png" --out "$out/icon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$out/icon-1024.png" --out "$out/icon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$out/icon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
rm -rf "$out/icon.iconset" "$out/icon-1024.png"

cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$app</string>
  <key>CFBundleDisplayName</key><string>$app</string>
  <key>CFBundleIdentifier</key><string>dev.nanomail.$app</string>
  <key>CFBundleExecutable</key><string>$app</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleGetInfoString</key><string>A JMAP mail client</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>$min_macos</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$bundle"
else
  codesign --force --sign - "$bundle"
fi
codesign --verify --strict "$bundle"
echo "built $bundle ($version)"

if [ "${DMG:-}" = 1 ]; then
  stage="$out/dmg"
  mkdir -p "$stage"
  cp -R "$bundle" "$stage/"
  ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -volname "$app" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$out/$app-macos-arm64.dmg"
  rm -rf "$stage"
  echo "built $out/$app-macos-arm64.dmg"
fi
