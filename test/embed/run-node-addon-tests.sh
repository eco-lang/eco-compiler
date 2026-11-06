#!/bin/sh
# Builds test/elm/src/PortEchoTest.elm as a Node addon (.node) and runs the Node hosts against it:
# echo_host.js (the port round trip) and lifecycle_host.js (app.stop()'s Promise, and no leaked
# keepalive after a stop, a send after stop, or a failed start). Also builds the parity fixtures
# test/embed/{BytesEchoService,ValuesService,JsonFlagsService}.elm both for the JS backend and as
# addons, and runs every embed_host.js scenario against both builds: flags, every port payload
# kind including Bytes (PORT_008), rejected sends, unsubscribe, a leak soak, and app.stop(); the
# two transcripts must be identical. Last, builds and runs the C++ embedding example,
# examples/cpp-ports.
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

# The parity fixtures (test/embed/*Service.elm), each built twice: for the JS backend (<P>-js.js)
# and as a Node addon (<P>-node.node, with its shim <P>-node.js). test/eco-divergence's elm.json,
# for its elm/bytes dependency.
mkdir -p "$OUT/parity/src"
cp "$ROOT/test/eco-divergence/elm.json" "$OUT/parity/elm.json"
for P in BytesEchoService ValuesService JsonFlagsService; do
    echo "node-addon: compiling $P (JS backend and addon)"
    cp "$ROOT/test/embed/$P.elm" "$OUT/parity/src/$P.elm"
    for TARGET in "$P.mlir" "$P-js.js"; do
        ( cd "$OUT/parity" \
          && { ulimit -s unlimited 2>/dev/null || ulimit -s "$(ulimit -H -s)" 2>/dev/null || true; } \
          && s=$(ulimit -s) && k=500000 \
          && { [ "$s" = unlimited ] || [ $((s / 10 * 9)) -ge $k ] || k=$((s / 10 * 9)); } \
          && "$NODE" --stack-size=$k "$ROOT/compiler/bin/index.js" make "src/$P.elm" \
               --output="$OUT/$TARGET" ) > "$OUT/$TARGET.log" 2>&1 \
            || { cat "$OUT/$TARGET.log"; echo "node-addon: FAILED to compile $TARGET"; exit 1; }
    done
    "$BOOT" "$OUT/$P.mlir" -o "$OUT/$P-node.node" > "$OUT/$P-lower.log" 2>&1 \
        || { tail -20 "$OUT/$P-lower.log"; echo "node-addon: FAILED to lower $P"; exit 1; }
done

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

# Parity: each embed_host.js scenario runs against the JS backend build and the addon build of its
# fixture. Both runs must pass their own checks (which include the known divergences, asserted per
# mode) and print the same transcript on stdout.
mkdir -p "$OUT/parity/t"
"$NODE" "$ROOT/test/embed/embed_host.js" list > "$OUT/parity/scenarios"
while read -r P SC; do
    f="$OUT/parity/t/$(echo "$SC" | tr ':' '_')"
    ok=1
    for MODE in js node; do
        timeout 150 "$NODE" --expose-gc "$ROOT/test/embed/embed_host.js" "$MODE" "$OUT/$P-$MODE.js" "$SC" \
            > "$f.$MODE.out" 2> "$f.$MODE.err" || ok=0
    done
    if [ "$ok" = 1 ] && cmp -s "$f.js.out" "$f.node.out"; then
        echo "PASS node-addon/parity/$SC"
    else
        echo "FAIL node-addon/parity/$SC"
        for MODE in js node; do
            echo "    -- $MODE stderr:"; grep -v 'DEV mode\|elm-lang.org' "$f.$MODE.err" | tail -5 | sed 's/^/    /'
        done
        echo "    -- transcript diff (js vs node):"; diff "$f.js.out" "$f.node.out" | head -10 | sed 's/^/    /'
        failed=$((failed + 1))
    fi
done < "$OUT/parity/scenarios"
grep -h '^DIVERGENCE' "$OUT"/parity/t/*.err | sort -u | sed 's/^/node-addon: /'
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

# The C++ embedding example, examples/cpp-ports, built as its Makefile builds it (its own .so, and
# host.cpp against runtime/include) and run on 4 MB of input: the output must be the input upper
# cased, and the summary must count all of it.
EX="$OUT/cpp-ports"
mkdir -p "$EX/proj"
cp -R "$ROOT/examples/cpp-ports/elm.json" "$ROOT/examples/cpp-ports/src" "$EX/proj/"
if ( cd "$EX/proj" \
     && { ulimit -s unlimited 2>/dev/null || ulimit -s "$(ulimit -H -s)" 2>/dev/null || true; } \
     && s=$(ulimit -s) && k=500000 \
     && { [ "$s" = unlimited ] || [ $((s / 10 * 9)) -ge $k ] || k=$((s / 10 * 9)); } \
     && "$NODE" --stack-size=$k "$ROOT/compiler/bin/index.js" make src/Upcase.elm \
          --output="$EX/upcase.mlir" ) > "$EX/build.log" 2>&1 \
   && "$BOOT" "$EX/upcase.mlir" -o "$EX/libupcase.so" >> "$EX/build.log" 2>&1 \
   && "${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -I"$ROOT/runtime/include" \
        "$ROOT/examples/cpp-ports/host.cpp" -L"$EX" -l:libupcase.so -lm -Wl,-rpath,"$EX" \
        -o "$EX/upcase" >> "$EX/build.log" 2>&1; then
    head -c 3000000 /dev/urandom | base64 > "$EX/in.txt"
    bytes=$(wc -c < "$EX/in.txt"); lines=$(wc -l < "$EX/in.txt")
    want="summary: {\"bytes\":$bytes,\"chunks\":$(( (bytes + 65535) / 65536 )),\"hostBytes\":$bytes,\"lines\":$lines}"
    if timeout 60 "$EX/upcase" < "$EX/in.txt" > "$EX/out.txt" 2> "$EX/err.txt" \
       && tr a-z A-Z < "$EX/in.txt" | cmp -s - "$EX/out.txt" \
       && [ "$(cat "$EX/err.txt")" = "$want" ]; then
        echo "PASS node-addon/cpp-ports-example"
    else
        echo "FAIL node-addon/cpp-ports-example (want: $want)"; sed 's/^/    /' "$EX/err.txt"
        failed=$((failed + 1))
    fi
else
    echo "FAIL node-addon/cpp-ports-example (build)"; tail -20 "$EX/build.log" | sed 's/^/    /'
    failed=$((failed + 1))
fi

if [ "$failed" -ne 0 ]; then
    echo "node-addon: $failed FAILED"
    exit 1
fi
echo "node-addon: all passed"
