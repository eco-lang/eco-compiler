#!/bin/sh
# check-casemap-tables.sh — fail if runtime/src/allocator/CaseMapTables.hpp is not what the vendored
# UnicodeData.txt generates, or if the given node's Unicode version is not the tables'
# (plans/char-simple-case-mapping.md, design_docs/char-case-mapping.md).
#
# The elm-conformance tests are recorded from node, so node's Unicode version must be the tables':
# to move to another version, update the vendored data, regenerate the tables and re-record those
# tests together.
#
# Usage: test/scripts/check-casemap-tables.sh [REPO_ROOT] [NODE]
set -eu
root=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
node=${2:-node}
exec "$node" "$root/compiler/scripts/gen-casemap-tables.mjs" --check "$root/runtime/src/allocator/CaseMapTables.hpp"
