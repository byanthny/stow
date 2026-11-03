#!/bin/bash
set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repository"
if [ "$#" -gt 1 ]; then
    printf 'usage: %s [output-directory]\n' "$0" >&2
    exit 2
fi
output=${1:-build}
mkdir -p "$output"
output=$(cd "$output" && pwd)

"$repository/scripts/build.sh" Release "$output"
app="$output/DerivedData/Release/Build/Products/Release/Stow.app"
xcrun lipo "$app/Contents/MacOS/Stow" -verify_arch arm64 x86_64
/usr/bin/codesign --force --sign - --options runtime "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$output/Stow.zip"
(
    cd "$output"
    /usr/bin/shasum -a 256 Stow.zip > Stow.zip.sha256
    /usr/bin/shasum -a 256 -c Stow.zip.sha256
)
printf 'local ad-hoc package: %s/Stow.zip\n' "$output"
