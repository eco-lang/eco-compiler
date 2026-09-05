# MonoTraverse: squeeze the traversal family to the floor

**Status: COMPLETE 2026-09-05 — all items done or measured out; output
byte-identical; family indirect dispatches −98.7 %; WALL FLAT and §6.4 proves
why (the family is 4.2 M node visits against 9.8 B objects allocated).** Follows `plans/e4a-deferred-overlay.md` (§7: the
`traverseExpr` re-lift fix). Scope: `compiler/src/Compiler/Monomorphize/MonoTraverse.elm`
(`traverseExpr`, `foldExpr`, `anyExprType`, `mapExprTypes`, `childrenOf`) and the three
backend gaps the scan exposed. Goal: every avoidable allocation, PAP, indirect call and
redundant pass out of this family, each change measured on its own, kept if it is a win
**or flat with a sound argument**, reverted only on a measured loss.

---

## 1. Ground truth — what Eco already emits for the current code

Read off `bin/v2b.mlir` (the bootstrap-fixed-point self-compile of the current source) and
the dispatch census of `eco-fixed2` on the pristine Sep-3 corpus (`scratchpad/b2-C.stderr`):

| fact | evidence |
|---|---|
| `traverseExpr` is cloned per callback site and the callback is a DIRECT call (`_$_37076` → `eco.call callee=@remapClosureLambdaId`); in the `resolveFusedLets` clone (`_$_40983`) the callback is inlined | census: `traverseExpr`, `remapClosureLambdaId`, `resolveFusedLets` = **0** dispatches |
| every `( x, ctx )`-returning HELPER has a `$sret` twin returning two SSA values; `make.tuple2`/`project.tuple2` pairs inside are SSA no-ops | `traverseExprs_$_37079$sret : (…) -> (!eco.value, !eco.value)` |
| `traverseExpr` itself has NO `$sret` twin — its result is the callback's boxed tuple, so every child visit does `project.tuple2` on a heap value | `traverseExpr_$_37076` returns `!eco.value`; callers `project.tuple2` it |
| every node is rebuilt unconditionally: 12 `construct.custom` arms + one 13-slot `record` copy per closure + `construct.list` per list element; `Jump i` is re-allocated | `traverseExprChildren_$_37077$sret`: `custom alloc: 12, record alloc: 1`; `traverseChoice$sret`: `custom alloc: 2` |
| `foldExpr` (point-free) = 2 `papCreate` + 1 `papExtend` per CALL, entry applied indirectly | `foldExpr_$_31905`; census `foldExprAccFirst_$_42178` 63,216 = one per call |
| `List.foldl` in the fold family IS eliminated (an `scf.while` with a direct call) but each of the 9 lambda sites still emits a `papCreate` whose value is never used | `_tail_mono_inline_49213_350603$cap`: `%0 = papCreate …` unused |
| whole family weight on the self-compile after the fixes | 494,221 dispatches of 2.28e9 = 0.02 % (`anyExprType` 336K, `foldExpr` 190K); visits ≈ 300K (`remapLambdaIds`) + 16K (`resolveFusedLets`) + folds |

So: the self-compile wall will not move visibly from this plan; the target metric is
**allocation and instructions per visit**, plus an inliner-heavy corpus where the family is
hot. That is the deal the brief makes: small wins count, flat-with-an-argument counts.

---

## 2. Instruments (build these first — the dispatch census is blind here)

Direct calls are invisible to `ECO_DISPATCH_STATS`; every item below is about allocation
and direct-call work, so the census cannot score it. Three instruments:

**I1 — honest allocation attribution.** Lower with `ECO_INLINE_ALLOC=0` so `eco_alloc_*`
calls are emitted and the per-tag counters are exact (`build-kernel/allocattr.sh` is the
template; `bin/eco-noinline` was built this way). Attribute by caller with the
`eco_alloc_closure` anchor slide + `nm`, exactly as the dispatch census is symbolised.
Score = allocations attributed to `MonoTraverse_*` + the callback clones, by tag
(custom/tuple2/record/list/closure). Deterministic per (binary × tree); n = 1 is valid.

**I2 — a visit-count cell.** `MonoTraverse` has no engine state, so add a report-gated
counter at the two callers (`remapLambdaIds`, `resolveFusedLets`) and the hot `foldExpr`
callers: nodes visited per pass (`ARGF` cells `trav|remap`, `trav|fused`, `fold|<site>`),
so allocations-per-visit can be computed from I1.

**I3 — a traversal-heavy corpus.** The self-compile is 0.02 %; a corpus where the family
is hot is needed to see wall move at all: a program that inlines aggressively (many small
non-recursive globals called from big bodies — `remapLambdaIds` runs per inlined copy),
deep let/case nesting, and long `MonoList` literals (the one long-list risk). Keep it under
`compiler/tests/SourceIR/` or a bench dir; measure wall + minor GCs (deterministic) + I1.

Gates for every item: crafted-corpus byte-identity (native pre-change vs JS post-change),
`MonoTraverseTest` + `LssLocalMultiEnrichTest`, self-compile output byte-identical (or
normalised-diff empty + bootstrap fixed point where an item legitimately changes
numbering), `--target full` 1718/1718.

---

## 3. Items, ranked by expected effect

### T1. Return the original when nothing changed (brief items 4, 6, 7) — the big one

Both live callers rewrite a tiny fraction of nodes (`remapLambdaIds`: closures only;
`resolveFusedLets`: fused vars only) and yet the traversal copies the whole tree: one
node + its list cells + a 13-slot `ClosureInfo` per closure, per visit, then the GC
promotes the copy. Elm has no identity test, so change detection must be a protocol:

- Public contract becomes `ctx -> MonoExpr -> Maybe ( MonoExpr, ctx )` (`Nothing` =
  unchanged; `Nothing` is an embedded constant, `Just` allocates only on the changed
  path). Internally the walk is the `Maybe`-returning shape already proven in
  `Translate.overlayLocalMultiUses` (`olmExpr`): parents rebuild only above a change.
- `traverseExpr` keeps its name and signature as a thin wrapper
  (`Maybe.withDefault ( expr, ctx )`), so the two callers adapt by returning `Nothing`
  in their `_ ->` arms.
- Removes: the per-visit node rebuild, the list-cell rebuilds, the `Jump i`
  re-allocation, the `ClosureInfo` copy, AND the per-node tuple of T2 on the unchanged
  path (no tuple is built when the answer is `Nothing`).
- Fusion bonus: AbiCloning's "cheap check first, rebuild only if needed"
  (`AbiCloning.elm:37`) exists because rebuilding was unconditional; with T1 the check
  pass can fold into the rewrite pass (brief item 5). Audit the other 29 `foldExpr`
  sites for the same check-then-rewrite pairing.
- Expected: allocation in the traversal → (changed nodes × 2 objects); the unchanged
  path allocates nothing. Verify with I1 (tags custom/list/record → ~0 under
  `MonoTraverse_*`) and I2.

### T2. Kill the per-node tuple at the callback boundary (brief items 4, 6)

What T1 leaves: on the CHANGED path the callback still returns a boxed `( x, ctx )` and
the caller projects it. Two complementary moves:

- **Source:** a ctx-free `mapExpr : (MonoExpr -> Maybe MonoExpr) -> MonoExpr -> MonoExpr`
  for callers whose ctx is `()` (`resolveFusedLets` today) — zero tuples anywhere.
- **Backend (B1 below):** extend `$sret` eligibility to a function whose result flows
  from a direct call to a lambda carrying `logical_result_types = ["tuple2:v:v"]` (the
  callback already carries it). Then `traverseExpr` itself gets a `$sret` twin and the
  tuple never touches the heap for ANY caller. This is the item with the widest reach —
  it pays in every traversal in the compiler, not only this module.

### T3. De-point-free `foldExpr`; de-lambda the fold's list walks (brief items 2, 3)

- `foldExpr f = foldExprAccFirst (\a e -> f e a)`: give it its parameters and walk with
  `f e acc` directly (children first) — no flip closure, no `papCreate`/`papExtend`, a
  direct entry. ~95K calls per self-compile across 29 sites in 9 modules
  (`MonoInlineSimplify` 8, `Monomorphize` 5, `Generate/MLIR/Expr` 5, `MonoSolver/Monomorphize` 4, …).
- Replace the nine `List.foldl (\e a -> foldExprAccFirst f a e)` sites with direct
  recursive list helpers (`foldExprs f acc list`), mirroring `traverseExprs`: nothing for
  the HOF pass to eliminate, and the dead `papCreate` it currently leaves behind is gone
  at the source. Same for `foldDeciderAccFirst`'s `FanOut` edges fold.
- Offer `foldExprAccFirst` as the public entry (acc-first is what the loop wants; the
  29 call sites can migrate incrementally — the wrapper stays).
- Expected: −3 PAP ops per call; −1 closure per visited list-bearing node IF the backend
  does not already DCE it (B2 decides; measure with I1 either way).

### T4. `anyExprType` — the family's biggest remaining row (336K dispatches)

Not in `traverseExpr` but in the same file and now the largest consumer. Confirm it
short-circuits on the first hit (an `any` that folds the whole tree is a full walk per
query); if it is built on `foldExpr` it inherits T3's PAPs and cannot exit early — give it
its own direct recursion with an early `True`. Also check why it dispatches at all
(336K indirect calls means its callback is not devirtualised: a multi-member set at the
predicate site or a point-free definition — either is fixable at the source).

### T5. Tail shape of the list helpers (brief item 1)

`traverseExprs`/`traverseKeyed`/`traverseCaptures`/`traverseBranches`/`traverseEdges` cons
after the recursive call; Eco has no tail-recursion-modulo-cons, so stack depth = list
length. Accumulate-reversed + `List.reverse` costs a second pass and a second list, a net
loss for call args/record fields/tuple elements. Decision: keep direct recursion for those;
give `MonoList` literals (the only unbounded list) an iterative arm, and after T1 the
unchanged path allocates nothing regardless. Measure on I3's long-literal case; keep
whichever is flat-or-better.

### T6. `mapExprTypes` / `mapNodeTypes` (same file, same shape)

They rebuild every node to map every embedded `MonoType` (`f` applied to each) — used by
the quiescence closing pass over the whole reachable graph. Apply T1's `Maybe` protocol:
`f : MonoType -> Maybe MonoType`, rebuild only where a type changed. For a pass whose
`f` is identity on most types this is the same copy-the-world cost T1 removes.

### T7. `childrenOf` (census/tests only today)

Builds lists with `++`, `concatMap`, `List.map` — fine where it is used, but if it is ever
put on a hot path replace it with a CPS-style `foldChildren : (MonoExpr -> acc -> acc)`
that visits without materialising a list. Note in the doc comment; no work unless a hot
caller appears.

### T8. Micro-level (brief item 7)

- `traverseChoice`: return the incoming `choice` for `Jump` (subsumed by T1, listed so it
  is not lost if T1 is staged).
- `{ info | captures = … }` only when captures changed (subsumed by T1).
- Leaves: with T1 the leaf arms return `Nothing` — no tuple, no call into the callback for
  callers that opt out of leaves? No: the contract visits every node; keep it, the callback
  is a direct call. (Measured 0 dispatches; nothing left here.)

### T9. Code-size / clone hygiene (brief item 9)

Per-site cloning multiplies the family (~12 functions per caller). Harmless at two
callers; if T1/T2 attract more callers (they should — a cheap generic rewrite is
attractive), watch `.mlir` size and Stage-6 lowering time (5:36 today) per new caller.

---

## 4. Backend items the scan exposed (bigger reach than the module)

**B1 — `$sret` through a direct callback call.** Today a function whose result comes from
a direct call to a lambda that itself returns a `tuple2` is not given a `$sret` twin, so the
tuple is boxed at exactly that boundary. Extending eligibility (the callee's
`logical_result_types` is already the signal) removes a heap tuple per node from every
context-threaded traversal in the codebase. Verify on `traverseExpr_$_37076`: expect a
`$sret` twin and zero `project.tuple2` on `!eco.value` in its callers.

**B2 — dead `papCreate` after HOF elimination.** When `List.foldl`'s lambda is inlined into
an `scf.while` with a direct call, the `papCreate` that materialised the lambda is left
behind unused (`_tail_mono_inline_49213_350603$cap`, `%0`). Confirm with I1 whether it is
DCE'd before lowering; if not, drop it in the HOF pass or mark `eco.papCreate` pure so MLIR
DCE removes it. Pays in every inlined HOF in the program.

**B3 — a reference-equality primitive.** `Eco.Kernel.Utils.refEq : a -> a -> Bool` (pointer
compare, kernel-only) would let ANY rebuild-style pass detect "callback returned the same
node" in O(1) without a `Maybe` protocol. T1 does not need it; it is the cheap generic
version for the other rebuilders (`mapExprTypes`, GlobalOpt rewrites).

---

## 5. Order and acceptance

1. Instruments I1–I3 (one afternoon; they are reused by every later item).
2. T1 (with T8 folded in), then T3, then T4 — each its own arm: I1 tags, I2 visits, I3
   wall + minor GCs, self-compile gates. Record the numbers in §6 win or flat.
3. T2-source (`mapExpr`) once T1's protocol is settled; T6 with the same protocol.
4. B1/B2/B3 as backend tickets with the `traverseExpr_$_37076` MLIR as the acceptance
   fixture.
5. T5 last, decided by I3's long-literal case.

Acceptance per item: allocation-per-visit down (I1/I2) OR instructions down with wall flat
and a stated reason; output byte-identical or fixed point re-established; never a measured
wall loss on I3 or the self-compile. Flat results are kept AND recorded — the point of the
plan is the floor, not a headline.

## 6. Results — MEASURED 2026-09-05

All gates green: unit suite 13,422 pass / 12 fail (**the same 12 pre-existing
typechecker failures**, byte-compared against the pre-change run), crafted corpus
byte-identical, **both benchmark corpora byte-identical output**, bootstrap fixed
point re-established.

### 6.1 Instruments actually used

- **I1** as planned: every arm lowered twice, once normally and once with
  `ECO_INLINE_ALLOC=0`, so `Objects allocated` / `Bytes allocated` are exact.
- **I2 changed method**: rather than adding report-gated counters (a rebuild per
  question), the visit counts were taken with **bpftrace uprobes** on the
  traversal entry points of the shipped binary. Overhead measured negligible
  (C2: 13.24 s probed vs 13.65 s unprobed), and it needs no instrumented build.
- **I3**: a generated 42,497-line / 25-module corpus (`scratchpad/travcorpus-big`)
  of closure-bearing helpers, 20-deep let chains of local functions, nested cases
  and 200-element list literals.
- C1 is a **frozen copy** of the compiler source in the scratchpad
  (`scratchpad/corpus-src`, 286 files / 223,536 lines) so both arms compile
  byte-identical input. (The pristine Sep-3 checkout used for the earlier
  measurements was deleted mid-session — see §8.)

### 6.2 The headline: everything worked, and it is worth 0.01 %

| | BEFORE | AFTER | delta |
|---|---:|---:|---:|
| **C1 wall** (normal) | 8:02.95 | 8:01.47 | −0.3 % (noise) |
| **C1 objects allocated** | 9,786,232,317 | 9,785,717,133 | **−515,184** (−0.01 %) |
| C1 bytes allocated | 406,304.5 MB | 406,286.6 MB | −17.9 MB |
| C1 minor GC cycles | 1,986 | 1,986 | **0** |
| C1 major GC cycles | 9 | 9 | 0 |
| C1 dispatch (`sat`) | 2,307,092,167 | 2,306,565,516 | **−526,651** |
| C1 peak RSS | 9.64 GB | 9.64 GB | 0 |
| C1 output `.mlir` | 15,674,017 B | 15,674,017 B | **byte-identical** |
| **C2 objects allocated** | 320,570,021 | 320,546,046 | −23,975 (−0.01 %) |
| C2 minor GC cycles | 187 | 187 | 0 |
| C2 output `.mlir` | 1,640,879 B | 1,640,879 B | **byte-identical** |

Minor-GC count is deterministic per (binary × tree), and it did not move: 17.9 MB
off 406 GB is below one nursery cycle.

### 6.3 Where the dispatch delta went (exact attribution)

The program-wide −526,651 is **almost exactly the family's own** −526,720; the
rest of the census is lambda renumbering that cancels.

| family, indirect dispatches on C1 | before | after |
|---|---:|---:|
| `anyExprType` — T4 killed the `List.any (anyExprType p)` PAP | 336,684 | **0** |
| `foldExpr` — T3 killed the `papCreate`+`papExtend` per call | 190,036 | **0** |
| `mapExprTypes` — T6 not done | 7,101 | 7,101 |
| **total** | **533,821** | **7,101** (−98.7 %) |

### 6.4 The ceiling — why 0.01 % is the whole prize (bpftrace visit census, C1)

| traversal | node visits per self-compile |
|---|---:|
| `travExpr` (the REWRITING traversal, both clones) | **247,583** |
| `anyExprType` | 838,933 |
| `foldExprAccFirst` (all 11 clones) | 3,130,446 |
| **whole family** | **4,216,962** |

Against **9,785,717,133 objects allocated** by the compile. So the family touches
4.2 M nodes while the program allocates 9.8 B objects: even if every visit had
allocated ten objects and we had removed all of them, the ceiling would be 0.43 %.
T1's own ceiling is the 247,583 rebuilds it can now skip, and the measured
−515,184 objects (T1 + T3 + T4 together) is at that ceiling.

**This is the finding, and it supersedes the plan's premise.** §1 assumed a
per-visit cost worth chasing because the family had been 68 % of dispatch before
`plans/e4a-deferred-overlay.md`; after that fix it is 0.02 %, and the rewriting
traversal in particular is simply cold — 247 K visits on a 223 K-line compile,
13 K on a 42 K-line one. The compiler's 9.8 B objects are elsewhere (the solver's
`Step` monad — memory `lss-cost-is-step-monad-allocation`).

### 6.5 Per item

| item | outcome |
|---|---|
| **T1** change detection (`( Maybe MonoExpr, ctx )`) | **SHIPPED.** Unchanged subtree allocates nothing; `ClosureInfo` copied only when captures move; `Jump` no longer re-allocated. Ceiling 247,583 rebuilds. |
| **T2** `mapExpr` + `$sret` at the callback boundary | **SHIPPED, and B1 came free** — T1 made `travExpr` construct its result, so Eco emitted `travExpr_$_37050$sret` (2 SSA values). No backend change needed. `mapExpr` added and used by `resolveFusedLets`. |
| **T3** `foldExpr` de-point-free + 9 direct list walks | **SHIPPED.** 190,036 → 0 dispatches. |
| **T4** `anyExprType` direct list walks | **SHIPPED.** 336,684 → 0 dispatches. |
| **T5** tail shape of the list walks | **Direct recursion kept.** The unchanged path allocates nothing at all, which beats accumulate+reverse; 200-element literals in C2 compile fine. Stack depth = list length, noted. |
| **T6** `mapExprTypes` change detection | **NOT DONE, measured out.** `Prune` already guards it with an allocation-free `anyNodeType` pre-scan, so only residual-bearing nodes are rebuilt; the residue is **7,101 dispatches** (0.0003 % of program). Not worth changing `closeType`/`widenSets` signatures. |
| **T7** `childrenOf` | Documented as list-materialising, for tests/censuses only. |
| **T8** micro (Jump, ClosureInfo copy, leaves) | Subsumed by T1. |
| **T9** clone hygiene | Fine: the new compiler's `.mlir` is **smaller** (15,510,386 vs 15,559,486 B). |
| **Prune** `closeType`/`hasResidualType` eta-expanded | **SHIPPED** (they were point-free PAPs); byte-identical. |
| **B1** `$sret` through a direct callback call | **Resolved by T1** — no backend work. |
| **B2** dead `papCreate` after HOF elimination | **CLEAN NEGATIVE.** Disassembled `_tail_mono_inline_49213_350603$cap` in the `ECO_INLINE_ALLOC=0` binary: 752 bytes, calls only `foldExprAccFirst` and `eco_follow_forward`, **zero allocation calls**. The MLIR `papCreate` is DCE'd before machine code and never cost anything. |
| **B3** `refEq` primitive | **Not needed** for T1, and not cheaply available: the pointer fast path lives in the `__eco_value_eq` diamond, which `EcoBackend.cpp:1815` records as never emitted ("Nothing emits eco.value.eq today"), so `==` goes to the structural kernel compare. |

### 6.6 New finding worth its own ticket

`Nothing` compiles to **`eco.call @Maybe_Nothing_$_34440`** — a memoized CAF call,
not an embedded constant. `[]`, `True`, `False` ARE embedded HPointer constants
(`plans/null-cons-hpointer-embedding.md`, wall −6.2 %). Extending that embedding
to nullary constructors of small sums would turn a call + cached load into a
constant materialisation on **every `Maybe`-returning hot path in the compiler**,
of which T1 just created one per unchanged node. Strictly bigger than anything
left in this plan.

### 6.7 Verdict

Every item that could be done was done, each is sound, the output is byte-identical
and the family's indirect dispatches fell 98.7 %. The wall is **flat**, and §6.4
says why: after the E4a fix this family is 0.02 % of the compiler. Kept per the
brief ("flat is good too if something holds up to analysis") — but the honest
guidance is that further work here has no headroom, and §6.6 is where to go next.

## 7. Traps met

- **Untracked files at the `/work` ROOT are deleted periodically** — `context.md`,
  `commit.txt`, `gitlog.txt`, `diff_with_aug26*.txt` and BOTH git checkouts
  (`eco-compiler-aug-26`, `eco-compiler-sep-3`) vanished mid-session, twice.
  Files inside tracked subdirectories (`plans/`, `compiler/`) survive. Keep
  corpora, binaries and notes in the scratchpad.
- The dispatch census is **blind to this work** — after the E4a fix the traversal
  recursion is a direct call, so `ECO_DISPATCH_STATS` shows 0 for it. Use
  `ECO_INLINE_ALLOC=0` object counts plus bpftrace uprobes.
- bpftrace probe names cannot contain `$` in the map name; number the maps.
