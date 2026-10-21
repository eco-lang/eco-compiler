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
# builds, but counts N with its own .build-number file.
#
# Tag builds (refs/tags/v<version>): the plain version, which must match
# version.txt.
#
# Needs the full history (actions/checkout with fetch-depth: 0); a shallow clone
# would count N as 1.
set -euo pipefail

cd "$(dirname "$0")/../.."
rev="${1:-HEAD}"
base=$(git show "$rev:version.txt" | tr -d '[:space:]')

if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
    if [ "${GITHUB_REF_NAME:-}" != "v$base" ]; then
        echo "::error::tag ${GITHUB_REF_NAME:-} does not match version.txt (v$base)" >&2
        exit 1
    fi
    echo "$base"
    exit 0
fi

if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
    echo "::error::shallow clone: check out with fetch-depth: 0 so the build number counts every commit" >&2
    exit 1
fi
echo "${base}~b$(git rev-list --count "$rev").g$(git rev-parse --short=12 "$rev")"
