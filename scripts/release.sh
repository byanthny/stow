#!/bin/bash
set -euo pipefail

# Prepares a release on a branch cut from an up-to-date main. It never pushes, tags, or publishes; it prints those steps.
repository=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repository"
version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
build_pattern='^(0|[1-9][0-9]*)$'
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && ! [[ $1 =~ $version_pattern ]]; }; then
    printf 'usage: %s [X.Y.Z]\n' "$0" >&2
    exit 2
fi

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

# Prints build setting $1, which project.yml sets once and the Xcode project sets to the same value.
setting() {
    local yaml xcode
    yaml=$(/usr/bin/sed -n -E "s/^[[:space:]]*$1:[[:space:]]*([^[:space:]]+)[[:space:]]*\$/\1/p" project.yml)
    xcode=$(/usr/bin/sed -n -E "s/^[[:space:]]*$1 = ([^;]+);\$/\1/p" Stow.xcodeproj/project.pbxproj | sort -u)
    case $yaml in
        '' | *$'\n'*) fail "Expected one $1 in project.yml." ;;
    esac
    [ "$xcode" = "$yaml" ] || fail "$1 differs between project.yml and the Xcode project."
    printf '%s\n' "$yaml"
}

# Replaces build setting $1's value $2 with $3 in project.yml and the Xcode project.
replace() {
    local old=${2//./\\.}
    /usr/bin/sed -i '' -E "s/^([[:space:]]*$1:[[:space:]]*)$old([[:space:]]*)\$/\1$3\2/" project.yml
    /usr/bin/sed -i '' -E "s/^([[:space:]]*$1 = )$old;\$/\1$3;/" Stow.xcodeproj/project.pbxproj
}

# Succeeds when version $1 is higher than version $2.
higher() {
    local new old i
    IFS=. read -r -a new <<< "$1"
    IFS=. read -r -a old <<< "$2"
    for i in 0 1 2; do
        if [ "${new[i]}" -gt "${old[i]}" ]; then return 0; fi
        if [ "${new[i]}" -lt "${old[i]}" ]; then return 1; fi
    done
    return 1
}

# Prints version $1 with its major, minor, or patch number ($2) raised and the numbers after it reset.
bump() {
    local part
    IFS=. read -r -a part <<< "$1"
    case $2 in
        major) printf '%d.0.0\n' "$((part[0] + 1))" ;;
        minor) printf '%d.%d.0\n' "${part[0]}" "$((part[1] + 1))" ;;
        patch) printf '%d.%d.%d\n' "${part[0]}" "${part[1]}" "$((part[2] + 1))" ;;
    esac
}

current=$(setting MARKETING_VERSION)
build=$(setting CURRENT_PROJECT_VERSION)
[[ $current =~ $version_pattern ]] || fail "MARKETING_VERSION isn't X.Y.Z: $current"
[[ $build =~ $build_pattern ]] || fail "CURRENT_PROJECT_VERSION isn't a whole number: $build"

[ -z "$(git status --porcelain)" ] || fail 'Commit or stash your changes first.'
branch=$(git symbolic-ref --quiet --short HEAD) || fail 'Check out a release branch first.'
[ "$branch" != main ] || fail 'Cut a release branch from main first.'
git fetch --quiet --tags origin main
git merge-base --is-ancestor origin/main HEAD || fail "$branch doesn't include the latest origin/main."

tag=
tags=$(git tag --merged HEAD --sort=-version:refname --list 'v*')
for candidate in $tags; do
    if [[ ${candidate#v} =~ $version_pattern ]]; then
        tag=$candidate
        break
    fi
done
if [ -n "$tag" ]; then
    range=$tag..HEAD
    base=${tag#v}
    since="since $tag"
else
    range=HEAD
    base=$current
    since='so far'
fi
subjects=$(git log --format=%s "$range")
bodies=$(git log --format=%b "$range")
[ -n "$subjects" ] || fail "Nothing to release: no commits $since."

scope='(\([^)]*\))?'
if grep -Eq "^[a-z]+$scope!: " <<< "$subjects" || grep -Eq '^BREAKING[ -]CHANGE: ' <<< "$bodies"; then
    reason='breaking change'
    if [ "${base%%.*}" = 0 ]; then level='minor'; else level='major'; fi
elif grep -Eq "^feat$scope: " <<< "$subjects"; then
    reason='feat'
    level='minor'
elif grep -Eq "^fix$scope: " <<< "$subjects"; then
    reason='fix'
    level='patch'
else
    reason='no feat or fix'
    level='patch'
fi
suggested=$(bump "$base" "$level")
printf 'Commits %s:\n' "$since"
git --no-pager log --format='  %s' "$range"
printf 'Suggested %s (%s).\n' "$suggested" "$reason"

version=${1:-$suggested}
if [ "$version" != "$suggested" ]; then printf 'Using %s instead.\n' "$version"; fi
higher "$version" "$current" || fail "$version isn't higher than the current version, $current."
if git rev-parse --quiet --verify "refs/tags/v$version" > /dev/null; then
    fail "v$version already exists."
fi

next_build=$((build + 1))
replace MARKETING_VERSION "$current" "$version"
replace CURRENT_PROJECT_VERSION "$build" "$next_build"
printf 'Set the version to %s, build %s. Running the tests.\n' "$version" "$next_build"
./scripts/test.sh || fail "Tests failed. Fix them and run ./scripts/test.sh before committing $version."

cat <<EOF

Prepared $version, build $next_build. Next steps:
1. Commit, push, and open the pull request:
   git commit -m 'chore(release): $version' -m 'Set the version to $version, build $next_build.' -- project.yml Stow.xcodeproj/project.pbxproj
   git push -u origin HEAD
   gh pr create --title 'chore(release): $version'
2. After it merges, tag the merge commit and push the tag:
   git fetch origin
   git tag -s v$version -m 'Stow $version (alpha)' "\$(gh pr view $branch --json mergeCommit --jq .mergeCommit.oid)"
   git push origin v$version
3. Publish the pre-release. This starts the release workflow, which builds the DMG and attaches it:
   gh release create v$version --prerelease --verify-tag --title 'Stow $version (alpha)'
EOF
