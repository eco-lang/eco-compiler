#!/usr/bin/env bash
# Delete every GitHub Actions cache entry on <ref> whose key starts with
# <key-prefix>, except the newest. The -aot workflows save one ccache entry
# per master commit (key <prefix><sha>) and restore by prefix, so only the
# newest is ever read; without pruning the old ones pile up past the 10 GB
# repository limit and GitHub evicts the multi-GB LLVM caches instead.
#
# Usage: prune-caches.sh <key-prefix> [<ref>]     (ref defaults to refs/heads/master)
# Env:   GH_TOKEN           token with actions: write
#        GITHUB_REPOSITORY  owner/repo (set by Actions)
#        DRY_RUN=1          list what would be deleted, delete nothing, and check
#                           that the token may delete caches
set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <key-prefix> [<ref>]" >&2
    exit 2
fi
prefix="$1"
ref="${2:-refs/heads/master}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"
dry="${DRY_RUN:-}"

# Newest first. `key` is a prefix match in this API.
entries=$(gh api --paginate -X GET "repos/$repo/actions/caches" \
    -f key="$prefix" -f ref="$ref" -f sort=created_at -f direction=desc \
    --jq '.actions_caches[] | "\(.id) \(.size_in_bytes) \(.key)"')

if [ -z "$entries" ]; then
    echo "no cache entries with prefix '$prefix' on $ref"
else
    first=1
    while read -r id size key; do
        if [ -n "$first" ]; then
            echo "keep    $key ($((size / 1048576)) MB)"
            first=
        elif [ -n "$dry" ]; then
            echo "would delete $key ($((size / 1048576)) MB)"
        else
            gh api -X DELETE "repos/$repo/actions/caches/$id" >/dev/null
            echo "deleted $key ($((size / 1048576)) MB)"
        fi
    done <<< "$entries"
fi

if [ -n "$dry" ]; then
    # Deleting a key that matches nothing answers 404 when the token may delete
    # caches and 403 when it may not, so this checks the permission the real
    # prune on master needs without touching any entry.
    out=$(gh api -X DELETE "repos/$repo/actions/caches?key=eco-prune-permission-probe&ref=$ref" 2>&1 || true)
    case "$out" in
        *"HTTP 404"*) echo "OK: the token may delete caches (probe answered 404)" ;;
        *) echo "ERROR: the cache-delete probe did not answer 404: $out" >&2; exit 1 ;;
    esac
fi
