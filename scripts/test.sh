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

swift test --scratch-path "$output/SwiftPM"
xcodebuild \
    -project Stow.xcodeproj \
    -scheme Stow \
    -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$output/DerivedData/Tests" \
    -clonedSourcePackagesDirPath "$output/SourcePackages" \
    -onlyUsePackageVersionsFromResolvedFile \
    "ARCHS=$(uname -m)" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_ALLOWED=YES \
    test
git diff --check
