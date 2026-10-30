#!/bin/sh
# Builds test/elm/src/PortEchoTest.elm as a Node addon (.node) and runs the Node hosts against it:
# echo_host.js (the port round trip) and lifecycle_host.js (app.stop()'s Promise, and no leaked
# keepalive after a stop, a send after stop, or a failed start).
#
#   usage: run-node-addon-tests.sh <repo-root> <build-dir> [node]
#
# The program is compiled to MLIR by the Stage 1 compiler (compiler/bin/index.js) and lowered with
# eco-boot-native, as the JIT E2E suite compiles its tests. Each host is run with a timeout, so a
# leaked handle that keeps Node alive fails the run rather than hanging it.
set -eu

ROOT=${1:?usage: run-node-addon-tests.sh <repo-root> <build-dir> [node]}
BUILD=${2:?usage: run-node-addon-tests.sh <repo-root> <build-dir> [node]}
NODE=${3:-node}
OUT="$BUILD/test/node-addon"
BOOT="$BUILD/runtime/src/codegen/eco-boot-native"

rm -rf "$OUT"
mkdir -p "$OUT"
ulimit -c 0

echo "node-addon: compiling PortEchoTest"
# Big stack, as test/NodeBigStack.hpp gives the Stage 1 compiler in the E2E harness.
# A copy of the project, as docker/static-build.Dockerfile's smoke stage makes, so the build's
# eco-stuff lands under $OUT, not in the source tree.
mkdir -p "$OUT/proj/src"
cp "$ROOT/test/elm/elm.json" "$OUT/proj/elm.json"
cp "$ROOT/test/elm/src/PortEchoTest.elm" "$OUT/proj/src/PortEchoTest.elm"
( cd "$OUT/proj" \
  && { ulimit -s unlimited 2>/dev/null || ulimit -s "$(ulimit -H -s)" 2>/dev/null || true; } \
  && s=$(ulimit -s) && k=500000 \
  && { [ "$s" = unlimited ] || [ $((s / 10 * 9)) -ge $k ] || k=$((s / 10 * 9)); } \
  && "$NODE" --stack-size=$k "$ROOT/compiler/bin/index.js" make src/PortEchoTest.elm \
       --output="$OUT/pe.mlir" ) > "$OUT/compile.log" 2>&1 \
    || { cat "$OUT/compile.log"; echo "node-addon: FAILED to compile"; exit 1; }
"$BOOT" "$OUT/pe.mlir" -o "$OUT/elm.node" > "$OUT/lower.log" 2>&1 \
    || { tail -20 "$OUT/lower.log"; echo "node-addon: FAILED to lower"; exit 1; }

failed=0
run() {   # run <name> <command...>: passes when the command exits 0 within 20 s
    name=$1; shift
    if timeout 20 "$@" > "$OUT/$name.log" 2>&1; then
        echo "PASS node-addon/$name"
    else
        echo "FAIL node-addon/$name"; sed 's/^/    /' "$OUT/$name.log"; failed=$((failed + 1))
    fi
}

run echo "$NODE" "$ROOT/test/embed/echo_host.js" "$OUT/elm.js"
run stop-promise "$NODE" "$ROOT/test/embed/lifecycle_host.js" "$OUT/elm.js" stop-promise
run send-after-stop "$NODE" "$ROOT/test/embed/lifecycle_host.js" "$OUT/elm.js" send-after-stop

# failed-start: with RLIMIT_NPROC at 1 (this user has more processes than that), pthread_create
# fails with EAGAIN, so eco_app_start fails. The limit is lowered on the running node, after its
# own threads exist, and the host is then told to go. The host's own 10 s guard ends it if the
# event loop stays held.
go="$OUT/failed-start.go"
log="$OUT/failed-start.log"
"$NODE" "$ROOT/test/embed/lifecycle_host.js" "$OUT/elm.js" failed-start "$go" > "$log" 2>&1 &
pid=$!
i=0
until grep -q 'HOST waiting' "$log" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -gt 200 ] && break; sleep 0.05
done
if prlimit --pid "$pid" --nproc=1:1 && touch "$go" && wait "$pid"; then
    echo "PASS node-addon/failed-start"
else
    kill "$pid" 2>/dev/null || true
    echo "FAIL node-addon/failed-start"; sed 's/^/    /' "$log"; failed=$((failed + 1))
fi

if [ "$failed" -ne 0 ]; then
    echo "node-addon: $failed FAILED"
    exit 1
fi
echo "node-addon: all passed"
