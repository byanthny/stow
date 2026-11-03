#!/bin/bash
set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repository"
configuration=${1:-Debug}
output=${2:-build}
case "$configuration" in
    Debug) architectures=$(uname -m) ;;
    Release) architectures='arm64 x86_64' ;;
    *) printf 'usage: %s [Debug|Release] [output-directory]\n' "$0" >&2; exit 2 ;;
esac
if [ "$#" -gt 2 ]; then
    printf 'usage: %s [Debug|Release] [output-directory]\n' "$0" >&2
    exit 2
fi
mkdir -p "$output"
output=$(cd "$output" && pwd)

xcodebuild \
    -project Stow.xcodeproj \
    -scheme Stow \
    -configuration "$configuration" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$output/DerivedData/$configuration" \
    -clonedSourcePackagesDirPath "$output/SourcePackages" \
    -onlyUsePackageVersionsFromResolvedFile \
    "ARCHS=$architectures" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

printf 'app: %s/DerivedData/%s/Build/Products/%s/Stow.app\n' "$output" "$configuration" "$configuration"
