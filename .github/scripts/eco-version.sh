#!/usr/bin/env bash
# Print the version a CI build stamps into eco and its bundles.
#
# Usage: eco-version.sh [<commit>]     (default HEAD; publish-nightly names the
#                                       commit whose builds it publishes)
#
# Branch builds: <version.txt>~b<N>.g<12-char hash>, e.g. 0.2.0~b2017.g5fa5d3439974,
# where N is the number of commits reachable from HEAD. N needs no stored state,
# rises along master, and is the same on every platform that builds a commit, so
# the nightly's assets share one version. The ~ makes Debian sort these builds
# before the plain release. docker/build-dist.sh uses the same format for local
# builds, but counts N with its own .build-number file. The ~ survives only in the
# built file names and in the .deb's Version field: publish-nightly.yml renames the
# nightly assets before upload (~ -> - in the archives, ~ -> . in the .deb),
# because GitHub would rewrite ~ in asset names itself.
#
# Tag builds: a release tag v<version> builds the plain version; a release
# candidate tag v<version>-rc<N> builds <version>~rc<N>, which Debian sorts
# after the ~b<N> nightlies and before the plain release. <version> must match
# version.txt either way, so version.txt stays put through an RC series.
#
# Needs the full history (actions/checkout with fetch-depth: 0); a shallow clone
# would count N as 1.
set -euo pipefail

cd "$(dirname "$0")/../.."
rev="${1:-HEAD}"
base=$(git show "$rev:version.txt" | tr -d '[:space:]')

if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
    tag="${GITHUB_REF_NAME:-}"
    if [ "$tag" = "v$base" ]; then
        echo "$base"
    elif [[ "$tag" =~ ^v${base//./\\.}-rc([1-9][0-9]*)$ ]]; then
        echo "${base}~rc${BASH_REMATCH[1]}"
    else
        echo "::error::tag $tag does not match version.txt (v$base or v$base-rc<N>)" >&2
        exit 1
    fi
    exit 0
fi

if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "::error::shallow clone: check out with fetch-depth: 0 so the build number counts every commit" >&2
    exit 1
fi
echo "${base}~b$(git rev-list --count "$rev").g$(git rev-parse --short=12 "$rev")"
