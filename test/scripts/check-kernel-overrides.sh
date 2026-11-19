#!/bin/sh
# check-kernel-overrides.sh — fail if compiler/src/Compiler/GenerateJs/KernelOverride/Files.elm is not what
# compiler/kernel-overrides/*.js generate, if an override file does not parse, or if an override's
# `package` line is not the version the compiler pins (plans/js-kernel-overrides.md §3.1). To fix a stale
# module:  node compiler/scripts/gen-kernel-overrides.mjs > compiler/src/Compiler/GenerateJs/KernelOverride/Files.elm
#
# Usage: test/scripts/check-kernel-overrides.sh [REPO_ROOT] [NODE]
set -eu
root=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
node=${2:-node}
cd "$root"
exec "$node" compiler/scripts/gen-kernel-overrides.mjs --check compiler/src/Compiler/GenerateJs/KernelOverride/Files.elm
