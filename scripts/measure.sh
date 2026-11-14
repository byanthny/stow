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

# The Debug configuration keeps the testing launch arguments; -O makes it run like a release build.
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

# Demo mode keeps GitHub refreshes off, so no gh process runs while measuring.
# open starts the app in front with its windows visible, like a launch from the Dock.
app="$output/DerivedData/Debug/Build/Products/Debug/Stow.app"
open -n -a "$app" --args --stow-testing-state "$folder" --stow-demo-load 30,20
for _ in $(seq 1 20); do
    pid=$(pgrep -n -f "$app/Contents/MacOS/Stow" || true)
    [ -z "$pid" ] || break
    sleep 1
done
[ -n "$pid" ] || { printf 'the app did not start\n' >&2; exit 1; }
printf 'launched pid %s with 30 cards and 20 notes; idle for 60 seconds\n' "$pid"
sleep 60
kill -0 "$pid"

# top -l prints the first sample without an interval, so its CPU is dropped. IDLEW is a running total for the
# process, so the rate is its growth from the first sample to the last over the five 10-second intervals.
swift scripts/usage.swift "$pid" 50 >"$output/usage.txt" &
usage_job=$!
samples=$(top -l 6 -s 10 -pid "$pid" -stats cpu,idlew,mem | awk '$1 ~ /^[0-9.]+$/ && NF == 3')
footprint_line=$(footprint "$pid" | awk '/Footprint:/ { sub(/.*Footprint: /, ""); sub(/ \(.*/, ""); print; exit }')
wait "$usage_job"
kill "$pid"
pid=''

printf '%s\n' "$samples" | awk -v footprint="$footprint_line" '
    { count++; cpu[count] = $1; idle[count] = $2 + 0; mem = $3; sub(/[+-]$/, "", mem) }
    END {
        if (count != 6) { printf "expected 6 top samples, got %d\n", count > "/dev/stderr"; exit 1 }
        for (i = 2; i <= count; i++) { sum += cpu[i]; if (cpu[i] > max) max = cpu[i] }
        printf "cpu: mean %.2f%% max %.2f%% over 5 samples\n", sum / 5, max
        printf "idle wakeups: %.2f/s (%d in 50 s)\n", (idle[count] - idle[1]) / 50, idle[count] - idle[1]
        printf "memory (top, last sample): %s\n", mem
        printf "phys footprint: %s\n", footprint
    }'
cat "$output/usage.txt"

if [ "$skip_tests" -eq 0 ]; then
    # Without the debug stub an optimized hosted app is hardened, and library validation rejects the ad-hoc test bundle.
    xcodebuild \
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
    awk '/measured \[Clock Monotonic Time, s\] average:/ {
        name = $0; sub(/.*testTypingIn/, "", name); sub(/\]. measured.*/, "", name)
        if (name ~ /^A[0-9]/) { sub(/^A/, "", name); sub(/Note$/, "", name); name = name " note" }
        else name = "short note with the board and 5 note windows open"
        average = $0; sub(/.*average: /, "", average); sub(/,.*/, "", average)
        printf "typing 50 characters, %s: %.3f s average\n", name, average
    }' "$output/tests.log"
fi
