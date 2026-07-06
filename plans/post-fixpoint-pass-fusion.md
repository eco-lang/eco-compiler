# Post-Fixpoint Pass Fusion (allocation reduction, phase-boundary-safe)

## Status: SHIPPED F1 + F2 (2026-07-06) — byte-identical (12868 unit + 1547 E2E, MLIR corpus
788/0-diff) and bootstraps to the native fixed point; Stage-8a gcstats in /work/gcstats.txt
(-0.05% objects — negligible, see assessment). F3 DEFERRED (shallow-array saving vs ~450-line
surgery). **F5 IMPLEMENTED THEN REVERTED**: byte-identical on the corpus but crashed the native
self-compile at Stage 7a (embedded-constant HPointer assertion in Allocator::resolve — a path the
test corpus does not cover); reverting only F5 restored the bootstrap, confirming it as trigger.
Root cause undetermined; needs a runtime-side look before any retry. Every claim was code-verified.
Derived from `monomorphization-perf-analysis.md` §5.2. This is the higher-value counterpart to
the §3.6 micro-optimizations (byte-identical but <0.1% gcstats): it removes whole **graph
copies and traversals**, where the Custom/Cons/Array allocation actually lives.

Corrections found during verification (vs the first draft):
- **F2's open question is resolved, trivially:** `buildStagingGraph` binds its `ProducerInfo`
  argument to `_` and never reads it (GraphBuilder.elm:53-54). The two walks are
  UNCONDITIONALLY fusable — no visitation-order hazard exists.
- **F1 is stronger than "fuse the counts":** the `Metrics` tuple is discarded in prod
  (`( simplifiedGraph, _ )`, Generate.elm:749) and the only test assertions on the closure
  counts are vacuous (`Expect.atLeast 0`). Delete the two count fields and both deep walks
  outright. Also: `buildCallGraph` is itself TWO more node-array folds the draft missed.
- **Phases 3 and 4 of `globalOptimize` are no-op stubs today** (`validateClosureStaging`
  returns its input, Staging.elm:111-116; `abiCloningPass` returns its input,
  AbiCloning.elm:39-41). The real transforms are wrap → staging → annotate.
- **F3 has a byte-identity trap the draft missed:** both InlineSimplify and
  wrapTopLevelCallables MINT lambda ids from a threaded counter. Naive per-node interleaving
  renumbers `AnonymousLambda` uids → emitted MLIR differs. The fusion below preserves the
  exact sequential numbering (inline ids first, then wrap ids) and stays byte-identical.
- **F5 is likely the LARGEST single win** (annotateCallStaging deep-copies the entire graph
  unconditionally today — verified :1103-1254) but also the most delicate (env threading).

## Verified pass inventory (fixpoint-end → codegen-start)

Pipeline (Builder/Generate.elm — three deliberately separate top-level functions, comment
:719-726, to release JS closure scope between phases; keep that structure):
`runMonoOptPipeline` :731 `Monomorphize.monomorphize` → `runInlineSimplifyPhase` :749-750
`( simplifiedGraph, _ ) = MonoInlineSimplify.optimize …` → `runGlobalOptPhase` :765
`MonoGlobalOptimize.globalOptimize simplifiedGraph` → codegen.

| # | Work | Locus | Cost today |
|---|---|---|---|
| 1 | `pruneUnreachableSpecs` (+fused close) | `Monomorphize/Prune.elm` | 1 array copy — **Monomorphize phase** |
| — | **HARD phase cut (Mono→GlobalOpt)** | | |
| 2a | `countClosuresInGraph nodes` | MonoInlineSimplify:111-112 | full DEEP walk (recurses every expr, :3160-3245) |
| 2b | `buildCallGraph nodes callEdges` | :114-115, def :343 | TWO node-array folds (index assignment + adjacency) |
| 2c | `Array.toList nodes` | :123-124 | deliberate GC aid (comment :120-127) — KEEP |
| 2d | main rewrite fold (`optimizeNodes`) | :143-158 | the real work |
| 2e | `Array.fromList (List.reverse …)` | :160-161 | 1 array materialization |
| 2f | `countClosuresInGraph optimizedNodes` | :163-164 | full DEEP walk |
| 3 | `wrapTopLevelCallables` | MonoGlobalOptimize:963-990 | `Array.foldl` + `Array.push` per node = 1 copy + 1 walk |
| 4a | `computeProducerInfo` | Staging/ProducerInfo.elm:33-46 | full walk #1 |
| 4b | `buildStagingGraph` | Staging/GraphBuilder.elm:53 | full walk #2 (ignores ProducerInfo!) |
| 4c | `Solver.solveStagingGraph` | Staging/Solver.elm:174-233 | walks StagingGraph only — not MonoGraph |
| 4d | `Rewriter.applyStagingSolution` | Staging/Rewriter.elm | full walk #3 (needs solution — cannot fuse upstream) |
| 5 | `validateClosureStaging` | Staging.elm:111-116 | **no-op stub** (returns input) |
| 6 | `abiCloningPass` | AbiCloning.elm:39-41 | **no-op stub** (returns input) |
| 7 | `annotateCallStaging` | MonoGlobalOptimize:1046-1058 | `Array.indexedMap` + UNCONDITIONAL deep rebuild of every composite expr |

## Non-negotiable architectural constraint

> **Never fuse across the Monomorphize → GlobalOpt handoff.** The `MonoGraph` that `Prune`
> returns is a HARD cut point (staging-agnostic Monomorphize vs GlobalOpt-owned staging,
> GOPT_001/016). All fusions below are within GlobalOpt. The InlineSimplify ↔ globalOptimize
> seam is **internal to GlobalOpt** and fair game (user-confirmed) — F3 crosses it.

---

## F1 — Delete the closure-count walks; merge buildCallGraph's two folds
**within `MonoInlineSimplify` — lowest risk, do first. Removes 2 deep walks (+1 fold).**

Verified facts: `metrics` is discarded in prod (Generate.elm:749 `( simplifiedGraph, _ )`) and
in TestPipeline (:334-336, :751-753 both `( simplifiedGraph, _ )`). The ONLY consumers of
`closureCountBefore/After` are MonoInlineSimplifyTest :211-232, and every assertion is
`Expect.atLeast 0 …` — vacuously true for any count, carrying no information.

**Steps:**
1. Remove `closureCountBefore`/`closureCountAfter` from the `Metrics` type (:43-44) — keep
   `inlineCount`, `betaReductions`, `letEliminations` (free: they come from `finalCtx.metrics`,
   no walk).
2. Delete `closuresBefore = countClosuresInGraph nodes` (:111-112), the `closuresBefore`
   parameter of `optimizeNodes` (:131-141), and `closuresAfter = countClosuresInGraph
   optimizedNodes` (:163-164).
3. Delete `countClosuresInGraph` (:3233-3245), `countClosuresInNode` (:3214),
   `countClosures` (:3160) — grep first to confirm no other callers.
4. Update MonoInlineSimplifyTest :211 (drop the two `closureCount*` expectations from the list)
   and :232 (replace the single `closureCountBefore` expectation with one of the surviving
   fields, e.g. `inlineCount`).
5. OPTIONAL (F1b, separate commit): `buildCallGraph` (:343+) folds `nodes` twice — once to
   assign indices, once to build adjacency. Inspect whether the two folds share an index
   invariant that lets them merge into one fold producing both. If entangled, skip — the win
   is one shallow fold, not a deep walk.

**Gate:** [BYTE-IDENTICAL] — metrics never influence the emitted graph.

## F2 — Fuse `computeProducerInfo` + `buildStagingGraph` into one traversal
**within `GlobalOpt/Staging` — verified unconditionally safe. Removes 1 full walk.**

Verified: `buildStagingGraph (Mono.MonoGraph mono) _ = …` — the `ProducerInfo` parameter is
`_`, unread anywhere in GraphBuilder (grep-confirmed; it reconstructs producer identities
directly from the AST in `producerFromExpr` :437-451). The Solver is the only ProducerInfo
consumer (`Dict.get (producerIdToKey pid) producerInfo.naturalSeg`, Solver.elm:226-248) and it
runs AFTER both walks, on the completed maps. So the two `Array.foldl`s over `mono.nodes`
(ProducerInfo.elm:33-46 and GraphBuilder.elm) can merge into ONE fold with no ordering hazard.

**Steps:**
1. In `Staging.elm` `analyzeAndSolveStaging` (:62-96): replace
   `producerInfo = ProducerInfo.computeProducerInfo graph0` +
   `sg = GraphBuilder.buildStagingGraph graph0 producerInfo`
   with one fused fold producing `( producerInfo, sg )`. Mechanically: add a
   `GraphBuilder.buildStagingGraphFused : Mono.MonoGraph -> ( ProducerInfo, StagingGraph )`
   whose per-node step runs `ProducerInfo.foldNode` (:49-122; expose it) and GraphBuilder's
   per-node step side by side in one `Array.foldl`. Drop `buildStagingGraph`'s dead
   `ProducerInfo` parameter while there.
2. **Preserve the early-out** (Staging.elm:71-80): today, if `producerInfo.naturalSeg` is
   empty, graph-building/solving/rewriting are all skipped and `graph0` is returned. Keep
   that check AFTER the fused fold: `if Dict.isEmpty producerInfo.naturalSeg then (skip,
   discarding sg) else …`. Cost: the rare empty case now builds a (tiny) StagingGraph it
   discards — acceptable; semantics identical.
3. `Rewriter.applyStagingSolution` stays separate (needs the Solver's solution — verified).

**Gate:** [BYTE-IDENTICAL] — Solver consumes identical `ProducerInfo` + `StagingGraph`.

## F3 — Fold `wrapTopLevelCallables` into InlineSimplify's output path
**intra-GlobalOpt (crosses the internal InlineSimplify↔globalOptimize seam — approved).
Removes 1 array copy + 1 walk. Contains the one real byte-identity trap: read carefully.**

Verified shape of `wrapTopLevelCallables` (MonoGlobalOptimize:963-990): an `Array.foldl` over
nodes threading `( accNodes, specId, accCtx )`; per node it reads ONLY (a) the node itself,
(b) `specHome accCtx.registry specId` — the CURRENT node's registry entry (:976, :143), and
(c) a threaded `lambdaCounter` for minting `AnonymousLambda home uid` ids (:53-61). It never
reads other nodes (grep-confirmed range 570-960), never changes SpecIds, is 1:1 per node.
InlineSimplify's `optimize` passes `registry` through unchanged and emits
`nextLambdaIndex = finalCtx.lambdaCounter` (:180); wrap seeds its counter from exactly that.

**THE TRAP:** both passes mint lambda ids from the same monotonic sequence. Today ALL
inline-minted ids precede ALL wrap-minted ids. If wrap runs per-node inside the inline fold,
the ids interleave → different `AnonymousLambda` uids → different emitted symbol names →
corpus NOT byte-identical. **Do not fuse per-node into `optimizeNode`.**

**The safe fusion — wrap the LIST between the fold and the `Array.fromList`:** today the
pipeline is: inline fold → `List.reverse` → `Array.fromList` → (fresh Array #1) → wrap's
`Array.foldl`+`Array.push` → (fresh Array #2). Instead:
1. Extract wrap's per-node worker (`wrapNodeCallables` :998 / `ensureCallableForNode` :516 +
   the `GlobalCtx` counter threading) so it can run against a `List` fold. Keep it in
   `MonoGlobalOptimize.elm` (or a shared module) as its own named function — the sub-passes
   remain separate *functions*; only the *traversals* merge.
2. In `optimizeNodes`: after `List.reverse optimizedNodesList` (now in specId order), run the
   wrap worker as a single `List.foldl`/mapAccum over that list — seeding its lambda counter
   with `finalCtx.lambdaCounter` (the same value wrap sees today) and threading it in specId
   order (same order as today's `Array.foldl`) — then ONE `Array.fromList` of the wrapped
   list. Emit `nextLambdaIndex` = the wrap counter's final value.
   Result: identical id numbering (all inline ids, then wrap ids in specId order), one Array
   materialization instead of two, one walk instead of two.
3. Delete Phase 1 from `globalOptimize` (:113-114) and update its header comment (it now
   assumes wrapping was done by InlineSimplify). Update `MonoGlobalOptimize`'s module doc
   (":5 Assumes MonoInlineSimplify.optimize has already been applied" — still true, stronger).
4. Test impact (verified): TestPipeline pairs optimize→globalOptimize at both sites
   (:336→339, :753→756) — combined behavior unchanged. MonoInlineSimplifyTest's three
   `optimize` calls assert only vacuous properties (`Expect.atLeast 0`, `expectGraphValid`
   matches any graph), so wrapped output does not break them. No test calls `globalOptimize`
   on an un-inlined graph (grep-confirmed).
5. `registry` needed by the wrap worker is already in InlineSimplify's `RewriteCtx`
   (`initRewriteCtx … registry …` :118) — pass it to the wrap fold directly.

**Gate:** [BYTE-IDENTICAL] — the lambda-numbering argument above is the proof obligation; if
the corpus diffs, the id sequencing was NOT preserved — revert and re-derive.

## F5 (optional, largest allocation win, highest care) — changed-flag `annotateCallStaging`
**within `annotateCallStaging` — removes most of a full deep graph copy.**

Verified: `annotateExprCalls` (:1103) rebuilds EVERY composite unconditionally — `MonoLet`
:1119, `MonoCall` :1140, `MonoCase` :1151, `MonoIf` :1162, `MonoClosure` :1192, records/
tuples — via `List.map` recursion; only leaves return `expr` unchanged (:1238-1254). The only
mutation is on `MonoCall` nodes: a fresh `CallInfo` (from `computeCallInfo` :1917, or reused
when `existingCallInfo.stageArities` is non-empty :1133-1135). Every call-free subtree is
copied for nothing.

Apply the `NormResult`-style changed-flag pattern (see §3.6 work in TypeSubst / the
`listMapChanged` helpers): each arm returns `( changed, expr )`, composites rebuild only when
a child changed or (for `MonoCall`) `newCallInfo /= oldCallInfo` (CallInfo is a record of
basic types — structural `==` works). **Cautions (verified):**
- The rewrite is NOT a pure map: `CallEnv` threads through binding forms — `MonoLet` via
  `annotateDefCalls` returning `( def1, env1 )` (:1111-1119, four env extensions :1284-1321),
  `MonoTailFunc` param slots (:1071-1090), `MonoClosure` captures (:1173-1187). The
  changed-flag must NOT disturb env threading: thread env exactly as today; only the
  *reconstruction* becomes conditional.
- Do NOT restructure into re-runs: `extendSourceArityEnv` (:1569) exists precisely because
  re-running `annotateExprCalls` is "exponential in the depth of lets nested in bound
  position" (:1563-1566). The changed-flag is a per-arm return-value change, nothing more.

**Gate:** [BYTE-IDENTICAL].

## NOT SAFE — do not fuse `Rewriter` with `annotateCallStaging`
Verified with three decisive sites: `annotateCallStaging` reads OTHER nodes' POST-REWRITE
shape from the completed graph — `callModelForExpr` (:1377-1394, `Array.get specId nodes` on
the CALLEE), `sourceArityForExpr` (:1426-1449, callee's closure param count), and
`closureBodyStageArities` (:1762-1765). Fusing with the Rewriter would read half-rewritten
callees → wrong staging metadata. The passes stay separate; F5 reduces annotate's cost
without changing pass structure.

---

## Verification protocol (self-contained; per item)

1. `cmake --build build --target guida` → "Success! Compiled N modules".
2. Unit: `cmake --build build --target elm-tests` → `Passed: 12868, Failed: 0`.
3. E2E + **byte-identical corpus oracle** (the real gate for every item here):
   ```bash
   # baseline (once, on the pre-change commit, after a green E2E run):
   find build -type d \( -name eco-stuff -o -name elm-stuff \) -prune -exec rm -rf {} +
   /work/build/test/test           # expect 1547/1547
   mkdir -p /tmp/mlir_base && for d in build/test/*/eco-stuff/mlir; do
     pkg=${d#build/test/}; pkg=${pkg%%/*}; [ "$pkg" = "elm-http" ] && continue
     mkdir -p /tmp/mlir_base/$pkg && cp $d/*.mlir /tmp/mlir_base/$pkg/ 2>/dev/null; done
   rm -f /tmp/mlir_base/*/Http*.mlir   # HTTP tests are nondeterministic run-to-run (proven)
   # after each item: rerun E2E the same way, capture to /tmp/mlir_new, then:
   diff -rq /tmp/mlir_base /tmp/mlir_new   # MUST be empty
   ```
   A non-empty diff means the fusion changed semantics (F3: lambda renumbering) — revert.
4. **Bootstrap + gcstats** (the point of this plan — expect a real move, unlike §3.6):
   capture a FRESH baseline bootstrap before starting (the old gcstats files are gone; for
   reference, the post-§3.6 Stage-8a was ~2,287.7M objects / 69,677 MB / 13 majors). Then
   after F1+F2, and again after F3(+F5): `cmake --build build --target bootstrap` (exit 0,
   Stage-8c fixed point holds), diff the Stage-8a `=== GC Statistics ===` block. Watch
   **Custom**, **Cons**, and total objects/bytes. ONE bootstrap at a time
   (`pgrep -f "ninja bootstrap"` first — two racing on `build/` corrupt Stage 8a; happened).
5. One item per commit (F1 may be two: counts, then F1b); GITSTYLE.md messages; snapshot the
   touched files before each item and revert on any red gate — no in-place debugging of a
   supposedly behavior-preserving refactor.

## Sequencing & expected effect

**F1 → F2 → F3 → (F5).** F1/F2 are single-module and risk-free — land, bootstrap, measure.
F3 next (the copy removal with the numbering proof). F5 last and optional: largest win
(most of one full deep graph copy) but touches the most delicate pass; take it only with the
env-threading cautions above.

Expected walk/copy accounting: F1 −2 deep walks (+1 shallow fold if F1b); F2 −1 full walk;
F3 −1 array copy −1 walk; F5 −(the unchanged fraction — likely most) of 1 deep graph copy.
Against the post-§3.6 baseline this is the first work in this series that plausibly moves
Stage-8a Custom/Cons by whole percentage points rather than hundredths.

## Out of scope
- Any Prune ↔ InlineSimplify fusion (violates the hard Mono→GlobalOpt boundary).
- Rewriter ↔ annotateCallStaging fusion (verified unsafe above).
- Removing the `Array.toList` in `optimize` (:120-127 — it is a deliberate GC aid).
- The spec-key String intern (`monomorphization-perf-analysis.md` §5.1) — separate,
  dedup-risky Registry work.
- Filling in the `validateClosureStaging` / `abiCloningPass` stubs — unrelated features.
