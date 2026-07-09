# MonoSolver: A Parallel Solver-Engine Monomorphizer (Architecture C, Drop-In)

## Status: **RUNTIME PARITY ACHIEVED** (2026-07-09, rev 11). 1566/1567 — every Elm test passes through MonoSolver.

The full E2E suite (~812 Elm programs across elm/, elm-core, elm-bytes, elm-json, elm-parser, elm-http, elm-regex,
elm-url, elm-time, eco-kernel, embed) compiles through `ECO_MONO_ENGINE=solver` and passes at runtime. The single
remaining "failure" is `codegen/construct_nested.mlir` — the pre-existing FLAKY nursery-GC SIGABRT on a hand-written
MLIR test that bypasses the front-end entirely (passes 3/3 on retry; the same flake hits default-engine runs).
Final two fixes: TupleSlotBoxingClosure (per-call-site instantiation for local-multi function call-args — crossed
LocalOpt-rebuilt annotation ids poisoned the shared memo) and LetDestructFuncTuple (three-part bridge:
appShapeConnect on indirect calls + derivedDestructors map + localCanTypes/canSlotForPath root-slot connect — the
engine's equivalent of the old derivedDestructorNames call-site refinement). Both also byte-MATCH.
Remaining (deferred, non-blocking): M7 determinism/perf measurements; junk-spec elimination tidy-up; ~50 runtime-
benign byte-diffs (spec-id order, layout-erasure choices, Debug-ABI cosmetics).

Fixed this round: elm-json null trio (kernel-ABI taint-proofing), LetNumber closures cluster (lambda-containing
let gate), NestedCustom (custom-slot navigation), IndirectDual (numeric-leaf letType rule), all tail-rec tests
(body-first TailDef), ListConcatMap (annotation-var taint exclusion from harvest — was a REAL deterministic GC
crash), PortEcho (decoder-value spec split + encoder type connect). Remaining: **TupleSlotBoxingClosure** (inner
lambda param/result SWAP — diagnosis in memory) and **LetDestructFuncTuple** (getter/setter destructor-derived
functions — needs old engine's derivedDestructorNames call-site refinement). Byte gate: 464/515, 0 declines.

## (rev 9) **Parity bar WEAKENED to RUNTIME EQUIVALENCE** (user decision).

**The acceptance bar is now runtime equivalence, not byte-identity**: the full E2E suite must pass with
`ECO_MONO_ENGINE=solver` compiling every Elm program. Rationale: 44 of the remaining byte-mismatches were
lambda-counter/registry-spec-ID shifts caused by differently-keyed UNREACHABLE JUNK specs (both engines enqueue
junk that Prune removes; only symbol names differ in MLIR; runtime-equivalent). Matching junk between engines has
no value. Two follow-ups deferred to a later tidy-up phase: (1) stop generating junk specs at all (don't enqueue
standalone-ref specs that are never reachable); (2) the byte-diff gate stays as a DEBUGGING AID — its serializer
now ignores the lambda counter so MATCH = graph-equivalent (spec IDs already canonicalized by the serializer).

Current standing (2026-07-09): runtime **1513/1567 (96.6%)**, graph-equivalence ~456/515 (412 + 44 lam-only),
zero declines. Remaining 54 runtime failures in clusters: RecordNarrow (10), higher-order locals (~9), elm-core
misc+GC (7), TupleSlotBoxing (6), UtilsEquality/OrderingCapture (6), elm-bytes GC/roundtrip (6), elm-json null (3),
LetNumber tail (3), misc (4). Next target: RecordNarrow.

## (rev 8) Status: 401/515 byte-match, **ZERO declines** — every test program now specializes. M5+M6 complete.

**The higher-order/SKI unify-failure class is ELIMINATED** (was 25 declines). Root cause: cross-item superTable
pollution — Join-R harvest writes Number taint by MVarId globally, and the SAME annotation var is instantiated at
DIFFERENT types across specializations (`k : x→y→x` at `y:=num` in one item taints `y`; the next item loads `y` as
`FlexSuper Number` which refuses to unify with a function → "Lambda /vs/ Lambda" on hand-unifiable types). This was
the per-call-site-substitution violation. Fix (mirrors the old engine's `refreshConstraints`): split `superStatic`
(static solver truth, consulted by `loadVar` — bindings never leak between items) from `superTable` (static+taint,
consulted ONLY by zonk-time residual classification via `residualWithTaint` — taint can re-stamp residuals but can
never block a unification). SKI combinators now MATCH byte-for-byte; number-multi intact; +16 net (385→401).

**Remaining: 114 MISMATCH — all byte-fidelity gaps, no functional declines.** Buckets: erasure corners (old keeps
CEcoValue where mine concretizes or vice versa), value-multi-lambda (getter/setter call-site refinement), complex-
shape number-multi, assorted structural. M7 (parity/determinism/perf + real-correctness measurement) is next.

**Destructor-derived multi-instance LANDED** (the subsystem for numbers/values reached through a destructure): the
`Destruct` arm diverts to `specializeNumberDestruct` when the path root is a number-multi target and the field is a
scalar number — seeds the destructor name as a multi-target, discovers uses body-first, then per used type overlays
the leaf onto the eager root type (`refineRootInstance`) + registers a root instance (`recordNumberInstance rootName`,
which the root's own `translateNumberMultiLet` emits) + emits a renamed destructor, with dead-destructor elimination.
6/7 destructure tests match (LetDestructuring, LetDestructAlias, LetNumberDestructure, LetNumberRecordDestructure,
LetNumberCaseTuple3, LetNumberWildcardSlot). No regressions.

**Remaining (rev 6 list, updated):**
1. **value-multi-with-lambda** (~8 "new-more-eco" MISMATCH — LetDestructFuncTuple, HOParamApplyTwo, …): ATTEMPTED,
   NOT achieved (net stayed 385). Two sub-cases: (a) a local function used at a concrete type stays erased; (b)
   getter/setter destructor-derived functions need call-site refinement. Kept safe net-neutral groundwork
   (specializeLambda param-peel + translateLocalMultiCall). BLOCKER: HOParamApplyTwo's local call renders as
   `MonoVarLocal(applyTwo)` but never reaches `translateCall`'s VarLocal-callee case — the TOpt representation of a
   local multi-arg application isn't what I assumed; needs investigation before this bucket can move. Routing
   TailDefs through local-multi was tried and REVERTED (broke tail recursion — can't rename the TailCall self-ref).
2. **Higher-order per-call-site instantiation** (25 declined SKI combinators): still the hard corner (`demandUnify
   (var->(var->var)) vs MFunction/1` — currying/arity from memo-shared polymorphic arg vars).
Plus assorted erasure/other MISMATCH in the tail.

---
## (rev 6) Status: 381/515. M5/M6 cores landed.

**Coverage: 381/515 (74%) byte-equivalent**, 109 MISMATCH, 25 declined (all SKI/higher-order unify-mismatches).
M5 landed: number-multi + **local-multi** (functions at N types via a generic multi-instance stack + per-instance
RHS re-translation). M6 landed: **SCC>1 mutual recursion** (member selected from `currentGlobal`, siblings enqueue
via cross-refs — 4/5 match), **ports** (specializePort: Platform.leaf wrapper, decoder enqueue, robust to erased
demand), best-effort higher-order call unification. Also fixed a destructure-root crash (number-multi now binds its
eager name in varEnv). Two DEEP remainders, each a subsystem:
1. **Destructor/case/record-derived multi-instance** (complex-shape number-multi + value-multi, ~15+ MISMATCH):
   a number reached through a destructure/case/record field isn't recorded as a multi-instance use — needs the old
   engine's `derivedDestructorNames` refinement.
2. **Higher-order per-call-site instantiation** (25 declined SKI combinators `s/k/i`): memo-shared polymorphic arg
   vars cause occurs/arity clashes; number-multi wants SHARED arg vars (demand propagation), SKI wants FRESH ones.
   The old engine reconciles this with per-call-site substs; my global memo conflates them.
Neither is a quick win; both are the "shadow type system" accretions. All else (M0–M4, M3, cycles, ports, multi-
instance cores) is solid and non-regressing.

**Coverage: 356/515 (69%) byte-equivalent** (diff-mode A/B), 112 MISMATCH, 47 declined. Landed since rev 4:
**number-multi** (a `let n = <number>` used at Int AND Float now emits the eager-Int def + `n$v<idx>` copies,
re-translating the RHS per type in a fresh store), plus a **solver-native demand-flow reorder** of kernel/global
calls (unify params with arg types BEFORE translating args, so an arg's use sees the demanded type). Remaining
112 MISMATCH root-causes (categorized): **83 "other-structural"** — a diverse tail of higher-order cases
(function composition, partial-application closures, higher-order local functions) with NO single dominant lever;
**15 complex-shape number-multi** (number-multi flowing through case/record/custom demand); **14 erasure edge
cases** (empty-list-field / container-element CEcoValue-vs-concrete). Plus 47 declined: local-multi *functions*
at N types, SCC>1 mutual recursion, higher-order-currying unify-mismatches, ports. Each remaining item is small
and distinct; the "shadow type system" tail is real. Full policies for every remaining case are in memory.

**Coverage: 333/515 (65%) of Elm E2E programs produce byte-equivalent MonoGraphs** through the solver engine
(diff-mode A/B), 144 MISMATCH, 38 declined. Default full suite green (1566/1567; the 1 = an unrelated LLVM MLIR
codegen flaky, not monomorphization). Landed since rev 3: **M3** (Ctor/Enum/Box/Link/Manager/Accessor + Case
decision-trees + Destructure with a full `varEnv` + path-type computation via `Analysis`/`instantiateUnionType`),
**partial M5** (single-instance let-bound functions + TailDef→MonoTailFunc + TailCall), **partial M6**
(single-recursion cycles / SCC-of-1 + VarCycle), best-effort kernel higher-order unification.

**Remaining hard accretions (the "shadow type system" — each byte-identity-hard, policies extracted & in memory):**
1. 144 MISMATCH, dominated by: **multi-instance let-poly** (localMulti `f$1`/valueMulti `n$v1` — a use at N
   monomorphic types needs N specialized copies), **number-multi** (`let n=30` at Int+Float → eager-Int + `n$v1`
   Float copy), **layout-erasure** (poly fn param whose tyvar is only in an erased container position stays
   `CEcoValue`; I over-concretize), and higher-order **currying** mismatches.
2. 31 unify-mismatches (higher-order global-call bodies — real `Unify` rejections on curried/erased fn args).
3. 5 SCC>1 mutual-recursion cycles (need multi-node-per-work-item materialization).
4. 2 ports (`specializePortNode`).
These are exactly the accretions `design-recovery.md` catalogs; reproducing them byte-for-byte is the bulk of the
remaining work. The engine core, A/B gate (canonical serializer), and all M0–M4/M3 features are solid and green.

**Implemented (compiles under --optimize, default suite untouched):**
- **M0 COMPLETE**: EntryPrep extraction, EcoConfig `mono.engine` (subst|solver|diff) + `ECO_MONO_ENGINE`/`ECO_MONO_DIFF_DUMP` env overrides, Generate.elm dispatch, MonoSolver skeleton, Diff.elm A/B. Default full suite 1567/1567 green.
- **M1+M2**: `Engine.elm` (state+Step monad+enqueueSpec+freshStore+harvestSuperTable), `Store.elm` (loadType/monoTypeToVar/unifyStep/zonkToMono + normalizePrimHome), `Zonk.elm` (canTypeToMono for entry seeding), `Translate.elm` (literals/vars/calls/if/list/tuple/record/access/update/let arms; store-based classify; unified instantiate-based global call; kernel ABI via deriveKernelAbiTypeCall/Ref; VarDebug). Driver: demandUnify per item + drain + assemble + shared Prune + Join-R harvest.
- **M4**: closures (`specializeLambda` → MonoClosure via shared `Closure.computeClosureCaptures`, AnonymousLambda currentModule counter++) + indirect/higher-order calls.
- **Diff gate**: canonical serializer (serExpr/serNode + `toComparableMonoType` for id-insensitive/dict-canonical types); Debug-kernel-ABI waiver (§7.3, backend-cosmetic).
- **Fixes found via A/B**: primitive-home normalization (real Unify rejects Basics-vs-String canonical clash the Dict engine absorbed — §6.3 early), standalone-kernel-ref must use item memo (not fresh instantiate) so demand concretization is visible, Join-R harvest required even for numbers-through-Debug.

**Remaining:** M3 (custom-type ctors/enum/case/destructure/accessor), M5 (let-bound local funcs + number-multi/value-multi — LetNumberFloat* genuinely miscompile: number used at Int+Float needs 2nd Float binding), 37 unify-mismatches (Combinator*/Compare*String — likely comparable-super or higher-order), M6 (Link/Cycle/ports/kernel-honesty), M7 (parity+bootstrap+perf). Post-M4 sweep: see /tmp/sweep_all.txt.

---

## Original plan (rev 2 — implementation-ready):

A second monomorphizer, built in `compiler/src/Compiler/MonoSolver/`, that uses the
type checker's real HM machinery (`Compiler/Type/{Unify,UnionFind}.elm`,
`System/TypeCheck/IO.elm`) as its unification engine, per **Architecture C** of
`design_docs/monomorphization/solver-reuse-evaluation.md`. The existing
monomorphizer (`Compiler/Monomorphize/`) is left untouched and remains the
default. The new one is a **drop-in replacement at the single production call
site**, selected by config/env, so the same tests run through both engines and
their outputs are compared until the new engine handles everything flawlessly.

**Hard rule — no fallback.** In `solver` mode the old engine is never consulted,
not per-node, not per-work-item, not on error. A construct the new engine cannot
handle yet returns `Err "MonoSolver.unsupported: <what>"` through the existing
`Result String MonoGraph` channel (which the pipeline already turns into a loud
build failure at `Builder/Generate.elm:733`). MonoSolver modules MUST NOT import
`Compiler.Monomorphize.TypeSubst` or `Compiler.Monomorphize.Specialize`
(grep-gated, §10.4). MonoDirect died with a TypeSubst fallback that crept back
in; this engine is born without the option.

All file:line references below were verified against the tree on 2026-07-08.

---

## 1. Why this exists

Per the eval doc and `design-recovery.md`: the monomorphizer's independent type
machinery (`TypeSubst.elm`, 1,658 lines, plus the `Pending*`/demand-replay/
multi-gate tower in `Specialize.elm`) is a second, weaker theory of Elm's type
space, and essentially all of the pass's seven months of bugs lived there.
Architecture C swaps that engine for the type checker's real unifier while
keeping the pass's identity (worklist, registry, IR translation, closures,
kernel ABI).

This plan implements Architecture C as a **parallel implementation** (user
decision) rather than the eval doc's §7 strangler. What makes that survivable is
that the boundary is razor thin — one function, one call site, shared input
prep, shared output IR, shared post-pass — and the MonoDirect failure modes are
addressed head-on (§9). The honest cost of the parallel route: the *translation
policy* (CallInfo, ClosureInfo, ctor shapes, destructor paths, kernel ABI modes)
must be ported from the old `Specialize.elm` arms rather than inherited — the
old arms are the reference implementation and the A/B gate enforces fidelity.

## 2. Prerequisites — status: all met except one, which is scheduled inside this plan

| Eval-doc gate | Status |
|---|---|
| §6.1 Bug A — `rewriteAnnotation` dropped root super | **FIXED.** `ensureBinder` is the single root-vs-plain dispatch point (`AssignMVarIds.elm:209-221`; docstring names Bug A). |
| §6.1 Bug B — cross-module solver-root aliasing | **FIXED.** `rootEnv` keyed `(moduleKey, rootIdx)` (`AssignMVarIds.elm:189-192`). |
| §6.2 structural super export | **DONE.** TYPE_SUPER_001 (enforced): supers are data (`RootedVar.super`, persisted `varSupers`), not name prefixes. |
| Defaulting-at-quiescence | **VALIDATED & SHARED.** MONO_028 (enforced). The discharge (`MVar _ CNumber → MInt`) lives in the *shared* `Prune.pruneUnreachableSpecs` (`Prune.elm:103-159`) — the new engine inherits it (§5.6). |
| §6.3 kernel-type honesty | **OPEN.** Scheduled at M6 (§8), where the real unifier localizes each fabrication loudly. |

**Correction to the eval doc / earlier notes, discovered during verification:**
there is **no `MErased` constructor anywhere** (grep-confirmed). Erasure is
`MVar id CEcoValue`. And number defaulting must NOT happen at zonk: the closing
pass is in shared Prune, and byte-identical output requires the new engine to
emit the same `MVar id CNumber`/`CEcoValue` residuals as the old engine (§5.5).

## 3. Verified integration boundary

- **Entry point (identical signature):**
  `Compiler.MonoSolver.Monomorphize.monomorphize : Name -> TypeEnv.GlobalTypeEnv -> TOpt.GlobalGraph Name -> Result String Mono.MonoGraph`
  mirroring `Compiler/Monomorphize/Monomorphize.elm:68`.
- **Single production call site:** `Builder/Generate.elm:731` inside
  `runMonoOptPipeline` (which already receives `ecoConfig`). Everything
  downstream (`MonoInlineSimplify` → `MonoGlobalOptimize` → MLIR streaming) is
  untouched.
- **Single unit-test call site:** `compiler/tests/TestLogic/TestPipeline.elm:574-576`
  (`monomorphizeAny`) — the only test reference to `Monomorphize.monomorphize`.
- **Solver surface: ZERO changes to `Compiler/Type/*` / `IO.elm` required.**
  Verified exposing lists:
  - `IO.elm:1-13` exposes `State` (transparent record alias, all six fields),
    `IO` (transparent alias `State -> (State, a)`, so a store threads by plain
    function application — no `unsafePerformIO` needed), `Point(..)`,
    `PointInfo(..)`, `Descriptor`, `Content(..)`, `FlatType(..)`,
    `SuperType(..)`, `Mark(..)`, `RootedVar`, `makeDescriptor`, and the monad
    helpers (`pure/map/andThen/foldM/mapM/loop/…`).
  - `NameState` (`IO.elm:164-171`) and `NodeIdState` (`IO.elm:221-227`) are
    plain record aliases → a fresh empty `IO.State` is constructible literally
    in MonoSolver (§5.1).
  - `UnionFind.elm:1` exposes all seven ops (`fresh/get/set/modify/union/equivalent/redundant`).
  - `Unify.elm:1` exposes `unify : Variable -> Variable -> IO Answer` and
    `Answer(..)` (`AnswerOk vars | AnswerErr vars t1 t2`); on mismatch it has
    already rendered both `Error.Type` values (usable directly in our error
    message) and poisoned the two roots to `Error` content (`Unify.elm:52-82`)
    — harmless for us since a failure aborts the work item.
  - `Type.elm:1-11` exposes `noRank` (=0), `outermostRank` (=1), `noMark`,
    `mkFlexVar`, `mkFlexNumber`, `unnamedFlexVar`, `unnamedFlexSuper`,
    `nameToFlex`, `nameToRigid`, `toAnnotation`.
  - `Solve.elm` internals (`makeCopy`, `srcTypeToVariable`, pools/ranks) are
    private and entangled with generalization — **not needed and not used**:
    the engine mints variables with `UF.fresh` + `IO.makeDescriptor` directly,
    and rank behavior is safe at any single fixed rank (`Unify.merge` uses
    `min r r = r`, `Unify.elm:272`; `Occurs` never reads rank). Use
    `outermostRank` for all engine-minted vars (never `noRank`, which means
    "generalized" to anything that might inspect it).

## 4. Shared vs. new vs. forbidden

**Shared by import (single source of truth; any change must keep the old engine
byte-identical):**

| Module | Used for |
|---|---|
| `Compiler.AST.Monomorphized` | Output IR: `MonoGraph`, `MonoNode`, `MonoExpr`, `MonoType`, `SpecKey`, `Global`, `resolveNumberType`, `toComparableSpecKey` |
| `Compiler.Monomorphize.Registry` | SpecId allocation (`getOrCreateSpecId`, `lookupSpecKey`, `updateRegistryType`, `emptyRegistry`) |
| `Compiler.Monomorphize.AssignMVarIds` | Phase-0 `Name → MVarId` rewrite (`assignIds`) |
| `Compiler.Monomorphize.Prune` | Fused close (CNumber discharge, MONO_002 check) + dead-spec prune + `ctorShapes` recompute |
| `Compiler.Monomorphize.ResolveAccessorValues` | Per-item `MonoAccessorValue` elimination (`rewriteNode`, threading `lambdaCounter`) |
| `Compiler.Monomorphize.KernelAbi` | Kernel ABI modes — explicitly backend-neutral (`KernelAbi.elm:22`); operates on `Can.Type MVarId`/`MonoType`/`MVarEnv` only |
| `Compiler.Monomorphize.State` | ONLY the `MVarEnv` record + `initMVarEnv`/`isNumberVar` (the type Prune and KernelAbi take); none of the engine machinery |
| `Compiler.Monomorphize.MonoTraverse`, `.Closure`, `.Analysis` | Output-side traversal; closure utilities; `lookupUnion`/ctor-shape helpers |
| `Compiler.Monomorphize.EntryPrep` *(new, extracted in M0)* | `insertFlagsDecoderNode`, `findEntryPointId`, `flagsDecoderName` — moved verbatim out of the old `Monomorphize.elm:99-179,395-423` so both drivers share input prep. Pure move; old driver re-imports; suite must stay green. |

**New (all under `compiler/src/Compiler/MonoSolver/`):** §6.

**Forbidden (grep-gated):** importing `Compiler.Monomorphize.TypeSubst` or
`Compiler.Monomorphize.Specialize` from any `MonoSolver.*` module; reading
`meta.tvar` anywhere in `MonoSolver.*` (it is partial and codec-dropped —
MonoDirect's tar pit; the engine works only from the total `meta.tipe`).

## 5. Engine architecture

### 5.1 Store lifecycle — pure, per-work-item

```elm
-- MonoSolver/Store.elm
freshStore : IO.State
freshStore =
    { ioRefsWeight = Array.empty
    , ioRefsPointInfo = Array.empty
    , ioRefsDescriptor = Array.empty
    , ioRefsMVector = Array.empty
    , names = { taken = Dict.empty, normals = 0, numbers = 0, comparables = 0, appendables = 0, compAppends = 0 }
    , nodeIds = { mapping = Array.empty, syntheticExprIds = EverySet.empty, schemeBinderVars = Dict.empty, recording = False }
    }
```

`IO a = State -> (State, a)` is a transparent alias, so running solver actions
is plain function application. Each work item gets a fresh store — cross-item
contamination is unrepresentable, stores stay small (locality), and discarded
stores are GC'd. No `unsafePerformIO` anywhere in the engine.

### 5.2 The item monad

Everything inside one work item runs in a Result-threading step monad so
`unsupported`/`mismatch` abort the item without Elm crashes (crashes would kill
diff-mode corpus runs; reserve `Utils.Crash.crash` for genuine
this-cannot-happen invariants):

```elm
type alias ItemState =
    { store : IO.State
    , memo : Dict Int IO.Variable        -- MVarId (Id.toComparable) → Point
    , revMemo : Dict Int TypeIds.MVarId  -- Point index of a *loaded var* → first MVarId that minted it
    }

type Failure
    = Unsupported String                  -- feature not yet implemented
    | UnifyMismatch String                -- rendered from AnswerErr's two Error.Types + context
    | EngineBug String                    -- invariant violation, still surfaced as Err

type alias Step a = ItemState -> Result Failure ( a, ItemState )
-- pure/map/andThen/foldM/traverse helpers; liftIO : IO a -> Step a runs against .store
```

`Failure` is rendered into the top-level `Err String` with the current
`(Global, SpecId, demanded MonoType)` context attached — the far-away
`mul_Float (f64, i64)` failure class becomes a named, near failure.

### 5.3 Loading types into the store

```elm
loadType : Can.Type TypeIds.MVarId -> Step IO.Variable
```

Structural recursion mirroring `Solve.srcTypeToVar` minus pools, over `UF.fresh`
+ `IO.makeDescriptor content outermostRank noMark Nothing`:

- `TVar mvarId` → memo hit returns the existing Point; miss mints
  `FlexSuper s Nothing` when the global super table (§5.5) or `AssignMVarIds`'
  exported `superVars` records a super for it, else `FlexVar Nothing`; records
  both memo directions.
- `TLambda a b` → `Structure (Fun1 pa pb)` (one arrow at a time — no flattening).
- `TType home name args` → `Structure (App1 home name pargs)`.
- `TRecord fields ext` → `Structure (Record1 pfields pext)`; `ext = Nothing` →
  `Structure EmptyRecord1` as the tail; `Just extId` → the ext var loads through
  the memo like any TVar.
- `TUnit` → `Structure Unit1`; `TTuple a b rest` → `Structure (Tuple1 …)`
  (match the `FlatType` arity convention — read `IO.elm:634-640` when
  implementing).
- `TAlias home name args (Filled inner)` → load `inner` (aliases are transparent
  to mono, matching `applySubstPure`'s policy, `TypeSubst.elm:865-878`);
  `Holey inner` → bind each `(paramId, argTy)` by pre-loading `argTy` and
  seeding the memo for `paramId` before loading `inner` (scoped: restore the
  memo entries afterward — alias params are not the def's vars).

The **memo is the propagation mechanism**: `AssignMVarIds` gives solver-root-
shared vars one global MVarId (annotation ↔ body included, via root-backed
`ensureBinder`), so loading a def's annotation and every node's `meta.tipe`
through one memo reconstructs the def's internal type graph in the store.
Verified: annotation and node rewrites use separate empty name-envs and connect
*only* via `rootEnv` (`AssignMVarIds.elm:276-294,303-334`) — so scheme vars
connect (root-backed), while non-root-backed fabrications stay def-local, which
is exactly the old engine's identity model.

```elm
monoTypeToVar : Mono.MonoType -> Step IO.Variable   -- demand as concrete structure
```
Dual of the classification table (§5.4): `MInt → App1 elm/core "Int" []`, …,
`MFunction [a] r → Fun1`, `MRecord dict → Record1 … EmptyRecord1`,
`MCustom home name args → App1`, `MTuple → Tuple1`, `MUnit → Unit1`,
`MVar id c` → loads through the memo (same Point as any other occurrence of
that MVarId; mints `FlexSuper Number` for `CNumber`).

### 5.4 Readback: `zonkToMono`

```elm
zonkToMono : IO.Variable -> Step Mono.MonoType
```

Post-order `UF.get` + dispatch, reproducing `applySubstPure`'s classification
(`TypeSubst.elm:757-878`) **exactly**:

| Store content | MonoType |
|---|---|
| `Structure (App1 home name args)`, home = elm/core | `"Int"→MInt`, `"Float"→MFloat`, `"Bool"→MBool`, `"Char"→MChar`, `"String"→MString`, `"List"→MList arg` (arity-1 else `MList MUnit`), otherwise `MCustom home name args` |
| `Structure (App1 home name args)`, other home | `MCustom home name args` |
| `Structure (Fun1 a b)` | `MFunction [zonk a] (zonk b)` — **one arg per arrow; GlobalOpt flattens later (GOPT_016). Do not flatten here** (`TypeSubst.elm:744-755`) |
| `Structure (Record1 fields ext)` | flatten the extension chain into one field dict → `MRecord` (closed; matches `TypeSubst.elm:832-857`) |
| `Structure Unit1` / `Tuple1` | `MUnit` / `MTuple` |
| `Alias _ _ _ real` | zonk `real` (transparent) |
| `FlexSuper Number _` (residual) | `MVar (revMemoId) CNumber` — **no defaulting here**; shared Prune discharges (§5.6) |
| `FlexVar _` / other flex supers (residual) | `MVar (revMemoId) CEcoValue` |
| `RigidVar`/`RigidSuper` | treat as the flex equivalents (annotation rigids arrive as plain MVarIds anyway) |
| `Error` | `EngineBug` — unreachable because unify failures abort the item first |

`revMemoId`: the Point's root may cover several loaded MVarIds after unions; use
the *first-loaded* MVarId (deterministic). If the root has **no** revMemo entry
(a Point minted internally by `Unify` for record extensions, `Unify.elm:286`),
allocate a fresh MVarId from the engine's allocator (seeded from
`mvarState.nextId`, exactly like the old engine's `freshMVar`). Residual-id
choice is a known byte-identity risk — §7.3.

Memoize zonk per Point root within an item (perf, §11).

### 5.5 The global super table (Join-R, solver-native)

Old engine: `superVars : Dict Int SuperType` is threaded globally so a number
merge discovered while specializing item B heals a stale `MVar id CEcoValue`
stamped by item A — Prune reads the final table (`State.isNumberVar`,
`Prune.elm:103-150`; `Mono.resolveNumberType`, `Monomorphized.elm:265-338`).

New engine equivalent: `superTable : Dict Int IO.SuperType` in global engine
state, seeded from `mvarState.superVars` (the `AssignMVarIds` export). At the
end of each work item, for every memo entry read the root content; if it is
`FlexSuper Number _` (or resolved through a number), insert `id → Number`
(monotonic). Stamping of residuals at zonk consults store content first, then
the table. At the end, `State.initMVarEnv engineNextId superTable` is passed to
the shared `Prune.pruneUnreachableSpecs` — identical healing semantics, sourced
from solver truth instead of taint calls.

### 5.6 What the shared Prune gives us for free

`Prune.pruneUnreachableSpecs mvarEnv globalTypeEnv rawGraph` (`Prune.elm:103`):
reachability prune from main, the fused close (`MVar _ CNumber → MInt`; tainted
`CEcoValue → MInt`; genuine `CEcoValue` survives boxed), the MONO_002 crash if
a number residual survives, and `ctorShapes` recompute
(`Analysis.computeCtorShapesForGraph`). The new driver calls it with the same
arguments as the old driver (`Monomorphize.elm:232-233`).

### 5.7 Per-work-item algorithm (the core)

Mirror of `processOneWorkItem` (`Monomorphize.elm:444-574`) +
`specializeNode` (`Specialize.elm:1564-1695`):

1. Pop head of LIFO worklist; skip if `inProgress` bit set; look up
   `(global, demandedMonoType) = Registry.lookupSpecKey specId`; set
   `inProgress`.
2. Resolve the TOpt node (follow `Link`s; `Kernel`/missing → `MonoExtern`,
   `Monomorphize.elm:534,1648-1650`).
3. `TOpt.Define expr _ meta`: fresh store + empty memo, then assert the demand —
   mirroring the old engine's two unifications (`Specialize.elm:1567-1591`):
   `unifyStep (loadType meta.tipe) (monoTypeToVar demanded)` and
   `unifyStep (loadType (TOpt.typeOf expr)) (monoTypeToVar demanded)`.
4. Translate the body (§5.8). Node result `MonoDefine monoExpr (Mono.typeOf monoExpr)`.
5. `Registry.updateRegistryType specId actualType` (mirrors `Monomorphize.elm:563-567`).
6. Run shared `ResolveAccessorValues.rewriteNode` (mirrors `Monomorphize.elm:551-554`),
   store node in `accum.nodes`, clear `inProgress`, harvest the super table
   (§5.5), discard the store, recurse on the worklist (tail-recursively).

Other node kinds: `Ctor`/`Enum`/`Box` mirror `specializeCtorViaScheme`
(`Specialize.elm:1597-1631`) — load the ctor scheme type, unify with demand,
zonk field types, build `MonoCtor CtorShape`/`MonoEnum`; `Cycle` → M7 scope
mirroring `specializeCycle` (`Specialize.elm:1665-1666`); `PortIncoming/
PortOutgoing` → M6 mirroring `specializePortNode` (`Specialize.elm:1668-1695`);
`Manager` → `MonoManagerLeaf`.

**Why so few unifications?** The demand unification propagates through every
body node *by identity*: all node `meta.tipe`s load through the same memo, and
scheme-var occurrences share MVarIds with the annotation (root-backed). Types
already solved concrete are loaded concrete. The only places additional
unification is required are exactly where `AssignMVarIds` deliberately splits
identity: let-bound defs (`withFreshBinding`, §8 M5), and fabricated types
(kernel positions, M6). This is the load-bearing simplification of Architecture
C — and the A/B gate (§7) verifies it empirically from M1 onward, so if any
propagation gap exists it surfaces as a MISMATCH immediately, not as a silent
wrong type.

### 5.8 Body translation

`translate : TOpt.Expr MVarId -> Step Mono.MonoExpr` — node dispatch where every
node's MonoType is `zonkToMono =<< loadType meta.tipe`, and the *translation
policy* is ported arm-by-arm from `specializeExpr` (`Specialize.elm:2526+`).
Byte-identity constraints that must be mirrored exactly:

- **SpecId allocation order = old engine's DFS pre-order.** `Registry.getOrCreateSpecId`
  fires at first reference during the walk; at `Call` sites args are processed
  BEFORE the callee (`processCallArgs` `Specialize.elm:2787` → callee enqueue
  `2846/2890`), so argument globals get lower SpecIds.
- **LIFO worklist**, enqueue = cons (`Specialize.elm:268`); `scheduled` BitSet
  dedups enqueues; seeding order: main = SpecId 0, flags decoder = SpecId 1
  consed after (`Monomorphize.elm:255-289,190-220`).
- **SpecKey stamps**: the old engine re-stamps constraints before keying
  (`refreshConstraints`, `Specialize.elm:244-249`); ours are stamped by zonk
  from live store + super table — same information source, verified by A/B.

Coverage table (translation targets from `Monomorphized.elm:579-597`; reference
arms in `Specialize.elm`):

| TOpt.Expr (TypedOptimized.elm:145-175) | MonoExpr | Milestone | Notes |
|---|---|---|---|
| `Bool/Chr/Str/Int/Float` | `MonoLiteral` | M1 | type = zonked meta (Int literals may zonk residual-CNumber in polymorphic bodies — correct; Prune closes them) |
| `VarLocal`/`TrackedVarLocal` | `MonoVarLocal` | M1 | type from zonked meta — no `VarEnv` needed (A/B verifies the equivalence) |
| `VarGlobal` | `MonoVarGlobal SpecId` | M1 | zonk → `enqueueSpec` → SpecId (ref `Specialize.elm:2626`) |
| `VarEnum`/`VarBox` | via enqueue (ref `2655/2671`) | M1 | |
| `Call` (callee `VarGlobal`, monomorphic) | `MonoCall` + `CallInfo` | M1 | mono fast path ref `2819-2854`; port `CallInfo` computation verbatim |
| `Call` (polymorphic callee) | `MonoCall` | M2 | old scheme/`unifyCallSiteDirectWithExpected` machinery (`2856-2896`) is NOT ported — demand for the callee = zonked callee `meta.tipe`; the callee's own item does the scheme unification |
| `VarKernel`/`VarDebug`, kernel `Call` arm | `MonoVarKernel` | M1 (UseSubstitution) / M2 (PreserveVars + suffix-selecting) | kernel fn type = `meta.tipe` on the VarKernel node itself (`Specialize.elm:2728-2736`); ABI via shared `KernelAbi` mirroring `deriveKernelAbiType` (`5399-5432`) with zonk in place of `applySubstPure` |
| `If` | `MonoIf` | M1 | |
| `List` | `MonoList` | M1 | |
| `Tuple`/`Unit` | `MonoTupleCreate`/`MonoUnit` | M1 | |
| `Record`/`TrackedRecord`/`Access`/`Update` | `MonoRecordCreate/Access/Update` | M1 | |
| `Let`/`Destruct` (monomorphic defs) | `MonoLet`/`MonoDestruct` | M1 | simple bindings; polymorphic lets → M5 |
| `Case` (compiled decision tree, `Decider`/`Choice`, jumps) | `MonoCase` | M3 | path typing (`MonoPath`) needs ctor field projection via `Analysis.lookupUnion`; port `computeCustomFieldType`/`computeIndexProjectionType`/`specializeDtPath` policies (`Specialize.elm:4684-4754,4786-4840,5035-5074`) |
| `Accessor` | `MonoAccessorValue` | M3 | + accessor virtual-global enqueues (ref `3783,4305,4331`); shared `ResolveAccessorValues` finishes the job |
| `Function`/`TrackedFunction` | `MonoClosure` | M4 | `ClosureInfo` + `lambdaCounter` policy ported from the Function arm |
| `TailCall` / `Def.TailDef` | `MonoTailCall`/`MonoTailDef` | M4 | |
| `Let` (let-polymorphic / multi-instance) | cloned `MonoLet` chains | M5 | §8 M5 design note first |
| `Shader` | (as old engine) | M6 | niche |

Stack discipline: mirror the old engine — plain recursion within a body,
`foldl`+`reverse` for sibling lists (`Specialize.elm:4059-4062`), tail-recursive
worklist drain as the cross-function safety valve.

### 5.9 Engine state (global, across items)

```elm
type alias EngineAccum =        -- mirrors State.SpecAccum minus schemeCache
    { worklist : List WorkItem, nodes : Array (Maybe Mono.MonoNode)
    , inProgress : BitSet, scheduled : BitSet
    , registry : Mono.SpecializationRegistry, ports : List Mono.PortRegistration }

type alias EngineCtx =          -- mirrors State.SpecContext minus subst machinery
    { toptNodes : DMap TOpt.Global (TOpt.Node MVarId)
    , annotations : TOpt.AnnotationsByGlobal MVarId
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , currentGlobal : Maybe Mono.Global      -- error context
    , lambdaCounter : Int
    , superTable : Dict Int IO.SuperType     -- §5.5
    , nextMVarId : TypeIds.MVarId }          -- for unify-minted ext vars (§5.4)
```

Dropped relative to the old engine (their jobs are subsumed): `schemeCache`/
`SchemeInfo`, `Substitution`, `varEnv`, `localMulti`/`valueMulti` stacks (M5
will introduce its own, simpler, local-instance bookkeeping), `currentFreeVars`,
`mvarEnv`-as-threaded-state.

### 5.10 Driver

`MonoSolver/Monomorphize.elm` mirrors the old driver phase-for-phase
(`Monomorphize.elm:68-92,181-235`): `EntryPrep.insertFlagsDecoderNode` →
`AssignMVarIds.assignIds` → seed (main demand = pure classification of its own
annotation, i.e. the engine's `canTypeToMono superTable` — the old engine's
`entryPointMonoType` with empty subst, `Monomorphize.elm:613-616`; flags decoder
likewise) → drain → assemble (`mainInfo = StaticMain`, callEdges/`specHasEffects`/
`specValueUsed` fold — port `assembleRawGraphFrom`, `Monomorphize.elm:297-379`,
which is plain output-IR code) → shared `Prune.pruneUnreachableSpecs`.

## 6. Module layout, `compiler/src/Compiler/MonoSolver/`

| Module | Contents |
|---|---|
| `Monomorphize.elm` | driver (§5.10); exposes only `monomorphize` |
| `Engine.elm` | `Step` monad, `Failure`, `ItemState`, work-item loop (§5.2, §5.7) |
| `Store.elm` | `freshStore`, `loadType`, `monoTypeToVar`, `unifyStep` (wraps `Unify.unify`; `AnswerErr → Failure` with both rendered types + context) |
| `Zonk.elm` | `zonkToMono`, `canTypeToMono` (store-free classification for entry seeding), the classification table (§5.4) — **the only module that stamps residual constraints** |
| `Translate.elm` | body walk (§5.8); splits into `TranslateCase.elm` / `TranslateClosure.elm` etc. as arms land |
| `Diff.elm` | diff-mode runner + FNV-1a fingerprint (copied from `GoldenConstraintTest.elm:48-69` — it is module-private there) |

CMake note: adding `.elm` files requires `cmake --preset build` reconfigure
(`ELM_SOURCES` is a non-CONFIGURE_DEPENDS glob).

## 7. Switching, diff mode, and the A/B gate

### 7.1 Config + env plumbing (exact edits)

1. `Compiler/Eco/Config.elm`: add
   `type MonoEngine = EngineSubst | EngineSolver | EngineDiff`,
   `type alias MonoConfig = { engine : MonoEngine }`, field `mono : MonoConfig`
   on `EcoConfig` (`:30-33`), `default.mono = { engine = EngineSubst }`,
   decoder via `optionalField "mono"` (strings `"subst"|"solver"|"diff"`,
   pattern of `:92-94`). **`hash` (`:151-168`): append an engine token only when
   `/= EngineSubst`** so default-config hashes — and everyone's Details caches —
   are unchanged.
2. `Builder/Eco/Config.elm` `load` (`:36`): after decoding, chain
   `Utils.envLookupEnv "ECO_MONO_ENGINE"` (`Utils/Main.elm:995`) and override
   `mono.engine` (unrecognized value → fail like a bad config file). Doing it
   inside `load` means the override automatically feeds the hash read at
   `Terminal/Make.elm:219`. Precedent for env-toggled E2E behavior:
   `ECO_TEXT_MLIR` (`test/TestSuite.hpp:20-26`).
3. `Builder/Generate.elm:731`:
   ```elm
   case ecoConfig.mono.engine of
       Config.EngineSubst  -> Monomorphize.monomorphize "main" globalTypeEnv typedGraph
       Config.EngineSolver -> MonoSolver.monomorphize "main" globalTypeEnv typedGraph
       Config.EngineDiff   -> MonoDiff.run "main" globalTypeEnv typedGraph
   ```
   inside the existing `Err → Task.throw` wrapper. This is the only production
   line that changes outside new files + Config.
4. `TestPipeline.elm`: parameterize `monomorphizeAny` (`:574-576`) — add
   `runToMonoWith : MonoEngine -> …` (and `runToGlobalOptWith`/`runToMlirWith`);
   existing entry points delegate with `EngineSubst` so all current tests are
   untouched byte-for-byte.

### 7.2 Diff-mode semantics (`MonoDiff.run`)

Run old engine, then new engine, on the identical input:

- both `Ok`: compare `fnv1a (Debug.toString g)` (Debug.toString canonicalizes
  Dicts — sorted rendering — which `(==)` does not guarantee). Equal → return
  the old graph. Unequal → `Err ("ECO_MONO_DIFF MISMATCH fpOld=… fpNew=…")`.
- new `Err e`: `Err ("ECO_MONO_DIFF " ++ e)` — carries the
  `MonoSolver.unsupported:`/`unify-mismatch:` classification through.
- old `Err`: propagate (identical to `subst` behavior).

So under `ECO_MONO_ENGINE=diff` **every E2E test is itself the verdict**: pass
= new engine matched; fail-log prefix distinguishes `MISMATCH` from
`unsupported` (grep the tee'd log). No new reporting infrastructure. Mismatch
diagnosis: a debug hook in `Diff.elm` (env `ECO_MONO_DIFF_DUMP=1`) that embeds
both `Debug.toString` renderings in the error for offline diffing.

### 7.3 Byte-identity doctrine

Target: **byte-identical `MonoGraph`** (same input MVarIds via shared
AssignMVarIds; same SpecId order via mirrored traversal; shared Registry/Prune).
Known residual risk: the representative MVarId stamped on residual `MVar id _`
when several ids share a union-find class (old engine: `findRootVar`'s
binding-chain policy; new engine: first-loaded, §5.4). If A/B shows divergence
*only* in residual-id numbering, add a canonical residual-renumbering
normalization **in `Diff.elm` only** (never in either engine) and document each
waived case in this plan. Escalation: byte-identical > normalized-identical >
per-case documented waiver. External arbiter: `--text-mlir` output byte-diff
(equal graphs ⇒ equal MLIR).

**Mismatch triage doctrine:** the old engine's unifier fails silently by design
— a MISMATCH is a candidate latent bug in *either* engine. Triage each; wins on
either side become regression tests.

### 7.4 Stale-artifact gotcha (will burn you on day one)

The E2E harness caches `.mlir` by source mtime (`ElmE2ETestBase.hpp:432-438`).
Flipping `ECO_MONO_ENGINE` does NOT invalidate it. When switching engines:
delete the fixtures' `eco-stuff/mlir` dirs or run the `full` target. Same
discipline as CLAUDE.md's stale-`.mlir` warning.

## 8. Milestones

Every milestone gates on: (a) its corpus 100% pass under `ECO_MONO_ENGINE=diff`,
(b) all earlier corpora still 100%, (c) full suite green with default config
(old engine untouched), (d) grep gates clean (§10.4). Test-run discipline per
CLAUDE.md: run once, `2>&1 | tee`, grep the file.

- **M0 — Scaffold, switch, harness.** `EntryPrep` extraction (pure move, suite
  green); Config field + env override + hash rule; `Generate.elm` branch;
  `TestPipeline` `*With` variants; `MonoSolver/` skeleton whose driver runs
  EntryPrep + AssignMVarIds + seeding and returns `Err "MonoSolver.unsupported:
  work item"` from the first item; `Diff.elm` with fingerprint + dump hook.
  *Gate: default-config full suite green; `ECO_MONO_ENGINE=diff` corpus run
  completes with 100% `unsupported`, zero crashes; `solver` mode fails builds
  loudly.*
- **M1 — Monomorphic spine.** `Store`/`Zonk`/`Engine` (§5.1-5.7); translation
  arms marked M1 in §5.8 including monomorphic kernel calls (UseSubstitution —
  arithmetic is kernel, so even trivial programs need it); assemble + shared
  Prune wired. *Gate: a named list of fully-monomorphic E2E programs (curate
  ~30-50 from `test/elm` during M0) at diff-MATCH.*
- **M2 — Polymorphism + numbers.** Polymorphic demand propagation (no
  call-site scheme machinery — §5.8 Call row); residual stamping + super table;
  PreserveVars/suffix-selecting kernel ABI + Debug; container/element demand.
  *Gate: LetNumber/Float/Destruct E2E families + polymorphic-call cases at
  diff-MATCH; `MonoGraphIntegrity` unit helpers (`expectMonoGraphComplete/
  Closed/expectSpecRegistryComplete/expectCallableMonoNodes`) pass via
  `runToMonoWith EngineSolver`.*
- **M3 — Decision trees + accessors.** `Case`/`Decider`/jumps, `MonoPath`
  projection typing via `Analysis.lookupUnion`, `Accessor` + virtual globals +
  shared `ResolveAccessorValues`. *Gate: case/pattern-heavy corpus at
  diff-MATCH.*
- **M4 — Closures + tail recursion.** `Function → MonoClosure` (`ClosureInfo`,
  `lambdaCounter`), `TailCall`/`TailDef`, higher-order flows. *Gate:
  closure/PAP/tailrec families at diff-MATCH.*
- **M5 — Let-polymorphism + multi-instance locals.** The §6.4 corner:
  `withFreshBinding` splits let-def identity from the enclosing body, so
  binding sites re-link explicitly — per use of a let-generalized def, load the
  def's scheme with fresh Points for its own vars, unify with the zonked
  use-site demand (per-use types are already per-instance in the IR), and emit
  cloned `MonoLet` chains mirroring the old localMulti/valueMulti *output*
  (not its machinery). **Deliverable order: short design note + dedicated test
  batch (generalized let functions, captured number vars, shadowing, nested
  lets) BEFORE implementation.** *Gate: let-poly/multi families at diff-MATCH.*
- **M6 — Kernel honesty, ports, cycles, the rest.** Port/decoder nodes, `Cycle`
  (mirror `specializeCycle`'s in-progress/scoping discipline — see
  `plans/mono-011-mutual-recursion-scoping-fix.md` for the known traps),
  `Manager`, `Shader`, flags-decoder end-to-end. Kernel-type honesty (§6.3 of
  the eval doc): fabricated `meta.tipe`s that are internally inconsistent
  surface as `UnifyMismatch`/MISMATCH here — triage each: fix the kernel type,
  make the placeholder genuinely fresh, or record a documented shim in
  `Store.loadType`. Budget explicitly; every find is a latent-miscompile
  candidate in the old engine too. *Gate: kernel-heavy/ports/cycle corpus at
  diff-MATCH.*
- **M7 — Parity, determinism, performance.** Full E2E (1547) at diff-MATCH;
  full suite green with `ECO_MONO_ENGINE=solver`; `--text-mlir` byte-diff on a
  sample; bootstrap fixed-point (self-compile reproduces); benchmark gate: eco
  self-compile wall time and elm-aws-codegen within agreed bounds (mitigations
  in reserve: zonk memoization per root, arena-style store reuse). *Gate: all
  of the above + keep/kill review recorded.*

**Horizon (separate plans after M7):** flip the default; delete
`TypeSubst`/old `Specialize` + their gates; invariant rewordings
(MONO_008/015/020/021/024/025 — `design_docs/hm-solver-reuse.md` appendix
drafts them); PostSolve 2.0; lambda sets in the mono store.

## 9. MonoDirect lessons — why this parallel implementation is survivable

1. **Production-wired from M0** — exercised by real `eco make`, never test-only.
2. **Compiles on every build** — lives in `ELM_SOURCES`; shared-type refactors
   break it loudly at compile time instead of orphaning it.
3. **No fallback, structurally** — forbidden-import grep gate; unsupported =
   `Err`, never "ask the old engine."
4. **Total types only** — `meta.tipe`, never `meta.tvar`.
5. **Keep/kill review per milestone** — measurable diff-MATCH gates; a stalled
   milestone triggers replan/stop, never a lingering half-dead shadow.

## 10. Verification

1. **Default-path safety:** every commit, full suite with default config; the
   only changed production lines outside new files are the Config field, the
   `load` override, and the `Generate.elm` branch.
2. **Diff dashboard:** corpus runs under `ECO_MONO_ENGINE=diff`; count
   `ECO_MONO_DIFF MISMATCH` vs `MonoSolver.unsupported` in the tee'd log. The
   number that moves each milestone is unsupported→pass, with MISMATCH pinned
   to 0 before the milestone closes.
3. **Invariant checks:** `MonoGraphIntegrity` helpers against solver output
   (MONO_004/005/010/011); MONO_028 holds structurally (grep: no `MInt`
   production outside `Zonk.elm`'s table and shared Prune; `Zonk` is the only
   residual-stamping module).
4. **Grep gates (CI/test):** no `Compiler.Monomorphize.TypeSubst` or
   `Compiler.Monomorphize.Specialize` import and no `.tvar` read under
   `compiler/src/Compiler/MonoSolver/`.
5. **M7:** bootstrap fixed-point + `--text-mlir` byte-diff + benchmarks, as
   §8.

## 11. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| Shadow drift / dual maintenance (the MonoDirect killer) | High if ignored | §9; shared modules by import; milestone keep/kill |
| Identity-borne propagation has a gap (some body type doesn't resolve from the root demand) | Medium probability, low cost | Surfaces as MISMATCH/residual from M1 via A/B; the fix is a localized extra unification at the offending construct — the architecture allows per-site assertions, it just doesn't start with them |
| Kernel/fabricated types reject or diverge (M6) | High (migration), positive (end state) | Explicit budget; per-case triage; documented shims in one place (`Store.loadType`) |
| Let-boundary re-linking subtlety (M5) | Medium | Design note + test batch before code |
| Residual `MVar` id / SpecId numbering divergence | Medium | Mirrored traversal order; `Diff.elm`-only normalization fallback with documented waivers (§7.3) |
| Perf regression (store churn, zonk walks, Debug.toString in diff mode) | Medium | Per-item stores; zonk memoization; concrete-type fast path (skip store for var-free `meta.tipe`s) held in reserve; diff mode is opt-in; benchmark gate at M7 |
| `Unify` internals change under typechecker Design B/C work | Low-Medium | Engine consumes only exposed, stable API (`unify`, `UF`, `IO` types) — zero Type/ edits means no landing-order coupling; coordinate only if Design C changes exposed signatures |
| Diff-mode memory (two graphs + two Debug.toString renderings) | Low | Fingerprint streams over one rendering at a time; dump hook opt-in |
| Stale `.mlir` cache poisons A/B conclusions | Certain without discipline | §7.4; wipe fixtures' `eco-stuff/mlir` or use `--target full` when flipping engines |

## 12. Relationship to other work

- **Implements:** `design_docs/monomorphization/solver-reuse-evaluation.md`
  Architecture C (deviating from §7's strangler per user decision, with §9
  mitigations); builds on `design-recovery.md`.
- **Corrects (vs. eval doc, verified against code):** defaulting stays in
  shared Prune, not zonk; `MErased` does not exist; kernel typing at mono time
  comes from `VarKernel` `meta.tipe`, not a PostSolve env; zero `Type/` edits
  needed (the eval doc's Phase-1 "additive wrappers" shrink to nothing).
- **Subsumes at parity:** J5 `MVarEnv` threading + the remaining verify-inert
  compensations (`plans/mvar-env-threading-and-arch-c-horizon.md` — its
  "Arch C horizon" section is this plan); the `Pending*`/demand-replay tower.
- **Prior art mined, not repeated:** `plans/*monodirect*.md` (post-mortem),
  `design_docs/hm-solver-reuse.md` (invariants appendix for the horizon phase).
- **Coordinates with:** typechecker Design B/C (`plans/typechecker-design-b.md`,
  `typechecker-design-c.md`) — read-only consumption of exposed solver API.
