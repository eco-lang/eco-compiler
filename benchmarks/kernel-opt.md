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

### 2026-08-11 14:05 UTC — Run H: kernel-opt-04 `eco.string.length` + `eco.string.code_unit_at` (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_STRING_LENGTH_OP=0` escapes**)

`plans/kernel-opt-04-string-length-code-unit-at.md`. `String.length` becomes an
INLINE-IR `eco.string.length`: a `__eco_string_len_inline` marker that
`expandStringLenMarkers` turns into an embedded-constant test (`ptr_ind`, bit 2)
plus, on the heap arm, `__eco_resolve_fwd` + a u32 load at `offsetof(Header,size)`
+ zext. One word serves all six String forms because HEAP_025/HEAP_032 define
`header.size` as the logical UTF-16 count for every one of them, so there is no
per-tag dispatch. **All 101 self-compile call sites convert: `callee =
@Elm_Kernel_String_length` 101 → 0 against `eco.string.length` 0 → 101, exact 1:1
with no declines.** Also lands `eco.string.code_unit_at` (a gc-leaf call to
`StringOps::charAt`) with **no Elm emission** — it exists to unblock kernel-opt-14's
String-HOF phase, so no wall is booked against it.

Wall **−0.12%** ⇒ FLAT, and the plan said so up front: 75.6M calls is 2.06% of the
kernel total, and this is call-deletion, not retention. Counters are identical
(objects differ by 162 of 220M, documented same-binary noise; minor 836, major 10,
promoted equal both arms), `-out.mlir` byte-identical in both rounds. Binary
−8,336 B. Gates: E2E **1636/1636 in BOTH flag states** and again default-on;
elm-tests 13,085 / 12 pre-existing, unchanged. `ptr_ind` was chosen over v1's
`icmp eq 0x6`: the word test would dereference address 4/5 for a Bool constant
where the kernel returns 0.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:24.65** | 4,894,268 kB | 219,915,775 | 13,335.65 MB | 836 | 361,202,849 (164.2%) | 10 | 79.92 s | 12,939,423 B |
| on r2 | **3:20.84** | 4,884,244 kB | 219,915,613 | 13,335.64 MB | 836 | 361,202,850 | 10 | 78.16 s | ≡ |
| off r1 | 3:22.47 | 4,888,640 kB | 219,915,616 | 13,335.65 MB | 836 | 361,202,842 | 10 | 78.45 s | ≡ |
| off r2 | 3:23.49 | 4,888,544 kB | ≡ | ≡ | 836 | ≡ | 10 | 78.98 s | ≡ |

### 2026-08-11 11:20 UTC — Run G: kernel-opt-02 lane A + A′ — union-find cell merge (**−4.46% WALL — a REAL SIGNAL, the first in this series; KEEP, no flag**)

`plans/kernel-opt-02-array-push-churn.md` lanes A + A′, selected by the Phase-0
census (recorded in that plan's §Results). **Lane A:** the three index-synchronised
`ioRefsWeight` / `ioRefsPointInfo` / `ioRefsDescriptor` arrays collapse to one
`ioRefsPoint : Array PointCell` (`Root Int Descriptor | Chain Point`), so
`UnionFind.fresh` does **1 `Array.push` instead of 3** and `union` does **2
`Array.set`s instead of 3**; `get`/`set`/`modify` lose their second array read.
12 files (7 compiler src + 5 test). **Lane A′:** `Data/Vector.imapM_` built an
array with `Array.push` per element and discarded it — deleted.

**G2, the load-bearing gate, passes: `out.mlir` byte-identical in both rounds** on
the frozen 243-module corpus, so the merge preserved Point ids and every
type-checking result exactly. (First attempt failed for the wrong reason — the
promoted baseline binary predates item 01's default flip, so it emitted kernel
cons calls while the new arm emitted `construct.list`; re-run with
`ECO_LIST_CONS_INTRINSIC=1` forced on **both** arms, which is what these legs are.)

Wall **−4.46%**, outside the ±2.8% band. **Retention moved with it** — `Objects
promoted` −2.96%, minor GC 862 → 836, bytes allocated −12.08%, GC time −6.04% —
which is exactly the channel this repo's measured record says wall tracks. Binary
−32,448 B. Gates: E2E **1633/1633**; elm-tests 13,085 passed / 12 pre-existing
failures, unchanged through a rewrite of the type checker's core.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| lane A m1 | **3:22.31** | 4,990,500 kB | 219,915,761 | 13,335.64 MB | 836 | 361,202,850 (164.2%) | 10 | 78.91 s | 12,939,423 B |
| lane A m2 | **3:24.59** | 4,831,912 kB | 219,915,596 | ≡ | 836 | 361,202,851 | 10 | 79.66 s | ≡ |
| base m1 | 3:33.38 | 5,085,100 kB | 232,557,637 | 15,167.93 MB | 862 | 372,239,194 (160.1%) | 10 | 84.61 s | ≡ |
| base m2 | 3:32.51 | 5,084,740 kB | ≡ | ≡ | 862 | ≡ | 10 | 84.17 s | ≡ |

### 2026-08-10 22:05 UTC — Run F: kernel-opt-01 `List.cons` → `eco.construct.list` (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_LIST_CONS_INTRINSIC=0` escapes**)

`plans/kernel-opt-01-list-cons-construct-list.md`: a `"List"` arm in
`kernelIntrinsic` lowers saturated `x :: xs` to `eco.construct.list`, so each cons
pays the HEAP_034 inline bump instead of a statepointed `Elm_Kernel_List_cons*`
call. **All 4,304 direct kernel cons sites convert to 0 — no declines at all**;
`= eco.construct.list ` 13,496 → 17,808 (+4,312) against `eco.call` 100,261 →
95,949 (−4,312), and the three kernel stubs leave the module. The +8 excess over
the 4,304 conversions localizes to exactly 3 functions (`…encodeEntry_$_30250` +5,
two `_tail_mono_inline_*` +2/+1) — cheaper bodies shifting inlining, 0.19%.
EcoListTemplate parity is **bit-identical** (`rewritten=444`, `unwind rewritten=38`,
`consRoots=0`, `headTy=0`, every bail counter equal), so the chunk rewriter absorbs
exactly the links it did before. Arms are one frozen 243-module corpus, `-out.mlir`
identical in both rounds **and** identical to the pre-change binary's output
(flag-off inertness, proven — see the corrected Gate 3 in the plan). Wall +0.36% ⇒
FLAT. Binary +29,008 B. Honest read: the plan called this "the highest-confidence
wall bet in the series"; ~147M dynamic kernel calls per run became inline bumps and
**the wall did not move** — the TIER pattern again.

**Allocation counters are NOT comparable across these arms** (benchmarks caveat
§18.3): the ON arm's conses take the HEAP_034 inline path, which bypasses the
per-tag tally, so `Objects allocated` 379,488,362 → 232,537,735 (−38.7%) and
`Bytes allocated` −18.1% are **counter blindness, not deleted allocation**. The
proof is that the retention counters are unmoved: `Objects promoted` 372,240,140 →
372,240,147 (+7 of 372M), minor 862 = 862, major 10 = 10. The `(160.1%)` promoted
ratio is that same shrunken denominator, not a retention change.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:33.68** | 5,141,168 kB | 232,537,735 † | 15,167.99 MB † | 862 | 372,240,147 (160.1%) | 10 | 85.96 s | 12,943,401 B |
| on r2 | **3:34.98** | 5,140,604 kB | ≡ | ≡ | 862 | ≡ | 10 | 86.38 s | ≡ |
| off r1 | 3:33.94 | 5,141,004 kB | 379,488,362 | 18,524.25 MB | 862 | 372,240,140 (98.1%) | 10 | 84.86 s | ≡ |
| off r2 | 3:33.19 | 5,141,136 kB | ≡ | ≡ | 862 | ≡ | 10 | 83.78 s | ≡ |

† inline-alloc counter blindness, see above — not an allocation reduction.

### 2026-08-10 20:36 UTC — Run E: kernel-opt-07 KernelFacts table (**FLAT — no regression; LANDED, no flag to flip**)

`plans/kernel-opt-07-kernel-facts-table.md`: `Compiler/GlobalOpt/KernelFacts.elm`
(52 rows = 48 kernel + 4 `Basics_*` ledger), `Borrow/KernelSigs.elm` demoted to a
70-line shim, 7 new elm-test suites, and the `Utils_equal` stderr trace deleted
(`Utils.cpp:557-562`). **Arms are the pre- and post-change compilers over a FROZEN
pristine source tree** (staged in scratch), so both compile byte-identical input —
and their `out.mlir` is **byte-identical in both rounds**, and byte-identical to
Run D's. That is the inertness gate the plan asks G4/G5 to carry, on all 243
modules rather than one file. Counters equal (promoted +63 of 372M); wall −1.30%,
inside the band ⇒ FLAT. Binary **+173,400 B (+0.27%)** — the table's code and
evidence strings outweigh the deleted trace, so the plan's "binary shrinks"
prediction is wrong; Stage-5 `.mlir` +20,808 B. RSS is bimodal on this workload
(~5,054 vs ~5,111 MB for the *same* binary — see Run B/C off-legs), so the −1.10%
here is lottery, not signal. Gates: E2E 1632/1632; elm-tests 13066→13073 passed
(exactly the 7 new suites), pre-existing 12 failures unchanged.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| post r1 | **3:30.70** | 5,054,148 kB | 379,488,337 | 18,524.23 MB | 862 | 372,250,180 (98.1%) | 10 | 82.46 s | 12,943,401 B |
| post r2 | **3:32.91** | 5,054,156 kB | ≡ | ≡ | 862 | ≡ | 10 | 83.92 s | ≡ |
| pre r1 | 3:34.72 | 5,110,592 kB | ≡ | 18,524.24 MB | 862 | 372,250,117 (98.1%) | 10 | 85.71 s | ≡ |
| pre r2 | 3:34.45 | 5,110,020 kB | ≡ | ≡ | 862 | ≡ | 10 | 85.67 s | ≡ |

Noise note: the `pre` arm is Run D's binary, and it measured 214.58 s here vs
211.59 s there — **+1.42% for the same binary across sessions**, which is why the
paired interleaved A/B is the comparison and Run D is only a trend line.

### 2026-08-10 19:54 UTC — Run D: loop-entry baseline (**reference point for the 14-item kernel-opt loop; not a change**)

Entry baseline for `guides/kernel-opt-loop.md`, which executes
`plans/kernel-opt-01..14`. No source change: the tree is exactly Run C's, rebuilt
from scratch with the standard track build env
(`ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_BORROW=1 ECO_AGG_PROMOTE=1`) after
deleting `bin/eco-compiler{,.mlir}` and `eco-stuff` to defeat ninja's
env-blindness; binary staged as `bin/eco-kopt-base`. It reproduces Run C: the
counters are bit-identical apart from the 1-object jitter already documented as
same-binary noise (tier2 Run O), and `out.mlir` is byte-identical at 12,943,401 B,
so the workload is unmoved. Mean wall **3:31.59** over the two rounds; the 4.67 s
spread between them is the protocol's ≈2.8% band, measured live.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| base r1 | **3:33.92** | 5,111,732 kB | 379,486,685 | 18,524.03 MB | 862 | 372,250,555 (98.1%) | 10 | 83.04 s | 12,943,401 B |
| base r2 | **3:29.25** | 5,111,812 kB | ≡ | ≡ | 862 | ≡ | 10 | 81.13 s | ≡ |

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
| D — loop-entry baseline (no change) | 3:31.59 (r1/r2 mean) | 379,486,685 obj / 18,524.03 MB |
| E — kernel-opt-07 KernelFacts table | 3:31.81 (r1/r2 mean) | 379,488,337 obj / 18,524.23 MB |
| F — kernel-opt-01 cons → construct.list | 3:34.33 (r1/r2 mean) | 232,537,735 obj / 15,167.99 MB (inline-alloc counter-blind; retention unmoved) |
| G — kernel-opt-02 union-find cell merge | **3:23.45** (m1/m2 mean, **−4.46%**) | 219,915,761 obj / 13,335.64 MB (promoted −2.96%) |
| H — kernel-opt-04 string.length inline | 3:22.75 (r1/r2 mean, −0.12% FLAT) | 219,915,775 obj / 13,335.65 MB |
