#!/bin/bash
set -euo pipefail

repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repository"
usage() {
    printf 'usage: %s [--skip-tests] [output-directory]\n' "$0" >&2
    exit 2
}
skip_tests=0
output=build/measure
positional=0
for argument in "$@"; do
    case "$argument" in
        --skip-tests) skip_tests=1 ;;
        -*) usage ;;
        *)
            [ "$positional" -eq 0 ] || usage
            output=$argument
            positional=1
            ;;
    esac
done
mkdir -p "$output"
output=$(cd "$output" && pwd)
architecture=$(uname -m)

folder=$(mktemp -d)
pid=''
cleanup() {
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
    rm -rf "$folder"
}
trap cleanup EXIT

# Builds Debug, which keeps the testing launch arguments, optimized with -O.
xcodebuild \
    -project Stow.xcodeproj \
    -scheme Stow \
    -configuration Debug \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$output/DerivedData/Debug" \
    -clonedSourcePackagesDirPath "$output/SourcePackages" \
    -onlyUsePackageVersionsFromResolvedFile \
    "ARCHS=$architecture" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    SWIFT_OPTIMIZATION_LEVEL=-O \
    build >"$output/build.log" 2>&1 || { tail -20 "$output/build.log" >&2; exit 1; }

# Opens the app in front in demo mode, with GitHub refreshes off.
app="$output/DerivedData/Debug/Build/Products/Debug/Stow.app"
open -n -a "$app" --args --stow-testing-state "$folder" --stow-demo-load 30,20
for _ in $(seq 1 20); do
    pid=$(pgrep -f -- "Contents/MacOS/Stow --stow-testing-state $folder" || true)
    [ -z "$pid" ] || break
    sleep 1
done
[ -n "$pid" ] || { printf 'the app did not start\n' >&2; exit 1; }
printf 'launched pid %s with 30 cards and 20 notes; idle for 60 seconds\n' "$pid"
sleep 60
kill -0 "$pid"

# Samples three minutes, dropping top's first sample and taking IDLEW's growth over the 18 intervals.
swift scripts/usage.swift "$pid" 180 >"$output/usage.txt" &
usage_job=$!
samples=$(top -l 19 -s 10 -pid "$pid" -stats cpu,idlew,mem | awk '$1 ~ /^[0-9.]+$/ && NF == 3')
footprint_line=$(footprint "$pid" | awk '/Footprint:/ { sub(/.*Footprint: /, ""); sub(/ \(.*/, ""); print; exit }')
wait "$usage_job"
kill "$pid"
pid=''

printf '%s\n' "$samples" | awk -v footprint="$footprint_line" '
    { count++; cpu[count] = $1; idle[count] = $2 + 0; mem = $3; sub(/[+-]$/, "", mem) }
    END {
        if (count != 19) { printf "expected 19 top samples, got %d\n", count > "/dev/stderr"; exit 1 }
        for (i = 2; i <= count; i++) { sum += cpu[i]; if (cpu[i] > max) max = cpu[i] }
        printf "cpu: mean %.2f%% max %.2f%% over 18 samples\n", sum / 18, max
        printf "idle wakeups: %.2f/s (%d in 180 s)\n", (idle[count] - idle[1]) / 180, idle[count] - idle[1]
        printf "memory (top, last sample): %s\n", mem
        printf "phys footprint: %s\n", footprint
    }'
cat "$output/usage.txt"

if [ "$skip_tests" -eq 0 ]; then
    # Runs the typing tests unhardened, with STOW_MEASURE set for the test runner.
    TEST_RUNNER_STOW_MEASURE=1 xcodebuild \
        -project Stow.xcodeproj \
        -scheme Stow \
        -configuration Debug \
        -destination "platform=macOS,arch=$architecture" \
        -derivedDataPath "$output/DerivedData/Tests" \
        -clonedSourcePackagesDirPath "$output/SourcePackages" \
        -onlyUsePackageVersionsFromResolvedFile \
        "ARCHS=$architecture" \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGNING_ALLOWED=YES \
        SWIFT_OPTIMIZATION_LEVEL=-O \
        ENABLE_HARDENED_RUNTIME=NO \
        -only-testing:StowAppTests/TypingMeasureTests \
        test >"$output/tests.log" 2>&1 || { tail -20 "$output/tests.log" >&2; exit 1; }
    awk '/^typing-measure / {
        name = $2; sub(/:$/, "", name)
        if (name == "board") label = "short note with the board and 5 note windows open"
        else label = name " note"
        average = $4
        printf "typing 50 characters, %s: %.3f s average\n", label, average
    }' "$output/tests.log"
fi
