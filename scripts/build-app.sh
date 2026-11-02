#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
build_root="/private/tmp/GesturePilotBuild"
app_path="$build_root/GesturePilot.app"
binary_path="$build_root/GesturePilot"
icon_generator="$build_root/IconGenerator"
icon_png="$build_root/GesturePilot-1024.png"
iconset="$build_root/GesturePilot.iconset"
module_cache="$project_root/work/clang-module-cache"
archive_path="$project_root/outputs/GesturePilot.zip"

cd "$project_root"
mkdir -p "$module_cache"
rm -rf "$build_root"
mkdir -p "$build_root" "$project_root/outputs"

clang \
    -fobjc-arc \
    -fmodules \
    -fmodules-cache-path="$module_cache" \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    -mmacosx-version-min=13.0 \
    -framework AppKit \
    -framework ApplicationServices \
    -framework ServiceManagement \
    "$project_root/Sources/Native/GesturePilot.m" \
    -o "$binary_path"

"$binary_path" --self-test

clang \
    -fobjc-arc \
    -fmodules \
    -fmodules-cache-path="$module_cache" \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    -mmacosx-version-min=13.0 \
    -framework AppKit \
    "$project_root/scripts/generate-icon.m" \
    -o "$icon_generator"

"$icon_generator" "$icon_png"
mkdir -p "$iconset"
/usr/bin/sips -z 16 16 "$icon_png" --out "$iconset/icon_16x16.png" >/dev/null
/usr/bin/sips -z 32 32 "$icon_png" --out "$iconset/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 32 32 "$icon_png" --out "$iconset/icon_32x32.png" >/dev/null
/usr/bin/sips -z 64 64 "$icon_png" --out "$iconset/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 128 128 "$icon_png" --out "$iconset/icon_128x128.png" >/dev/null
/usr/bin/sips -z 256 256 "$icon_png" --out "$iconset/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "$icon_png" --out "$iconset/icon_256x256.png" >/dev/null
/usr/bin/sips -z 512 512 "$icon_png" --out "$iconset/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "$icon_png" --out "$iconset/icon_512x512.png" >/dev/null
cp "$icon_png" "$iconset/icon_512x512@2x.png"

rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_path" "$app_path/Contents/MacOS/GesturePilot"
cp "$project_root/App/Info.plist" "$app_path/Contents/Info.plist"
python3 "$project_root/scripts/create-icns.py" \
    "$iconset" \
    "$app_path/Contents/Resources/GesturePilot.icns"
rm -rf "$build_root/Validated.iconset"
/usr/bin/iconutil -c iconset \
    "$app_path/Contents/Resources/GesturePilot.icns" \
    -o "$build_root/Validated.iconset"

chmod 755 "$app_path/Contents/MacOS/GesturePilot"
codesign \
    --force \
    --deep \
    --sign - \
    --identifier com.arun.GesturePilot \
    --requirements "$project_root/App/GesturePilot.requirements" \
    "$app_path"

plutil -lint "$app_path/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app_path"

rm -f "$archive_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive_path"
unzip -t "$archive_path" >/dev/null

print "$app_path"
print "$archive_path"
