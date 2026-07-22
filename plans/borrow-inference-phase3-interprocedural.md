# Borrow Inference — Phase 3: Interprocedural Signatures (B3)

Status: IMPLEMENTATION-READY (v2, deep-dive pass). Parent design:
`design_docs/globalopt/borrow-inference-design.md` (v2) §11, §12;
milestone B3. Series: `plans/borrow-inference-phase{0..6}-*.md`.

**Dependencies:** Phase 2 (walker + solver + census live). Phase 0's
U0.3 audit feeds U3.2's table content. **Feeds:** Phase 4 (handshake)
and Phase 5 (reification precision). **Gates:** B2 gates re-pass +
census shows boundary recovery (`poisonedParams` down) + BORROW_005
check + wall budget re-measure.

**Goal:** per-SpecId `BorrowSig`s via a reverse-topological SCC
fixpoint, plus the audited kernel signature table — direct calls and
kernel calls stop being all-owned poison.

All new modules go under `compiler/src/Compiler/GlobalOpt/Borrow/`.
Adding a new compiler `.elm` source requires a reconfigure —
`cmake --preset build` — because `ELM_SOURCES` is a non-CONFIGURE_DEPENDS
glob (the `ninja-clang-lld-linux` preset name in CLAUDE.md is stale;
the configure preset is `build`).

## Verified facts this plan is built on

1. **`MonoGraph.callEdges` is EMPTY at Phase 6 — not merely stale.**
   `MonoInlineSimplify.optimize` reassembles the graph with
   `callEdges = Array.empty` (and empty `specHasEffects`/`specValueUsed`)
   at `MonoInlineSimplify.elm:900`, and the pipeline order is
   inline-simplify → GlobalOpt (`Builder/Generate.elm:802`
   `runInlineSimplifyPhase` → `:823` → `:900` `runGlobalOptPhase`;
   `MonoGlobalOptimize.elm:97` "Assumes MonoInlineSimplify.optimize has
   already been applied"). GlobalOpt phases 1–5
   (`globalOptimizeWithStats`, `MonoGlobalOptimize.elm:125-152`) never
   touch the field: P1 `wrapTopLevelCallables` (`:1004`) wraps node
   bodies in alias closures, P2/P3 Staging rewrites wrappers/types, P4
   AbiCloning stamps `CallInfo`/clones lambdas (lambdaIds, not SpecIds),
   P5 `annotateCallStaging` rewrites `CallInfo` — none writes
   `callEdges`. **Re-collection is mandatory, not optional prudence.**
   (Design §5.3/§11.1 say "may have staled" — reality is stronger; see
   Design discrepancies.)
2. **`stronglyConnCompInt` already returns reverse-topological order
   (callees first) — no reversal needed.** `Compiler/Graph.elm:38-69` is
   Kosaraju with the passes mirrored: the first DFS
   (`reversePostOrder`, `:291`) runs on the **transposed** graph and the
   component-collection DFS (`collectComponent`, `:340`) on the
   **forward** graph. Standard Kosaraju emits SCCs in topological order
   of the first-pass graph's condensation; here that graph is Gᵀ, so
   emission order = topo order of Gᵀ = sinks of G first. With
   `fwd` = caller→callee (as `buildCallGraph` builds it), sinks are leaf
   callees — emission is callees-before-callers. The fold accumulates
   with `::` and the final `List.reverse sccs` (`:69`) restores emission
   order, so the returned list is processed head-to-tail as-is.
3. **Mono kernel names carry NO `_Int/_Float/_Char` suffix — no
   normalization needed.** `MonoVarKernel Region Name Name Name MonoType`
   is "kernel prefix, home, name, type" (`Monomorphized.elm:917`), e.g.
   `("Elm","Utils","compare")`, `("Eco","Console","write")`. The suffix
   is chosen at MLIR emission time only: `kernelInstanceSymbol`
   (`Generate/MLIR/KernelAbi.elm:182`) pattern-matches
   `(home, name, argTypes)` — e.g. `("Utils","compare",[MInt,MInt]) →
   "_Int"` — building `<prefix>_Kernel_<home>_<name><suffix>`.
   `Monomorphize/KernelAbi.suffixSelectingKernels` (`:145-193`) only
   controls whether the concrete MonoType is *preserved* so the emitter
   can select; it never renames. `KernelTypeEnv` keys by `(home, name)`
   (`Type/KernelTypes.elm:44`: `Dict ( Name, Name ) (Can.Type Name)`).
   Verdict: `Borrow/KernelSigs.lookup` keys by plain `(home, name)`,
   ignoring the prefix field.
4. **CallKind/CallInfo** (`Monomorphized.elm:1493-1497, 1538-1550`):
   `CallKind = CallDirectKnownSegmentation | CallDirectFlat |
   CallGenericApply | CallSegmentationUnknown`.
   `isSingleStageSaturated : Bool` is "consumes all arguments and fits
   entirely in the first stage" — so both under-application (PAP
   creation) and over-application report `False`. `stageArities : List
   Int` is the callee's full stage-arity list.
5. **The mono-time edge fold to copy**: `Monomorphize.elm:532-570` —
   `extractSpecId` (cons `specId` on `MonoVarGlobal _ specId _`),
   `collectCalls = Traverse.foldExpr extractSpecId []`,
   `collectCallsFromNode` (bodies of `MonoDefine`/`MonoTailFunc`/
   `MonoPortIncoming`/`MonoPortOutgoing`; `[]` for
   `MonoCtor`/`MonoEnum`/`MonoExtern`/`MonoManagerLeaf`). Design §5.3
   explicitly blesses `MonoTraverse.foldExpr` for this one-shot fold.
6. **TestLogic home**: `compiler/tests/TestLogic/GlobalOpt/` (existing:
   `MonoInlineSimplifyTest.elm`, `CallInfoComplete.elm`).
   `TestLogic.TestPipeline.runToGlobalOpt : Src.Module -> Result String
   GlobalOptArtifacts` (`TestPipeline.elm:332`) yields
   `.optimizedMonoGraph : Mono.MonoGraph` (`:160`). Fixtures are built
   with `Compiler.AST.SourceBuilder`
   (`compiler/tests/Compiler/AST/SourceBuilder.elm`: `define, callExpr,
   ifExpr, listExpr, binopsExpr, intExpr, varExpr, tLambda, tType, …`);
   `SourceIR.LocalTailRecCases` shows the tail-recursive fixture idiom.
   elm-test-rs auto-discovers any tests-dir module exposing `suite :
   Test`; no aggregator registration exists or is needed.

### Design discrepancies

- Design §5.3/§11.1 hedge that `callEdges` "may have staled" through the
  inline pre-pass and wrapper insertion. Code fact: the inline pass
  **discards** it (`callEdges = Array.empty`,
  `MonoInlineSimplify.elm:900`). Same conclusion (re-collect), stronger
  reason. Any Phase-6 code path that read `callEdges` would silently see
  an edgeless graph — one SCC per def, no ordering — so U3.1 must not
  even fall back to it.
- Design §5.3 cites `buildCallGraph` at `:1057-1210`; actual anchors are
  `type alias CallGraph` `:1057-1060`, `buildCallGraph` `:1063-1206`.
  Cosmetic.

## U3.1 — `Borrow/Sig.elm` + driver upgrade (~200 + ~250 LoC)

Files: **create** `compiler/src/Compiler/GlobalOpt/Borrow/Sig.elm`;
**edit** `compiler/src/Compiler/GlobalOpt/Borrow.elm` (Phase 2's driver)
and `Borrow/Constrain.elm` (call-boundary upgrade). Reconfigure after
creating Sig.elm (`cmake --preset build`).

### U3.1.a — Signature types (`Borrow/Sig.elm`)

```elm
module Compiler.GlobalOpt.Borrow.Sig exposing
    ( BorrowSig, SigTy, ResPos
    , optimisticSig, allOwnedSig, readbackSig, sigEq
    )

type alias ResPos =
    Int   -- pre-order position index into an RTy's resource list

type alias SigTy =
    { shape : Mono.MonoType        -- ground; freshRTy re-mints at use sites
    , modes : Array Mode           -- indexed by ResPos (pre-order of Rty.allRes)
    }

type alias BorrowSig =
    { params : List SigTy
    , result : SigTy
    , resultLts : List ( ResPos, Set Int )  -- result position → LParams set
    }
```

**Position convention (decision):** a `SigTy` carries modes positionally,
indexed by the pre-order mint order of `freshRTy`/`Rty.allRes` (Phase 2
U2.1). This is sound because every pairing site zips *ground, equal*
MonoTypes (design §7.3: "always aligned … ground and equal by
construction"), so re-minting `freshRTy` from `shape` at a call site
reproduces the same resource ordering. No per-signature ResVars are
stored — signatures are pure data, decoupled from any def's variable
supply.

- `optimisticSig : List Mono.MonoType -> Mono.MonoType -> BorrowSig` —
  params all-`Borrowed` per position; `resultLts` seeded so that each
  param top resource carries lifetime var αᵢ = `LParams (Set.singleton
  i)` when the def is analyzed (the driver seeds param resources, see
  U3.1.d); result modes all-`Borrowed`, `resultLts = []` (design §11.1:
  "params Borrowed with fresh α, results LParams ∅").
- `allOwnedSig : List Mono.MonoType -> Mono.MonoType -> BorrowSig` — the
  poison/baseline sig (every mode `Owned`, `resultLts = []`); used for
  ports/extern/manager nodes and the non-convergence bailout.
- `readbackSig : Solved -> List RTy -> RTy -> BorrowSig` — for each
  param RTy: `modes = Array.fromList (List.map (\r -> Solve.reifiedMode
  r solved) (Rty.allRes rty))` (Phase 2 U2.3's §9.5 primary-rule API;
  note the argument order is `reifiedMode : ResVar -> Solved -> Mode`,
  ResVar first — the lambda avoids the inverted partial application);
  same for the result; `resultLts` = for each result resource whose
  solved **ltA** is `LParams s`, emit `(pos, s)`. **Decision:** read
  `resultLts` from ltA, not ltP — ltA is the superset approximation, and
  the caller-side consumer only *adds* coupling flows (§8.3), so a
  superset is the conservative direction. Flagged as an open question
  for design ratification.
  - **Phase 2 API dependency:** this unit (and U3.3's BORROW_005 test)
    read approximate lifetimes via Phase 2 U2.3's already-exported
    `Solve.ltAOf : ResVar -> Solved -> Lifetime.Lifetime` (Phase 2's
    U2.3 readback API declares `reifiedMode`, `ltAOf`, and
    `coercionPoints`, and retains the raw-ResVar lifetime arrays on the
    returned `Solved` record). No new Phase-2 accessor is required —
    `ltAOf` is the accessor. Provision `analyzeDefForTest` for U3.3 the
    same way (add it to `Borrow` if Phase 2 did not).
- `sigEq : BorrowSig -> BorrowSig -> Bool` — the convergence test:
  positional equality of all `modes` arrays + set-equality of
  `resultLts` (shapes are fixed across iterations; skip comparing them).

### U3.1.b — Edge re-collection (`Borrow.elm`)

Copy the `Monomorphize.elm:532-570` fold (verified fact 5) into
`Borrow.elm` (~25 lines — copying beats importing: `collectCalls` is
unexported from `Monomorphize.elm`):

```elm
collectEdges : Array (Maybe Mono.MonoNode) -> Array (Maybe (List Mono.SpecId))
```

One `Array.foldl` over `nodes` producing exactly the shape
`buildCallGraph` consumes (`Array (Maybe (List SpecId))`, index =
caller SpecId). Per node, `MonoTraverse.foldExpr` with the
`MonoVarGlobal _ specId _ -> specId :: acc` extractor over the four
body-carrying node kinds. Duplicate edges are fine (Kosaraju is
duplicate-insensitive; `List.member`-based self-loop detection still
works); do not bother deduplicating. Port bodies are included (their
sigs are poisoned regardless, but their edges keep SCC ordering exact).
B3.5 forward-compat: this is the fold that will also collect routed
edges (design §11.1 step 1); leave a comment, add nothing now.

### U3.1.c — SCC computation (`Borrow.elm`)

Copy `MonoInlineSimplify.buildCallGraph` (`MonoInlineSimplify.elm:
1063-1206`) with ONE modification — keep the SCC list instead of
collapsing to `isRecursive`. The scaffold, precisely:

1. Dense indices: fold `nodes`, collecting live SpecIds in order →
   `specIds : List SpecId`, `n = length`, `indexToSpecId : Array SpecId`
   (`Array.fromList specIds`), `idToIndex : Dict SpecId Int`.
2. Adjacency: fold `nodes` again; per live SpecId look up its edge list
   (here: from `collectEdges` output, NOT `graph.callEdges` — verified
   fact 1), map neighbor SpecIds through `idToIndex`
   (`List.filterMap`), accumulate `fwd : Dict Int (List Int)`,
   `trans : Dict Int (List Int)` (prepend caller idx per target), and
   `selfLoops : BitSet` (`BitSet.insert idx` when `List.member idx
   neighborIdxs`; start `BitSet.emptyWithSize n`).
3. Convert Dicts to `Array (List Int)` via `Array.initialize n` (the
   Dict-then-Array pattern is deliberate — avoids O(E) persistent-array
   copies).
4. `Graph.stronglyConnCompInt { fwd, trans, selfLoops, size = n } :
   List (Graph.SCC Int)` — where the modification lands: return
   `( indexToSpecId, sccsInt )` instead of the `isRecursive` Dict.

Processing order: the returned list head-to-tail IS
reverse-topological (callees first) — verified fact 2; do not reverse.
Map `SCC Int` back to SpecIds through `indexToSpecId`.

### U3.1.d — Fixpoint driver (`Borrow.run` upgrade, `Borrow.elm`)

State: `type alias SigTable = Array (Maybe BorrowSig)` sized
`Array.length nodes` (nodes are padded to `registry.nextId`,
`Monomorphize.elm:206-216`), index = SpecId. `Nothing` = not yet
solved; the `Env.sigs : SpecId -> Maybe BorrowSig` closure reads it.
Reverse-topological processing guarantees non-SCC callees are `Just`
by the time a caller is analyzed; a `Nothing` read is therefore either
an in-SCC member before initialization (prevented below) or a bug —
count it (`sigMissReads`, expected 0 steady-state) and treat as
all-owned.

```elm
solveScc : Ctx -> SigTable -> Graph.SCC Int -> SigTable
```

- `AcyclicSCC idx`: no self-loop possible. Analyze once (Phase 2's
  per-def constrain+solve with `Env.sigs = lookup table`), `readbackSig`,
  `Array.set specId (Just sig)`.
- `CyclicSCC idxs` (includes self-loop singletons):
  1. **Init**: `Array.set` each member to `Just (optimisticSig …)`
     (param/result MonoTypes from the node: `MonoTailFunc params body t`
     directly; `MonoDefine (MonoClosure info body _) t` via `info.params`
     — post-P1 every top-level callable is closure-wrapped,
     `MonoGlobalOptimize.elm:1004`; value defs get `params = []`).
  2. **Iterate** (`iterate : Int -> SigTable -> SigTable`): fold over
     members; per member run analyzeDef against the current table,
     `readbackSig`, compare with `sigEq`; on change, set and mark
     `changed`. If `changed && n < maxIter` recurse (tail call), else
     done.
  3. **Bailout**: `maxIter = 20`. Monotonicity (modes only `& → •`,
     lifetime sets only grow) guarantees termination in theory; the
     guard is the LssInfer-discipline defense against a
     non-monotone-readback bug. On bailout: set every member to
     `allOwnedSig` (total poison fallback, design §5.3 disciplines) and
     bump census `sccFixpointBailouts` (expected 0; nonzero = bug).
- Per-def analysis of an SCC member seeds each param top resource with
  its α: the driver marks param position i's resources with lifetime
  `LParams (Set.singleton i)` before solving (this is what makes
  `readbackSig`'s `LParams s` readback meaningful). Tail-call escape
  seeding (§8.5, Phase 2) already flows tail args into these param
  resources.
- Node kinds `MonoCtor`/`MonoEnum` keep the construct rule (result
  owned-fresh); `MonoExtern`/`MonoManagerLeaf`/`MonoPortIncoming`/
  `MonoPortOutgoing` get `allOwnedSig` immediately (RPort poison, §8.2).
- Contract with Phase 2 as-built: this unit renames/refactors Phase 2's
  per-def loop into `analyzeDef : Ctx -> SigTable -> SpecId ->
  Mono.MonoNode -> Solved`; if Phase 2 shipped different internal names,
  keep its constrain+solve pipeline intact and only re-parent the
  orchestration.

### U3.1.e — Call-boundary upgrade (`Borrow/Constrain.elm`)

The §8.3 direct-call rule goes live. Dispatch inside the `MonoCall
region callee args t callInfo` arm:

- **Direct**: callee is `MonoVarGlobal _ specId _` AND
  `callInfo.callKind` is `CallDirectFlat` or
  `CallDirectKnownSegmentation` AND `callInfo.isSingleStageSaturated`.
  Fetch `env.sigs specId`; `Nothing` → all-owned (count `sigMissReads`).
  With `Just sig`: zip `args` against `sig.params` — per param position,
  re-mint the param instance via `freshRTy sigTy.shape gen` (Phase 2
  declares `freshRTy : MonoType -> Gen -> (RTy, Gen)`, so the ResVar-
  supply `Gen` must be threaded through each per-call mint site — the
  driver already carries `Gen` from Phase 2; thread the returned `Gen'`
  into the next mint), then per ResPos:
  - mode **Owned** → owned use: `flows` arg→param-instance pairwise
    (`zipRTy`), nested `storageEq`;
  - mode **Borrowed** → liveness only: `seeds (argTopRes, callPath)`; no
    ownership transfer.
  Result: `freshRTy` of the result type; for each `(pos, s)` in
  `sig.resultLts`, add `flows argRes(i) → resultRes(pos)` for every
  `i ∈ s` (paper §5.1 argument–return coupling).
- **Kernel**: callee is `MonoVarKernel _ _ home name _` (any callKind —
  post-inline kernel calls are typically `CallDirectFlat`, but dispatch
  on the callee shape): same zip against `KernelSigs.lookup (home,
  name)` (U3.2), with `resultAliases = Just i` modeled as a `gets`
  (vertical flow) from arg i's top resource to the result's top
  resource at the call path; undeclared results owned-fresh.
- **Everything else** — under-application (`isSingleStageSaturated =
  False`: PAP creation → captured args `forcedOwned RClosureBoundary`),
  over-application (also reports `False` — verified fact 4 — so it
  conservatively lands here too; fine for v1), `CallGenericApply`/
  `CallSegmentationUnknown`, non-var callees: unchanged Phase-2
  behavior (all-owned poison; `LssFacts.query` arrives in B3.5).
- Zero-arity `MonoVarGlobal` in value position (§8.2): result-only sig
  application (`params = []` path of the same code).

Census wiring (declared in Phase 2, live now): for each param the
fixpoint forced Owned, count callers that demanded Owned vs would have
accepted Borrowed → `poisonedParams`, `poisoningCallSites` (§11.2).

## U3.2 — `Borrow/KernelSigs.elm` (~120 LoC)

Create `compiler/src/Compiler/GlobalOpt/Borrow/KernelSigs.elm`
(reconfigure). No imports beyond core — pure data.

```elm
module Compiler.GlobalOpt.Borrow.KernelSigs exposing
    ( ParamMode(..), KernelSig, lookup )

type ParamMode
    = PBorrowed      -- reads only; never stores or returns-by-identity
    | POwned         -- default; may store, return, or hand to unknown code

type alias KernelSig =
    { params : List ParamMode
    , resultAliases : Maybe Int   -- Just i: result may alias param i
    }

lookup : ( Name, Name ) -> KernelSig
```

- Total: unlisted keys → `{ params = [ POwned, … ] (padded on demand by
  the caller against actual arg count), resultAliases = Nothing }`.
  Implementation: internal `Dict ( Name, Name ) KernelSig` built once
  (top-level constant); `lookup` = `Dict.get` with all-owned default.
  Since the arg count at a call site can exceed a listed `params` list
  only on audit error, the Constrain-side zip treats a missing tail as
  `POwned` (defensive).
- **Keying (verified fact 3):** plain `(home, name)` exactly as
  `KernelTypeEnv` (`Type/KernelTypes.elm:44`). The `MonoVarKernel`
  prefix field (`"Elm"`/`"Eco"`) is IGNORED — suffix instances
  (`_Int/_Float/_Char`) are an MLIR-emission concern
  (`Generate/MLIR/KernelAbi.elm:182`) and never appear in Mono names.
  No normalization step exists or is needed.
- Seed entries = the U0.3-audited allowlist (design §12.2), copied from
  the B0 report's checklist table (kernel → verdict → evidence
  file:line). Expected seeds, each pending its U0.3 evidence line:
  `Utils.{equal,notEqual,compare,lt,le,gt,ge}` (all params PBorrowed),
  `String.{length,startsWith,endsWith,contains}`,
  `JsArray.length`, `JsArray.unsafeGet` (`params = [PBorrowed,
  PBorrowed]`, `resultAliases = Just 1` — the C signature is `unsafeGet
  index array`, so the aliased array is param **1**, per Phase 0's U0.3
  arg-order audit / D0.1; the §12.2 `Just 0` assumed `(array,index)`
  order and is stale), `Basics.*` numeric ops (scalar args carry no
  resources — entries are documentation), `Debug.{log,toString}`
  (`Debug.log` `resultAliases = Just 1` — identity return, D0.3;
  `Debug.toString` `resultAliases = Nothing`). **Dropped per the U0.3
  audit (do NOT seed these):** `List.length` and `String.isEmpty` are
  not kernels — pure-Elm, never surface as `MonoVarKernel` (D0.2); and
  `Console.{write,log}` is not borrowed — `write` stores `content` into
  a surviving `Task_Binding` ⇒ POwned (D0.1), so the all-owned default
  is already sound. Do NOT list anything U0.3 did not audit — the
  default is already sound.
- Per-kernel census: `Constrain` bumps a hit counter per allowlisted key
  and a miss counter per defaulted key with heap-typed args
  (`kernelSigHits`/`kernelDefaultedHeapCalls`) — the evidence stream for
  growing the list.

## U3.3 — B3 gate run

- **All B2 gates re-pass.** Analysis-only ⇒ emitted MLIR byte-identity
  flag-on vs flag-off still holds (same mechanics as Phase 2 U2.5,
  including the harness env-blindness trap: touch all test `.elm`
  before flag-on legs). Full E2E:
  `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`
  (run ONCE; grep the file). Front-end tests:
  `cmake --build build --target elm-tests` — run serially with the E2E
  suite, never concurrently (typed-artifacts cache race).
- **Census delta vs B2 recorded** in this plan's as-built section:
  `poisonedParams`/`poisoningCallSites` now live; would-be dup counts
  drop at direct/kernel boundaries; `kernelSigHits` per key;
  `sccFixpointBailouts = 0`; `sigMissReads = 0`; max SCC iteration
  count observed (design predicts 2–3).
- **BORROW_005 scaffold** (drop placement itself is Phase 5; land the
  analysis-invariant test now). New module
  `compiler/tests/TestLogic/GlobalOpt/BorrowTailCallEscapeTest.elm`
  exposing `suite : Test`, run by the `elm-tests` target
  (auto-discovered; reconfigure after adding the file):
  - Fixture via `Compiler.AST.SourceBuilder` (mirror the
    `SourceIR.LocalTailRecCases` idiom, but heap-typed): a top-level
    tail-recursive `loop : Int -> List Int -> List Int` with
    `loop n acc = if n <= 0 then acc else loop (n - 1) (cons n acc)`
    (`ifExpr`/`binopsExpr`/`callExpr`/`listExpr`), annotated with
    `tLambda`/`tType` so `acc` is heap-typed.
  - Drive `TestLogic.TestPipeline.runToGlobalOpt` (`TestPipeline.elm:
    332`) → `.optimizedMonoGraph`; locate the `MonoTailFunc` node (fold
    nodes; assert exactly one exists — fixture guard) and the
    `MonoTailCall _ tailArgs _` inside its body.
  - Run the analysis directly: `Borrow` exposes (add if Phase 2 did
    not) `analyzeDefForTest : Mono.MonoGraph -> Mono.SpecId -> Maybe
    Solved`. Assert, for each heap-typed tail-call arg resource `r`:
    `Solve.ltAOf r /= LEmpty` and NOT `Lifetime.endsBefore (Solve.ltAOf
    r) p` for the tail-call's own path `p` — i.e. §8.5's escape seeding
    fired and the arg is never dead at/before the tail call, which is
    exactly the fact Phase 5 will rely on to never place a drop after a
    `MonoTailCall` (BORROW_005, design §20). Negative control in the
    same suite: a non-tail helper's read-only arg DOES satisfy
    `endsBefore` past its last use (proves the assertion isn't
    vacuously true).
- **Wall budget re-measure**: interleaved self-compile timing flag-on
  vs flag-off, ≤3% total (record majors per house methodology — the
  major-GC trigger lottery lesson). elm-aws-codegen canary re-run: the
  deep inliner let chains are the pathological SCC/edge-collection
  input (the `annotateCallStaging` exponential incident's shape); gate
  = canary completes with wall within budget, SCC iteration count
  bounded.

## Gates summary

E2E + byte-identity + elm-tests green · poisonedParams census delta
recorded · BORROW_005 scaffold green (positive + negative control) ·
`sccFixpointBailouts = 0` · wall ≤3% total · canary passes.

## References

Design §5.3 (SCC/scaffold reuse), §8.3 (call boundaries), §8.5 (tail
calls), §11 (signatures, fixpoint, measured poisoning), §12 (kernel
sigs), §13 (census), §20 (BORROW_005), paper §5.1 (argument–return
coupling, α-joins). Code anchors: `MonoInlineSimplify.elm:900,
1063-1206` · `Graph.elm:38-69` · `Monomorphize.elm:532-570` ·
`Monomorphized.elm:917, 1493-1550` · `Type/KernelTypes.elm:44` ·
`Generate/MLIR/KernelAbi.elm:182` · `MonoGlobalOptimize.elm:125-152` ·
`Builder/Generate.elm:802-914` · `TestPipeline.elm:332`.
