#!/usr/bin/env bash
# One iteration of the LSS flag-off SOLO census. See flag-off-lss-loop.md.
#
#   flag-off-lss-solo.sh setup       lower the shipping compiler into the instrument
#   flag-off-lss-solo.sh base        the all-flags-ON baseline row
#   flag-off-lss-solo.sh <N>         turn off flag N AND ONLY FLAG N (32..1)
#   flag-off-lss-solo.sh all         base, then every flag 32 -> 1
#
# SOLO: each run overrides exactly one flag. Nothing accumulates, so iterations
# are independent and may be run or re-run in any order. Records land in
# benchmarks/flag-off-lss-solo.tsv and are rendered into
# benchmarks/flag-off-lss-solo-results.md after every run.
#
# The cumulative predecessor is flag-off-lss-run.sh; it is kept because it is
# what produced the archived cumulative series.
#
# ============================== EXPIRED 2026-09-18 ==============================
# 31 of the 32 LSS flags this census sweeps were FIXED AT THEIR DEFAULTS AND
# REMOVED (plans/fix-lss-flags-at-defaults.md). `lss.enabled` is the only
# switch left, plus the three numeric caps and the four censuses, none of
# which this script rows.
#
# Setting a deleted `ECO_MONO_LSS_*` variable is now a SILENT NO-OP — the
# compiler does not read it and does not complain — so every row below except
# the last would report a "flag off" measurement that is really the baseline
# measured twice. That failure mode is why this banner exists rather than a
# quiet deletion: a stale row here is indistinguishable from a genuinely inert
# flag, which is exactly the reading `flag-off-lss-solo-findings.md` was
# written to make.
#
# The last census taken while the flags existed is
# benchmarks/flag-off-lss-solo-findings.md (2026-09-18), and its per-flag rows
# are reproduced in plans/fix-lss-flags-at-defaults.md §7. Use those; do not
# re-run this script expecting per-flag rows.
# ==============================================================================
set -uo pipefail

WORK=/work
BK=$WORK/build/compiler/build-kernel
BOOT=$WORK/build/runtime/src/codegen/eco-boot-native
ENTRY=$WORK/compiler/src/Terminal/Main.elm
SEED=$BK/bin/eco-post                # any working native compiler, current tree
STD=$BK/bin/eco-opt-solo-census      # THE instrument (shipping compiler) — never rebuild mid-series
RESULTS=$WORK/benchmarks/flag-off-lss-solo.tsv
TABLE=$WORK/benchmarks/flag-off-lss-solo-results.md
BASEMLIR=$BK/bin/solo-base-out.mlir

ORDER="32 31 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1"

# Flag N -> the ONE "VAR=value" that turns it off. Every flag here is
# default-ON, so every row is a real change.
off_env_for() {
    case "$1" in
        base) echo "" ;;                    # all flags ON: the reference row
        32) echo "ECO_MONO_LSS_ROOT_FOLD_DEPTH=0" ;;
        31) echo "ECO_MONO_LSS_INSTANCE_QUAL_USE_INJECT_PAP=0" ;;
        30) echo "ECO_MONO_LSS_FLOW_LIT_FACTS=0" ;;
        29) echo "ECO_MONO_LSS_FLOW_ACCESS_FLOW=0" ;;
        28) echo "ECO_MONO_LSS_FLOW_LET_OVERLAY=0" ;;
        27) echo "ECO_MONO_LSS_INSTANCE_QUAL_USE_INJECT=0" ;;
        26) echo "ECO_MONO_LSS_PAP_FAST=0" ;;
        25) echo "ECO_MONO_LSS_FLAT_PEEL=0" ;;
        24) echo "ECO_MONO_LSS_INSTANCE_QUAL=0" ;;
        23) echo "ECO_MONO_LSS_FLOW_CONNECT=0" ;;
        22) echo "ECO_MONO_LSS_VAR_LAMBDA=0" ;;
        21) echo "ECO_MONO_LSS_VAR_CTOR_ROWS=0" ;;
        20) echo "ECO_MONO_LSS_VAR_SUCC=0" ;;
        19) echo "ECO_MONO_LSS_DESTR_ANNO=0" ;;
        18) echo "ECO_MONO_LSS_RS_TOP=0" ;;
        17) echo "ECO_MONO_LSS_INJ_TOTAL=0" ;;
        16) echo "ECO_MONO_LSS_REF_PAP_SPINE=0" ;;
        15) echo "ECO_MONO_LSS_ROOT_FOLD=0" ;;
        14) echo "ECO_MONO_LSS_REG_IDENTITY=0" ;;
        13) echo "ECO_MONO_LSS_PAP_MEMBERS=0" ;;
        12) echo "ECO_MONO_LSS_REF_IDENTITY=0" ;;
        11) echo "ECO_MONO_LSS_ARROW_ROOTS=0" ;;
        10) echo "ECO_MONO_LSS_ARROW_ID=0" ;;
         9) echo "ECO_MONO_LSS_DEVIRT_POST=0" ;;
         8) echo "ECO_MONO_LSS_LAYOUT_QUAL=0" ;;
         7) echo "ECO_MONO_LSS_SIG_FLOW=0" ;;
         6) echo "ECO_MONO_LSS_GROUND=0" ;;
         5) echo "ECO_MONO_LSS_MU_TIE=0" ;;
         4) echo "ECO_MONO_LSS_DEVIRT_FN=0" ;;
         3) echo "ECO_MONO_LSS_KEYED_GLOBALS=" ;;
         2) echo "ECO_MONO_LSS=unkeyed" ;;
         1) echo "ECO_MONO_LSS=0" ;;
    esac
}

flag_name_for() {
    case "$1" in
        base) echo "<none>" ;;
        32) echo stamp.rootFoldDepth ;;     31) echo stamp.useInjectPap ;;
        30) echo flow.litFacts ;;           29) echo flow.accessFlow ;;
        28) echo flow.letOverlay ;;         27) echo stamp.useInject ;;
        26) echo stamp.papFast ;;           25) echo stamp.flatPeel ;;
        24) echo instanceQual ;;            23) echo flow.connect ;;
        22) echo settle.varLambda ;;        21) echo settle.varCtorRows ;;
        20) echo settle.varSucc ;;          19) echo destrAnno ;;
        18) echo rsTop ;;                   17) echo injTotal ;;
        16) echo refPapSpine ;;             15) echo rootFold ;;
        14) echo regIdentity ;;             13) echo papMembers ;;
        12) echo refIdentity ;;             11) echo arrowSolverRoots ;;
        10) echo arrowIdentity ;;            9) echo postSettleDevirt ;;
         8) echo layoutQualMembers ;;        7) echo sigFlow ;;
         6) echo groundStandalones ;;        5) echo muTie ;;
         4) echo devirtFnGlobals ;;          3) echo keyedGlobals ;;
         2) echo keyed ;;                    1) echo enabled ;;
    esac
}

# One measured self-compile on the FIXED instrument. $1 = tag, $2.. = env.
measure() {
    local tag=$1; shift
    cd "$BK" || exit 1
    rm -rf eco-stuff
    echo "[$(date -Is)] $tag: env: ${*:-<defaults>}" >&2
    env "$@" ECO_MONO_ENGINE=solver ECO_DISPATCH_STATS=1 ECO_MONO_LSS_REPORT=1 \
        /usr/bin/time -v -o "$BK/$tag.time" \
        "$STD" make --optimize \
            --kernel-package eco/compiler \
            --local-package eco/kernel=$WORK/eco-kernel-cpp \
            --output="bin/$tag-out.mlir" \
            "$ENTRY" \
        > "$BK/$tag.stdout" 2> "$BK/$tag.stderr"
    local rc=$?
    echo "[$(date -Is)] $tag: exit $rc" >&2
    return $rc
}

# Context + artifact + the three census groups, as one TSV fragment.
extract() {
    local tag=$1
    python3 - "$BK" "$tag" "$BASEMLIR" <<'PYEOF'
import os, re, subprocess, sys
bk, tag, basemlir = sys.argv[1], sys.argv[2], sys.argv[3]

def read(p):
    try:
        return open(p, "rb").read().replace(b"\0", b"").decode("utf8", "replace")
    except FileNotFoundError:
        return ""

err, out, tim = read(f"{bk}/{tag}.stderr"), read(f"{bk}/{tag}.stdout"), read(f"{bk}/{tag}.time")
F = []

def num(pat, s, g=1):
    m = re.search(pat, s, re.M)
    return m.group(g) if m else "ERR"

# context
m = re.search(r"Elapsed \(wall clock\) time.*: (\S+)", tim)   # last COLON-SPACE; the value itself has colons
F.append(m.group(1).strip() if m else "ERR")
rss = num(r"Maximum resident set size \(kbytes\): (\d+)", tim)
F.append(f"{int(rss)/1024:.1f}" if rss != "ERR" else "ERR")
F.append(num(r"Minor GC cycles:\s+(\d+)", out))
F.append(num(r"Major GC cycles:\s+(\d+)", out))
F.append(num(r"totals: promoted \d+ \((\d+) MiB\)", out))

# artifact
mlir = f"{bk}/bin/{tag}-out.mlir"
F.append(str(os.path.getsize(mlir)) if os.path.exists(mlir) else "ERR")
if tag == "fbase":
    F.append("(baseline)")
elif os.path.exists(basemlir) and os.path.exists(mlir):
    same = subprocess.run(["cmp", "-s", basemlir, mlir]).returncode == 0
    F.append("same" if same else "DIFFERS")
else:
    F.append("?")

# lss-coverage
cov = re.search(r"^coverage: (.*)$", err, re.M)
covline = cov.group(1) if cov else ""
vals = {}
for k in ("positions", "k1", "kN", "var", "top", "part"):
    mm = re.search(rf"\b{k}=(\d+)", covline)
    vals[k] = int(mm.group(1)) if mm else None
    F.append(str(vals[k]) if vals[k] is not None else "ERR")
if vals["positions"]:
    F.append(f'{100.0*((vals["k1"] or 0)+(vals["kN"] or 0))/vals["positions"]:.2f}')
else:
    F.append("ERR")

# lss-stamping
g = re.search(r"^lss globalopt: (.*)$", err, re.M)
gl = g.group(1) if g else ""
for k in ("dispatchUpgraded", "stampedPapGlobal", "stampedStaged", "stampedPapPrefix",
          "declinedNoInstance", "declinedBlocked", "declinedShape",
          "declinedAbiMismatch", "declinedBodyMismatch", "multiInstanceGroups"):
    mm = re.search(rf"\b{k}=(\d+)", gl)
    F.append(mm.group(1) if mm else "ERR")
mm = re.search(r"devirtPost\([^)]*\)=(\d+)/(\d+)/(\d+)/(\d+)", gl)
F.append("/".join(mm.groups()) if mm else "ERR")

# dispatch-stats
mm = re.search(r"\[dispatch-stats\] sat=(\d+) gen=(\d+) typed=(\d+) fast=(\d+) distinct=(\d+)", err)
if mm:
    F.extend(mm.groups())
else:
    F.extend(["ERR"]*5)

print("\t".join(F))
PYEOF
}

record() {  # iter flagname tag offswitch
    mkdir -p "$(dirname "$RESULTS")"
    if [ ! -s "$RESULTS" ]; then
        printf 'iter\tflag\ttag\twall\trss_mb\tminor_gc\tmajor_gc\tpromoted_mib\tout_bytes\tvs_base\tpositions\tk1\tkN\tvar\ttop\tpart\tcoverage\tdispatchUpgraded\tstampedPapGlobal\tstampedStaged\tstampedPapPrefix\tnoInstance\tblocked\tshape\tabiMismatch\tbodyMismatch\tmultiInst\tdevirtPost\tsat\tgen\ttyped\tfast\tdistinct\toff_switch\n' \
            > "$RESULTS"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(extract "$3")" "$4" >> "$RESULTS"
    render_table
}

render_table() {
    {
        echo "# LSS flag-off SOLO census — results"
        echo
        echo "Generated by \`flag-off-lss-solo.sh\`; protocol in"
        echo "\`flag-off-lss-loop.md\`. Source of truth is"
        echo "\`benchmarks/flag-off-lss-solo.tsv\`."
        echo
        echo "Each row is ONE run of the fixed shipping-compiler instrument"
        echo "(\`bin/eco-opt-solo-census\`) self-compiling with exactly ONE flag off,"
        echo "under \`ECO_DISPATCH_STATS=1 ECO_MONO_LSS_REPORT=1\`."
        echo
        echo "**Groups 2 and 3 are the flag's EFFECT** (what the analysis concluded)."
        echo "**Groups 1 and 4 are COST** (what computing it took, on the shipping compiler)."
        echo "What a flag BUYS at run time is out of scope — see the protocol's"
        echo "\"What this census does NOT measure\"."
        echo
        echo "## 1. Context — cost"
        echo
        echo "Wall carries a ~19 % census tax, paid uniformly, so it cancels in comparisons"
        echo "but is NOT comparable to a census-off run. **Max RSS is bimodal and is not a"
        echo "per-flag metric.** Minor GC and promoted MiB are the honest allocation signal."
        echo
        echo "| Iter | Flag turned off | Wall | Max RSS (MB) | Minor GC | Major GC | Promoted (MiB) |"
        echo "|-----:|-----------------|-----:|-------------:|---------:|---------:|---------------:|"
        tail -n +2 "$RESULTS" | awk -F'\t' '{printf "| %s | `%s` | %s | %s | %s | %s | %s |\n", $1,$2,$4,$5,$6,$7,$8}'
        echo
        echo "## 2. lss-coverage — the flag's effect on the analysis"
        echo
        echo "| Iter | Flag turned off | positions | k1 | kN | var | ⊤ | part | coverage % |"
        echo "|-----:|-----------------|----------:|---:|---:|----:|--:|-----:|-----------:|"
        tail -n +2 "$RESULTS" | awk -F'\t' '{printf "| %s | `%s` | %s | %s | %s | %s | %s | %s | %s |\n", $1,$2,$11,$12,$13,$14,$15,$16,$17}'
        echo
        echo "## 3. lss-stamping — the flag's effect on AbiCloning"
        echo
        echo "| Iter | Flag turned off | upgraded | papGlobal | staged | papPrefix | noInstance | blocked | shape | abiMism | bodyMism | multiInst | devirtPost fn/ctor/noSpec/amb |"
        echo "|-----:|-----------------|---------:|----------:|-------:|----------:|-----------:|--------:|------:|--------:|---------:|----------:|---|"
        tail -n +2 "$RESULTS" | awk -F'\t' '{printf "| %s | `%s` | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1,$2,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27,$28}'
        echo
        echo "## 4. dispatch-stats — cost, deterministic (no run-to-run noise)"
        echo
        echo "| Iter | Flag turned off | sat | gen | typed | fast | distinct |"
        echo "|-----:|-----------------|----:|----:|------:|-----:|---------:|"
        tail -n +2 "$RESULTS" | awk -F'\t' '{printf "| %s | `%s` | %s | %s | %s | %s | %s |\n", $1,$2,$29,$30,$31,$32,$33}'
        echo
        echo "## 5. Artifact — did the effect reach the emitted code?"
        echo
        echo "\`same\` means the flag changed NOTHING the compiler emits on this workload."
        echo
        echo "| Iter | Flag turned off | out.mlir (B) | vs base | Off switch |"
        echo "|-----:|-----------------|-------------:|---------|------------|"
        tail -n +2 "$RESULTS" | awk -F'\t' '{printf "| %s | `%s` | %s | %s | %s |\n", $1,$2,$9,$10,($34=="" ? "*(none)*" : "`" $34 "`")}'
    } > "$TABLE"
}

# ---------------------------------------------------------------- setup ----
if [ "${1:-}" = setup ]; then
    cd "$BK" || exit 1
    SRCMLIR=${2:-bin/post-change.mlir}
    [ -f "$SRCMLIR" ] || { echo "setup: no such MLIR: $SRCMLIR" >&2; exit 1; }
    echo "[$(date -Is)] setup: lowering shipping compiler $SRCMLIR -> $STD" >&2
    ECO_LSS_DISPATCH_SITE_COUNTERS=1 "$BOOT" "$SRCMLIR" -o "$STD" \
        > solo-opt-lower.stdout 2> solo-opt-lower.stderr || {
            echo "setup: lowering FAILED" >&2; exit 1; }
    cp "$SRCMLIR" "$BK/bin/solo-instrument-src.mlir"
    echo "[$(date -Is)] setup: done, $(stat -c %s "$STD") bytes" >&2
    exit 0
fi

# -------------------------------------------------------------- all mode ----
if [ "${1:-}" = all ]; then
    "$0" base || { echo "all: baseline FAILED, stopping" >&2; exit 1; }
    for n in $ORDER; do
        "$0" "$n" || { echo "all: iteration $n FAILED, stopping" >&2; exit 1; }
    done
    echo "all: every flag measured; now re-run 'base' as the drift check" >&2
    exit 0
fi

# ------------------------------------------------------------ iteration ----
N=${1:?usage: flag-off-lss-solo.sh setup | base | all | <N>}
[ -x "$STD" ] || { echo "missing $STD — run 'setup' first" >&2; exit 1; }

FLAG=$(flag_name_for "$N")
[ -n "$FLAG" ] || { echo "unknown flag index: $N" >&2; exit 1; }
OFF=$(off_env_for "$N")

if [ "$N" != base ] && [ ! -f "$BASEMLIR" ]; then
    echo "no baseline out.mlir yet ($BASEMLIR) — run 'base' first so vs-base can be decided" >&2
    exit 1
fi

echo "=== iteration $N ($FLAG) — off switch: ${OFF:-<none>}" >&2
if [ -n "$OFF" ]; then measure "f$N" "$OFF" || exit 1; else measure "f$N" || exit 1; fi

# the baseline's artifact is the comparison target for every other row, and is
# also the MLIR the instrument itself was lowered from (see the protocol §0)
if [ "$N" = base ]; then
    cp "$BK/bin/fbase-out.mlir" "$BASEMLIR"
    if [ -f "$BK/bin/solo-instrument-src.mlir" ] \
       && ! cmp -s "$BASEMLIR" "$BK/bin/solo-instrument-src.mlir"; then
        echo "WARNING: baseline output != the MLIR the instrument was built from." >&2
        echo "         The instrument and the tree have diverged; the series is invalid." >&2
    fi
fi

record "$N" "$FLAG" "f$N" "$OFF"
echo "=== iteration $N done" >&2
tail -1 "$RESULTS" >&2
