#!/usr/bin/env bash
# Build the release bundles (.deb, .tar.gz, .zip) into ./dist with a per-build version.
#
# The version is <version.txt>~b<N>.g<hash>, plus .dirty when tracked files differ from HEAD,
# for example 0.2.0~b17.g1a2b3c4d5e6f. The ~ makes Debian sort these builds before the plain
# release version, so a later 0.2.0 release upgrades over them. N comes from BUILD_NUMBER when
# set (for CI), otherwise from the local counter in .build-number, which this script increments.
# The ~ stays in the file names in ./dist; published nightly assets differ, because
# .github/workflows/publish-nightly.yml renames them (~ -> - in the archives, ~ -> . in the .deb).
#
# Run from anywhere; extra arguments are passed on to docker build.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

base=$(tr -d '[:space:]' < version.txt)

if [ -n "${BUILD_NUMBER:-}" ]; then
    n=$BUILD_NUMBER
else
    counter=.build-number
    n=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$counter"
fi

# .git is excluded from the Docker build context, so the hash is computed here.
hash=$(git rev-parse --short=12 HEAD)
git diff --quiet HEAD -- || hash="$hash.dirty"

version="${base}~b${n}.g${hash}"
echo "Building eco $version"

docker build -f docker/static-build.Dockerfile --target eco-bundle \
    --build-arg ECO_VERSION="$version" -o ./dist "$@" .

echo "Built eco $version into ./dist"
