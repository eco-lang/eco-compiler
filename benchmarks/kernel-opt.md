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

### 2026-08-12 16:05 UTC — Run P: kernel-opt-13 Mono-level CSE of pure calls (**FLAT — no regression; KEPT DEFAULT-OFF, `ECO_CSE=1` enables**)

C1 census + C2 pass. **The D-C gate FAILED by a factor of 40** — `nearShareBp=5`
against a required 200 — and C2 was built and benchmarked anyway on instruction.

**The census was wrong the first time and the error is worth recording.** Its
first run reported `nearRedundant=1619 nearShareBp=109`; every `Leaf (Inline _)`
in a decider `Chain`/`FanOut` shared one path step, so two distinct occurrences
collided on one path key, their common prefix swallowed both suffixes and the
pair classified as trivially-near. The transform had the identical defect and
emitted a `MonoLet` that did not dominate its uses (`unbound variable
mono_cse_N`). Corrected: **`nearRedundant=82`, and `MonoCse` independently
reports `merged=82`** — census and transform agree exactly, which is what makes
the corrected figure trustworthy and the first one discardable.

**`b2_branch=1672` of 1,909 redundant occurrences (87.6%)** is the dominant
bucket: pairs where neither occurrence dominates, i.e. C4 speculation
territory. The probe-then-insert idiom this plan targets is close to absent
from the compiler's own source — `b1c_probe=54`.

**A second real defect the fixtures caught:** the scope test tracked `MonoLet`
and `MonoDestruct` binders but not `MonoTailDef` PARAMETERS, so a candidate
mentioning a tail-function parameter was hoisted above its binder
(`MultiLocalTailRecTest`, `lookupVar: unbound variable i`). With parameters
tracked, that group is correctly `shadowBlocked`.

**Cost/benefit is the reason it stays off.** 81 merges on the frozen corpus and
`-out.mlir` −1,052 B, against **`Objects allocated` +3,611,190 (+1.66%)** and
bytes +1.23% — the pass's own analysis cost, since it walks all 30,905 specs and
builds path keys for 69,995 candidates to find 81 merges. Wall **−1.71%** ⇒
FLAT. Gates: E2E **1646/1646** in both flag states.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:21.43** | 4,969,684 kB | 221,523,797 | 13,408.16 MB | 838 | 360,780,815 (162.9%) | 10 | 79.03 s | 12,928,998 B |
| on r2 | **3:21.20** | 4,970,400 kB | ≡ | ≡ | 838 | ≡ | 10 | 78.83 s | ≡ |
| off r1 | 3:24.39 | 4,970,448 kB | 217,912,607 | 13,245.86 MB | 836 | 360,869,914 | 10 | 80.00 s | 12,930,050 B |
| off r2 | 3:25.23 | 4,970,536 kB | ≡ | ≡ | 836 | ≡ | 10 | 80.66 s | ≡ |

### 2026-08-12 20:05 UTC — Run O: kernel-opt-11 mono DCE via KernelFacts + kernel cost classes (**FLAT — no regression; KEEP — both DEFAULT-ON, `ECO_KERNEL_FACTS_DCE=0` / `ECO_KERNEL_COST_CLASSES=0` escape**)

Two independent consumers of the kernel-opt-07 table, both in
`MonoInlineSimplify`. **(a)** `isPureExpr` generalizes to `isPureExprGen kDrop`,
so the dead-binding gate can drop a dead saturated call to a kernel the table
certifies `droppable` (`cseSafe && totality == Total`) with all args pure. The
H2.5/H6.1 partial-forward guards keep the legacy all-calls-impure predicate.
**(b)** `computeCost`'s flat 6-per-kernel-call becomes a derived `CostClass`
(`CGcLeaf`/`CAlloc`/`CHof`) plus an inline-op oracle, so an `eco.int.add` no
longer scores the same as a rope-allocating `Utils_append`.

**Census first, and it is small: the DCE widening's realizable ceiling on the
entire 261-module self-compile is FOUR sites** (`deadLets=450
deadDroppableKernelLets=4`), of which **2 realize** — `letDCE` 498 → 500,
`kernelLetDCE=2`, exactly the predicted `≤` relationship, the gap being argument
impurity. (a) therefore ships for the enabling value and for ending the
`isPureExpr`-says-impure / `CafHoist`-says-pure contradiction, **not** for a win.
**Decision D-K settled by measurement: `deadBareKernelVar = 0 / 450`**, so a bare
kernel var in value position stays impure-conservative.

**(b) does change real inlining decisions:** emitted `.mlir` +1,341 B and
`letDCE` 498 → 441 on the live self-compile. Wall FLAT.

Arms are one binary under different env (these are runtime config). **Item-10
flag-off is byte-identical to the item-09 baseline on the frozen corpus in both
rounds** — the widening is fully gated. Gates: E2E **1646/1646** in both flag
states and again after the default flip; `elm-tests` 13085 passed / 12 failed,
exactly the pre-existing baseline.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:21.32** | 4,985,552 kB | 217,912,477 | 13,245.85 MB | 836 | 360,870,804 (165.6%) | 10 | 79.07 s | 12,930,050 B |
| on r2 | **3:24.12** | 4,985,044 kB | ≡ | ≡ | 836 | ≡ | 10 | 80.61 s | ≡ |
| off r1 | 3:22.47 | 4,916,816 kB | 217,944,793 | 13,246.63 MB | 836 | 360,789,971 | 10 | 79.48 s | 12,928,709 B |
| off r2 | 3:20.72 | 4,981,396 kB | 217,944,629 | 13,246.62 MB | 836 | 360,789,973 | 10 | 78.84 s | ≡ |
| base r1 † | 3:24.26 | 4,882,412 kB | 217,928,795 | 13,246.14 MB | 836 | 361,232,810 | 10 | 79.95 s | ≡ |
| base r2 † | 3:23.20 | 4,882,936 kB | ≡ | ≡ | 836 | ≡ | 10 | 79.12 s | ≡ |

† item-09 baseline binary, same frozen corpus. on vs off **+0.56%**, off vs base
**−1.05%**, on vs base **−0.50%** — all FLAT.

### 2026-08-12 14:20 UTC — Run N: kernel-opt-09 gc-leaf safepoint relaxation + inline-group split (**FLAT — no regression; KEEP — both DEFAULT-ON, `ECO_GCPREPARE_LEAF_SAFEPOINT=0` / `ECO_GCPREPARE_SPLIT_INLINE_GROUPS=0` escape**)

Two surviving phases of a plan whose headline transform the census killed.
**Phase 3:** a new module pass `EcoMarkGCLeafCalls` copies `eco.gc_leaf` from the
kernel decl onto each direct `eco.call` as `eco.callee_gc_leaf`, and
`EcoGCPrepare` stops treating those calls as safepoints. **Phase 2-pre:** a run
of adjacent allocations whose members each have a call-free HEAP_034 inline
lowering is no longer grouped — grouping such a run costs an out-of-line
`eco_gc_alloc_region_fast` plus one `eco_init_*_at` per member where the
ungrouped form makes no calls at all.

**Phases 2 / 2A / 2B DROPPED** on the census: of 2,145 crossable merge windows,
**2,105 (98.1%) are blocked by a real intra-group SSA dependency** and
`mergeableLeaf` was **exactly 0** — the gc-leaf fact unlocks no merge anywhere in
the module. Design-doc §8 row 3's "two diamonds where one sufficed, split by an
opaque kernel call" does not hold on this tree.

**Phase 3 is byte-identical by construction and was gated as such:** with split
forced off in both arms, the produced `eco-compiler` is **identical** with the
relaxation on and off. Its effect is MLIR-analysis-only — safepoints
154,323 → 153,525 (**−798**, exactly the stamped-call count) and root operands
527,779 → 525,246 (**−2,533**), all of which were discarded at lowering anyway.
0.52% of one pass; it lands because it is free, not because it is big.

**Phase 2-pre carries the whole measurable delta:** 1,385 groups covering 2,788
objects stop being grouped, deleting **1,385 region calls + 2,788 init calls**.
Binary **−25,304 B (−0.039%)**, split `.text` **+16,192** / `.llvm_stackmaps`
**−40,104** — more inline code, but 1,385 fewer statepointed region diamonds.

**Counter note — the allocation drop is HEAP_034 counter blindness, not deleted
allocation.** `Objects allocated` −1,838,862 (−0.84%) and `Bytes allocated`
−85.18 MB (−0.64%) are the 2,788 sites moving from the *counted* region path to
the *uncounted* inline bump. `Objects promoted` moved by **+8 in 361 million**
and minor/major cycles are identical at 836/10 — retention is untouched, so no
real allocation was removed. Same lesson as Run F.

Wall **−0.23%** ⇒ FLAT. `-out.mlir` byte-identical in both rounds. Gates: E2E
**1643/1643** default-on and again with both kill switches; item-09-all-off
build byte-identical to the pre-item-09 `eco-compiler`.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:22.92** | 4,903,096 kB | 217,928,793 | 13,246.14 MB | 836 | 361,232,810 (165.8%) | 10 | 79.62 s | 12,928,709 B |
| on r2 | **3:22.68** | 4,903,332 kB | ≡ | ≡ | 836 | ≡ | 10 | 79.51 s | ≡ |
| off r1 | 3:22.85 | 4,887,696 kB | 219,767,655 | 13,331.32 MB | 836 | 361,232,802 | 10 | 79.84 s | ≡ |
| off r2 | 3:23.70 | 4,888,028 kB | ≡ | ≡ | 836 | ≡ | 10 | 80.03 s | ≡ |

### 2026-08-12 08:33 UTC — Run M: kernel-opt-08 kernel `eco.gc_leaf` stamp (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_KERNEL_GCLEAF_EMIT=0` / backend `ECO_KERNEL_GCLEAF=0` escape**)

Every kernel whose `KernelFacts` row is `gcLeafEligible` (14 rows, `gcAlloc =
GcNone` and no call back into Elm) gets an `eco.gc_leaf` UnitAttr on its
`func.func` decl; `KernelFuncOpLowering` reflects that into
`passthrough = ["gc-leaf-function"]` so RS4GC skips statepointing the call
sites. Eligibility is carried on `KernelDeclInfo` from the
`KernelInstanceKey` — never reverse-parsed from the symbol — and OR-merged in
`insertKernelDecl`. gc-leaf is the only attribute such a decl may hold
pre-RS4GC (REP_LLVM_002), so the fixture's negative CHECKs are load-bearing.

**Arms differ in how each binary was COMPILED, not in what it emits:**
`eco-k08-on` was built by a compiler run with the flag on, so its own call
sites are de-statepointed. Both then compile the frozen corpus with the flag
off, and `-out.mlir` is byte-identical in both rounds — the self-consistency
check still holds. Wall **−1.25%** ⇒ FLAT. Gates: E2E **1643/1643** in both
flag states.

**Coverage (`ECO_GCFREE_LEAF=c` on the same Stage-5 module):** 3,688 → 3,709
GC-free functions (of 87,327) and **11,950 → 14,173 de-statepointed direct
call sites (+2,223, +18.6%)**. Binary **−287,952 B (−0.439%)**, of which
`.llvm_stackmaps` is −284,976 B and `.text` only −2,064 B — 99.0% metadata,
which is precisely why the wall is flat.

**10 of the 14 eligible kernels are actually stamped**, and the four absentees
are this series eating its own seed corn: `Utils_equal`/`Utils_notEqual` no
longer have stubs (Run K routed all 1,452 sites through `eco.value.eq`),
`String_length` likewise (Run H), and `Utils_le` has zero sites (Run J).

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:21.84** | 4,903,404 kB | 219,767,579 | 13,331.32 MB | 836 | 361,232,812 (164.4%) | 10 | 78.37 s | 12,928,651 B |
| on r2 | **3:25.39** | 4,903,112 kB | ≡ | ≡ | 836 | ≡ | 10 | 81.69 s | ≡ |
| off r1 | 3:27.32 | 4,929,412 kB | 219,767,740 | 13,331.33 MB | 836 | 361,232,748 | 10 | 81.12 s | ≡ |
| off r2 | 3:25.08 | 4,908,216 kB | 219,767,582 | 13,331.32 MB | 836 | 361,232,804 | 10 | 80.95 s | ≡ |

### 2026-08-12 04:10 UTC — Run L: kernel-opt-03 `ECO_VALUE_EQ_STRCASE` (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_VALUE_EQ_STRCASE=0` escapes**)

Closes the one switch Run K shipped unmeasured. Under `ECO_VALUE_EQ_STRCASE` the
two SYNTHESIZED string-`case` sites — the SCF if-chain
(`EcoControlFlowToSCF.cpp`) and the LLVM-level `lowerStringCase`
(`EcoToLLVMControlFlow.cpp`) — emit `eco.value.eq` instead of a boxed
`Elm_Kernel_Utils_equal` call plus a True-word decode. Both halves must be
switched together, which is why one flag drives both. Flag-off also keeps
`ensureEqualDeclared` so no dead `func.func` stub is left behind flag-on.

**Backend-only flag, so this is the cheap A/B shape:** both arms are one Stage-5
`.mlir` lowered twice, differing only by the env var at lowering time — no
compiler rebuild, no `.mlir` regeneration. `-out.mlir` byte-identical in both
rounds. Wall **−0.22%** ⇒ FLAT (−0.34% excluding the off-r1 outlier). Binary
**+8,168 B**. Gates: E2E **1642/1642** default-on and again with the kill switch.

**Counter note:** `off r1` is a GC-trigger-lottery outlier — 819 minor cycles and
+520K promoted against 836 / 361,223,669 on the other three legs, which agree
bit-for-bit. Majors are 10 everywhere. The delta is FLAT under either reading.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:24.77** | 4,903,004 kB | 219,818,080 | 13,332.69 MB | 836 | 361,223,669 (164.3%) | 10 | 80.82 s | 12,933,089 B |
| on r2 | **3:23.02** | 4,903,416 kB | ≡ | ≡ | 836 | ≡ | 10 | 79.21 s | ≡ |
| off r1 † | 3:24.10 | 4,923,064 kB | 219,829,162 | 13,333.52 MB | 819 | 361,743,676 (164.6%) | 10 | 80.47 s | ≡ |
| off r2 | 3:24.59 | 4,884,536 kB | 219,818,084 | 13,332.69 MB | 836 | 361,223,669 | 10 | 80.72 s | ≡ |

† GC-trigger lottery, see above — not an effect of the flag.

### 2026-08-12 01:30 UTC — Run K: kernel-opt-03 `eco.value.eq` emission (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_VALUE_EQ=0` escapes**)

`plans/kernel-opt-03-value-eq-fastpath.md` Phases 1/3/4/6, completing the item
(Phase 2 landed earlier; Phase 5 was closed by kernel-opt-06's 64-site residue).
Boxed structural equality now emits `eco.value.eq`, which expands pre-RS4GC into
word-equality → embedded-constant test → gc-leaf kernel call decoded against the
True word. **Emission: `Utils_equal` 1392→0 and `Utils_notEqual` 60→0 against
`eco.value.eq` +1452 — 100% conversion, exact 1:1.**

Wall **−1.84%**: directionally good but **inside the ±2.8% band, so recorded
FLAT**, not a win. That is consistent with the Phase-0 census, which measured the
inline arms at only 6.47% of non-Bool traffic — most of the 1,452 sites still
reach arm 3 and pay the call. Counters identical, `-out.mlir` byte-identical both
rounds.

`Elm_Kernel_Utils_equal`'s declaration now carries `gc-leaf-function` (Phase 4):
kernel-opt-07 recorded it as one of the A1 stampable 14 and deleted the stderr
trace that was its last observable effect. `CGEN_076` records the whole contract.
Gates: E2E **1642/1642 in ALL THREE switch states** (off; `ECO_VALUE_EQ=1`;
`ECO_VALUE_EQ=1 ECO_VALUE_EQ_STRCASE=1`) and again default-on.

**Not measured:** `ECO_VALUE_EQ_STRCASE` ships **default-off** — the two
synthesized string-`case` sites are implemented and proven correct, but no wall
A/B was run for them, so they must not be defaulted on without one.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:22.93** | 4,894,736 kB | 219,818,234 | 13,332.70 MB | 836 | 361,223,661 (164.3%) | 10 | 79.47 s | 12,933,089 B |
| on r2 | **3:20.32** | 4,888,020 kB | 219,818,067 | 13,332.69 MB | 836 | 361,223,662 | 10 | 78.44 s | ≡ |
| off r1 | 3:25.29 | 4,884,248 kB | 219,818,070 | 13,332.70 MB | 836 | 361,223,654 | 10 | 80.93 s | ≡ |
| off r2 | 3:25.54 | 4,884,284 kB | ≡ | ≡ | 836 | ≡ | 10 | 81.05 s | ≡ |

### 2026-08-11 21:15 UTC — Run J: kernel-opt-06 String ordering → `eco.string.cmp3` (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_STRING_ORDER_INTRINSIC=0` escapes**)

`plans/kernel-opt-06-string-ordering-cmp3.md`. `<`/`<=`/`>`/`>=` on two Strings
now emit `eco.string.cmp3` plus ONE signed test against 0, replacing a boxed
`Elm_Kernel_Utils_{lt,le,gt,ge}` call whose `HPtr` Bool was immediately
`eco.unbox`-ed. Phase-0 reproduced the recorded baseline exactly (lt 79 / le 0 /
gt 40 / ge 2). **Emission: lt 79→14, gt 40→10, ge 2→2, cmp3 1→96 — 95
conversions, 95 new ops, exact 1:1**, inside the plan's predicted 95–100 range.
The sign is UNCLAMPED, so the test is against 0 and must be SIGNED; CGEN_075
gains clause (f) recording that, since an unsigned predicate would read −1 as a
huge positive and invert every answer.

Wall **−0.34%** ⇒ FLAT, as the plan predicted in bold — it is the fourth
compare-family deletion to measure flat, and it changes no retention: the boxed
Bool it removes was an embedded HPointer constant that never allocated.
Counters identical, `-out.mlir` byte-identical both rounds. Gates: E2E
**1639/1639 in BOTH flag states** and again default-on; elm-tests 13,085 / 12.

**Owed to kernel-opt-03:** the surviving boxed comparison population is now
**64 sites** (lt 14, le 0, gt 10, ge 2, compare 38) — well under the >200
threshold 03's Phase 5 is gated on, so **that phase must not execute**.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:22.94** | 4,888,716 kB | 219,817,471 | 13,332.69 MB | 836 | 361,224,067 (164.3%) | 10 | 79.84 s | 12,932,396 B |
| on r2 | **3:23.55** | 4,888,488 kB | ≡ | ≡ | 836 | ≡ | 10 | 80.26 s | ≡ |
| off r1 | 3:24.86 | 4,887,332 kB | 219,817,640 | 13,332.70 MB | 836 | 361,224,058 | 10 | 79.80 s | ≡ |
| off r2 | 3:23.02 | 4,888,656 kB | 219,817,474 | 13,332.69 MB | 836 | 361,224,059 | 10 | 79.50 s | ≡ |

### 2026-08-11 17:40 UTC — Run I: kernel-opt-05 `Utils_append` type split (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_APPEND_SPLIT=0` escapes**)

`plans/kernel-opt-05-utils-append-type-split.md` Phases 1a/1b/3. `++` at mono
sites that statically know the operand type now emits typed `eco.string.append` /
`eco.list.append` instead of the polymorphic `Elm_Kernel_Utils_append`, which
re-derives the type at runtime from two tag loads and silently returns its first
argument for any pair it does not recognise. **3,468 sites → 67, and the split
reconciles exactly: 2,695 string + 706 list = 3,401 displaced (98.1%).** The 67
residue is the `MVar`-operand population falling through `utilsIntrinsic`'s final
wildcard, as designed.

Wall **+0.80%** ⇒ FLAT, which is what §Expected impact predicted ("the deleted
per-call dispatch is a handful of loads and branches, so wall could well be
flat"). Counters identical, `-out.mlir` byte-identical both rounds. The purchase
the plan actually claims is IR size, and it is real but small: Stage-5 `.mlir`
**−6,773 B (−0.05%)** from the `eco.call` root tails that leave the IR. Both ops
are deliberately trait-free and appear in none of EcoGCPrepare's four lists —
they allocate variable-size results, so RS4GC statepoints the lowered calls and
attaches roots from its own liveness. Phase 3 also filled the `(Utils, append)`
borrow axes as `POwned/POwned` + `resultAliases = [0,1]` (OWNER over both string
and list — the borrow upside is FALSE, per the census correction), which required
growing kernel-opt-07's golden from 33 to 34 rows in the same change. Gates: E2E
**1638/1638 in BOTH flag states** and again default-on; elm-tests 13,085 / 12.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:24.48** | 4,888,560 kB | 219,913,079 | 13,335.56 MB | 836 | 361,202,876 (164.2%) | 10 | 79.77 s | 12,939,141 B |
| on r2 | **3:25.65** | 4,888,684 kB | ≡ | ≡ | 836 | ≡ | 10 | 80.39 s | ≡ |
| off r1 | 3:24.26 | 4,901,736 kB | 219,913,243 | 13,335.57 MB | 836 | 361,202,867 | 10 | 79.11 s | ≡ |
| off r2 | 3:22.62 | 4,903,676 kB | 219,913,082 | 13,335.56 MB | 836 | 361,202,868 | 10 | 78.97 s | ≡ |

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
| I — kernel-opt-05 append type split | 3:25.07 (r1/r2 mean, +0.80% FLAT) | 219,913,079 obj / 13,335.56 MB |
| J — kernel-opt-06 String ordering cmp3 | 3:23.25 (r1/r2 mean, −0.34% FLAT) | 219,817,471 obj / 13,332.69 MB |
| K — kernel-opt-03 eco.value.eq emission | 3:21.63 (r1/r2 mean, −1.84% FLAT) | 219,818,234 obj / 13,332.70 MB |
| L — kernel-opt-03 STRCASE synthesized sites | 3:23.90 (r1/r2 mean, −0.22% FLAT) | 219,818,080 obj / 13,332.69 MB |
| M — kernel-opt-08 kernel gc-leaf stamp | 3:23.62 (r1/r2 mean, −1.25% FLAT) | 219,767,579 obj / 13,331.32 MB (+2,223 de-statepointed sites; binary −287,952 B) |
| N — kernel-opt-09 leaf safepoints + inline-group split | 3:22.80 (r1/r2 mean, −0.23% FLAT) | 217,928,793 obj / 13,246.14 MB (counter-blind; retention unmoved. −798 safepoints, −4,173 out-of-line calls; binary −25,304 B) |
| O — kernel-opt-11 mono DCE + kernel cost classes | 3:22.72 (r1/r2 mean, −0.50% vs base FLAT) | 217,912,477 obj / 13,245.85 MB (DCE ceiling 4 sites, 2 realized; cost classes move inlining, .mlir +1,341 B) |
| P — kernel-opt-13 Mono CSE (default-OFF) | 3:21.32 (r1/r2 mean, −1.71% FLAT) | 221,523,797 obj / 13,408.16 MB (**+1.66% — the pass's own analysis cost**; 81 merges, .mlir −1,052 B; D-C gate failed 40×) |
