# Post-inline dead-spec prune

**Status:** BUILT AND GATED 2026-09-13, DEFAULT-ON. Results in §8.
**Origin:** `plans/pre-mono-lss-transforms-03-lift-closed-lambda-args.md` §12.4 — the trace that
found every non-loopify `g1absentl` decline sitting in a spec that the post-mono inliner had
orphaned. Evidence base: `build/compiler/build-kernel/k-loop0.stderr` / `k-post0.stderr`
(`instQual.absentL` `T|` rows), the converted artifacts `$SP/k-loop0-text.mlir` /
`$SP/k-post0-text.mlir`, memory `g1absentl-612-are-io-continuations`.
**Independence:** touches nothing in `MonoInlineSimplify` and nothing in LSS. Lands on its own.

## 1. Problem

`MonoInlineSimplify` inlines a callee at a call site and leaves the callee's specialization in the
graph. When that was the spec's only reference, the spec is dead: no `eco.call`, no
`eco.papCreate`, no value reference anywhere. Nothing removes it. `Prune.pruneUnreachableSpecs`
runs once, at the END of monomorphization, and the inliner returns `callEdges = Array.empty`, so
the graph that reaches `MonoGlobalOptimize`, AbiCloning, CafHoist, Borrow and emission carries
every orphan through to `out.mlir`.

Measured on the self-compile (2026-09-13, `eco-src3`, unreferenced CODE-BEARING function
definitions in the emitted text; constructor and layout descriptors excluded):

| arm | dead functions | bytes | share of the text artifact |
|---|---:|---:|---:|
| `ECO_INLINE_POST_MONO=0` | 921 | 1,079,342 | 1.27 % |
| defaults | **6,608** | **4,508,040** | **4.86 %** |

The delta is the inliner's leftovers and it is exactly the "called-param" class the pass exists
to inline: `Task.andThen` 1,116, `List.foldr` 917, `Task.map` 408, `Task.succeed` 290,
`Elm.JsArray.foldl` 177. η-expansion (plan 01) made the monad-bind sites saturated,
`hofThreshold` admits the bind, the single caller is inlined and its callback beta-reduces away —
the intended win — and the keyed spec stays behind.

Two consequences, one of which is why this was found at all:

  - **Artifact size.** ~3.4 MB of MLIR text per self-compile that lowers, links and ships for
    nothing. (`out.mlir` is bytecode; the byte delta there is smaller but of the same order.)
  - **Census noise.** AbiCloning walks the dead specs and consults their call sites. All 1,758
    `g1absentl` declines at defaults (plan 03 §11–§12: 1,146 loopify-made, 612 hof-inline-made)
    are sites in dead specs whose callback member has no instance BECAUSE the inliner consumed
    it. They are counted as noInstance declines, hosted under `List.foldl`, `IO.andThen`,
    `Result.andThen`, `Maybe.map`, and they have misdirected two plans (this arc's item 3, and
    §12.3's dispatch attribution before the per-site trace corrected it). They carry zero
    dispatch.

The 921 dead functions with the inliner OFF are a separate, pre-existing population (mono-time
`Prune` keeps them; `List.foldl` 471 of them). This plan removes those too — same walk — but
they are not its motivation and are not part of the gate.

## 2. Where the prune goes, and why not inside the inliner

**A separate pass, immediately after `MonoInlineSimplify.optimize` returns**, in
`Builder/Generate.elm:runMonoOptPipeline` (today `:1010`), before the `Task.andThen` into
`runGlobalOptPhase`. Not inside the inliner, for three reasons that were each checked:

  1. **Deadness is a global fact the inliner never has at a replacement site.** A spec stays
     alive through ANY `MonoVarGlobal` occurrence — a call, a PAP builder (`eco.papCreate
     function=@spec`, the shape every `IO.andThen` wrapper in §12.4 has), a value stored in
     data. The inliner tracks the calls it inlines (`inlinedByCallee`), not the references it
     leaves.
  2. **Inlining ADDS references.** Copying a body that names spec S into three callers adds
     three references to S (`remapLambdaIds` copies verbatim). A per-site decrement needs an
     exact initial count plus increments on every copy, across `fixpointIterations` rounds, with
     the walk proceeding one SCC at a time. That is reference counting bolted onto a rewriter.
  3. **The body must stay in the array while any caller might still inline it.** Deleting
     mid-fixpoint races the later rounds; the callee body is read from `nodes` by
     `buildBodyLookup`.

A reachability walk over the FINISHED graph answers the question in one linear pass and cannot
be wrong about ordering.

**Why before `MonoGlobalOptimize`.** At that point the only cross-spec references are
`MonoVarGlobal`. Everything that later references a spec by another route comes after the prune
and therefore cannot dangle: AbiCloning's fast-dispatch stamps (`fastEvaluatorSpec`), post-settle
devirt targets (`PsStamp specId` — chosen from `specsByGlobal`, which is inverted from
`reverseMapping`), CafHoist's minted CAF specs, `wrapTopLevelCallables`' wrappers. Placing the
prune after any of those would require treating `CallInfo` fields as edges.

## 3. Design

### 3.1 Reuse `Prune`, do not write a second reachability

`Compiler/Monomorphize/Prune.elm` already does the whole job for the mono-time call:
`reachableFromMain` (BitSet DFS over `callEdges` from the roots), then filter `nodes` to
`Nothing` gaps, filter `callEdges`, null dead `reverseMapping` entries, recompute `ctorShapes`.
Spec ids are array indices and stay stable — no renumbering, nothing downstream moves.

Two things stop it being called as-is after the inliner:

  - **Edges.** The inliner returns `callEdges = Array.empty` (`MonoInlineSimplify.elm:938`), and
    even the mono-time array is stale by then (bodies changed). Re-collect from the rewritten
    bodies. `Borrow.collectEdges` (`Borrow.elm:419`, "callEdges is empty at Phase 6") already
    does exactly this — `Array.map (Maybe.map collectFromNode)`, every `MonoVarGlobal` an edge
    whatever its position — because Borrow hit the same emptiness. Move it to a shared home
    (`MonoTraverse.collectSpecEdges`), have Borrow call the shared one, and hand its result to
    the prune. Every-occurrence collection is the rule: the 2026 bitset plan
    (`plans/prune-bitset-calledges-reachability.md`) was BLOCKED on an incomplete `callEdges`
    once, and the failure mode was MONO_011 / CGEN_044 at 702 tests. The edge collector must be
    one full expression fold, never a curated list of constructors.
  - **The number-var close.** `pruneUnreachableSpecs : State.MVarEnv -> TypeEnv.GlobalTypeEnv ->
    MonoGraph -> MonoGraph` fuses MONO_028 quiescence closing into the rebuild and needs the
    mono-time environment for `isNumberVar`. Post-inline there are no residual number vars (the
    mono-time call already crashed on any survivor, MONO_002), so the close is a no-op — but the
    environment is not in scope in `runMonoOptPipeline`. Split `Prune` into the reachability
    core and the closing wrapper:

    ```elm
    -- Prune.elm
    pruneUnreachableWith : Array (Maybe (List SpecId)) -> (MonoNode -> MonoNode) -> MonoGraph -> MonoGraph
    pruneUnreachableSpecs mvarEnv globalTypeEnv graph =        -- unchanged signature, mono-time
        pruneUnreachableWith record.callEdges (closeNodeWith mvarEnv) graph
    pruneAfterInline : MonoGraph -> MonoGraph                    -- NEW, post-inline
    pruneAfterInline graph =
        pruneUnreachableWith (MonoTraverse.collectSpecEdges nodes) identity graph
    ```

    `pruneUnreachableWith` is the existing body with the edge array and the node closer taken
    as parameters.

    AS BUILT the closer is a record (`node`/`tipe`/`hasResidual`/`ctorShapes`), and
    `ctorShapes` is NOT recomputed post-inline: it is carried through. Recomputing needs
    `globalTypeEnv` threaded to the hook and costs a whole-graph walk, to produce a map that can
    only be a subset of the one already there — and pruning only removes nodes, so the existing
    map is a superset of what the live nodes look up. Every consumer reads it by
    `Mono.layoutMapGet` on a type, never by iteration, so an unused entry is inert. Mono time
    still recomputes, because closing CHANGES the layout keys and they must match the closed
    nodes.

### 3.2 Roots

Identical to the mono-time call: `main` (`StaticMain`), every `PortRegistration.decoderSpecId`,
`flagsDecoder`. All three are referenced only from generated preambles emitted after any prune
(PORT_003, Phase 5). `main = Nothing` (a library compile) keeps everything, as today.

No new root is needed at this position — verified by enumerating what references a spec by
something other than a `MonoVarGlobal`: AbiCloning `CallInfo` stamps (after), CafHoist mints
(after), `MonoManagerLeaf` (reached from `main` through the effect-manager plumbing, exactly as
at mono time), kernel `MonoExtern` (not a caller). If a future pass adds a by-name reference
before this point it must add a root here; §7's `mono.validate` check is what would catch the
omission.

### 3.3 Registry hygiene is load-bearing, not cosmetic

Nulling the dead `reverseMapping` entries is the soundness half of the pass. E9.5 post-settle
devirt (`AbiCloning.postSettleTarget`) picks a direct-call target among the registry's specs of
a global (`specsByGlobal`, built by folding `reverseMapping` and SKIPPING `Nothing` entries,
`AbiCloning.elm:856-870`). A dead spec left in the registry is a candidate whose node is gone:
`PsStamp specId` would emit `eco.call @dead` and CGEN_044 fires at lowering — or, worse, if the
node were left too, a call into code that no longer receives the callback it was keyed on. The
existing prune already nulls them; `pruneUnreachableWith` inherits it. `registry.mapping` is
already `specKeyMapEmpty` after mono-time pruning and `countByGlobal` is `Dict.empty`; both
stay.

### 3.4 Flag and hash

`inline.pruneDead : Bool`, default `True` once §7's gates pass (§8), env
`ECO_INLINE_PRUNE_DEAD=0` to turn off, hash token `prune=` in `Compiler/Eco/Config.elm`'s
config hash (artifact-affecting: it removes functions). Plumbing copies `applyInlinePreserveSetsOverride`
verbatim (`Builder/Eco/Config.elm`, record UPDATE through the `inline` binding; the flat
`InlineConfig` record is not near a slot cap). The flag exists for the byte-identity gate and
for a one-line diagnosis if a later pass ever dangles; it is not expected to be turned off in
anger.

With `inline.postMono = False` the prune still runs (the 921 pre-existing dead functions are
real), so the EARLY arm of the position A/B changes by exactly that population. Record it.

### 3.5 Report line

Behind `inline.report`, on the existing `inline-simplify:` line or a `post-inline-prune:` line:
`pruned=<n> kept=<n> bytesEstimate=` (node count only; no size estimate in Elm), plus the top 10
pruned globals by count. Zero cost report-off. `closuresRemaining` on the inline line is
computed from `simplifiedGraph` today; compute it AFTER the prune so it stops counting closures
in dead code (record the before/after once, in §8, since every downstream reading of that field
shifts).

## 4. Adversarial review

**R1 — an edge the collector misses = a pruned live spec = MONO_011.** The one real risk, and
the one that has bitten before. RESOLUTION: the collector is a single `MonoTraverse.foldExpr`
over every node expression matching only `MonoVarGlobal`; `foldExpr` visits every child
(`foldChildren` is total over the constructor set). Gate: `mono.validate` runs a post-prune
closure check — every `MonoVarGlobal` in every live node names a live node (§7.2) — and the
full E2E suite under `ECO_MONO_VALIDATE=1`.

**R2 — something between the inliner and the prune references a spec by other means.** Nothing
does today (§3.2). RESOLUTION: the prune is the FIRST thing after the inliner, and the
`mono.validate` check makes any future violation loud at the point of insertion.

**R3 — the reference census reads dead code.** `renderInlineReportWith` counts
`closuresRemaining` over the graph; AbiCloning's whole census (`lss globalopt:`, `coverage:`,
`niGuard`, `byHost`) counted dead sites until now. RESOLUTION: every one of those numbers moves
once, downward, and the move is the CORRECTION. Record the before/after pair in §8 and in
`benchmarks/call-stats.md` as a protocol note so no later A/B compares a pre-prune row to a
post-prune one on `noInstance` or `declinedNoInstance`.

**R4 — dispatch.** None expected: dead code does not execute. Gate: the two-arm protocol's
`sat`/`gen`/`fast` flat to noise; `stampedPapGlobal`/`dispatchUpgraded` may DROP by the number of
stamps that were in dead specs — that is not a regression, and the census should say how many.

**R5 — CafDedupe / CafHoist interplay.** CafHoist mints new specs after the prune and its
dedupe map is built from its own candidates, not the registry; no dependence. RESOLUTION: none
needed; `caf-hoist:` counters recorded in §8.

**R6 — the EARLY arm.** `postMono=0` + prune removes the 921; `postMono=0` alone keeps them.
Any future position A/B must run both arms with the flag in the same state. Documented on the
flag.

**R7 — bootstrap.** The compiler compiling itself: the pruned artifact must reproduce itself
(fixed point) and the flag flip needs one extra iteration to propagate (memory
`premono-inliner-shipped-default-on`: `A != B` is propagation, the gate is `B == C`).

## 5. Lowered steps

| # | change | files | gate |
|---|---|---|---|
| 1 | Move `collectEdges`/`collectFromNode`/`collectFromExpr` to `MonoTraverse.collectSpecEdges`; Borrow calls it | `Monomorphize/MonoTraverse.elm`, `GlobalOpt/Borrow.elm` | byte-identical output |
| 2 | Split `Prune` into `pruneUnreachableWith` + the mono-time wrapper; add `pruneAfterInline` | `Monomorphize/Prune.elm` | mono-time output byte-identical (the wrapper is the old body) |
| 3 | Flag + plumbing + hash token | `Compiler/Eco/Config.elm`, `Builder/Eco/Config.elm` | env round-trips; hash token present; byte-identical flag-off |
| 4 | Hook after `MonoInlineSimplify.optimize` in `runMonoOptPipeline`; report line; `closuresRemaining` after the prune | `Builder/Generate.elm` | flag-on self-compile: `g1absentl` from 1,758 to ≈0; report shows `pruned≈6,600` |
| 5 | `mono.validate` post-prune closure check (R1) | `Builder/Generate.elm` (next to `validateMinted`) | E2E under `ECO_MONO_VALIDATE=1`, both flag states |
| 6 | Unit tests §7.1 | `tests/TestLogic/Monomorphize/PostInlinePruneTest.elm` | green |
| 7 | Gates §7.2–7.3 | — | E2E both arms; fixed point; two-arm protocol flat |
| 8 | Default-on; record §8; amend plan 03 §12.4 and `benchmarks/call-stats.md` protocol note | this file, plan 03, benchmarks | `B == C` bootstrap after the flip |

## 6. What is deliberately NOT changed

  - `MonoInlineSimplify` is untouched. No reference counting, no in-pass deletion.
  - Spec ids are never renumbered. Dead slots become `Nothing`, as at mono time; emission already
    skips them (`Functions.generateNode` walks `Array (Maybe MonoNode)`).
  - The mono-time prune keeps its signature and behaviour; the split is a refactor with a
    byte-identical gate.
  - `lssMemberOrigins` / `lssMemberKinds` / `lssBlockedMembers` are not filtered. They are
    keyed by member id, not spec id, and a member whose only instance died is exactly what
    AbiCloning's index already handles (it simply never sees a site for it now). Filtering them
    would be a second reachability over members for no consumer.

## 7. Tests and measurement

### 7.1 Unit — `PostInlinePruneTest.elm`

Harness: `TestPipeline.runToMono` then `MonoInlineSimplify.optimize` then `Prune.pruneAfterInline`.

  - A small global inlined at its only call site: its spec is `Nothing` after the prune and the
    caller's body contains no `MonoVarGlobal` to it.
  - The same global referenced ALSO as a value (`List.map f xs` with `f` a global — a PAP
    builder): its spec is kept.
  - A port decoder spec and the flags decoder are kept with no references in any body (roots).
  - `reverseMapping` entry of a pruned spec is `Nothing`; of a kept spec unchanged.
  - Every `MonoVarGlobal` in every live node names a live node (the R1 closure check as a test).
  - Flag off: the graph is returned unchanged (structural equality).

### 7.2 E2E

`--target full` with the flag on, then at defaults after the flip, both under
`ECO_MONO_VALIDATE=1`. The `ECO_INLINE_POST_MONO=0` leg (the EARLY arm) once, to record R6.

### 7.3 Measurement — `benchmarks/call-stats.md` Run 9

Two-arm protocol (reference = subst-built from the current tree; both arms with every flag
explicit). Expected: `out.mlir` smaller by the pruned functions; `noInstance`,
`declinedNoInstance`, `g1absentl` and `closuresRemaining` fall (correction, not regression);
`sat`/`gen`/`fast` flat to noise; wall flat. Any `sat` movement beyond noise means the
prune removed something live and R1's gate missed it — stop and diff the artifacts.

## 8. Results (2026-09-13)

### 8.1 What shipped

`Config.default.inline.pruneDead = True` (`ECO_INLINE_PRUNE_DEAD=0` turns it off; hash token
`prune=`). Four source changes, in the order §5 lowered them:

  - `MonoTraverse.collectSpecEdges` — the every-`MonoVarGlobal` adjacency, moved out of `Borrow`
    (which had written it for the same "callEdges is empty at Phase 6" reason) so both post-mono
    consumers walk ONE relation that cannot drift.
  - `Prune.pruneUnreachableWith` + a `Closer` record — the reachability, the node/registry/edge
    filter and the ctorShapes step, parameterized. `pruneUnreachableSpecs` keeps its signature and
    passes the mono-time closer (quiescence closing fused in, ctorShapes recomputed);
    `pruneAfterInline` passes the identity closer and carries ctorShapes through.
  - `Generate.runMonoOptPipeline` — the hook, immediately after `MonoInlineSimplify.optimize`,
    plus a `post-inline-prune:` census line and `renderInlineReportWith` moved onto the PRUNED
    graph.
  - `Generate.validatePruned` — the MONO\_011 closure check under
    `mono.validate` (`ECO_MONO_VALIDATE=1`).

MONO\_022 amended: the invariant now names the post-inline re-establishment, the roots, and the
"a call, a `papCreate` and a stored reference are equally edges" rule.

### 8.2 Gates

| gate | result |
|---|---|
| Unit (`elm-tests`) | **13,512 / 12** — the 12 are the pre-existing POST\_010 accessor failures; the 6 new are `PostInlinePruneTest` |
| E2E, plain defaults (prune ON) | **1,725 / 1,725** |
| E2E, `ECO_INLINE_PRUNE_DEAD=0` | **1,725 / 1,725** |
| E2E, prune ON + `ECO_MONO_VALIDATE=1` | 1,720 / 1,725 — all 5 are the PRE-mono identity validator (`ArrowId N occurs twice`), which runs before monomorphization. CONTROL: both reproduce with the prune OFF, so they are pre-existing and independent (`LssGapCtorRebuild` ArrowId 1619, `UnboxApplyNothingTest` ArrowId 1633). The post-prune closure check itself fired on nothing. |
| Flag-off byte identity | **IDENTICAL** — the new binary at `ECO_INLINE_PRUNE_DEAD=0` reproduces `eco-psetsDefA`'s emission on a fixed input (5,391 B) |
| Bootstrap fixed point | **B == C at 13,367,419 B** |

### 8.3 The artifact

The flag flip needed the recorded extra iteration: A is the new source compiled by the PRE-flip
binary, so A carries the new default but was produced without pruning. `A != B` is the flip
propagating; the gate is `B == C`, and it holds.

| build | out.mlir (B) |
|---|---:|
| A — new source, compiled by the pre-change binary (no prune) | 15,532,506 |
| B — compiled by A (prunes) | **13,367,419** |
| C — compiled by B | 13,367,419 (identical to B) |

**−2,165,087 B, −13.94 %** of the compiler's own artifact. That is larger than §1's 4.86 %
estimate, and the two are not the same measurement: §1 counted unreferenced CODE-BEARING function
definitions in the MLIR TEXT of one arm, excluding constructor and layout descriptors, whereas
this is the whole bytecode artifact with every dead definition of any kind removed.

On the `PapStampTest` fixture the pass reports `pruned=6 kept=15` and the artifact goes
5,391 B → 4,738 B (−12.1 %); `List.foldl` is among the six, which is the fixture's single
`g1absentl` host disappearing exactly as §1 predicted.

## 9. What not to do

  - Do not prune inside the inliner or add reference counts to it (§2).
  - Do not collect edges from a hand-written constructor list; one `foldExpr`, every
    `MonoVarGlobal` (§3.1, the bitset plan's failure).
  - Do not place the pass after AbiCloning; `CallInfo` then holds spec references the collector
    does not see (§2).
  - Do not renumber spec ids to close the gaps. Ids are keys in `reverseMapping`, `callEdges`,
    LSS member keys (`l|<raw>|<specId>`), CafHoist and AbiCloning's `hostSpecId`.
  - Do not compare a pre-prune census row to a post-prune one on any `noInstance` figure (R3).

### 8.4 Run 9 / Run 10 — dispatch neutral, artifact −13.94 %

`benchmarks/call-stats.md` Runs 9 (`prune=1`) and 10 (`prune=0`). The SAME two binaries do both
runs, so every difference is the workload flag; both reference arms are a subst build of the
current tree, which can honour it.

| | prune=0 | prune=1 | Δ |
|---|---:|---:|---:|
| `out.mlir` | 15,532,506 | 13,367,419 | **−13.94 %** |
| specs | 43,827 | 33,930 | **−9,897 (−22.6 %)** |
| `sat` (benchmark) | 846,220,006 | 841,170,945 | −0.60 % |
| `sat` (reference) | 2,849,654,112 | 2,836,638,231 | −0.46 % |
| `fast %` | 54.79 | 54.83 | +0.04 pp |
| wall (benchmark, s) | 529.4 | 525.7 | noise at N=1 |

**Dispatch is neutral, as §7.3 predicted.** The benchmark arm's −0.60 % is almost entirely the
reference arm's −0.46 %: the same binary compiling the same source under the other flag moves
nearly as much, so the delta is the pass's own saved work (there is less code to walk downstream),
not a property of the pruned binary. The residue is ≈0.14 %, below what one run resolves.

Group 1 (lss-coverage) is IDENTICAL to the digit across the two runs — 148,838 positions, 101,254
`k1`, 34,597 `kN`. Coverage is measured during monomorphization, upstream of the prune, which is
the cleanest possible statement that the pass changes no analysis.

### 8.5 The census corrections, and `g1absentl` = 0

R3 said every AbiCloning figure would step down once. Measured (Runs 9/10, identical in both arms):

| | prune=0 | prune=1 |
|---|---:|---:|
| `dispatchUpgraded` | 18,139 | 16,673 |
| `stampedPapGlobal` | 3,722 | 3,251 |
| `declinedNoInstance` | 14,662 | 10,917 |
| `declinedBlocked` | 4,084 | 2,418 |
| `multiInstanceGroups` | 3,667 | 1,783 |
| `devirtPost.fn` | 108 | 67 |
| **`g1absentl`** (`ECO_MONO_LSS_CENSUS=1`) | **1,781** | **0** |

**`g1absentl` goes to ZERO**, which closes plan 03 §12.4's diagnosis completely: every one of those
declines was a call site in a specialization nothing reaches, whose callback member had no
instance because the inliner had consumed the closure on purpose. Not one was a missed
optimization. The same is now true of the 1,146 loopify-made ones, which §8's open question asked
about — they are in the 1,781 and they are gone with it.

A stamp recorded at a site that never executes was never worth anything, so the 1,466
`dispatchUpgraded` and 471 `stampedPapGlobal` that disappear are bookkeeping, not lost work; the
dispatch numbers in §8.4 are the proof, since they do not move.

`benchmarks/call-stats.md` carries a protocol note: do NOT compare a group-2 figure from Runs 1-8
with one from Run 9 onward. Groups 1, 3 and 4 stay comparable.
