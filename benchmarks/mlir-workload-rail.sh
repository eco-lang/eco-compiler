#!/usr/bin/env bash
# THE FIXED-WORKLOAD RAIL — emission + analysis equality for a front-end change.
#
#   mlir-workload-rail.sh <tag>          build nothing, compile the workload set
#   DIFF=<other-tag> mlir-workload-rail.sh <tag>    …and diff against <other-tag>
#
# Compiles every module in test/elm/src (632) plus examples/src/Hello.elm with
# the CURRENT Stage-1 compiler (`compiler/bin/index.js` over
# build/compiler/build-xhr/bin/guida.js) and records TWO artefacts under
# $OUTROOT/<tag>:
#
#   <tag>.manifest   per-workload MLIR sha256   — the EMISSION gate
#   <tag>.census     every workload's `=== LSS census ===` block (~65k lines)
#                    — the ANALYSIS gate, and strictly the sharper of the two:
#                    it moves when coverage / var / ⊤ / stamping move even
#                    where the emitted bytes do not.
#
# Why this and not a self-compile: a self-compile cannot gate a change to the
# compiler itself (the workload IS the edited source). These 633 external
# workloads can, they run in ~70 s 8-way, and both artefacts are DETERMINISTIC
# — two runs of one tree produce identical manifests and a zero-line census
# diff once the output path is scrubbed.
#
# Validated 2026-09-18 (plans/fix-lss-flags-at-defaults.md §9):
#   - deterministic: two runs of one tree, 0-line diff on both artefacts;
#   - sensitive: ECO_MONO_LSS_ROOT_FOLD=0 moved 16 of the 633 manifests;
#   - cache-honest: the per-worker `eco-stuff`/`elm-stuff` caches are WIPED
#     each run, and a cold run reproduced the warm run exactly — a warm
#     front-end artifact cache was never masking a monomorphizer change.
#
# Rebuild the compiler yourself first (`cmake --build build --target guida`);
# this script deliberately builds nothing, so the tag names a tree you chose.
set -uo pipefail

TAG=${1:?usage: mlir-workload-rail.sh <tag>}
NPAR=${NPAR:-8}
OUTROOT=${OUTROOT:-${TMPDIR:-/tmp}/eco-workload-rail}
OUT=$OUTROOT/$TAG
rm -rf "$OUT"; mkdir -p "$OUT"

LIST=$OUTROOT/workloads.txt
ls /work/test/elm/src | sed 's/\.elm$//' > "$LIST"

# One project dir per worker (concurrent compiles in one dir race on the
# artifact cache). `src` is a symlink; the caches are wiped per run.
for i in $(seq 0 $((NPAR - 1))); do
    d=$OUTROOT/proj$i
    mkdir -p "$d"
    cp /work/test/elm/elm.json "$d/elm.json"
    ln -sfn /work/test/elm/src "$d/src"
    rm -rf "$d/eco-stuff" "$d/elm-stuff"
done
rm -rf /work/examples/eco-stuff

compile_one() {
    idx=$1; name=$2
    d=$OUTROOT/proj$((idx % NPAR))
    ( cd "$d" && ECO_MONO_LSS_REPORT=1 node /work/compiler/bin/index.js make \
        "src/$name.elm" --output="$OUT/$name.mlir" ) >"$OUT/$name.log" 2>&1
    [ -s "$OUT/$name.mlir" ] || echo "FAILED $name" >> "$OUT/failures.txt"
}
export -f compile_one; export OUTROOT OUT NPAR

n=0
while read -r name; do echo "$n $name"; n=$((n + 1)); done < "$LIST" \
    | xargs -P "$NPAR" -n 2 bash -c 'compile_one "$0" "$1"'

( cd /work/examples && ECO_MONO_LSS_REPORT=1 node /work/compiler/bin/index.js make \
    src/Hello.elm --local-package eco/kernel=/work/eco-kernel-cpp \
    --output="$OUT/__Hello.mlir" ) >"$OUT/__Hello.log" 2>&1

( cd "$OUT" && sha256sum -- *.mlir | sort -k2 ) > "$OUTROOT/$TAG.manifest"
for f in "$OUT"/*.log; do
    printf '##### %s\n' "$(basename "$f" .log)"
    # Scrub the per-tag output path: it is the only run-varying text.
    sed -n '/=== LSS census ===/,$p' "$f" | tr -d '\0' | sed "s#$OUT#@OUT@#g"
done > "$OUTROOT/$TAG.census"

echo "workloads hashed: $(wc -l < "$OUTROOT/$TAG.manifest")"
[ -f "$OUT/failures.txt" ] && { echo "COMPILE FAILURES:"; cat "$OUT/failures.txt"; }

if [ -n "${DIFF:-}" ]; then
    if diff -q "$OUTROOT/$DIFF.manifest" "$OUTROOT/$TAG.manifest" >/dev/null; then
        echo "EMISSION: byte-identical to $DIFF"
    else
        echo "EMISSION: $(diff "$OUTROOT/$DIFF.manifest" "$OUTROOT/$TAG.manifest" | grep -c '^<') workloads differ from $DIFF"
    fi
    echo "CENSUS: $(diff "$OUTROOT/$DIFF.census" "$OUTROOT/$TAG.census" | wc -l) diff lines vs $DIFF"
fi
exit 0
