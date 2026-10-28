#!/bin/sh
# check-casemap-tables.sh — fail if runtime/src/allocator/CaseMapTables.hpp is not what the given
# node generates (plans/char-case-mapping-elm-exact.md Step 1).
#
# The case tables are node's own toUpperCase/toLowerCase, the reference the elm-conformance tests
# were recorded against. A node with another Unicode version (or an ICU fix within one) changes
# the reference: regenerate the tables and re-record the conformance tests together.
#
# Usage: test/scripts/check-casemap-tables.sh [REPO_ROOT] [NODE]
set -eu
root=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
node=${2:-node}
exec "$node" "$root/compiler/scripts/gen-casemap-tables.mjs" --check "$root/runtime/src/allocator/CaseMapTables.hpp"
