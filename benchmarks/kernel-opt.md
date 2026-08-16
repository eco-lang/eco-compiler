# Kernel Opt Track — Stage-7a Cold-Cache Benchmarks

Tracks the wall/RSS/allocation impact of the kernel-boundary optimization
track (`design_docs/kernel-boundary-reduction.md`;
`plans/string-cmp-order-intrinsic-and-postmono-compare-rewrite.md` and
successors — deleting opaque kernel calls and the work they carry) on the
standard bootstrap workload. Append one labelled section per run.

---

## Recording instructions (fixed — keep every entry uniform)

**Entry shape (fixed):** heading, then the results table(s), then **at most 10 lines**
of prose. Nothing else — no preamble above the table, no appendices below the prose.

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

**READ THE SUMMARY TABLE DOWN A COLUMN AT YOUR PERIL.** Its wall column is
comparable ACROSS ROWS only while the workload is unchanged, and the workload is
**the compiler's own source** — so any item that adds compiler source enlarges it
and shifts the absolute wall for every later run. The per-run `out.mlir` byte size
is the tell, and it is deliberately NOT in this table; it lives in each run entry.
Run T is the worked example: its 3:48 against Run R's 3:24 is corpus growth
(+271,895 B of emitted MLIR since Run S, most of it predating Run T), not a
regression — a control run of a binary containing NONE of Run T's change scored
3:57.96 on the same corpus. **Compare walls only within a run, arm against arm,
after confirming `out.mlir` matches.**

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

### 2026-08-13 — DONE: kernel-opt series close-out (bootstrap fixed point + cumulative A/B + dynamic re-census)

| | Run D (2026-08-10) | final (2026-08-13) | Δ |
|---|---|---|---|
| wall | 3:31.59 | **3:23.96** | **−3.6%** |
| objects allocated | 379,486,685 | 217,958,017 | −42.6% |
| promoted | 372,250,555 | 360,871,768 | **−3.1%** |
| minor / major GC | 862 / 10 | 836 / 10 | −26 / = |
| out.mlir | 12,943,401 B | 12,933,556 B | −9,845 B |

| axis | before | after |
|---|---|---|
| dynamic kernel calls | 3,676,097,627 | **390,926,633 (−89.4%)** |
| kernel symbols | 98 | 88 |
| static direct sites | — | 6,574 |

14 items executed: 10 KEPT-ON, 1 REAL WIN (02, −4.46%), 2 KEPT-DARK (13 census-failed,
10 correctness-blocked on NaN sharing), 1 REJECTED (14, Run S). `--target bootstrap`
converges to a NEW fixed point (Stage 8c byte-identical; JS stages 7,300,241 B). The
cumulative allocation figure is partly HEAP_034 counter-blindness. The r1 leg (3:35.24)
overlapped the bootstrap build and is contention-contaminated; r2 is quoted. Residue map:
`Utils_equal` 252.6M (64.6%), `List_reverse` 44.0M, `array_push_box` 32.5M, then the fold
HOF band. Gates: E2E 1656/1656, elm-tests 13085/12. **Heap-validate was never built this
loop** — that debt stands. Lessons: wall follows retention and deleted per-op work, never
call counts; counters convict where walls stay silent; censuses must be verified against
their own transform; allocation dedup is observable through NaN × pointer-equality.

### 2026-08-16 05:20 UTC — Run V: map-template round 2, G-0…G-3 (**FLAT — no regression; KEPT-DARK, `ECO_LIST_MAP_TEMPLATE=1` enables**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **4:03.79** | 5,330,112 kB | 237,455,932 | 14,521.69 MB | 915 | 431,019,109 (181.5%) | 12 | 104.41 s | 13,249,278 B |
| on r2 | **4:02.94** | 5,330,000 kB | ≡ | ≡ | 915 | ≡ | 12 | 104.15 s | ≡ |
| off r1 | 4:02.01 | 5,272,368 kB | 227,290,386 | 14,211.45 MB | 914 | 427,179,257 (187.9%) | 12 | 104.56 s | ≡ |
| off r2 | 4:01.20 | 5,272,396 kB | ≡ | ≡ | 914 | ≡ | 12 | 104.22 s | ≡ |

| axis | on | off | Δ |
|---|---|---|---|
| binary | 64,847,536 B | 66,497,048 B | **−1,649,512 B (−2.48%)** |
| licensed map specs | 297 / 592 | 0 | +297 |
| `Cons` allocated | 52,342,739 | 48,785,794 | +7.3% |
| `ConsChunk` allocated | 14,130,511 | 7,876,357 | +79.4% |

`plans/list-map-mlir-template.md` G-0…G-3: licensed **58 → 297 of 592** (G-1 generic-apply
+15, G-2 `CsePurity` ctor/enum seed +61, G-3 `OriginGlobal`→SpecId +163); G-0 was a
measurement-only counter split that sized the other three. Wall **+0.74%** ⇒ FLAT. The
binary credit scales with the pool — −291,816 B at 50 specs (T), −325,912 B at 58 (U),
−1,649,512 B at 297 — ≈5,500 B per spec, flat across a 6× change. The allocation column is
HEAP_034 counter-blindness at 5× Run T's scale, as the two `Cons*` rows show; the
blind-free axes are flat (promotion +0.90%, minors +1, majors equal, GC −0.14%). The
`ECO_INLINE_ALLOC=0` legs that would adjudicate it were **not run**, so +4.47% objects is
un-adjudicated, not a regression. Gates: E2E 1,675/1,675 both flag states, `ECO_CSE=1`
1,675/1,675, elm-tests 13,085/12, default-config artifacts byte-identical to pre-G.

### 2026-08-14 21:40 UTC — Run U: map-template follow-ups F-1L…F-5C (**FLAT — no regression; KEPT-DARK, `ECO_LIST_MAP_TEMPLATE=1` enables**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:54.43** | 5,523,668 kB | 227,631,274 | 14,185.38 MB | 913 | 416,654,491 | 11 | 98.14 s | 13,244,058 B |
| on r2 | **3:52.18** | 5,523,296 kB | — † | — † | — † | — † | — † | — † | ≡ |
| off r1 | 3:53.63 | 5,526,188 kB | 226,690,246 | 14,143.22 MB | 914 | 417,381,243 | 11 | 96.87 s | ≡ |
| off r2 | 3:56.54 | 5,526,484 kB | — † | — † | — † | — † | — † | — † | ≡ |

† r2 GC dumps were not retained for this run; wall and RSS are per-round. Binary: on
66,092,112 B, off 66,418,024 B (**−325,912 B**).

**F-2A budget sweep** (ten flag-off Stage-5 legs on the frozen post-F-5 tree; flag-on legs
for the licence pool):

| N | wall r1 / r2 | mean | Δ vs 64 | artifact B | binary B | Δ binary | recognized `map` | licensed |
|---|---|---|---|---|---|---|---|---|
| **64** | 6:56.03 / 7:36.10 | 436.1 s | — | 13,710,047 | 66,418,024 | — | 592 | **58** |
| 128 | 7:45.48 / 7:31.45 | 458.5 s | +5.1% | 13,904,958 | 66,991,792 | +0.86% | 599 | 61 |
| 256 | 7:45.73 / 7:49.54 | 467.6 s | +7.2% | 14,152,621 | 67,464,104 | +1.57% | 625 | 69 |
| 512 | 7:38.76 / 7:54.21 | 466.5 s | +7.0% | 14,384,050 | 68,200,968 | +2.68% | 678 | — |
| 1024 | 7:43.42 / 7:40.85 | 462.1 s | +6.0% | 14,650,323 | 69,311,736 | +4.36% | 813 | 143 |

Licence pool **50 → 58 of 592**: F-4's argument-taint rule REMOVED 2 (a live D-4a hole —
captured function values laundered through `List.any`/`List.sortWith`), F-3 recovered 0,
F-5A+F-5B's ctor-as-callback arm ADDED 9. Wall **−0.76%** ⇒ FLAT; reads exactly like Run T
one item bigger, same counter-blind allocation column, retention unmoved. The sweep's knee
rule selects **N = 64, the incumbent**, so `maxSpecsPerGlobal` does not move (64→128 buys 3
sites for +0.86% binary). **Its wall column is not usable** — the r1/r2 spread within N=64
is 40.1 s (9.2%), wider than the ±5% band the rule tests, and the trend is non-monotone;
binary size is the decisive axis. F-4 makes a default-ON decision arguable, but its recorded
residual (a closure in a concrete custom-type field) wants the purity plan first.

### 2026-08-14 09:05 UTC — Run T: `List.map` forward MLIR template (**FLAT — no regression; KEPT-DARK, `ECO_LIST_MAP_TEMPLATE=1` enables**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:48.37** | 5,347,008 kB | 228,050,612 | 14,062.57 MB | 900 | 407,138,781 (178.5%) | 11 | 93.90 s | 13,205,451 B |
| on r2 | **3:49.17** | 5,344,992 kB | 228,050,449 | 14,062.57 MB | 900 | 407,138,782 | 11 | 94.97 s | ≡ |
| off r1 | 3:52.89 | 5,459,500 kB | 225,154,129 | 13,956.70 MB | 900 | 407,074,509 (180.8%) | 12 | 98.94 s | ≡ |
| off r2 | 3:54.21 | 5,459,824 kB | ≡ | ≡ | 900 | ≡ | 12 | 100.02 s | ≡ |

**`ECO_INLINE_ALLOC=0` census legs** (both Stage-5 artifacts re-lowered with the
inline-alloc path off — the only allocation column here that means anything):

| leg | objects alloc'd | bytes alloc'd | `Cons` alloc'd | `ConsChunk` alloc'd | `Cons` promoted | minor GC |
|---|---|---|---|---|---|---|
| on | 4,037,332,291 | 160,674.08 MB | **410,390,748** | **10,648,356** | 149,907,357 | 900 |
| off | 4,040,422,326 | 160,706.56 MB | **416,225,020** | **7,857,203** | 149,910,075 | 900 |

**Corpus-growth control** (same pristine binary carrying none of this item, two corpora):

| corpus | out.mlir | wall | minor GC | major GC | promoted |
|---|---|---|---|---|---|
| pristine | 13,161,408 B | 3:31.13 | 865 | 10 | 374,827,174 |
| current | 13,205,451 B | **3:57.96** | 900 | 12 | 407,132,733 |

A licensed `List.map` spec's body becomes one `eco.list.map` op — forward cursor loop,
devirtualized callback, scratch pushes, one `eco_scratch_finish_fwd`. **50 of 591 specs
qualify (8.5%)**; 425 decline on LTop callback sets. Wall **−2.05%** ⇒ FLAT, binary
**−291,816 B**. The standard allocation column is counter-blind in the *unfavourable*
direction (+1.29% objects); the census legs give the truth — `Cons` −1.40%, `ConsChunk`
+35.5%, net −3,090,035 objects — but `Cons` promoted moved −0.002% with minors identical, so
the deleted cons died in the nursery. **Absolute wall is NOT comparable to Runs A–S**: the
workload is the compiler's own source and this item grew it (+271,895 B since Run S, of which
+227,852 predates the item); on the current corpus ON 3:48.4 < OFF 3:52.9 < pristine 3:58.0.
Gates: E2E 1664/1664 all three flag states, heap-validate flag-on, bootstrap 8c identical.

### 2026-08-13 22:30 UTC — Run S: kernel-opt-14 Elm-source List HOFs (**REJECTED — the loop's first true counter regression; kernels stay C++**)

| arm | own-code migration | objects | RSS | majors | wall |
|---|---|---|---|---|---|
| base (item-13 binary) | none | 218.0M | 4.98 GB | 10 | 3:23.4 |
| P1 workload-only (env off) | none (emission only) | 218.0M | 4.98 GB | 10 | 3:23.6 |
| P1 in-binary (flip, stock core) | reverse | 209.0–210.3M | 4.7–5.1 GB † | **11–12** | 3:30.8–3:40.3 † |
| mapN-only binary | reverse+mapN | **353.2–354.6M** | 5.6–5.8 GB | 10 | 3:36.0–3:36.6 |
| sorts-only binary | reverse+sorts | **353.5–354.9M** | 5.6 GB | 10 | 3:35.0–3:36.4 |
| full binary | all | **352.8–354.6M** | 5.6 GB | 10 | 3:32.9–3:37.7 |

† bimodal / GC-lottery legs; the majors movement is the stable signal.

The full ladder was built and measured: P1 (un-shunt `List.reverse`), 2A (elm/core overlay), P3
(`map2..map5` in Elm), P4 (`sortBy`/`sortWith` as a stable Elm merge sort). **Correctness was
never the problem** — E2E 1656/1656 under the full migration, and the chunk hard-gate IMPROVED
(`rewritten` 446→518, all List HOF kernel callee counts → 0). The rejection is entirely the
counters: ConsChunk **6.2M → 146.3M (+4.3 GB)** plus ListBacking +2.8M, because the Elm idioms
multiply whole-list materializations (`mapNHelp` builds then reverses; the merge sort materializes
per level; `sortBy` decorates) where the C++ kernels built each result once. Objects +61.6%, bytes
+35.8%, RSS +13%, wall +2.9–3.7%. **Non-additivity was the tell** (mapN-only ≈ sorts-only ≈ full ≈
354M): the cost is the shared idiom, not any one function. The `shuntReverse` machinery and 2A
overlay survive; no kernel symbol was deleted.

### 2026-08-13 14:30 UTC — Run R: kernel-opt-12 `eco.cse_safe` purity channel (**attr FREE in both CSE states — KEEP DEFAULT-ON, `ECO_CALL_PURITY=0` escapes; CSE flip attempted and REVERTED**)

| arm | exe | wall (mean) | promoted | minor GC |
|---|---|---|---|---|
| CSE off, no attr | 65,776,800 | 3:25.37 | 360,869,913 | 836 |
| CSE off, **attr** | **byte-identical** | 3:24.85 | ≡ | ≡ |
| CSE on, no attr | 65,482,112 | 3:23.29 | 357,228,556 | 834 |
| CSE on, **attr** | 65,465,728 | 3:24.17 | **≡ (bit-identical)** | 834 |

The purity channel end to end: KernelFacts `droppable` emission, `MemoryEffectOpInterface` on
`Eco_CallOp`, verifier arms, the EcoGCPrepare Step-4 strip. Coverage **S = 4,330 stamped sites**
of 85,437 `eco.call`, ~6,500 below prediction because items 01/03/05 had already deleted the top
contributors. **The attr's marginal contribution is ~zero in BOTH states**: CSE-off
byte-identical, CSE-on −16,384 B with bit-identical counters. CSE's retention effect swings SIGN
with the artifact (+5.6M in Run Q, −3.64M here). **The CSE default-on flip was REVERTED** — 3
Float container-equality tests failed: CSE merges two NaN-containing constructs into one object,
and the equality kernel's pointer-eq fast path answers True before the NaN-aware walk. Object
identity IS observable through NaN (CSE_001). The env-var legs had only run the codegen subset;
the Float tests are Elm-side.

### 2026-08-13 08:40 UTC — Run Q: kernel-opt-10 MLIR project-of-construct folder + M4 CSE (**folder KEEP DEFAULT-ON, `ECO_MLIR_FOLD=0` escapes; CSE KEPT-DARK**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| fold r1 | **3:38.92** | 4,781,228 kB | 217,956,881 | 13,247.64 MB | 819 | 358,417,886 (164.4%) | 10 | 82.82 s | 12,930,050 B |
| fold r2 | **3:34.51** | 4,781,496 kB | ≡ | ≡ | 819 | ≡ | 10 | 80.85 s | ≡ |
| off r1 | 3:35.49 | 4,791,372 kB | 217,957,046 | 13,247.64 MB | 819 | 358,417,885 | 10 | 81.27 s | ≡ |
| off r2 | 3:34.65 | 4,762,256 kB | ≡ | ≡ | 819 | ≡ | 10 | 80.31 s | ≡ |
| cse r1 † | 3:36.59 | 4,804,268 kB | 217,942,537 | 13,247.20 MB | 822 | 358,455,269 | **11** | 82.91 s | ≡ |
| both r1 † | 3:40.87 | **5,106,176 kB** | 217,942,523 | 13,247.20 MB | 820 | **364,019,657** | **11** | 86.77 s | ≡ |

† one representative round; both r2 / cse r2 agree bit-for-bit on counters.

Backend-only item: (1) `EcoFoldProject`, seven `fold()` impls, and (2) stock MLIR
`createCSEPass()` — the first consumer the dialect's 102 `[Pure]` declarations ever had.
**The A/B split the item in half.** Folder-only: counters bit-equal to off (promoted +1 in
358M), 2,382 folds, exe −4,096 B. **CSE regressed retention ON THIS ARTIFACT**: promoted
+1.56%, RSS +330 MB, majors 10 → 11, wall +2.66%. **AMENDED by Run R: that is a property of
the item-11-era artifact, not the switch** — the same composition on the item-13 artifact
measures promoted −3.64M. Both are bit-stable, so neither is noise; the sign swings with the
artifact, wall FLAT in both worlds. A later default-on attempt was reverted for correctness
(Run R). Two real bugs found: a latent `EcoListCursor` `hasOneUse`-per-RESULT dangle (SEGV,
un-triggerable before a dedup pass) and two fixtures pinning now-folded projections.

### 2026-08-12 20:05 UTC — Run P: kernel-opt-13 Mono-level CSE of pure calls (**FLAT — no regression; KEPT DEFAULT-OFF, `ECO_CSE=1` enables**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:21.43** | 4,969,684 kB | 221,523,797 | 13,408.16 MB | 838 | 360,780,815 (162.9%) | 10 | 79.03 s | 12,928,998 B |
| on r2 | **3:21.20** | 4,970,400 kB | ≡ | ≡ | 838 | ≡ | 10 | 78.83 s | ≡ |
| off r1 | 3:24.39 | 4,970,448 kB | 217,912,607 | 13,245.86 MB | 836 | 360,869,914 | 10 | 80.00 s | 12,930,050 B |
| off r2 | 3:25.23 | 4,970,536 kB | ≡ | ≡ | 836 | ≡ | 10 | 80.66 s | ≡ |

C1 census + C2 pass. **The D-C gate FAILED by 40×** (`nearShareBp=5` against a required 200)
and C2 was built and benchmarked anyway on instruction. **The census was wrong the first
time**: every `Leaf (Inline _)` in a decider shared one path step, so two occurrences collided
on one key — reported `nearRedundant=1619`, corrected to **82**, which `MonoCse` independently
confirms as `merged=82`; the transform had the identical defect and emitted a non-dominating
`MonoLet`. `b2_branch=1672` of 1,909 redundant occurrences (87.6%) is the dominant bucket, and
the probe-then-insert idiom is nearly absent (`b1c_probe=54`). A second defect the fixtures
caught: the scope test tracked `MonoLet` binders but not `MonoTailDef` PARAMETERS. It stays
off on cost/benefit: 81 merges and −1,052 B of `.mlir` against **objects +1.66%**, the pass's
own analysis cost over 30,905 specs. Wall −1.71% ⇒ FLAT. Gates: E2E 1646/1646 both states.

### 2026-08-12 16:05 UTC — Run O: kernel-opt-11 mono DCE via KernelFacts + kernel cost classes (**FLAT — no regression; KEEP — both DEFAULT-ON, `ECO_KERNEL_FACTS_DCE=0` / `ECO_KERNEL_COST_CLASSES=0` escape**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:21.32** | 4,985,552 kB | 217,912,477 | 13,245.85 MB | 836 | 360,870,804 (165.6%) | 10 | 79.07 s | 12,930,050 B |
| on r2 | **3:24.12** | 4,985,044 kB | ≡ | ≡ | 836 | ≡ | 10 | 80.61 s | ≡ |
| off r1 | 3:22.47 | 4,916,816 kB | 217,944,793 | 13,246.63 MB | 836 | 360,789,971 | 10 | 79.48 s | 12,928,709 B |
| off r2 | 3:20.72 | 4,981,396 kB | 217,944,629 | 13,246.62 MB | 836 | 360,789,973 | 10 | 78.84 s | ≡ |
| base r1 † | 3:24.26 | 4,882,412 kB | 217,928,795 | 13,246.14 MB | 836 | 361,232,810 | 10 | 79.95 s | ≡ |
| base r2 † | 3:23.20 | 4,882,936 kB | ≡ | ≡ | 836 | ≡ | 10 | 79.12 s | ≡ |

† item-09 baseline, same corpus. on vs off +0.56%, off vs base −1.05%, on vs base −0.50%.

Two consumers of the kernel-opt-07 table, both in `MonoInlineSimplify`. **(a)** `isPureExpr`
generalizes so the dead-binding gate can drop a dead saturated call to a `droppable` kernel
with pure args. **(b)** `computeCost`'s flat 6-per-kernel-call becomes a derived `CostClass`
plus an inline-op oracle. **Census first, and it is small: the DCE widening's ceiling on the
entire 261-module self-compile is FOUR sites**, of which 2 realize — exactly the predicted
`≤`, the gap being argument impurity. (a) ships for the enabling value and for ending the
`isPureExpr`-says-impure / `CafHoist`-says-pure contradiction, not for a win; D-K settled by
measurement (`deadBareKernelVar = 0 / 450`). (b) does change real inlining decisions: `.mlir`
+1,341 B, `letDCE` 498 → 441. Item-10 flag-off is byte-identical to the item-09 baseline.
Gates: E2E 1646/1646 both states; elm-tests 13085/12 unchanged.

### 2026-08-12 14:20 UTC — Run N: kernel-opt-09 gc-leaf safepoint relaxation + inline-group split (**FLAT — no regression; KEEP — both DEFAULT-ON, `ECO_GCPREPARE_LEAF_SAFEPOINT=0` / `ECO_GCPREPARE_SPLIT_INLINE_GROUPS=0` escape**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:22.92** | 4,903,096 kB | 217,928,793 | 13,246.14 MB | 836 | 361,232,810 (165.8%) | 10 | 79.62 s | 12,928,709 B |
| on r2 | **3:22.68** | 4,903,332 kB | ≡ | ≡ | 836 | ≡ | 10 | 79.51 s | ≡ |
| off r1 | 3:22.85 | 4,887,696 kB | 219,767,655 | 13,331.32 MB | 836 | 361,232,802 | 10 | 79.84 s | ≡ |
| off r2 | 3:23.70 | 4,888,028 kB | ≡ | ≡ | 836 | ≡ | 10 | 80.03 s | ≡ |

Two surviving phases of a plan whose headline transform the census killed. **Phase 3:**
`EcoMarkGCLeafCalls` copies `eco.gc_leaf` onto each direct call so `EcoGCPrepare` stops
treating them as safepoints. **Phase 2-pre:** a run of adjacent allocations that each have a
call-free HEAP_034 inline lowering is no longer grouped. **Phases 2/2A/2B DROPPED on the
census**: of 2,145 crossable merge windows, 2,105 (98.1%) are blocked by a real SSA
dependency and `mergeableLeaf` was **exactly 0**. Phase 3 is byte-identical by construction;
its effect is analysis-only — safepoints −798, root operands −2,533. Phase 2-pre carries the
delta: 1,385 groups stop being grouped, deleting 1,385 region + 2,788 init calls, binary
−25,304 B. **The allocation drop is counter blindness** — objects −0.84% is those sites moving
to the uncounted inline bump; promoted moved +8 in 361M. Wall −0.23% ⇒ FLAT; E2E 1643/1643.

### 2026-08-12 08:33 UTC — Run M: kernel-opt-08 kernel `eco.gc_leaf` stamp (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_KERNEL_GCLEAF_EMIT=0` / backend `ECO_KERNEL_GCLEAF=0` escape**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:21.84** | 4,903,404 kB | 219,767,579 | 13,331.32 MB | 836 | 361,232,812 (164.4%) | 10 | 78.37 s | 12,928,651 B |
| on r2 | **3:25.39** | 4,903,112 kB | ≡ | ≡ | 836 | ≡ | 10 | 81.69 s | ≡ |
| off r1 | 3:27.32 | 4,929,412 kB | 219,767,740 | 13,331.33 MB | 836 | 361,232,748 | 10 | 81.12 s | ≡ |
| off r2 | 3:25.08 | 4,908,216 kB | 219,767,582 | 13,331.32 MB | 836 | 361,232,804 | 10 | 80.95 s | ≡ |

Every kernel whose `KernelFacts` row is `gcLeafEligible` (14 rows) gets an `eco.gc_leaf`
UnitAttr on its decl; `KernelFuncOpLowering` reflects that into
`passthrough = ["gc-leaf-function"]` so RS4GC skips statepointing the call sites. Eligibility
rides on `KernelDeclInfo` from the `KernelInstanceKey`, never reverse-parsed from the symbol;
gc-leaf is the only attribute such a decl may hold pre-RS4GC (REP_LLVM_002), so the fixture's
negative CHECKs are load-bearing. Arms differ in how each binary was COMPILED, not in what it
emits. Coverage: 3,688 → 3,709 GC-free functions and **11,950 → 14,173 de-statepointed call
sites (+2,223)**. Binary **−287,952 B**, of which `.llvm_stackmaps` is −284,976 and `.text`
only −2,064 — **99.0% metadata, which is precisely why the wall is flat** (−1.25% ⇒ FLAT).
10 of the 14 eligible kernels are stamped; the absentees are Runs K, H, J eating the seed corn.

### 2026-08-12 04:10 UTC — Run L: kernel-opt-03 `ECO_VALUE_EQ_STRCASE` (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_VALUE_EQ_STRCASE=0` escapes**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:24.77** | 4,903,004 kB | 219,818,080 | 13,332.69 MB | 836 | 361,223,669 (164.3%) | 10 | 80.82 s | 12,933,089 B |
| on r2 | **3:23.02** | 4,903,416 kB | ≡ | ≡ | 836 | ≡ | 10 | 79.21 s | ≡ |
| off r1 † | 3:24.10 | 4,923,064 kB | 219,829,162 | 13,333.52 MB | 819 | 361,743,676 (164.6%) | 10 | 80.47 s | ≡ |
| off r2 | 3:24.59 | 4,884,536 kB | 219,818,084 | 13,332.69 MB | 836 | 361,223,669 | 10 | 80.72 s | ≡ |

† GC-trigger lottery — 819 minor cycles and +520K promoted against 836 / 361,223,669 on the
other three legs, which agree bit-for-bit. Majors are 10 everywhere; not an effect of the flag.

Closes the one switch Run K shipped unmeasured. Under `ECO_VALUE_EQ_STRCASE` the two
SYNTHESIZED string-`case` sites — the SCF if-chain and the LLVM-level `lowerStringCase` —
emit `eco.value.eq` instead of a boxed `Elm_Kernel_Utils_equal` call plus a True-word decode.
Both halves must be switched together, which is why one flag drives both; flag-off keeps
`ensureEqualDeclared` so no dead stub is left behind flag-on. Backend-only flag, so this is
the cheap A/B shape: one Stage-5 `.mlir` lowered twice, no compiler rebuild. Wall −0.22% ⇒
FLAT (−0.34% excluding the off-r1 outlier). Binary +8,168 B. `-out.mlir` byte-identical in
both rounds. Gates: E2E 1642/1642 default-on and again with the kill switch.

### 2026-08-12 01:30 UTC — Run K: kernel-opt-03 `eco.value.eq` emission (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_VALUE_EQ=0` escapes**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:22.93** | 4,894,736 kB | 219,818,234 | 13,332.70 MB | 836 | 361,223,661 (164.3%) | 10 | 79.47 s | 12,933,089 B |
| on r2 | **3:20.32** | 4,888,020 kB | 219,818,067 | 13,332.69 MB | 836 | 361,223,662 | 10 | 78.44 s | ≡ |
| off r1 | 3:25.29 | 4,884,248 kB | 219,818,070 | 13,332.70 MB | 836 | 361,223,654 | 10 | 80.93 s | ≡ |
| off r2 | 3:25.54 | 4,884,284 kB | ≡ | ≡ | 836 | ≡ | 10 | 81.05 s | ≡ |

Phases 1/3/4/6 of `plans/kernel-opt-03-value-eq-fastpath.md`. Boxed structural equality now
emits `eco.value.eq`, which expands pre-RS4GC into word-equality → embedded-constant test →
gc-leaf kernel call decoded against the True word. **Emission: `Utils_equal` 1392→0 and
`Utils_notEqual` 60→0 against `eco.value.eq` +1452 — 100% conversion, exact 1:1.** Wall −1.84%
is directionally good but **inside the ±2.8% band, so recorded FLAT** — consistent with the
Phase-0 census, which put the inline arms at only 6.47% of non-Bool traffic, so most of the
1,452 sites still reach arm 3 and pay the call. `Elm_Kernel_Utils_equal` now carries
`gc-leaf-function` (CGEN_076). **Not measured:** `ECO_VALUE_EQ_STRCASE` ships default-off —
proven correct but no wall A/B (see Run L). Gates: E2E 1642/1642 in ALL THREE switch states.

### 2026-08-11 21:15 UTC — Run J: kernel-opt-06 String ordering → `eco.string.cmp3` (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_STRING_ORDER_INTRINSIC=0` escapes**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:22.94** | 4,888,716 kB | 219,817,471 | 13,332.69 MB | 836 | 361,224,067 (164.3%) | 10 | 79.84 s | 12,932,396 B |
| on r2 | **3:23.55** | 4,888,488 kB | ≡ | ≡ | 836 | ≡ | 10 | 80.26 s | ≡ |
| off r1 | 3:24.86 | 4,887,332 kB | 219,817,640 | 13,332.70 MB | 836 | 361,224,058 | 10 | 79.80 s | ≡ |
| off r2 | 3:23.02 | 4,888,656 kB | 219,817,474 | 13,332.69 MB | 836 | 361,224,059 | 10 | 79.50 s | ≡ |

`<`/`<=`/`>`/`>=` on two Strings now emit `eco.string.cmp3` plus ONE signed test against 0,
replacing a boxed `Elm_Kernel_Utils_{lt,le,gt,ge}` call whose `HPtr` Bool was immediately
`eco.unbox`-ed. **Emission: lt 79→14, gt 40→10, ge 2→2, cmp3 1→96 — 95 conversions, exact
1:1**, inside the predicted range. The sign is UNCLAMPED, so the test must be SIGNED; CGEN_075
gains clause (f), since an unsigned predicate would read −1 as huge positive and invert every
answer. Wall −0.34% ⇒ FLAT, as the plan predicted in bold — the fourth compare-family deletion
to measure flat, and it changes no retention (the boxed Bool it removes was an embedded
HPointer constant that never allocated). **Owed to kernel-opt-03:** the surviving boxed
comparison population is now 64 sites, under the >200 threshold its Phase 5 is gated on, so
**that phase must not execute**. Gates: E2E 1639/1639 both states.

### 2026-08-11 17:40 UTC — Run I: kernel-opt-05 `Utils_append` type split (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_APPEND_SPLIT=0` escapes**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:24.48** | 4,888,560 kB | 219,913,079 | 13,335.56 MB | 836 | 361,202,876 (164.2%) | 10 | 79.77 s | 12,939,141 B |
| on r2 | **3:25.65** | 4,888,684 kB | ≡ | ≡ | 836 | ≡ | 10 | 80.39 s | ≡ |
| off r1 | 3:24.26 | 4,901,736 kB | 219,913,243 | 13,335.57 MB | 836 | 361,202,867 | 10 | 79.11 s | ≡ |
| off r2 | 3:22.62 | 4,903,676 kB | 219,913,082 | 13,335.56 MB | 836 | 361,202,868 | 10 | 78.97 s | ≡ |

`++` at mono sites that statically know the operand type now emits typed `eco.string.append`
/ `eco.list.append` instead of the polymorphic `Elm_Kernel_Utils_append`, which re-derives the
type at runtime from two tag loads and silently returns its first argument for any pair it
does not recognise. **3,468 sites → 67, and the split reconciles exactly: 2,695 string + 706
list = 3,401 displaced (98.1%)**; the residue is the `MVar`-operand population falling through
the final wildcard, as designed. Wall +0.80% ⇒ FLAT, which §Expected impact predicted. The
purchase the plan claims is IR size, real but small: Stage-5 `.mlir` −6,773 B. Both ops are
trait-free and appear in none of EcoGCPrepare's four lists — they allocate variable-size
results, so RS4GC statepoints the lowered calls. Phase 3 filled the `(Utils, append)` borrow
axes as POwned/POwned; the borrow upside is FALSE. Gates: E2E 1638/1638; elm-tests 13,085/12.

### 2026-08-11 14:05 UTC — Run H: kernel-opt-04 `eco.string.length` + `eco.string.code_unit_at` (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_STRING_LENGTH_OP=0` escapes**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:24.65** | 4,894,268 kB | 219,915,775 | 13,335.65 MB | 836 | 361,202,849 (164.2%) | 10 | 79.92 s | 12,939,423 B |
| on r2 | **3:20.84** | 4,884,244 kB | 219,915,613 | 13,335.64 MB | 836 | 361,202,850 | 10 | 78.16 s | ≡ |
| off r1 | 3:22.47 | 4,888,640 kB | 219,915,616 | 13,335.65 MB | 836 | 361,202,842 | 10 | 78.45 s | ≡ |
| off r2 | 3:23.49 | 4,888,544 kB | ≡ | ≡ | 836 | ≡ | 10 | 78.98 s | ≡ |

`String.length` becomes an INLINE-IR `eco.string.length`: a `__eco_string_len_inline` marker
that `expandStringLenMarkers` turns into an embedded-constant test (`ptr_ind`, bit 2) plus, on
the heap arm, `__eco_resolve_fwd` + a u32 load at `offsetof(Header,size)` + zext. One word
serves all six String forms because HEAP_025/HEAP_032 define `header.size` as the logical
UTF-16 count for every one, so there is no per-tag dispatch. **All 101 call sites convert,
exact 1:1 with no declines.** Also lands `eco.string.code_unit_at` with **no Elm emission**, to
unblock kernel-opt-14's String-HOF phase, so no wall is booked against it. Wall −0.12% ⇒ FLAT,
as the plan said up front: 75.6M calls is 2.06% of the kernel total, and this is call-deletion,
not retention. Binary −8,336 B. Gates: E2E 1636/1636 both states; elm-tests 13,085/12.

### 2026-08-11 11:20 UTC — Run G: kernel-opt-02 lane A + A′ — union-find cell merge (**−4.46% WALL — a REAL SIGNAL, the first in this series; KEEP, no flag**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| lane A m1 | **3:22.31** | 4,990,500 kB | 219,915,761 | 13,335.64 MB | 836 | 361,202,850 (164.2%) | 10 | 78.91 s | 12,939,423 B |
| lane A m2 | **3:24.59** | 4,831,912 kB | 219,915,596 | ≡ | 836 | 361,202,851 | 10 | 79.66 s | ≡ |
| base m1 | 3:33.38 | 5,085,100 kB | 232,557,637 | 15,167.93 MB | 862 | 372,239,194 (160.1%) | 10 | 84.61 s | ≡ |
| base m2 | 3:32.51 | 5,084,740 kB | ≡ | ≡ | 862 | ≡ | 10 | 84.17 s | ≡ |

**Lane A:** the three index-synchronised `ioRefsWeight` / `ioRefsPointInfo` /
`ioRefsDescriptor` arrays collapse to one `ioRefsPoint : Array PointCell`, so `UnionFind.fresh`
does **1 `Array.push` instead of 3** and `union` does **2 `Array.set`s instead of 3**;
`get`/`set`/`modify` lose their second array read (12 files). **Lane A′:** `Data/Vector.imapM_`
built an array with `Array.push` per element and discarded it — deleted. **G2, the load-bearing
gate, passes: `out.mlir` byte-identical in both rounds**, so the merge preserved Point ids and
every type-checking result exactly. Wall **−4.46%**, outside the band, and **retention moved
with it**: promoted −2.96%, minor GC 862 → 836, bytes −12.08%, GC time −6.04% — exactly the
channel this repo's record says wall tracks. Binary −32,448 B. Gates: E2E 1633/1633; elm-tests
13,085/12 through a rewrite of the type checker's core.

### 2026-08-10 22:05 UTC — Run F: kernel-opt-01 `List.cons` → `eco.construct.list` (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_LIST_CONS_INTRINSIC=0` escapes**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:33.68** | 5,141,168 kB | 232,537,735 † | 15,167.99 MB † | 862 | 372,240,147 (160.1%) | 10 | 85.96 s | 12,943,401 B |
| on r2 | **3:34.98** | 5,140,604 kB | ≡ | ≡ | 862 | ≡ | 10 | 86.38 s | ≡ |
| off r1 | 3:33.94 | 5,141,004 kB | 379,488,362 | 18,524.25 MB | 862 | 372,240,140 (98.1%) | 10 | 84.86 s | ≡ |
| off r2 | 3:33.19 | 5,141,136 kB | ≡ | ≡ | 862 | ≡ | 10 | 83.78 s | ≡ |

† inline-alloc counter blindness, not an allocation reduction — see below.

A `"List"` arm in `kernelIntrinsic` lowers saturated `x :: xs` to `eco.construct.list`, so
each cons pays the HEAP_034 inline bump instead of a statepointed `Elm_Kernel_List_cons*` call.
**All 4,304 direct kernel cons sites convert to 0 — no declines**; the three kernel stubs leave
the module, and the +8 excess localizes to 3 functions (cheaper bodies shifting inlining).
EcoListTemplate parity is bit-identical. **Allocation counters are NOT comparable across these
arms** (§18.3): the ON arm's conses take the inline path, which bypasses the per-tag tally, so
objects −38.7% is counter blindness. The proof is that retention is unmoved — promoted +7 of
372M, minor 862 = 862, major 10 = 10. Wall +0.36% ⇒ FLAT; binary +29,008 B. Honest read: the
plan called this "the highest-confidence wall bet in the series"; ~147M dynamic kernel calls
became inline bumps and **the wall did not move** — the TIER pattern again.

### 2026-08-10 20:36 UTC — Run E: kernel-opt-07 KernelFacts table (**FLAT — no regression; LANDED, no flag to flip**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| post r1 | **3:30.70** | 5,054,148 kB | 379,488,337 | 18,524.23 MB | 862 | 372,250,180 (98.1%) | 10 | 82.46 s | 12,943,401 B |
| post r2 | **3:32.91** | 5,054,156 kB | ≡ | ≡ | 862 | ≡ | 10 | 83.92 s | ≡ |
| pre r1 | 3:34.72 | 5,110,592 kB | ≡ | 18,524.24 MB | 862 | 372,250,117 (98.1%) | 10 | 85.71 s | ≡ |
| pre r2 | 3:34.45 | 5,110,020 kB | ≡ | ≡ | 862 | ≡ | 10 | 85.67 s | ≡ |

`Compiler/GlobalOpt/KernelFacts.elm` (52 rows), `Borrow/KernelSigs.elm` demoted to a 70-line
shim, 7 new elm-test suites, and the `Utils_equal` stderr trace deleted. **Arms are the pre-
and post-change compilers over a FROZEN pristine source tree**, so both compile byte-identical
input — and their `out.mlir` is byte-identical in both rounds, and to Run D's. That is the
inertness gate the plan asks G4/G5 to carry, on all 243 modules rather than one file. Counters
equal (promoted +63 of 372M); wall −1.30% ⇒ FLAT. Binary **+173,400 B**, so the plan's "binary
shrinks" prediction is wrong. RSS is bimodal on this workload (~5,054 vs ~5,111 MB for the
*same* binary), so the −1.10% here is lottery, not signal. The `pre` arm is Run D's binary and
measured +1.42% slower across sessions — which is why the paired interleaved A/B is the
comparison and Run D is only a trend line. Gates: E2E 1632/1632; elm-tests 13066→13073.

### 2026-08-10 19:54 UTC — Run D: loop-entry baseline (**reference point for the 14-item kernel-opt loop; not a change**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| base r1 | **3:33.92** | 5,111,732 kB | 379,486,685 | 18,524.03 MB | 862 | 372,250,555 (98.1%) | 10 | 83.04 s | 12,943,401 B |
| base r2 | **3:29.25** | 5,111,812 kB | ≡ | ≡ | 862 | ≡ | 10 | 81.13 s | ≡ |

Entry baseline for `guides/kernel-opt-loop.md`, which executes `plans/kernel-opt-01..14`.
No source change: the tree is exactly Run C's, rebuilt from scratch with the standard track
build env (`ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_BORROW=1 ECO_AGG_PROMOTE=1`) after
deleting `bin/eco-compiler{,.mlir}` and `eco-stuff` to defeat ninja's env-blindness; binary
staged as `bin/eco-kopt-base`. It reproduces Run C: the counters are bit-identical apart
from the 1-object jitter already documented as same-binary noise, and `out.mlir` is
byte-identical, so the workload is unmoved. Mean wall **3:31.59**; the 4.67 s spread between
the two rounds is the protocol's ≈2.8% band, measured live.

### 2026-08-10 14:30 UTC — Run C: one-call Order materialization (**FLAT — no regression; KEEP — DEFAULT-ON, `ECO_ORDER_FROM_SIGN=0` escapes**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| on r1 | **3:34.71** | 5,112,024 kB | 379,486,686 | 18,524.03 MB | 862 | 372,250,555 (98.1%) | 10 | 84.43 s | 12,943,401 B |
| on r2 | **3:32.00** | 5,111,792 kB | ≡ | ≡ | 862 | ≡ | 10 | 82.60 s | ≡ |
| off r1 | 3:30.40 | 5,055,312 kB | 379,486,851 | ≡ | 862 | ≡ | 10 | 82.12 s | ≡ |
| off r2 | 3:33.08 | 5,111,864 kB | 379,486,686 | ≡ | 862 | ≡ | 10 | 83.13 s | ≡ |

CGEN_075 phase C-v1: `emitOrderSelect` folds the sign in SSA and makes ONE gc-leaf
`eco_order_from_sign(i64)` call instead of calling all three `Eco_Runtime_getOrder*` getters
unconditionally — in the shipped binary **24 call instructions → 8 sites** (4 call + 4 tail
`jmp`), since the single-call shape ends the function. `.text` −240 B, stackmaps unchanged.
FLAT: the rounds SPLIT (r1 +2.05%, r2 −0.51%), mean +0.76%, inside the band; the 165-object
delta on off-r1 is documented same-binary noise. Small by construction — Run B already
rewrote 373 of 389 sites so only 8 survive; this was the 881M-call/run lever *before* B.
Gates: E2E 1632/1632 in both flag states.

### 2026-08-10 12:40 UTC — Run B: `eco.string.cmp_order` + post-mono compare→branch rewrite (**FLAT — no regression; counters identical; KEEP — DEFAULT-ON, `ECO_CMPCASE=0` escapes**)

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

CGEN_075 phases A+B+D. **A:** `Utils.compare [MString,MString]` selects
`eco.string.cmp_order` over the boxed root — boxed `Utils_compare` sites 295 → 38 (250 of
the 258 new string compares in `Dict_insertHelp`/`Dict_get`). **B:** an Eco→Eco peephole
turns single-use compare + 3-arm case-on-Order into ordered lt/gt + nested bool cases —
`[cmpcase] rewritten=373 skipped=16`. **D:** deleted the dead pre-mono rewrite (−242 lines).
Arms are one Stage-5 `.mlir` lowered twice: `out.mlir` identical, counters equal ⇒ pure code
quality; `.text` −46,784 B, stackmaps unchanged. Wall FLAT by the ≥3% bar (mean −2.08%,
band ±2.8%); vs Run A also FLAT, since phase A moves emitted code. Entries here use the
pre-2026-08-10 warmup+measured convention: measured first, throwaway warmup in brackets.
Gates: E2E + heap-validate 1631/1631, bootstrap 8c identical.

### 2026-08-09 15:54 UTC — Run A: series baseline (**carried over from `benchmarks/tier2-opt.md` Run O — NOT re-measured**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| baseline measured | **3:36.18** | 5,012,240 kB | 379,768,314 | 18,537.46 MB | 871 | — | 10 | — | 12,955,155 B |
| baseline warmup | 3:36.11 | 5,012,120 kB | ≡ | ≡ | 871 | — | 10 | — | ≡ |

Series baseline, carried over from `benchmarks/tier2-opt.md` Run O (contiguous nursery extents
+ configurable old-gen/nursery split, HEAP_042/043) arm C = M1+M2 default. That run was FLAT on
wall, kept for nursery slow-path entries 417,585 → 316 and RSS −2.56%. Every default-on tier-2
track optimization (gc-free propagation, capacity-check hoisting, contiguous nursery, inline
nursery allocation) is therefore live here. `Objects promoted` and `GC time` are `—` because
the source entry recorded `ensure calls` / `old-gen cap` instead; both are captured from Run B
onward. Old-gen cap was 20,480 MB. Gates: E2E `--target full`, heap-validate tree 1628/1628.

### 2026-08-16 17:11 UTC — Run W: O(n) size checks → the predicates they stood in for (**FLAT — no regression; counters all down, unconditional**)

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| r1 | **3:57.36** | 5,314,540 kB | 226,934,421 | 14,169.60 MB | 909 | 420,155,755 (185.1%) | 12 | 100.46 s | 13,248,429 B |
| r2 | **3:59.46** | 5,314,416 kB | ≡ | ≡ | 909 | ≡ | 12 | 101.44 s | ≡ |

| axis | Run V off | Run W | Δ |
|---|---|---|---|
| wall (r1/r2 mean) | 4:01.61 | 3:58.41 | −1.32% (FLAT) |
| objects allocated | 227,290,386 | 226,934,421 | −355,965 (−0.16%) |
| bytes allocated | 14,211.45 MB | 14,169.60 MB | −41.85 MB (−0.29%) |
| objects promoted | 427,179,257 | 420,155,755 | **−7,023,502 (−1.64%)** |
| minor / major GC | 914 / 12 | 909 / 12 | −5 / = |
| binary | 66,497,048 B | 66,489,560 B | −7,488 B |
| out.mlir | 13,249,278 B | 13,248,429 B | −849 B |

Tiers 1–3 of `plans/redundant-cardinality-computations.md` plus the `CsePurity` `Set Int` →
`BitSet` switch: twelve sites where an O(n) `Dict.size`/`Set.size`/`List.length` answered a
yes/no question. Wall −1.32% ⇒ FLAT; the exact counters all move down and promoted −1.64% is
the one that matters on this workload. Compared against Run V's OFF arm, the matching config.
NOT an A/B — the change is unconditional, so no second arm exists, and `out.mlir` byte-identity
is unavailable because the edits are IN the corpus (−849 B emitted, 0.006%, against −0.16% of
allocation: the allocation delta is the optimization, not the smaller input). Much of the set is
INERT in this leg — subst skips `sameShapeModuloNumeric`, borrow-off skips `fixAlpha`,
CSE/template-off skips `CsePurity.analyze`; live are Tier 1, `Local`, `Unify`, `HashMap` and the
`scc` hoist. Gates: E2E 1675/1675 ×3 legs, elm-tests 13,104/12, licence census 297/592 unmoved.

---

## Summary

One row per run. Wall is the arm with the run's optimization applied — its r1/r2 mean where
two rounds were measured. Allocation is that same arm's `Objects allocated` / `Bytes
allocated`. Caveats, counter-blindness notes and secondary figures belong in the run entry,
never here.

| run | wall | heap allocation |
|---|---|---|
| A — baseline (tier2 Run O) | 3:36.18 | 379,768,314 obj / 18,537.46 MB |
| B — string cmp_order + compare→branch rewrite | 3:33.39 | 379,486,686 obj / 18,524.03 MB |
| C — one-call Order materialization | 3:34.71 | 379,486,686 obj / 18,524.03 MB |
| D — loop-entry baseline | 3:31.59 | 379,486,685 obj / 18,524.03 MB |
| E — kernel-opt-07 KernelFacts table | 3:31.81 | 379,488,337 obj / 18,524.23 MB |
| F — kernel-opt-01 cons → construct.list | 3:34.33 | 232,537,735 obj / 15,167.99 MB |
| G — kernel-opt-02 union-find cell merge | **3:23.45** | 219,915,761 obj / 13,335.64 MB |
| H — kernel-opt-04 string.length inline | 3:22.75 | 219,915,775 obj / 13,335.65 MB |
| I — kernel-opt-05 append type split | 3:25.07 | 219,913,079 obj / 13,335.56 MB |
| J — kernel-opt-06 String ordering cmp3 | 3:23.25 | 219,817,471 obj / 13,332.69 MB |
| K — kernel-opt-03 eco.value.eq emission | 3:21.63 | 219,818,234 obj / 13,332.70 MB |
| L — kernel-opt-03 STRCASE synthesized sites | 3:23.90 | 219,818,080 obj / 13,332.69 MB |
| M — kernel-opt-08 kernel gc-leaf stamp | 3:23.62 | 219,767,579 obj / 13,331.32 MB |
| N — kernel-opt-09 leaf safepoints + inline-group split | 3:22.80 | 217,928,793 obj / 13,246.14 MB |
| O — kernel-opt-11 mono DCE + kernel cost classes | 3:22.72 | 217,912,477 obj / 13,245.85 MB |
| P — kernel-opt-13 Mono CSE | 3:21.32 | 221,523,797 obj / 13,408.16 MB |
| Q — kernel-opt-10 MLIR folder | 3:36.72 | 217,956,881 obj / 13,247.64 MB |
| R — kernel-opt-12 eco.cse_safe purity channel | 3:24.85 | — |
| S — kernel-opt-14 Elm-source List HOFs | 3:32.9–3:37.7 | 352.8M–354.6M obj / — |
| T — List.map forward template | 3:48.77 | 228,050,612 obj / 14,062.57 MB |
| U — map-template follow-ups F-1L…F-5C | 3:53.31 | 227,631,274 obj / 14,185.38 MB |
| V — map-template round 2 G-0…G-3 | 4:03.36 | 237,455,932 obj / 14,521.69 MB |
| W — O(n) size checks → predicates, BitSet oracle | 3:58.41 | 226,934,421 obj / 14,169.60 MB |
