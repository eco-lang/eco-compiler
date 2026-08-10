# Kernel Opt Track — Stage-7a Cold-Cache Benchmarks

Tracks the wall/RSS/allocation impact of the kernel-boundary optimization
track (`design_docs/kernel-boundary-reduction.md`;
`plans/string-cmp-order-intrinsic-and-postmono-compare-rewrite.md` and
successors — deleting opaque kernel calls and the work they carry) on the
standard bootstrap workload. Append one labelled section per run.

---

## Recording instructions (fixed — keep every entry uniform)

**Per run:** give it a **label** (Run A, Run B, …). Record **wall time**,
**max RSS**, and the **number and size of heap allocations** from the GC
stats exit dump (`Objects allocated`, `Bytes allocated`), plus
`Minor GC cycles`, `Objects promoted`, `Major GC cycles` (never report a
wall without its majors — trigger-lottery lesson), `Total GC/Alloc time`,
and the output `.mlir` byte size (workload-constancy check). Describe the
run in **max 10 lines of text** — no extensive write-ups; keep the labelled
entries uniform in appearance, stats recorded, and briefness.

**What this protocol is and is not (read before drawing a conclusion).**
It is a **regression check**, not a precision instrument. The measured
run-to-run spread of an unchanged binary on this workload is **≈6 s on ≈213 s
(≈2.8%)**, so:

- a delta of **≳3%** is a real signal — report it;
- anything **below that is FLAT**. Write "no regression detected", never "a
  −1% gain". A sub-noise number is not a measurement no matter how many runs
  average into it.
- **The GC counters are exact even from one run.** `Objects allocated`,
  `Bytes allocated`, `Minor/Major GC cycles` and `Objects promoted` were
  bit-identical across all 16 legs of Run B, so they carry real information at
  n=1 — an unexpected move in *those* is a far stronger regression signal than
  a few seconds of wall. Judge changes on the counters first, wall second.
- Establishing a genuine small (<3%) gain is a deliberate, separately-budgeted
  exercise, not part of the routine protocol. Do not drift into it by adding
  rounds until the number looks good.

**Run notation in run tables:** one row per (arm, round), labelled `on r1`,
`on r2`, `off r1`, `off r2`. Each row is **one** cold run — there is no warmup
leg and no bracketed second number. (Entries recorded before 2026-08-10 used a
warmup+measured leg pair and show `**3:33.39** (warm 3:32.70)`: measured first,
throwaway warmup in brackets.)

**Summary table:** maintained at the **bottom of this file** — one row per
run: label, wall time, total heap allocation. Numbers are for the arm
**with the run's optimization applied** only (its r1 wall, or the r1/r2 mean
if labelled as such); baseline, A/B and flavor numbers belong in the run
entries. Just the table, no write-up.

**Allocation-count caveat (census §18.3):** the standard binary's HEAP_034
inline-alloc fast path bypasses the per-tag counter, so `Objects allocated`
undercounts codegen'd constructs (~6× on this workload). The figure is
comparable **run-to-run** only for unchanged lowering; when a track
optimization is expected to move allocation, add a separate census leg with
an `ECO_INLINE_ALLOC=0`-lowered binary and record it explicitly as such.

---

## Methodology (repeat exactly each time; adapted from `benchmarks/runtime-calls.md`)

**Workload — cold-cache Stage 7a, constant-config.** The tested
`eco-compiler` binary compiling the entire compiler front-end
(`compiler/src/Terminal/Main.elm`, ~243 modules) to MLIR. The workload runs
under the **cheap fixed configuration** — `ECO_MONO_ENGINE=subst`, no LSS,
no borrow (both default-off under subst) — so the job the binary executes
stays essentially constant across track changes and the measurement isolates
**how fast the optimized binary runs**, undistorted by the recursive tax of
solver/LSS/borrow running *as* workload.

**Binary — the thing being tested.** Built with **solver + LSS + borrow ON
plus every track optimization under test**: this is the artifact whose
performance the track is improving. `build` preset (RelWithDebInfo,
asserts + GC-stats ON — the standard bootstrap config; ~2.6× slower than
release but deterministic). Note: `ECO_BORROW=1` without report/reify is
inert-by-construction today (the Phase-6 pass self-skips); it is set anyway
so the build line already carries every track knob as they become real.

**Two independent engine knobs** (do not confuse): the **build engine** (env
at the `cmake --build` step — how the binary itself is compiled) vs the
**workload engine** (env at the `make` run — how the binary monomorphizes
what it compiles). Here: build = solver+LSS+borrow+track-opts; workload =
subst, always.

**Cache reset — delete `eco-stuff/` immediately before every run; do NOT
touch sources.** `rm -rf build/compiler/build-kernel/eco-stuff` is the
honest cold-cache reset (touching mtimes is fragile; engine changes are
invisible to mtime). **Never delete `~/.eco`** (warm package cache).

**Testing is a separate pass** — never mix gate runs into a benchmark; they
pollute timings and the `eco-stuff/` cache.

**Commands** (run from `/work`):

```bash
BK=build/compiler/build-kernel

# Phase 1 — build the tested binary (repeat when the track changes):
# NINJA IS ENV-BLIND (discovered Run B): with no source change, an env-only
# flavor change does NOT rerun Stage 5 — delete its outputs to force it.
rm -f "$BK/bin/eco-compiler.mlir" "$BK/bin/eco-compiler"
rm -rf "$BK/eco-stuff"
ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_BORROW=1 ECO_AGG_PROMOTE=1 \
    cmake --build build --target eco-compiler          # + further track-opt env vars as they land
cp -p "$BK/bin/eco-compiler" "$BK/bin/eco-compiler-borrowopt"

# Phase 2 — benchmark. ONE cold run per arm per round. NO warmup leg: it
# doubled the cost for a second sample of the same ~2.8% noise band, which a
# regression check does not need.
#   ARMS = the binaries to compare: one name for a plain run, two for an A/B.
#   2 rounds x 2 arms = 4 runs, ~13 min total. That is the whole budget —
#   do NOT extend to more rounds chasing a sub-noise delta (see "What this
#   protocol is and is not" above).
ARMS="eco-compiler-borrowopt"          # A/B example: "eco-cmpcase-on eco-cmpcase-off"
for ROUND in 1 2; do
  # Round 2 runs the arms in reverse order, so machine drift cannot
  # systematically favour whichever arm goes first. Free; always do it.
  [ "$ROUND" = 2 ] && ARMS=$(echo $ARMS | tr ' ' '\n' | tac | tr '\n' ' ')
  for ARM in $ARMS; do
    rm -rf "$BK/eco-stuff"
    ( cd "$BK" && ulimit -c 0 && \
        ECO_MONO_ENGINE=subst \
        /usr/bin/time -v -o "$ARM-r$ROUND.time" \
        "./bin/$ARM" make --optimize --kernel-package eco/compiler \
            --local-package eco/kernel=/work/eco-kernel-cpp \
            --output="bin/$ARM-r$ROUND-out.mlir" /work/compiler/src/Terminal/Main.elm \
            > "$ARM-r$ROUND.stdout" 2> "$ARM-r$ROUND.stderr" )
  done
done
# Report both rounds per arm. Wall + Max RSS from the .time files; allocation
# stats from the GC dump in .stdout; output size from the -out.mlir files.
```

For an A/B against a prior run, `cmp` the `-out.mlir` files — the subst-mode
output must stay **byte-identical** across track changes (the track optimizes
the binary, not the semantics of what it emits); a size or byte diff means the
workload moved and walls are not comparable. When the change deliberately
alters emitted code, say so explicitly and compare only within the A/B (both
arms lowered from the same Stage-5 `.mlir`), which stays byte-identical.

---

## Runs

### 2026-08-10 14:30 UTC — Run C: one-call Order materialization (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_ORDER_FROM_SIGN=0` escapes**)

`plans/string-cmp-order-intrinsic-and-postmono-compare-rewrite.md` (CGEN_075)
phase C-v1: `emitOrderSelect` folds the sign in SSA and makes ONE gc-leaf
`eco_order_from_sign(i64)` call instead of calling all three
`Eco_Runtime_getOrder*` getters unconditionally — in the shipped binary
**24 call instructions → 8 sites (4 call + 4 tail `jmp`)**, since the
single-call shape ends the function. `.text` −240 B, stackmaps unchanged.
FLAT: the rounds SPLIT (r1 +2.05%, r2 −0.51%), mean +0.76%, inside the band;
the 165-object counter delta on off-r1 is documented same-binary noise (tier2
Run O). Small by construction — B already rewrote 373 of 389 sites so only 8
survive; this was the 881M-call/run lever *before* B. Gates: 1632/1632 both.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:34.71** | 5,112,024 kB | 379,486,686 | 18,524.03 MB | 862 | 372,250,555 (98.1%) | 10 | 84.43 s | 12,943,401 B |
| on r2 | **3:32.00** | 5,111,792 kB | ≡ | ≡ | 862 | ≡ | 10 | 82.60 s | ≡ |
| off r1 | 3:30.40 | 5,055,312 kB | 379,486,851 | ≡ | 862 | ≡ | 10 | 82.12 s | ≡ |
| off r2 | 3:33.08 | 5,111,864 kB | 379,486,686 | ≡ | 862 | ≡ | 10 | 83.13 s | ≡ |

### 2026-08-10 12:40 UTC — Run B: `eco.string.cmp_order` + post-mono compare→branch rewrite (**no regression; counters identical; KEEP — DEFAULT-ON, `ECO_CMPCASE=0` escapes**)

`plans/string-cmp-order-intrinsic-and-postmono-compare-rewrite.md` (CGEN_075),
phases A+B+D. A: `Utils.compare [MString,MString]` selects `eco.string.cmp_order`
over the boxed root — boxed `Utils_compare` sites 295 → 38 (250 of the 258 new
string compares in `Dict_insertHelp`/`Dict_get`). B: an Eco→Eco peephole turns
single-use compare + 3-arm case-on-Order into ordered lt/gt + nested bool cases
— `[cmpcase] rewritten=373 skipped=16`. D: deleted the dead pre-mono rewrite
(−242 lines). Arms are one Stage-5 `.mlir` lowered twice: `out.mlir` identical,
counters equal ⇒ pure code quality; `.text` −46,784 B, stackmaps unchanged.
Wall FLAT by the ≥3% bar (mean −2.08%, band ±2.8%); vs Run A also FLAT (phase A
moves emitted code). Gates: E2E + heap-validate 1631/1631, bootstrap 8c identical.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:33.39** (warm 3:32.70) | 5,111,872 kB | 379,486,686 | 18,524.03 MB | 862 | 372,250,555 (98.1%) | 10 | — | 12,943,401 B |
| on r2 | **3:33.46** (warm 3:30.31) | 5,111,916 kB | ≡ | ≡ | 862 | ≡ | 10 | — | ≡ |
| on r3 | **3:31.89** (warm 3:34.91) | 5,111,816 kB | ≡ | ≡ | 862 | ≡ | 10 | — | ≡ |
| on r4 | **3:29.69** (warm 3:28.73) | 5,112,136 kB | ≡ | ≡ | 862 | ≡ | 10 | 81.91 s | ≡ |
| off r1 | 3:38.36 (warm 3:38.25) | 5,055,476 kB | ≡ | ≡ | 862 | ≡ | 10 | — | ≡ |
| off r2 | 3:34.94 (warm 3:32.81) | 5,116,344 kB | ≡ | ≡ | 862 | ≡ | 10 | — | ≡ |
| off r3 | 3:35.11 (warm 3:36.23) | 5,115,612 kB | ≡ | ≡ | 862 | ≡ | 10 | — | ≡ |
| off r4 | 3:38.06 (warm 3:34.83) | 5,116,068 kB | ≡ | ≡ | 862 | ≡ | 10 | 83.59 s | ≡ |

### 2026-08-09 15:54 UTC — Run A: series baseline (**carried over from `benchmarks/tier2-opt.md` Run O — NOT re-measured**)

Series baseline, carried over from `benchmarks/tier2-opt.md` Run O (contiguous
nursery extents + configurable old-gen/nursery split, HEAP_042/043,
`plans/contiguous-nursery-space.md`) arm C = M1+M2 default. That run was FLAT on
wall, kept for nursery slow-path entries 417,585 → 316 and RSS −2.56%. Every
default-on tier-2 track optimization (gc-free propagation, capacity-check
hoisting, contiguous nursery, inline nursery allocation) is therefore live here.
`Objects promoted` and `GC time` are `—`: the source entry recorded `ensure
calls` / `old-gen cap` instead, so capture both from Run B onward. Old-gen cap
was 20,480 MB. Gates at that point: E2E `--target full` and heap-validate tree
1628/1628.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| baseline measured | **3:36.18** | 5,012,240 kB | 379,768,314 | 18,537.46 MB | 871 | — | 10 | — | 12,955,155 B |
| baseline warmup | 3:36.11 | 5,012,120 kB | ≡ | ≡ | 871 | — | 10 | — | ≡ |

---

## Summary

| run | wall | total heap allocation |
|---|---|---|
| A — baseline (tier2 Run O) | 3:36.18 | 379,768,314 obj / 18,537.46 MB |
| B — string cmp_order + compare→branch rewrite | 3:33.39 | 379,486,686 obj / 18,524.03 MB |
| C — one-call Order materialization | 3:34.71 | 379,486,686 obj / 18,524.03 MB |
