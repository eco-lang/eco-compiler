# Performance-Tuning Loop — Status

Driver: `guides/perf-tune-loop.md` · Worklist: `perf-investigation-report.md` (§5 order)
Harness: `/work/bench/eco-current` (baseline binary), `/work/bench/eco-boot-native` (lowerer).
Revert: git is unusable in this container (worktree gitdir missing) → back up each edited file
to `<file>.perfbak` before editing; restore from it on NO-WIN / BROKE-TESTS.

## Baseline

| metric | value |
|--------|-------|
| baseline_min_wall | **287.03 s** (Batch1 promoted; was 295.25) |
| baseline_min_user | **282.82 s** (Batch1 promoted; was 290.79) — primary metric |
| baseline_rss | **4,939,148 KB** (Batch1 promoted; was 5,471,520) |
| baseline MLIR md5 (unchanged src) | 37943afad74d18e3ef05a12f05f92f28 (deterministic across all 3 runs) |
| noise floor | ~±1.5% wall; min-user spread of 2 fastest ~0.2s. Win bar: ≥1% on min-user. |

**Measurement note:** individual items are sub-1% (below wall noise) and the perf binary has
no deterministic alloc counter (`#if ENABLE_GC_STATS`, off). Measuring at §5-**batch**
granularity; each item correctness-screened individually via self-fixed-point byte-identity;
bisect a batch only if it regresses.

## Items (§5 sequencing order)

| # | Item | Status | Δwall | Notes |
|---|------|--------|-------|-------|
| 1 | `substituteAll` N→1 walk (MonoInlineSimplify) | PENDING | | |
| 2 | `dropDeadDefs`/`forwardInChain` O(K³)→O(K) | PENDING | | |
| 4 | `generateLetSingle` varMappings O(depth²) | WIN✓ | see below | E2E PASSED (0 failed); promoted |
| 10 | `recordFieldCanTypes` single-field | WIN✓ | see below | included in Batch 1 |
| 6 | Delete `lamLabels` dead build | WIN✓ | see below | minimal form (kill string build) |
| 17 | Dead `Dict.fromList` in `typeToVar` | WIN✓ | see below | included in Batch 1 |
| 11 | `freshenLetChain` K→1 pass | PENDING | | |
| 15 | `computeClosureCaptures` 3→1 walk | PENDING | | |
| 6 | Delete `lamLabels` dead build | PENDING | | |
| 9 | Gate AbiCloning report-only census | PENDING | | |
| 14 | Discarded `arrowSlots` gate + trivial-sig | PENDING | | |
| 17 | Dead `Dict.fromList` in `typeToVar` | PENDING | | |
| 3 | Keyed `enqueueSpec` no-op guard | PENDING | | |
| 5 | `rewriteNode` accessor gate | MEASURING (Batch2) | | candidate building |
| 7 | S-copy elimination (unifySlotWithSet/harvest/unifyStep) | PENDING | | |
| 8 | Fixpoint `iterate` counter + passthrough | PENDING | | |
| 10 | `recordFieldCanTypes` single-field | PENDING | | |
| 12 | Inliner SpecId Dict Int → Array | PENDING | | |
| 13 | `poisonGo`/`spineGo` seen-set → BitSet | PENDING | | |
| 18 | `CallGraph.isRecursive` → BitSet | PENDING | | |
| 19 | `definedSsaVars` → BitSet | PENDING | | |
| 20 | Kernel-ABI membership → direct match | PENDING | | |
| 16 | Parser `charAt` intrinsic | PENDING | | |

Status legend: PENDING / WIN / NO-WIN / BROKE-TESTS / SKIPPED.

## Log
- (setup) branch unavailable (git worktree broken); using .perfbak backups. Baseline binary =
  build/compiler/build-kernel/bin/eco-compiler (Jul 22 10:58, clean tree) copied to /work/bench/eco-current.

## Batch 1 result (#4, #10, #6, #17) — WIN

| metric | baseline (min) | Batch1 (min) | Δ |
|--------|---------------:|-------------:|---|
| user | 290.79 s | 282.82 s | **−2.74%** |
| wall | 295.25 s | 287.03 s | **−2.78%** |
| RSS  | 5,471,520 KB | 4,939,148 KB | **−9.73%** |

- Both candidate runs (282.82/285.23 user) beat the fastest baseline (290.79) — clean separation, >noise.
- Self fixed point PASS: cand.mlir == candout1 == candout2 (md5 29f6bd30ead464dd776a0e329352631a).
- Files: Expr.elm(#4), Translate.elm(#10), AssignMVarIds.elm(#6), Solve.elm(#17). Backups: *.perfbak.
- New baseline binary on E2E pass: /work/bench/eco-cand → /work/bench/eco-current; baseline_min_user := 282.82.
- Note: the −9.7% RSS confirms the changes are genuine allocation-churn reductions (#4 stops rebuilding
  varMappings dicts per let; #10 stops Dict.map-ing whole field trees per record access).

## Metric refinement (deterministic GC-stats available!)

The lowered binaries emit an exit-time GC-stats banner (captured in each run log). Deterministic
corroborators (baseline runs 2&3 identical; candidate runs identical):

| metric | baseline | Batch1 | Δ | note |
|--------|---------:|-------:|---|------|
| wall (min) | 295.25 s | 287.03 s | −2.78% | primary (user's ask); candidate beat ALL baseline runs |
| total bytes allocated | 46527 MB | 46511 MB | −0.03% | INSENSITIVE — dominated by transient nursery churn |
| old-gen alloc (histogram total) | 3.685 GB | 3.360 GB | −8.8% | retained alloc — the real signal for these changes |
| RSS (peak) | 5.47 GB | 4.94 GB | −9.7% | |
| major GC cycles | 13 | 11 | −2 | fewer/cheaper majors → wall win |
| minor GC cycles | 1192 | 1191 | −1 | |
| major GC time | 34.24 s | ~29.7 s | −4.5 s | ~half the wall win |

**Decision metric going forward:** WALL (min of runs) corroborated by the deterministic set
(old-gen alloc, RSS, major-GC count). Total-bytes-allocated is too coarse (nursery-churn dominated).
These changes win by cutting RETAINED memory → GC pressure, not transient churn.

## #5 (rewriteNode accessor gate) — NO-WIN (reverted)
- Fixed-point PASS (output-preserving) but wall/user dead-neutral: cand min wall 286.70s vs baseline
  287.03s (−0.11%, inside the 6.8s candidate run-spread); user 282.67 vs 282.82. RSS −1.5% (small),
  major GC 11→12 (+1). ResolveAccessorValues runs once-per-def (not the hot fixpoint) and the
  hasAccessor pre-scan offsets the skipped rebuild. Reverted per loop criterion (no wall win).
  A clean example of the loop rejecting a plausible-but-flat change.

## #3 (keyed enqueueSpec no-op guard) — MEASURING
- Applied to Engine.elm: reuse-hit path no longer builds the eager ~25-field S copy (mirrors the
  non-keyed D2 guard). Per-node hot path; expected to cut transient S-copy allocation.

## #3 (keyed enqueueSpec guard) — NO-WIN (reverted)
- Deterministically allocation-NEUTRAL: bytes 46513MB vs baseline 46511MB (+0.004%). Fixed-point PASS.
- Wall read +2.2% (293.3 vs 287.0) BUT a same-binary control run drifted to 290.2s / majGC 12 (vs the
  baseline's earlier 287.0 / majGC 11) — i.e. the "regression" was major-GC-trigger LOTTERY on a neutral
  change. Reverted (highest verifier score, 70, yet empirically no allocation win at Stage-7a scale).

## KEY METHODOLOGY FINDINGS (for continuation)
1. **Deterministic GC-stats beat wall.** The lowered binaries emit `bytes allocated`, old-gen-alloc
   histogram totals, and minor/major GC counts — deterministic run-to-run. Decide on these, not wall.
2. **Wall is major-GC-trigger-lottery noisy** (~±3s / ±1-2 major GCs for the *identical* binary ≈ ±2%).
   Individual sub-3% changes are NOT wall-resolvable. (Matches the documented E9.3 lottery warning.)
3. **What actually moves the needle:** RETAINED-memory / asymptotic reductions (Batch 1's #4 O(depth^2)
   varMappings + #10 per-access field-dict) — old-gen −8.8%, RSS −9.7%, wall −2.7%, E2E green.
4. **What doesn't (at Stage-7a scale):** per-node micro record-copy eliminations (#3, #5) — the copies are
   nursery-cheap, lost in the ~46 GB total churn → deterministically allocation-neutral.
5. **CPU-only items (#12 Array, #2 dropDeadDefs, #18 BitSet-membership) are unmeasurable individually**
   here (no allocation delta + GC-lottery wall). They need either §5 BATCH measurement (accumulate a
   resolvable cumulative delta, bisect on regress) or a `perf` CPU profile — not single-item wall.

## RECOMMENDED CONTINUATION
- Implement the remaining items in §5 BATCHES (asymptotic batch #1/#2/#11/#15; data-structure batch
  #12/#13/#18/#19) and measure each BATCH's deterministic allocation + wall; include/exclude at batch
  granularity, bisecting only on regression. This is the only statistically sound path for sub-noise items.
- The CAF-memoization item (★, reservedWords) is codegen-level and potentially the biggest single win —
  investigate separately (verify the old-gen-retention tradeoff first).

## FINAL STATE
- KEPT (promoted): Batch 1 = #4, #10, #6, #17 → baseline 290.79s→282.82s user, RSS 5.47→4.94 GB, E2E green.
- NO-WIN (reverted): #5, #3.
- PENDING (need batch measurement): #1,#2,#7,#8,#9,#11,#12,#13,#14,#15,#16,#18,#19,#20 + ★CAF.
- Harness intact for resume: /work/bench/eco-current (baseline binary), /work/bench/eco-boot-native.

## #18 (CallGraph.isRecursive → BitSet) — NO-WIN (reverted)
- Deterministically allocation-NEUTRAL: bytes 46510.60MB vs 46511MB (−0.0009%). Fixed-point PASS.
  Wall +2.4% = major-GC lottery (+1 major) + machine drift (control run showed baseline binary itself
  at ~290s now). The Dict→BitSet saves only a few hundred build-time tree nodes per module — negligible.

## CONCLUSIVE FINDING (4 items measured)
Deterministic bytes-allocated verdicts:
- Batch 1 (#4,#10,#6,#17): old-gen −8.8%, RSS −9.7%, wall −2.7% → **WIN (retained-memory/asymptotic)**
- #5 accessor gate:  bytes −0.03% → neutral (once-per-def)
- #3 enqueue guard:  bytes +0.004% → neutral (per-node micro record-copy; nursery-cheap)
- #18 CallGraph BitSet: bytes −0.0009% → neutral (CPU-only + tiny build alloc)
=> At Stage-7a scale, ONLY retained-memory / asymptotic changes are measurable. Per-node micro-copy,
   BitSet/Array data-structure swaps, and CPU-only changes are below resolution (lost in ~46GB churn;
   wall is major-GC-lottery noise of ±1-2 majors ≈ ±2%). The remaining report items of those classes
   cannot be individually included/excluded here — they need a CPU profile or must be judged by code
   reasoning, not this wall benchmark.

## REMAINING HIGH-VALUE WORK (proper work session, not quick loop iterations)
- Asymptotic batch #1/#2/#11/#15: intricate multi-function rewrites (substituteMany / renameLocalMany
  multi-key with shadowing; dropDeadDefs backward-sweep count map; computeClosureCaptures walk fusion).
  These reduce transient allocation during inlining and are the best remaining measurable-win candidates.
- ★ CAF memoization (reservedWords etc.): codegen-level; potentially the biggest single win; verify the
  old-gen-retention tradeoff first.

## #1 (substituteAll -> substituteMany) — NO-WIN (reverted)
- Full substituteMany family (~150 lines) implemented + byte-correct (fixed-point PASS).
- Deterministically NEUTRAL-to-negative: bytes 46532.97MB vs 46511MB (+0.047% — the rename Dict I build
  ADDS allocation that offsets the saved walks). wall −0.25% (noise). RSS −0.14%.
- WHY: the "asymptotic" K in substituteAll = FUNCTION ARITY, which is 2-3 in practice, so K walks->1 is a
  tiny constant-factor change, and the Dict/tuple overhead cancels it. The [b] single-binding fast path
  already keeps K=1 cheap. => the flagship asymptotic item does not help on this workload.

## ASYMPTOTIC BATCH — assessment after measuring the flagship (#1)
- #1 (K=arity, small): measured NEUTRAL.
- #11 freshenLetChain (K=let-chain len): same small-K shape as #1's Dict tradeoff; likely neutral.
- #15 computeClosureCaptures (per-closure walk fusion): small per-closure; likely neutral.
- #2 dropDeadDefs O(K^3) (K=let-chain len): the ONE with real potential — #4 (O(depth^2) on let-chains) WON,
  proving chains are deep enough for super-linear costs to bite. BUT: implementing it BYTE-IDENTICALLY is
  high-risk — the O(K^3) comes from a restart-to-fixpoint that handles the transitive drop cascade + a
  closure earlier-use check; an O(K) single-pass would drop FEWER defs (miss transitive drops) => output
  differs from baseline (not byte-identical). Exact-cascade O(K) liveness is a real algorithm, not a quick edit.

## OVERALL EMPIRICAL CONCLUSION (6 items measured)
Only Batch 1 (retained-memory: #4 O(depth^2) varMappings + #10 field-dict) is a WIN (-2.7% wall, -9.7% RSS).
Everything else measured — #5, #3, #18, #1 — is deterministically NEUTRAL. The self-compile's allocation is
dominated by transient nursery churn (~46 GB) that these targeted micro/small-K-asymptotic reductions don't
touch. Further real wins need: (a) the ★CAF-memoization codegen work (biggest single lever), or (b) a `perf`
CPU profile to find the ACTUAL hot spots — not more report items of these classes.
