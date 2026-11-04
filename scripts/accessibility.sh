#!/bin/bash
set -euo pipefail

# Runs Xcode's accessibility audit against the Debug app with synthetic state. UI automation needs Automation
# Mode: macOS may ask for an administrator's approval, and the test takes over the pointer while it runs.
repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repository"
if [ "$#" -gt 1 ]; then
    printf 'usage: %s [output-directory]\n' "$0" >&2
    exit 2
fi
output=${1:-build}
mkdir -p "$output"
output=$(cd "$output" && pwd)

# Stow writes each test's synthetic state under this root; the sandboxed test runner can't remove it.
state=$(mktemp -d "${TMPDIR:-/tmp}/StowUITests.XXXXXX")
trap 'rm -rf "$state"' EXIT
# xcodebuild passes TEST_RUNNER_-prefixed variables to the test runner without the prefix.
# Shares derived data with scripts/test.sh so running both reuses one Debug build.
TEST_RUNNER_STOW_UI_TEST_STATE_ROOT="$state" xcodebuild \
    -project Stow.xcodeproj \
    -scheme StowUITests \
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
