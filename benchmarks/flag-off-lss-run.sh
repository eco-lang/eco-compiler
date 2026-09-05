#!/usr/bin/env bash
# One iteration of the LSS flag-off loop. See flag-off-lss-loop.md.
#
#   flag-off-lss-run.sh setup       build bin/eco-std (subst reference compiler)
#   flag-off-lss-run.sh <N>         run iteration for flag N (31..1)
#   flag-off-lss-run.sh <N> --force run a skipped (no-op) iteration anyway
#   flag-off-lss-run.sh all         run every effective iteration, 31 -> 1
#
# Flags N..31 are off for iteration N. Records land in
# benchmarks/flag-off-lss-loop.tsv and are rendered as a table into
# /work/flag-off-lss-results.md after every run.
set -uo pipefail

WORK=/work
BK=$WORK/build/compiler/build-kernel
BOOT=$WORK/build/runtime/src/codegen/eco-boot-native
ENTRY=$WORK/compiler/src/Terminal/Main.elm
SEED=$BK/bin/eco-native-probe
STD=$BK/bin/eco-std
RESULTS=$WORK/benchmarks/flag-off-lss-loop.tsv
TABLE=$WORK/flag-off-lss-results.md

# Iterations that cannot change the configuration, so they are SKIPPED:
#   30 23 15 14 7  booleans already default-off in defaultLss
#   4  2           numeric caps where 0 already IS "no limit"
# 31 is also a no-op but is KEPT: it is the all-defaults baseline pair every
# later iteration is read against. `--force` runs a skipped one anyway.
SKIP="30 23 15 14 7 4 2"
EFFECTIVE="31 29 28 27 26 25 24 22 21 20 19 18 17 16 13 12 11 10 9 8 6 5 3 1"

# Flag N -> "VAR=value" applied when flag N and below-in-index are off.
# Index 4 and 2 are numeric caps already at their off value (0 = unlimited);
# index 31/30/23/15/14/7 are booleans already default-off. Both kinds emit
# nothing, so those iterations re-run the previous configuration.
off_env_for() {
    case "$1" in
        31) echo "ECO_MONO_LSS_STAGE_ANCHOR_DEMAND_FILL=0" ;;
        30) echo "ECO_MONO_LSS_STAGE_ANCHOR_ROW_FILL=0" ;;
        29) echo "ECO_MONO_LSS_FLOW_CONNECT=0" ;;
        28) echo "ECO_MONO_LSS_VAR_LAMBDA=0" ;;
        27) echo "ECO_MONO_LSS_VAR_CTOR_ROWS=0" ;;
        26) echo "ECO_MONO_LSS_VAR_SUCC=0" ;;
        25) echo "ECO_MONO_LSS_DESTR_ANNO=0" ;;
        24) echo "ECO_MONO_LSS_RS_TOP=0" ;;
        23) echo "ECO_MONO_LSS_ARG_POINTS=0" ;;
        22) echo "ECO_MONO_LSS_INJ_TOTAL=0" ;;
        21) echo "ECO_MONO_LSS_REF_PAP_SPINE=0" ;;
        20) echo "ECO_MONO_LSS_ROOT_FOLD=0" ;;
        19) echo "ECO_MONO_LSS_REG_IDENTITY=0" ;;
        18) echo "ECO_MONO_LSS_SIG_ROOT_ID=0" ;;
        17) echo "ECO_MONO_LSS_PAP_MEMBERS=0" ;;
        16) echo "ECO_MONO_LSS_REF_IDENTITY=0" ;;
        15) echo "ECO_MONO_LSS_QSOLVE=0" ;;
        14) echo "ECO_MONO_LSS_ARROW_ROOTS=0" ;;
        13) echo "ECO_MONO_LSS_ARROW_ID=0" ;;
        12) echo "ECO_MONO_LSS_DEVIRT_POST=0" ;;
        11) echo "ECO_MONO_LSS_LAYOUT_QUAL=0" ;;
        10) echo "ECO_MONO_LSS_SIG_FLOW=0" ;;
         9) echo "ECO_MONO_LSS_GROUND=0" ;;
         8) echo "ECO_MONO_LSS_MU_TIE=0" ;;
         7) echo "ECO_MONO_LSS_SPINE_ARITY=0" ;;
         6) echo "ECO_MONO_LSS_DEVIRT_FN=0" ;;
         5) echo "ECO_MONO_LSS_KEYED_GLOBALS=" ;;
         4) echo "" ;;                      # maxSpecsPerGlobal: 0 already
         3) echo "ECO_MONO_LSS=unkeyed" ;;
         2) echo "" ;;                      # maxSetSize: 0 already
         1) echo "ECO_MONO_LSS=0" ;;        # supersedes the =unkeyed above
    esac
}

flag_name_for() {
    case "$1" in
        31) echo stageAnchor.demandFill ;;  30) echo stageAnchor.rowFill ;;
        29) echo flowConnect ;;             28) echo settle.varLambda ;;
        27) echo settle.varCtorRows ;;      26) echo settle.varSucc ;;
        25) echo destrAnno ;;               24) echo rsTop ;;
        23) echo argPoints ;;               22) echo injTotal ;;
        21) echo refPapSpine ;;             20) echo rootFold ;;
        19) echo regIdentity ;;             18) echo sigRootIdentity ;;
        17) echo papMembers ;;              16) echo refIdentity ;;
        15) echo qSolve ;;                  14) echo arrowSolverRoots ;;
        13) echo arrowIdentity ;;           12) echo postSettleDevirt ;;
        11) echo layoutQualMembers ;;       10) echo sigFlow ;;
         9) echo groundStandalones ;;        8) echo muTie ;;
         7) echo spineArity ;;               6) echo devirtFnGlobals ;;
         5) echo keyedGlobals ;;             4) echo maxSpecsPerGlobal ;;
         3) echo keyed ;;                    2) echo maxSetSize ;;
         1) echo enabled ;;
    esac
}

# Cumulative off-set for iteration N: flags 31 down to N.
cumulative_env() {
    local n=$1 i e
    for (( i = 31; i >= n; i-- )); do
        e=$(off_env_for "$i")
        [ -n "$e" ] && printf '%s\n' "$e"
    done
}

# One measured self-compile. $1 compiler, $2 tag, $3.. env assignments.
measure() {
    local compiler=$1 tag=$2; shift 2
    cd "$BK" || exit 1
    rm -rf eco-stuff
    echo "[$(date -Is)] $tag: $compiler  env: $*" >&2
    env "$@" ECO_MONO_ENGINE=solver \
        /usr/bin/time -v -o "$BK/$tag.time" \
        "$compiler" make --optimize \
            --kernel-package eco/compiler \
            --local-package eco/kernel=$WORK/eco-kernel-cpp \
            --output="bin/$tag.mlir" \
            "$ENTRY" \
        > "$BK/$tag.stdout" 2> "$BK/$tag.stderr"
    local rc=$?
    echo "[$(date -Is)] $tag: exit $rc" >&2
    return $rc
}

# Pull the five metrics out of <tag>.time / <tag>.stdout as a TSV fragment.
extract() {
    local tag=$1
    local wall rss minor major prom
    wall=$(grep -a 'Elapsed (wall clock)' "$BK/$tag.time" | sed 's/.*: //')
    rss=$(grep -a 'Maximum resident set size' "$BK/$tag.time" | sed 's/.*: //')
    minor=$(grep -a 'Minor GC cycles:' "$BK/$tag.stdout" | awk '{print $NF}')
    major=$(grep -a 'Major GC cycles:' "$BK/$tag.stdout" | awk '{print $NF}')
    prom=$(grep -a 'totals: promoted' "$BK/$tag.stdout" \
           | sed 's/.*(\([0-9]*\) MiB).*/\1/')
    # RSS kB -> MB, one decimal.
    rss=$(awk -v k="${rss:-0}" 'BEGIN{printf "%.1f", k/1024}')
    printf '%s\t%s\t%s\t%s\t%s' \
        "${wall:-ERR}" "$rss" "${minor:-ERR}" "${major:-ERR}" "${prom:-ERR}"
}

record() {  # iter flagname run tag offset
    mkdir -p "$(dirname "$RESULTS")"
    if [ ! -s "$RESULTS" ]; then
        printf 'iter\tflag\trun\ttag\twall\trss_mb\tminor_gc\tmajor_gc\tpromoted_mib\toff_set\n' \
            > "$RESULTS"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "$3" "$4" "$(extract "$4")" "$5" >> "$RESULTS"
    render_table
}

# Render the TSV as a markdown table in /work/flag-off-lss-results.md. One row
# per compiler run, standard above optimized within each iteration, newest
# iteration last. Rewritten from scratch each time so it is always consistent
# with the TSV.
render_table() {
    {
        echo "# LSS flag-off loop — results"
        echo
        echo "Generated by \`flag-off-lss-run.sh\`; protocol in"
        echo "\`flag-off-lss-loop.md\`. Source of truth is"
        echo "\`benchmarks/flag-off-lss-loop.tsv\`."
        echo
        echo "\`standard\` = the subst-built reference compiler (\`bin/eco-std\`)"
        echo "self-compiling at this flag level. \`optimized\` = the compiler built"
        echo "from that run's own output, self-compiling the same source at the"
        echo "same flag level. Both runs share one LSS configuration; only the"
        echo "compiling binary differs."
        echo
        echo "| Iter | Flag turned off | Run | Wall | Max RSS (MB) | Minor GC | Major GC | Promoted (MiB) |"
        echo "|-----:|-----------------|-----|-----:|-------------:|---------:|---------:|---------------:|"
        awk -F'\t' 'NR>1 {printf "| %s | `%s` | %s | %s | %s | %s | %s | %s |\n", \
            $1, $2, $3, $5, $6, $7, $8, $9}' "$RESULTS"
        echo
        echo "## Reference build (setup)"
        echo
        echo "\`bin/eco-std\`, built once under \`ECO_MONO_ENGINE=subst\`:"
        echo
        echo "| Run | Wall | Max RSS (MB) | Minor GC | Major GC | Promoted (MiB) |"
        echo "|-----|-----:|-------------:|---------:|---------:|---------------:|"
        if [ -f "$BK/std-subst.time" ]; then
            printf '| setup (subst) | %s |\n' \
                "$(extract std-subst | awk -F'\t' '{print $1" | "$2" | "$3" | "$4" | "$5}')"
        fi
        echo
        echo "## Cumulative off-set per iteration"
        echo
        echo "| Iter | Off-set |"
        echo "|-----:|---------|"
        awk -F'\t' 'NR>1 && !seen[$1]++ {printf "| %s | %s |\n", $1, $10}' "$RESULTS"
    } > "$TABLE"
}

# ---------------------------------------------------------------- setup ----
if [ "${1:-}" = setup ]; then
    cd "$BK" || exit 1
    rm -rf eco-stuff
    echo "[$(date -Is)] setup: subst self-compile -> bin/std-subst.mlir" >&2
    env ECO_MONO_ENGINE=subst \
        /usr/bin/time -v -o "$BK/std-subst.time" \
        "$SEED" make --optimize \
            --kernel-package eco/compiler \
            --local-package eco/kernel=$WORK/eco-kernel-cpp \
            --output=bin/std-subst.mlir \
            "$ENTRY" \
        > "$BK/std-subst.stdout" 2> "$BK/std-subst.stderr" || {
            echo "setup: subst self-compile FAILED" >&2; exit 1; }
    echo "[$(date -Is)] setup: lowering -> bin/eco-std" >&2
    "$BOOT" bin/std-subst.mlir -o bin/eco-std \
        > "$BK/std-lower.stdout" 2> "$BK/std-lower.stderr" || {
            echo "setup: lowering FAILED" >&2; exit 1; }
    echo "[$(date -Is)] setup: done, $(ls -l bin/eco-std | awk '{print $5}') bytes" >&2
    exit 0
fi

# -------------------------------------------------------------- all mode ----
if [ "${1:-}" = all ]; then
    for n in $EFFECTIVE; do
        "$0" "$n" || { echo "all: iteration $n FAILED, stopping" >&2; exit 1; }
    done
    echo "all: every effective iteration done" >&2
    exit 0
fi

# ------------------------------------------------------------ iteration ----
N=${1:?usage: flag-off-lss-run.sh setup | all | <N> [--force]}
FORCE=${2:-}

for s in $SKIP; do
    if [ "$N" = "$s" ] && [ "$FORCE" != "--force" ]; then
        echo "iteration $N ($(flag_name_for "$N")) SKIPPED — already at its off" \
             "value in defaultLss, so this iteration cannot change the" \
             "configuration. Re-run with --force to measure it anyway." >&2
        exit 0
    fi
done

FLAG=$(flag_name_for "$N")
mapfile -t OFFSET < <(cumulative_env "$N")
OFFSTR=$(IFS=' '; echo "${OFFSET[*]:-<defaults>}")

[ -x "$STD" ] || { echo "missing $STD — run 'setup' first" >&2; exit 1; }

echo "=== iteration $N ($FLAG) — off-set: $OFFSTR" >&2

measure "$STD" "i$N-std" "${OFFSET[@]}" || exit 1
record "$N" "$FLAG" standard "i$N-std" "$OFFSTR"

echo "[$(date -Is)] i$N: lowering -> bin/eco-i$N" >&2
"$BOOT" "bin/i$N-std.mlir" -o "bin/eco-i$N" \
    > "$BK/i$N-lower.stdout" 2> "$BK/i$N-lower.stderr" || {
        echo "i$N: lowering FAILED" >&2; exit 1; }

measure "$BK/bin/eco-i$N" "i$N-opt" "${OFFSET[@]}" || exit 1
record "$N" "$FLAG" optimized "i$N-opt" "$OFFSTR"

echo "=== iteration $N done" >&2
tail -3 "$RESULTS" >&2
