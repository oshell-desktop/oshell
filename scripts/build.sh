#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 OShell contributors

set -euo pipefail
export OSHELL_LEGACY=0
export OSHELL_MACOS_MINIMUM=13.0
project_root="$(cd "$(dirname "$0")/.." && pwd)"
export OSHELL_TEST_HARNESS=0
if [ "$#" -gt 0 ]; then
    if [ "$#" -eq 1 ] && [ "$1" = "--tests" ]; then export OSHELL_TEST_HARNESS=1
    else echo 'Usage: bash scripts/build.sh [--tests]' >&2; exit 2; fi
fi
if [ "$OSHELL_TEST_HARNESS" = 1 ]; then
    build_dir="${OSHELL_BUILD_DIR:-$project_root/work/build-tests}"
    app_dir="$project_root/work/test-app/OShell.app"
else
    build_dir="${OSHELL_BUILD_DIR:-$project_root/work/build}"
    app_dir="$project_root/dist/OShell.app"
fi
destination_app="$app_dir"
mkdir -p "$(dirname "$destination_app")" "$build_dir" "$project_root/validation"
staging_dir="$(mktemp -d "$(dirname "$destination_app")/.oshell-build-XXXXXX")"
trap 'build_status=$?; if [ "$build_status" -eq 0 ]; then rm -rf "$staging_dir"; else echo "Build failed; staging preserved: $staging_dir" >&2; fi' EXIT
app_dir="$staging_dir/OShell.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Helpers"
export CLANG_MODULE_CACHE_PATH="$build_dir/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/modules"
swift build --package-path "$project_root" --scratch-path "$build_dir/swift" --cache-path "$build_dir/cache" --config-path "$build_dir/config" --security-path "$build_dir/security" --disable-sandbox -c release \
    -Xswiftc -file-prefix-map -Xswiftc "$project_root=/OShell" \
    -Xswiftc -debug-prefix-map -Xswiftc "$project_root=/OShell" \
    -Xswiftc -file-compilation-dir -Xswiftc /OShell \
    -Xcc "-ffile-prefix-map=$project_root=/OShell"
helper_source="$build_dir/lrzsz-0.12.20"
if [ ! -x "$helper_source/src/lrz" ] || [ ! -f "$helper_source/.oshell-macos13-public-paths" ]; then
    if [ ! -d "$helper_source" ]; then tar -xzf "$project_root/Vendor/lrzsz-0.12.20.tar.gz" -C "$build_dir"; fi
    (
        cd "$helper_source"
        helper_arch="$(uname -m)"
        if [ "$helper_arch" = arm64 ]; then helper_host=arm-apple-darwin; else helper_host="$helper_arch-apple-darwin"; fi
        CC=clang CFLAGS="-Os -mmacosx-version-min=13.0 -std=gnu89 -Wno-error=implicit-function-declaration -Wno-error=incompatible-function-pointer-types -ffile-prefix-map=$project_root=/OShell -fdebug-prefix-map=$project_root=/OShell" \
          ./configure --disable-nls --disable-timesync --host="$helper_host" --prefix=/usr > "$build_dir/helpers-configure.log" 2>&1
        make clean > "$build_dir/helpers-clean.log" 2>&1
        make -j4 > "$build_dir/helpers-build.log" 2>&1
        touch .oshell-macos13-public-paths
    )
fi
binary_dir="$(swift build --package-path "$project_root" --scratch-path "$build_dir/swift" -c release --show-bin-path)"
cp "$binary_dir/OShell" "$app_dir/Contents/MacOS/OShell"
cp "$binary_dir/OShell-ZOC" "$app_dir/Contents/MacOS/OShell-ZOC"
file_bridge="$app_dir/Contents/Helpers/OShell-FileZilla.app"
mkdir -p "$file_bridge/Contents/MacOS"
cp "$binary_dir/OShell-FileZilla" "$file_bridge/Contents/MacOS/OShell-FileZilla"
cp "$project_root/scripts/FileZilla-Info.plist" "$file_bridge/Contents/Info.plist"
cp "$binary_dir/OShellSSH" "$app_dir/Contents/Helpers/OShellSSH"
cp "$binary_dir/OShellProxy" "$app_dir/Contents/Helpers/OShellProxy"
cp "$binary_dir/OShellAskpass" "$app_dir/Contents/Helpers/OShellAskpass"
cp "$helper_source/src/lrz" "$helper_source/src/lsz" "$app_dir/Contents/Helpers/"
ln -sf lrz "$app_dir/Contents/Helpers/rz"
ln -sf lsz "$app_dir/Contents/Helpers/sz"
cp -R "$binary_dir/SwiftTerm_SwiftTerm.bundle" "$app_dir/Contents/Resources/"
for font_directory in NerdFonts DejaVuFonts CascadiaCode; do
    rm -rf "$app_dir/Contents/Resources/$font_directory"
    cp -R "$project_root/Vendor/$font_directory" "$app_dir/Contents/Resources/$font_directory"
done
cp "$project_root/LICENSE" "$app_dir/Contents/Resources/OShell-LICENSE.txt"
cp "$project_root/THIRD_PARTY_NOTICES.txt" "$app_dir/Contents/Resources/"
cp "$project_root/Vendor/ColorSchemes/LICENSE" "$app_dir/Contents/Resources/ColorSchemes-LICENSE.txt"
cp "$project_root/shell-integration/oshell-integration.sh" "$app_dir/Contents/Resources/"
cp "$project_root/Vendor/SwiftTerm/LICENSE" "$app_dir/Contents/Resources/SwiftTerm-LICENSE.txt"
cp "$helper_source/COPYING" "$app_dir/Contents/Resources/lrzsz-COPYING.txt"
cp "$project_root/Vendor/lrzsz-0.12.20.tar.gz" "$app_dir/Contents/Resources/"
cp "$project_root/scripts/Info.plist" "$app_dir/Contents/Info.plist"
if [ "$OSHELL_TEST_HARNESS" = 1 ]; then
    /usr/libexec/PlistBuddy -c 'Add OShellTestHarness bool true' "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Delete NSServices' "$app_dir/Contents/Info.plist"
fi
swift "$project_root/scripts/icon.swift" "$build_dir/OShell.iconset"
iconutil -c icns "$build_dir/OShell.iconset" -o "$app_dir/Contents/Resources/OShell.icns"
# Drop debug maps and local linker names from shipped executables. Keep external
# symbols and runtime metadata; never apply this to bundled third-party frameworks.
for executable in "$app_dir/Contents/MacOS/OShell" "$app_dir/Contents/MacOS/OShell-ZOC" "$file_bridge/Contents/MacOS/OShell-FileZilla" "$app_dir/Contents/Helpers/OShellSSH" "$app_dir/Contents/Helpers/OShellProxy" "$app_dir/Contents/Helpers/OShellAskpass" "$app_dir/Contents/Helpers/lrz" "$app_dir/Contents/Helpers/lsz"; do
    xcrun strip -S -x "$executable"
done
codesign --force --sign - "$app_dir/Contents/Helpers/lrz"
codesign --force --sign - "$app_dir/Contents/Helpers/lsz"
codesign --force --sign - "$app_dir/Contents/Helpers/OShellAskpass"
codesign --force --sign - "$app_dir/Contents/Helpers/OShellSSH"
codesign --force --sign - "$app_dir/Contents/Helpers/OShellProxy"
codesign --force --sign - "$app_dir/Contents/MacOS/OShell-ZOC"
codesign --force --sign - "$file_bridge"
python3 "$project_root/scripts/embed-sparkle.py" "$app_dir" "$(uname -m)"
python3 "$project_root/scripts/sign-app.py" "$app_dir"
python3 "$project_root/scripts/check-public-source.py" --app "$app_dir"
published_app="$(python3 "$project_root/scripts/install-local-app.py" "$app_dir" "$destination_app")"
echo "Built: $published_app"
