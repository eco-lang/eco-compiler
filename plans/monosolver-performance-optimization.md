# MonoSolver Performance Optimization — Implementation Plan

## SESSION 3 — user-directed: (A1) kill `Step`, (A2) `Dict Int`→`Array`, (A3) desugar point-free (2026-07-10)

Three aggressive levers requested by the user. STATUS: all three implemented on the HOT paths and gated
**byte-identical** (6/6 fixed inputs + corpus **466 MATCH / 51 MISMATCH / 0 ERR**, mismatch set identical
to baseline). Specifics:
- **A2 DONE:** `revMemo` (point-index, dense) → `Array (Maybe MVarId)`; the MVarId-keyed Dicts
  (`memo`/`superStatic`/`superTable`) correctly KEPT as Dict — their global-monotonic sparse keys make an
  Array pathological (documented below).
- **A1 + A3 (hot paths DONE):** converted to explicit trailing-`S` param (`f x s = …`, eliminating the
  per-call `\s ->` closure) — `translate` (F2, the per-node flagship) and its whole call fan-out
  (`translateVarRef`/`translateGlobalCall`(+Fast/GroundMemo/Slow)/`translateKernelCall`/`emitCall`/
  `localCalleeCall`/`translateLocalMultiCall`/`translateIndirectCall`/`translateUpdate`/`argUnifyVar`/
  `unifyParamsCollect`/`localMultiArgName`/`enrichFromEnv`/`connectTypes`/`classify`), plus the hot Engine
  leaves (`enqueueSpec`/`insertVar`/`lookupVar`/`localVarInfo`/`isLocal/NumberMultiTarget`/`push/popLocal/
  NumberMulti`/`numberMultiRootType`/`recordMultiInstance`/`scoped`) and `Store.classifyDirect`. A3
  point-free desugars folded in (`recordNumberInstance`/`recordLocalInstance` were `= recordMultiInstance …`
  partials → explicit args; `classify`/`classifyDirect` η-expanded). SAFETY held throughout: `Step a` IS
  `S -> Result…`, so each function converted independently stayed green (unsaturated callers curry).
- **NOT yet converted (lower-frequency; the `Step` alias + combinators therefore remain):** `translateBranch`/
  `translateIfBranch`, `specializeLambda`/`specializeJumps`/`specializeDecider`, kernel-ABI helpers,
  cycles/ports, `Store.loadType`/`monoTypeToVar`/`zonkToMono` wrappers, `demandUnify`, and the primitives
  `succeed`/`fail`/`getS`/`modifyS`/`andThen`/`map`/`traverse`/`foldlS`/`liftIO`. Full `Step` removal is the
  same mechanical pattern over these remaining sites; deferred as diminishing-return / higher-churn.

**MEASURED — A1+A2+A3 are PERFORMANCE-NEUTRAL (a clean negative result).** dev-JS --cpu-prof, pre-A1 (post-M6)
vs post-A1+A2+A3, same machine: total 173.8→175.2s, **GC 69.79→70.91s, `(anonymous)` 64.92→65.73s,
`_Utils_cmp` 9.14→9.01s, `_Utils_update` 8.68→8.50s — every bucket flat within the ±10-15s single-run noise.**
WHY: the state-passing encoding `Step a = S -> Result Failure (a, S)` allocates an `Ok ( a, s )`
Result-of-tuple at EVERY step regardless of whether the function is written point-free (`f x = \s -> …`) or
explicit-param (`f x s = …`). Removing the `\s ->` closure removes one small allocation, but the dominant
allocation is that per-step `Ok ( a, s )` tuple — which BOTH styles pay and A1 does NOT change. So
de-monadification (in the explicit-param sense) cannot move the closure/GC buckets; the closures the
profiler attributes to `(anonymous)` are overwhelmingly the traverse/foldl/List.map callbacks + the
still-monadic Store/Zonk internals, not the per-function `\s ->` wrappers. A2's `revMemo`→Array likewise
didn't move `_Utils_cmp` because that Dict is small/per-item. **Implication:** the ONLY lever that would cut
the per-step tuple allocation is a different encoding — pushing per-item state (memo/varEnv/…) into
`IO.State` array-refs so the inner ops thread just the store via the existing `IO` monad (the plan's
"more radical alternative"), or an in-place/mutable representation. That is a much larger rearchitecture,
not a mechanical de-monadify.

NATIVE Stage-7a A/B CONFIRMS NEUTRAL (same-binary ECO_MONO_ENGINE flip, cold eco-stuff, 2 runs each,
solver MLIR deterministic + self-hosts): A1/A2/A3 binary = subst avg 269.5s, solver avg 325.9s → **gap
+56.4s**; prior (pre-A1) gap was **+53.0s**. The gap (which cancels cross-run machine drift) did NOT shrink —
A1/A2/A3 is performance-neutral (the ~3s is run-to-run noise, direction slightly negative). Byte-identity
fully preserved (corpus 466/51/0, solver MLIR deterministic across both runs). CONCLUSION: the three
user-requested levers are correct and safe but do not move the needle; the real remaining lever is the
`Ok (a,s)`-per-step allocation, addressable only by an encoding change (IO.State refs / mutation).

### A2 — `Dict Int` → `Array` (do first; bounded, data-structure change)
`Array.get`/`set` are O(log₃₂ N) with Int indexing (no `_Utils_cmp`), vs `Dict Int`'s O(log₂ N) with an
Int comparison per node — so for Int keys an Array is both faster AND allocates less on insert (narrower
path copy). BUT `Array.set k` on a shorter array pads `k−len+1` `Nothing`s (`arraySetGrowing`), so it is
only viable when keys are **dense / zero-rooted**. Verdict per field (MVarIds are GLOBAL & monotonic —
`AssignMVarIds.nextId` never resets):
- **`revMemo : Dict Int MVarId`** (key = union-find POINT index; fresh store per item ⇒ dense from 0) →
  **Array (clean win)**. Hot: read on every zonk `residualId`.
- **`superStatic`/`superTable`/`memo` (all key = MVarId) → KEEP Dict.** RE-ASSESSED: MVarIds are GLOBAL and
  monotonic, so all three are keyed by high, SPARSE ids. An Array must be sized to the max KEY, not the entry
  count — so `superStatic` (few super-constrained vars, but at high MVarIds) would allocate a huge ~all-`Nothing`
  global Array; `memo` (per-item) would pad ~maxKey `Nothing`s EACH item via `arraySetGrowing`. Both
  pathological. A dense remap (MVarId→[0,K)) would itself need a Dict, so no win. Same verdict for the small
  per-call `subst : Dict Int MonoType` accumulators (`classify*` / `Zonk.canTypeToMonoWith`).
  **NET: only `revMemo` (point-index keyed) is a genuine dense/zero-rooted Array candidate; it is the one
  converted. The MVarId-keyed Dicts stay Dict — the "keys dense & zero-rooted" precondition fails for them.**
- Iteration order preserved: `Dict Int` folds in ascending key order == `Array` index order (skip `Nothing`).

### A1 — Fully de-monadify, remove `Step`
`Step a = S -> Result Failure (a, S)`. M6 desugared the hot arms but still wrote them point-free
(`f x = \s -> …`), which allocates the `\s ->` closure per call. A1 goes further: give every function an
EXPLICIT trailing `s` parameter (`f x s = …`) so saturated call sites compile to `A2/A3(f, …, s)` with NO
intermediate closure, then delete the combinators (`andThen`/`map`/`getS`/`modifyS`/`succeed`/`fail`/
`traverse`/`foldlS`/`scoped`/`liftIO`) and the `Step` alias. KEY SAFETY: because `Step a` IS
`S -> Result…`, a function rewritten `f x s = …` still has type `… -> Step a` — so the alias can stay during
the transition and functions convert ONE AT A TIME, always green, byte-identical (state threading
unchanged). Remove the alias only once no combinator use remains. Bulk is Translate.elm (~167 `andThen`) +
Engine helpers.

### A3 — Desugar point-free functions into direct (explicit-argument) functions
Point-free definitions (`f = g << h`, `f = foldExpr step []`, `classify = zonk ∘ loadType`, any
partial-application-as-definition) compile in Elm to composition wrappers / curried thunks that allocate a
closure per call and hide an extra indirection. Rewriting them with explicit arguments
(`f x = g (h x)`, `f x acc = foldExpr step [] x`) removes the wrapper and lets the compiler emit a saturated
`A2/A3` call. This GENERALIZES A1 (whose `f x = \s -> …` → `f x s = …` is the Step-specific case): A3
sweeps ALL point-free forms across MonoSolver (Engine/Store/Zonk/Translate/Monomorphize), not just the
Step-returning ones. Byte-identical (η-/composition-law equivalences). Do alongside A1.

### A4 — Extensible-record `StateFields r`: merge per-item state into `IO.State`, run the hot ops in plain `IO`
**Rationale — this is the FIRST lever that actually cuts the per-bind allocation** (A1/A2/A3 measured flat
because they left it intact). Today a hot store op costs ~3 allocations: the `IO` tuple `(store1,a)` from
`UF.get`, the `Step` result `Ok (a, …)` (an `Ok` box wrapping a tuple = 2 objects), AND a ~25-field `S`
copy (`_Utils_update`, via `liftIO`'s `{ s | store = … }`). If the per-item mutable fields live INSIDE the
store and the inner ops run in plain `IO`, that drops to ~1 allocation (just the `(store,a)` tuple): the
`Ok`-box and the whole-`S` copy disappear, and the copied record shrinks from `S`'s ~25 fields toward ~11.
Irreducible floor remains the one `IO` tuple/bind + `Array.set` path-copies (eco's `unsafeSet` copies, no
RC-1 in-place — verified `elm-kernel-cpp/src/core/JsArrayExports.cpp:225`), so this is a REAL-BUT-PARTIAL win.

**Design (avoids polluting the typechecker — the key constraint).** `memo`/`revMemo`/`varEnv`/`numberMulti`/
`localMulti` are monomorphization-only; the type inferencer's `IO.State` must not carry them (that would
re-introduce the M7 copy-tax on every `UF.set`/`fresh` and couple `Compiler/Type/*` to mono). Use a
row-polymorphic record alias so the SAME array-ref store serves both, lean for TC and extended for mono:
```elm
type alias StateFields r =
    { r | ioRefsWeight : Array Int, ioRefsPointInfo : Array PointInfo
        , ioRefsDescriptor : Array Descriptor, ioRefsMVector : …, names : NameState, nodeIds : NodeIdState }
type alias State     = StateFields {}                                        -- typechecker (unchanged shape)
type alias MonoState = StateFields { memo : …, revMemo : …, varEnv : …, numberMulti : …, localMulti : … }
```
`UF.get : Point -> StateFields r -> ( StateFields r, Descriptor )` (and the IORef/Unify leaves) become
polymorphic over `r`, threading the extra fields through untouched: `r := {}` for TC, `r := {memo,…}` for
the solver, ZERO mono fields visible to the inferencer. The solver's inner ops (`loadType`/`zonk`/`classify`/
`unify`/`insertVar`/`recordMultiInstance`) rewrite from `Step`-over-`liftIO` to **plain `IO` over MonoState**;
`S` shrinks to just the cross-item accumulators (`worklist`/`registry`/`nodes`/caches/`env`), and `Step` (if
kept at all) wraps only the top-level per-work-item driver, not the hot inner loop.

**Costs / risks (why it's "try it and revert if not a win," not a slam-dunk):**
1. **Touches shared `Compiler/Type/*`.** `IO a = State -> (State,a)` is the inferencer's spine (~95 `IO`-typed
   sigs across ~16 files; `UnionFind`/`Unify` built on it). Making UF/Unify work over `StateFields r` forces
   `IO` to carry the row var (`IO r a`) along the IORef→UnionFind→Unify path. Bound the blast radius to that
   subsystem (leave `Solve`/constraint-gen on concrete `State`), but it is still invasive edits to hot,
   correctness-critical shared code — forfeiting today's "zero typechecker changes" property.
2. **eco MONOMORPHIZES the row-poly functions** (unlike stock Elm-JS where `{r|…}` is free): `UF.get`/
   `Unify.unify` get compiled twice (at `State` and at `MonoState`, different field offsets) → binary bloat
   for the two largest hot modules, and it is exactly the row-polymorphic-record-layout path that historically
   stressed the monomorphizer (RecordNarrow). Expect to exercise those code paths hard; gate carefully.
3. **Elm has no value-level record extension** (`{ state | +memo = … }` is impossible) — fine here because TC
   and solver each build their own record from scratch (`freshStore`/`initState`) and never convert between
   them, but it means `MonoState`'s init must list all base + mono fields explicitly.

**Plan (each step byte-identity-gated: 6 fixed inputs + corpus 466/51/0):**
- A4.0 — refactor `IO.State` → `StateFields r` (alias only; `State = StateFields {}`), make IORef/UnionFind/
  Unify signatures row-poly `IO r a`. Typechecker stays on `State`; MUST stay byte-identical + type-checks.
  (This step alone changes no behavior; it's the enabling refactor. If it bloats/breaks, STOP here and revert.)
- A4.1 — define `MonoState = StateFields { memo, revMemo, varEnv, numberMulti, localMulti }`; move those 5 out
  of `S` into the store; `initState`/`resetItem`/`harvestSuperTable` build/reset them in the store.
- A4.2 — rewrite the hot inner ops to plain `IO` over `MonoState` (drop `liftIO`/`Step` on that path). `S`
  keeps only cross-item accumulators.
- A4.3 — measure (dev-JS profile GC/`_Utils_update`/`(anonymous)` + native Stage-7a A/B gap). REVERT if the
  gap does not shrink beyond the ±10-15s noise floor — the whole point is that this one SHOULD move it, unlike
  A1/A2/A3, so a flat result means the `IO` tuple/`Array.set` floor dominates and the invasiveness isn't paid
  back. Keep the git stash/branch so revert is one command.

**Expected outcome (hypothesis to test):** GC + `_Utils_update` drop measurably (the `Ok`-box + `S`-copy per
hot bind are eliminated); `(anonymous)` roughly flat; native solver↔subst gap shrinks by more than noise.
If confirmed, it's the highest-value front-end lever found; if flat, it localizes the remaining cost firmly
at the kernel (`Array.set` copy / no RC-1 in-place) and justifies stopping front-end optimization there.

**PRE-ANALYSIS VERDICT — A4 NOT IMPLEMENTED, provably flat from existing data (2026-07-10).** Before building
even the cheap test, two facts settled it: (1) the two hottest inner loops `loadType`/`zonk` were ALREADY
bundle-threaded in M3/M6.0 (a 3-field `LoadCtx`/`ZonkCtx`, one `S`-write) — the scoped version of A4 — so
A4's incremental target is only the **~13 remaining `liftIO` sites** (Store 3, Engine 5, Translate 5), not
the hot loop. (2) The `prof_a123` profile (total 175.2s) measures those sites directly: `UnionFind.get`
0.03s, `UnionFind.fresh` 0.05s, `Unify.actuallyUnify` 0.01s, `Engine.liftIO` 0.00s; the ENTIRE MonoSolver
Elm business logic is <0.6s self-time. The `liftIO` wrapper allocations (`Ok`-box + tuple + `S`-copy, ~10⁵–
10⁶ fires) are ≈0.1% of total allocation ⇒ ≈0.1s of the 70.9s GC — an order of magnitude below the ±10-15s
noise floor. So the cheap test (and full A4) would confirm ≈0 change. ROOT CAUSE (the through-line for
A1/A2/A3/A4 all being flat): the solver's whole overhead over subst is NOT concentrated in any optimizable
function (every MonoSolver fn <0.3s) — it is the `(State,a)`/`Ok (a,s)` tuple allocated on EVERY monadic bind,
spread thin across all of translate/classify/loadType/zonk, showing up only as `(anonymous)` (65.7s) + GC
(70.9s). No front-end restructuring (de-monadify, Dict→Array, point-free desugar, IO.State merge, or even
removing `IO`) removes that tuple. **The front-end allocation lever is exhausted.** The only remaining levers:
(a) kernel-level refcount-1 in-place mutation (kill the per-bind tuple/record-copy alloc everywhere — runtime
work, benefits the whole compiler), or (b) an algorithmically different solver with fundamentally fewer
threaded steps (a redesign). `IO`'s `loop` trampoline (self-tail-recursive → while-loop) is a genuine
stack-safety feature and should be KEPT regardless.

---

This session took the "remaining" list to completion. All byte-identity-gated the same way
(6 fixed inputs vs the pre-M1 baseline + the 517-program `ECO_MONO_ENGINE=diff` corpus sweep,
which must hold at **51 MISMATCH, identical SET** to the baseline — the mismatches are the
documented CEcoValue/MONO_003 engine divergences, not regressions).

LANDED + GATED (byte-identical; corpus mismatch set identical to baseline):
  - **M7** env move-out: the 5 immutable fields (`toptNodes, annotations, globalTypeEnv,
    currentModule, superStatic`) nested into one `Env` sub-record in `S`, so each `{ s | … }`
    copies one `env` ref instead of five it never changes.
  - **D6** `KernelAbi.hasAnyFreeVar` (short-circuiting emptiness test; replaces
    `not (List.isEmpty (freeVarIds …))` in `deriveKernelAbiMode` + Translate). Faithful mirror
    of `freeVarIdsHelp` (emptiness preserved — dedup only skips duplicates).
  - **D11** direct state-passing for the two hottest call builders (`emitCall`,
    `translateGlobalCallSlow`, `translateKernelCall`) — desugared the 7-deep andThen nests.
  - **D13** `processItem` per-global memo (`S.nodeResolution`): the `DMap.get` node lookup +
    `nodeAnnotationIds` walk are resolved once per global and reused across its N specs.
  - **D14** `assembleRawGraph` single fused walk (`collectEdgesAndEffects`) — was two full
    `foldExpr` passes (call-edges + effects) over each node's expr.
  - **M6 (hot-path de-monadify)** — direct state-passing rewrite (`\s -> case m s of Err e ->
    Err e; Ok (x, s1) -> …`) of the hot `translate` arms (VarLocal, Int, Float, If, TailCall,
    Accessor, Tuple, Record, TrackedRecord, List, Case, plain-value Let) and helpers
    (`translateVarRef`, `translateCall` VarGlobal arm, `localCalleeCall`,
    `translateLocalMultiCall`, `translateIndirectCall`, `unifyParamsCollect`,
    `translateArgsWith`, `argUnifyVar`, `localMultiArgName`, `enrichFromEnv`, `translateUpdate`).
    Removes the per-bind closure the monad allocated at each `andThen`/`map` — the profile's
    dominant cost (see below). Rarer arms (Let TailDef, number-/local-multi lets,
    specializeLambda, translateAccess) intentionally left monadic (low frequency, high nesting).

EXPLORED → DEFERRED (with fresh profile evidence, dev-JS --cpu-prof of the D11+D13+D14 solver):
  Profile buckets: **GC 44.2%**, **`(anonymous)` closures 35.3%**, `_Utils_cmp` 4.7%,
  `_Utils_update` 4.6%; MonoSolver/Type Elm business logic <1% self-time each. Conclusions:
  - **D15 (solver-local Unify without the fresh-var accumulator): NOT WORTH IT.** `Compiler.Type.
    Unify`/`UnionFind`/`Solve` together are <0.2% of self-time — unification is not hot. Forking
    the entire type-checker-shared CPS unifier (guardedUnify + Unify/UnifyOk/register/…) to drop
    a tiny `List IO.Variable` cons accumulator is high-risk, ~zero-reward. Matches the plan's own
    "only if record/comparable unify proves hot" guard — it doesn't.
  - **D12 (registry structural comparator key): DEFERRED.** Would attack part of the 4.7%
    `_Utils_cmp` (Dict-String key compares) + some GC (key string allocation), BUT: (a) it is
    SHARED code (`Monomorphized.toComparableSpecKey`, used by BOTH engines via `Registry`) — the
    plan's "T6" cost — so it does NOT close the solver↔subst gap that is the actual goal; (b) Elm
    has NO custom-comparator ordered map (`Data.Map`/`Data.Set` both still derive a `comparable`
    per op), so it needs a new balanced-tree data structure built on correctness-critical shared
    code, with a comparator that must EXACTLY replicate the string normalization (CEcoValue-EQ,
    CNumber≡MInt, record fields in `Dict.toList` order) — medium-high risk for a shared-only,
    gap-neutral win. The cheap-safe partial (constant CEcoValue key fragment) is already in place.

The dominant remaining cost is now GC + the residual closure bucket; M6's hot-path desugar
targets the latter directly.

MEASURED (M6, dev-JS --cpu-prof self-compile, same machine, back-to-back — single-run ±10-15s noise):
pre-M6 (D11+D13+D14) total **189.4s** → post-M6 **173.8s** (−8.2%); **GC 83.8s → 69.8s (−14.0s / −17%)**
— M6 removes the per-bind closure AND its `Ok (a, s)` tuple at each desugared `andThen`/`map`, so the
payoff shows primarily as reduced ALLOCATION (GC), not as `(anonymous)` self-time. `_Utils_update`
unchanged (8.65s → 8.68s) — expected: M6 targets closures, not the S-copy (that is M7's lever).

HEADLINE — NATIVE Stage-7a A/B (same binary, ECO_MONO_ENGINE flip, cold eco-stuff, warm ~/.eco, `build`
preset asserts-on; 2 runs each, deterministic — identical md5 within each engine):
  - subst  avg **278.8s** (278.87 / 278.67), MLIR 12,057,978 B
  - solver avg **331.75s** (330.83 / 332.67), MLIR 12,086,438 B (+28,460 B — the documented CEcoValue /
    spec-id-order divergence, runtime-equivalent)
  - **gap +53.0s, solver = 1.19× subst** — down from the pre-optimization **1.54× / +141.6s** (≈63% of the
    native gap closed across all rounds). **BOTH solver runs rc=0, no crash** → the native solver self-hosts
    cleanly; the previously-reported Stage-7a "Pointer below heap base" GC crash (root-caused to the
    Types.bitmapSetKind 32-bit wraparound, since fixed) does NOT recur.
  - Full-stack self-host: bootstrap JS fixed-point (Stage 4b) GREEN with all changes; native solver
    fixed-point (lower solver MLIR → ELF → recompile under solver → reproduce) — see run log.

---

## Status: 14 OPTIMIZATIONS LANDED — 82% of the gap closed, byte-identical, self-hosts green (2026-07-10)

FINAL measured (dev-JS --cpu-prof, all opts incl. M6.0-a monoTypeToVar + M6.0-b zonk bundle):
solver CPU **341.5s → 168.7s (−51%)**; gap vs subst (129.7s) **+211.7s → +39.0s = 82% CLOSED**; wall 373→183s.
Buckets: GC 163.5→65.3, `_Utils_update` 48.8→**8.4** (near subst's 2.1!), closures 88.9→64.5. Corpus held at
466 MATCH / 51 MISMATCH / 0 ERR every round (byte-identical); M1+M2+M3 native bootstrap self-hosts green.
The 14: M1 classifyDirect · M2a closed-scheme cache · M2b ground call-site memo · M3 loadType bundle ·
D1 map/map2/traverse direct · D2 enqueueSpec no-op · D3 lazy diagnostics · D4 no-op pad · D5 length-only lists ·
D8 instantiate 3→1 · D9 VarLocal getS-fuse · D10 callMemo+specId · M6.0-a monoTypeToVar bundle · M6.0-b zonk
bundle. Remaining (below, within-noise/milestone): M6 full de-monadify, M7 env-move-out, D6, D11, D12, D13,
D14, D15. Cleanup TODO: dead Step `struct`/`recordFieldPoints`/`residual*` in Store.elm.

---

## Status (prior): 13 OPTIMIZATIONS LANDED & MEASURED (2026-07-10)

LANDED (all byte-identical on 6 fixed inputs + corpus held at 466 MATCH / 51 MISMATCH / 0 ERR throughout;
M1+M2+M3 self-hosts green incl. native fixed-point):
  M1 classifyDirect · M2a closed-scheme cache · M2b ground call-site memo · M3 loadType bundle ·
  D1 map/map2/traverse direct · D2 enqueueSpec no-op · D3 lazy unify diagnostics · D4 translateArgsWith
  no-op-pad · D5 drop length-only argCanTypes lists · D8 instantiate 3→1 S-copy · D9 VarLocal 3-getS fuse ·
  D10 callMemo+specId · M6.0-a monoTypeToVar bundle.
MEASURED (dev-JS --cpu-prof, single-run so ±10-15s noise): preM1 solver 341.5s → ~185-201s CPU (-42 to -46%);
subst 129.7s. Gap +211.7s → ~+55-71s (66-74% closed). NATIVE Stage-7a A/B (M1+M2+M3, cleaner): solver
404→337s (-16.6%), native gap +141.6→+63.7s (55% closed), self-hosts green. The small D-milestones now sit
within the single-run noise floor — a signal the bulk of the achievable win is captured.
REMAINING (specified below with designs; each now within-noise per milestone, increasing effort/risk):
  M6.0-b zonk bundle · M6 full de-monadify Translate · M7 env move-out (Reader) · D6 freeVarIds hasAny ·
  D11 flatten andThen chains · D12 registry structural key (biggest, but shared T6 + comparator risk) ·
  D13 processItem per-spec recompute · D14 assembleRawGraph single walk · D15 unify no-accumulator.

---

## Status: M1+M2a+M2b+M3 LANDED & MEASURED (2026-07-09) — 68% of the solver↔subst gap closed

Measured on the dev-JS `--cpu-prof` A/B (perf plan §7 recipe). All landed milestones are BYTE-IDENTICAL to
pre-M1 solver on 6 fixed inputs and hold the corpus at 466 MATCH / 51 MISMATCH / 0 ERR (= pre-existing
baseline); E2E green.

| milestone | mechanism | solver JS CPU | Δ | notes |
|-----------|-----------|--------------:|----:|-------|
| pre-M1    | (baseline)                              | 341.5 s | —      | subst 129.7 s; gap +211.7 s |
| **M1**    | `classifyDirect` (read-only classify)   | 257.5 s | -84.0  | GC 163.5→113.9, _Utils_update 48.8→31.6 |
| **M2a**   | closed-scheme fast path + `schemeMono`  | 245.9 s | -11.6  | localized |
| **M2b**   | ground call-site memo `callMemo`        | 209.0 s | -36.9  | hits hot polymorphic calls; GC 108.7→82.2 |
| **M3**    | `loadType` bundle-threading (`LoadCtx`)  | 197.9 s | -11.1  | _Utils_update 23.7→15.9 as designed |
| **total** |                                         | **197.9 s** | **-143.6 (-42%)** | **gap +211.7→+68.2 s = 68% closed**; wall 373→213 s |

DEFERRED after assessment: **M2c** kernel-ABI cache (its PreserveVars branch consumes fresh MVar ids via
`remapEcoVarsFresh` → byte-drift, and the mode depends on per-item taint → a sound key is complex; low hotness).
**M4** Dict→Array (superStatic is shared with `Zonk.canTypeToMono`'s Dict signature; revMemo needs a growing
array aligned against Unify-internal Points that bypass `freshVarC`; the ~9 s `_Utils_cmp` is dominated by the
registry's *string* SpecKeys — a shared T6 cost — not these two tables). **M5** harvest skip-flag (needs an
exhaustive audit of every FlexSuper-Number construction site; ~1-3 s reward). **M3-extend** to
`monoTypeToVar`/`zonkToMono` would recover more of the residual `_Utils_update` (15.9 vs subst 2.1) — the clean
next step if more is wanted. Given 68% closed byte-identically, the remaining items are diminishing-return.

---

## Status: NOT STARTED (plan rev 1, 2026-07-09)

Companion to `plans/monosolver-performance.md` (the measurement + analysis document —
read it first; its §2 profile table is the evidence base for everything here).

**Baseline** (frontendstats Stage-7a protocol, cold eco-stuff, warm ~/.eco, `build` preset):
native subst **262.5 s** vs solver **404.1 s** (+141.6 s, 1.54×). JS front-end CPU delta
+211.7 s = GC +116.9 s + `_Utils_update` +46.7 s + closures +35.0 s; MonoSolver's own
algorithmic self-time is 2.2 s (~1%). The slowdown is allocation churn from monadic
plumbing, not algorithms.

**Target**: native Stage 7a ≤ ~310 s after M1-M5 (recover ≥65% of the gap). Stretch: parity.

---

## Discovered opportunities (3 parallel review agents + user review, 2026-07-09)

Ranked by impact ÷ risk. **The top tier is CHEAPER and SAFER than the big M6/M7 refactors** and
directly attacks the profiled buckets — do these FIRST. All byte-identical unless noted; gate each
with the 6-fixed-input byte check + corpus 466-MATCH.

### Tier 1 — cheap, byte-identical, high-value (do first)
- **D1 `map`/`map2`/`traverse` direct rewrite** (Engine.elm:164-178). *[= user's CPS→direct idea, biggest instance.]*
  `map f step = andThen (\a -> succeed (f a)) step` allocates 2-3 closures where 1 suffices; it fires on
  ~every zonk/encode node. Rewrite to `map f step = \s -> case step s of Err e -> Err e; Ok (a,s1) -> Ok (f a,s1)`
  (+ map2, + `traverse` as direct order-preserving recursion, no `List.reverse`). ~15-line diff, monad-law
  preserving, zero risk. **Attacks the 17% closure bucket across the whole pass.** Both Engine/Store and
  Translate agents ranked this #1.
- **D2 `enqueueSpec` no-op update** (Engine.elm ~247). *[= user's no-op-update idea, biggest instance.]*
  When `BitSet.member specId s.scheduled`, `getOrCreateSpecId` returned the SAME registry (found branch →
  `(specId, registry)` unchanged), so `{ s | registry = reg1 }` copies the whole S to change nothing. Return
  `Ok (specId, s)` unaltered. VERY hot (every repeat `VarGlobal`, the common case). Byte-identical.
- **D3 lazy unify diagnostics** (Translate.elm:65,~1998; `unifyStepCtx`). `demandUnify` eagerly builds
  `canKind ++ monoKind` (full recursive type→String walks) on EVERY unify, used only in the `Err` arm (a
  compile-aborting failure). Make the context `(() -> String)`, force only on mismatch. Zero risk; removes two
  string-tree builds per demand-unify.
- **D4 `translateArgsWith` no-op append** (Translate.elm ~1780). *[= user's no-op idea.]* `stash ++ List.repeat
  (len args - len stash) Nothing` — `unifyParamsCollect` always returns exactly `len args` entries, so this is
  `stash ++ []` which still copies `stash` and walks it twice. Replace with `stash`. Byte-identical (record the
  length invariant in a comment).
- **D5 `List.map TOpt.typeOf args` built only for `List.length`** (Translate.elm:1603,1555,1168). Three call
  builders allocate a full canonical-type list just to take its length; the hottest is `translateKernelCall`
  (every `+ - * == < >`). Replace `argCount` with `List.length args`.
- **D6 `List.isEmpty (freeVarIds …)`** (KernelAbi.deriveKernelAbiMode:99; Translate.elm:2272). Materializes the
  whole free-var-id list to test emptiness — one per kernel call + per let. Short-circuit `hasAnyFreeVar` walk.

### Tier 2 — concrete, low-med risk, byte-identical
- **D7 `zonkToMono` read-only S-copy** (Engine.liftIO:210; Store.zonkToMono:495). `zonk` does `liftIO (UF.get)`
  per node = a full S-copy, but `UF.get` on a root doesn't change the store. Read via a non-compressing
  `getS (\s -> readDescNoCompress s.store var)` so the per-node S-copy vanishes. HIGH impact on the 22% bucket;
  medium risk (must mirror `UF.get`/`repr`). ORTHOGONAL to M6.0's write-bundle (zonk never writes).
- **D8 `instantiate` 3 S-copies → 1** (Translate.elm:1968). memo:=empty + loadType-internal + restore = 3
  copies; thread a `LoadCtx {store, memo=empty, revMemo}` and write once (reuse M3 machinery). Hot (every
  kernel/slow/local-multi call). Byte-identical.
- **D9 `VarLocal` 3 sequential `getS`** (Translate.elm:179-223). Fuse `isLocalMultiTarget`+`isNumberMultiTarget`
  +`lookupVar` into one `getS` returning a tagged result, branch after. Byte-identical; hot node.
- **D10 `callMemo` → cache `specId` too** (Translate.elm:1483; Engine.callMemo). On a hit, `emitCall` still
  re-`enqueueSpec`s → re-serializes `funcMonoType` for the registry. Store `(funcMono, resultMono, specId)`;
  emit directly on hit (spec already scheduled, id stable). Byte-identical; kills redundant ground-call
  serialization.
- **D11 flatten `andThen` chains in `translateGlobalCallSlow`/`translateKernelCall`** (~8 closures/call) to
  direct `\s -> case … of` style — the M6 pattern applied to the two hottest call builders. Re-profile after D1
  (which may absorb much of it).

### Tier 3 — bigger / shared-cost (deeper)
- **D12 Registry structural key** (Registry.elm:50; Monomorphized.toComparableSpecKey). Replace `Dict String`
  keyed on a re-serialized MonoType string with a structural comparator (`compareSpecKey`: Global then MonoType
  by tag, replicating the CEcoValue-EQ / CNumber≡MInt / record-field-order normalization EXACTLY). Biggest
  single GC + `_Utils_cmp` win, but MEDIUM risk (comparator must match string-eq) and it's the shared **T6**
  cost (helps subst too). Cheap safe partial: pre-build the 4-cons `CEcoValue` fragment as one constant string.
- **D13 `processItem` per-spec recompute** (Monomorphize.elm:228,243). Re-serializes the global for a `DMap.get`
  and rebuilds `nodeAnnotationIds` EverySet per spec of the same global. Stash the resolved node at enqueue;
  memoize annotation-ids per global.
- **D14 `assembleRawGraph` double full-program walk** (Monomorphize.elm:402-431). `collectCallsFromNode` and
  `nodeHasEffects` each fold the whole program; fuse into one `foldExpr`, build edges via `Array.fromList`.
  One-time (not per-spec) → low priority.
- **D15 solver-local `Unify` without the discarded fresh-var accumulator** (Unify.elm; Store.unifyStep discards
  `AnswerOk _`). Forks type-checker-shared code → medium risk; only if record/comparable unify proves hot.

---

## M6 (NEW, HIGHEST remaining leverage) — De-monadify the hot paths (direct state-passing)

**Rationale.** `Step a = S -> Result Failure (a, S)` is a state monad + failure short-circuit.
Its `Engine.andThen`/`map` combinators allocate a **closure per bind** (the profile's
`(anonymous)` bucket, +35 s over subst pre-opt) and its `modifyS`/`liftIO` copy the whole
~25-field `S` (`_Utils_update`). Together the monad machinery was ~30-40% of the whole gap.
We cannot remove state threading (Elm is pure), but we can remove the monadic ENCODING:
rewrite the hot paths in **direct state-passing** (`let (x, s1) = m s0 in …` / explicit
`case … of Err e -> Err e; Ok (x, s1) -> …`), which the Elm→JS compiler emits as flat code
with **no per-bind closure**, threading a small bundle so the residual copies are cheap.
**M3 already proved this exact pattern byte-identical** (`Store.LoadCtx` for `loadType`); M6
is its generalization — the single largest remaining lever.

**Plan (incremental, each byte-identity-gated like M1-M3):**
- M6.0 — finish M3: bundle-thread `Store.zonkToMono` and `monoTypeToVar` (extend `LoadCtx`
  to carry `nextMVarId`; zonk's `residualId`/`allocFreshMVarId` need it). Small, clean.
- M6.1 — define `ItemCtx = { store, memo, revMemo, next, varEnv, numberMulti, localMulti,
  derivedDestructors, localCanTypes }` (the fields `resetItem` clears) + a `withItem` wrapper
  that reads them from `S` once and writes back once. Read-only globals (`superStatic`,
  `superTable`, `annotations`, `toptNodes`, `globalTypeEnv`, caches) pass as args.
- M6.2 — rewrite the hot **Translate** inner functions in direct style over `ItemCtx`:
  `translate`, `translateGlobalCallSlow`, `translateKernelCall`, `unifyParamsCollect`,
  `argUnifyVar`, `enrichFromEnv`, `translateArgsWith`, the case/destruct/let arms. Each
  `Engine.andThen (\x -> k) m` becomes a direct `let`/`case` threading `ItemCtx`. Public
  entry points keep the `Step` signature via `withItem`.
- M6.3 — the global accumulators (worklist, nodes, registry, lambdaCounter, caches, ports)
  that genuinely span items can stay in `S` (updated far less often than the per-item ops).

**Risk.** Large but MECHANICAL rewrite; the transformation is local and each step is
byte-identity-checkable against the pre-M1 baseline (6 fixed inputs + corpus 466 MATCH), so
regressions surface immediately. Do it function-by-function, gating after each cluster.

**More radical alternative (noted, not first choice):** push the per-item state
(memo/revMemo/varEnv) INTO `IO.State` as additional Array-emulated "refs" so the inner ops
thread only the store via the existing `IO` monad, shrinking `S` to the global accumulators.
Bigger rearchitecture; revisit only if M6.1-6.3 leave a monad-shaped residual.

**Non-goals** (still out of scope, see §9): registry string-key rework (T6),
UF array packing (T7), junk-spec elimination.

---

## M7 (NEW, low-risk, complements M6) — Nest `S` by update frequency

**Rationale.** `_Utils_update` copies EVERY top-level key of the record on every update
(`for (k in old) new[k]=old[k]`), so a 23-field `S` copies 23 refs per `modifyS`/`liftIO`
even to change one field. An update-site survey of MonoSolver shows **5 fields are never
updated** — `toptNodes`, `annotations`, `globalTypeEnv`, `currentModule`, `superStatic` —
yet they are copied on every update. Nesting shrinks the top-level key count so each update
copies fewer refs.

**CAUTION — nest by CO-UPDATE, or it backfires.** `{ s | g = { s.g | f = x } }` copies the
outer keys PLUS the inner group's keys; grouping independently-updated fields makes updates
copy MORE. Rule: keep FREQUENTLY-updated fields top-level; sink RARELY-/NEVER-updated fields
into sub-records grouped by what moves together.

**Grouping (from the survey):**
- `env` — the 5 IMMUTABLE fields (`toptNodes, annotations, globalTypeEnv, currentModule,
  superStatic`). PREFERRED: **move them OUT of `S` entirely** into a separate `Env` record
  that is *threaded through but never updated* (a Reader context passed as a parameter),
  rather than nested inside `S`. Moving-out shrinks `S` to **18 fields** and passes `Env` by
  reference (0 refs copied per update); nesting would leave one `env` ref in `S` copied on
  every update (19 fields). The codebase ALREADY does exactly this for `superStatic` — M3's
  `loadTypeC`/`loadVarC` take it as an arg, not from `S` — so the pattern is proven; this
  generalizes it to all 5. Composes with M6: the direct-style `ItemCtx` functions take `Env`
  as an extra parameter (no monad needed — it never changes). **Zero-risk standalone win; do
  this first, independent of everything else.** (Mechanics: either add an `Env ->` parameter
  to the hot functions, or make `Step a = Env -> S -> Result Failure (a, S)` — a Reader+State
  monad where `Env` is threaded but never rebuilt.)
- `caches` (`schemeMono, kernelAbiMono, callMemo` — written only on a miss): one ref; the
  frequent cache-HIT path stops copying 3 refs.
- `item` (`store, memo, revMemo, varEnv, numberMulti, localMulti, derivedDestructors,
  localCanTypes`): **this is exactly M6's `ItemCtx` bundle** — nesting and M6 converge here.
  `resetItem` becomes a one-ref reset; M6 threads this sub-record directly.
- Keep top-level (hot): `worklist, scheduled, inProgress, registry, nodes, ports,
  lambdaCounter, nextMVarId, currentGlobal, superTable`.

Net: ~23 → ~10 top-level fields, so a hot `enqueueSpec`/writeback copies ~10 keys not 23
(~2×). Byte-identical (pure data-layout change). Sequence: M7 `env` group first (trivial,
zero-risk), then fold the `item` group into M6, then `caches`.

---

## 0. Ground rules

### 0.1 One milestone = one commit
Each milestone below is independently revertable and lands only when its gate battery
passes. Do not interleave milestones in one commit.

### 0.2 Gate battery (run after EVERY milestone)

```bash
# A. Fast compile check (~1-2 min incremental; catches Elm type errors):
cmake --build build --target eco-boot

# B. Byte gate on a single test (fast dev loop; guida.js is built from compiler/src
#    by target `guida`, so it contains your change after that target is rebuilt):
cmake --build build --target guida
cd test/elm && GUIDA_JS_PATH=/work/build/compiler/build-xhr/bin/guida.js \
  ECO_MONO_ENGINE=diff node /work/compiler/bin/index.js make src/<Test>.elm --output=/tmp/x.mlir
# diff mode errors loudly with "ECO_MONO_DIFF ..." on graph mismatch or junk regression;
# a successful compile means the two engines' graphs matched for this program.

# C. Full E2E suite under the solver (must stay green; run SERIALLY, never
#    concurrently with other suites — ~/.eco corruption gotcha):
find build/test -path '*eco-stuff/mlir/*.mlir' -delete   # mtime cache doesn't key on engine
ECO_MONO_ENGINE=solver cmake --build build --target full 2>&1 | tee /tmp/test_output.txt

# D. Corpus byte sweep (per-milestone byte-identity expectations are stated in each
#    milestone; regenerate the sweep as in the parity work): compile every
#    test/elm/src/*.elm with ECO_MONO_ENGINE=diff via GUIDA_JS_PATH as in (B), count
#    MATCH / MISMATCH / declines. Baseline BEFORE M1: record the current counts.

# E. Solver bootstrap (JS 4b + native 8c fixed points):
ECO_MONO_ENGINE=solver cmake --build build --target bootstrap

# F. Perf measurement (after M2, M3 and final only — it is the expensive one):
#    frontendstats.txt Stage-7a A/B (cold eco-stuff protocol, warmup + 1 run each), plus
#    the JS profile recipe from monosolver-performance.md §7; record the
#    GC/_Utils_update/(anonymous) buckets — each milestone predicts which bucket moves.
```

### 0.3 Repo gotchas that WILL bite you
- `compiler/src` is compiled with `--optimize` by eco-boot: **`Debug.toString`/`Debug.log`
  are forbidden** in engine code (build fails at stage 3, not at `guida`).
- After any cmake build, **verify the artifact timestamp** (`ls -la
  build/compiler/build-xhr/bin/guida.js`) before trusting a probe — stale-binary probes
  have burned hours twice before.
- An insert between a docstring and its declaration silently breaks the build.
- New `.elm` files under `compiler/src` need `cmake --preset build` (non-CONFIGURE_DEPENDS
  glob). This plan adds no new files — all edits are to existing modules.

### 0.4 Byte-identity discipline
M1, M2a, M2b are designed to be **byte-identical** on the corpus (stronger than the
runtime bar — use gate D to prove it; any new MISMATCH vs the pre-milestone baseline is
a bug in the milestone). M2c and M4b may shift residual MVar ids (runtime-benign,
ids are excluded from spec keys per MONO_003); for those two the acceptance is
"no new runtime failures, byte-drift only in MVar ids / spec-id order".

---

## M1 — `classifyDirect`: read-only classification (biggest win)

### Goal
Replace `Translate.classify = Store.zonkToMono ∘ Store.loadType` (42 call sites; runs
for every Int/Float literal, `VarLocal` fallback, var-ref, case/let/access typing) with
a **read-only** walk that performs zero store writes, zero Point minting, zero `S`
copies. Predicted effect: large cut to all three delta buckets.

### Why it is semantics-preserving (the argument, up front)
`classify`'s only *reads* that matter are: (a) the memo binding for each `TVar` (to see
demand concretization), (b) the store content reachable from a memo-bound Point, (c)
`superStatic`/`superTable` for residual stamping. Its *writes* (fresh Points for every
structural node, memo entries for unseen vars) are consumed only by the zonk that
immediately follows — except the memo entry, which a LATER load could hit. But a later
`loadType` that misses the memo mints a Point with **identical content** (fresh
`FlexVar`/`FlexSuper` from `superStatic`) — so deferring the mint to the first *actual*
store use (a unification site) changes nothing observable. Residual ids also match:
`loadVar` always mints a var's Point with its own `mvarId` recorded in `revMemo`, so
`residualId` of a memo-miss var == that var's own id — exactly what `classifyDirect`
stamps directly. Memo-HIT vars zonk the same Point either way. Hence: byte-identical.

### Implementation

**File: `compiler/src/Compiler/MonoSolver/Store.elm`** — add (and export) `classifyDirect`:

```elm
{-| Read-only classification of a canonical type: structure is classified purely
(mirroring zonkFlat/classifyApp); a TVar consults the alias substitution, then the item
memo (zonking the bound Point — full fidelity for demand-concretized vars), then stamps
a residual from the super tables. Never writes to the store. Replaces
`zonkToMono ∘ loadType` at classification-only sites (Translate.classify).
-}
classifyDirect : Can.Type TypeIds.MVarId -> Step Mono.MonoType
classifyDirect canType =
    \s ->
        classifyGo s Dict.empty canType
            |> Result.map (\mono -> ( mono, s ))   -- read-only: S returned untouched


classifyGo : S -> Dict Int Mono.MonoType -> Can.Type TypeIds.MVarId -> Result Failure Mono.MonoType
```

`classifyGo` arms (each mirrors an existing implementation — copy the logic, do not
re-derive it):

| Can.Type arm | behavior | mirrors |
|---|---|---|
| `TVar v` | 1. `aliasSubst` hit → that MonoType. 2. `Dict.get (mvarIdKey v) s.memo` hit → `zonkPointReadOnly s pt` (below). 3. miss → residual: `superTable` says `Number` → `MVar v CNumber` else `superStatic`… — copy the EXACT rule from `residualWithTaint`+`Zonk.canTypeToMonoWith` (taint consulted from `s.superTable`, static from the same table; a var never in the memo is unbound by construction) | `Store.residualWithTaint`, `Zonk.canTypeToMonoWith` TVar arm |
| `TLambda` | build `MFunction [a] b` chains | `Zonk.lambdaChain` |
| `TType home name args` | recurse args, then `classifyApp home name` (already in Store.elm — reuse it, do NOT duplicate the elm/core prim table) | `Store.classifyApp` |
| `TRecord fields ext` | ext: `Nothing` → base `Dict.empty`; `Just extVar` → resolve extVar by the TVar rule; result `MRecord` → its fields are the base; anything else → base `Dict.empty` (matches `zonkRecordExt`). Then fold `fields` over the base | `Store.zonkFlat` Record1 arm + `zonkRecordExt` |
| `TTuple` / `TUnit` | direct | `Zonk` |
| `TAlias _ _ _ (Filled inner)` | recurse inner | both |
| `TAlias _ _ args (Holey inner)` | classify each arg, extend `aliasSubst` keyed by `mvarIdKey paramId`, recurse inner | `Zonk.canTypeToMonoWith` Holey arm |

`zonkPointReadOnly`: the existing `zonkToMono` is *already* read-only in effect except
that (i) it threads the store through `liftIO (UF.get …)` (repr writes path-compression
links — those ARE store writes, but purely internal/idempotent) and (ii)
`residualId` can call `allocFreshMVarId` (mutates `nextMVarId`). Do NOT rebuild it:
for memo-hit vars simply call the existing `zonkToMono pt` as a `Step` (its S-threading
cost is paid only for the demand-concretized minority). Concretely `classifyGo`
delegates memo-hit vars back into the Step world:

```elm
-- inside Translate.classify:
classify canType =
    Store.classifyDirect canType   -- new
```

with `classifyDirect` implemented as a Step that walks structure purely and calls
`zonkToMono` only on memo-hit `TVar`s / record-ext vars. (Implementation detail: write
it as a normal `Step` using `Engine.getS`/`Engine.andThen` at the var arms ONLY —
ground subtrees must not allocate Step closures per node; recurse with a plain inner
function that takes `s` read-only and returns `Result Failure Mono.MonoType`, calling
into Step-land only when it encounters a memo-hit var. The pattern:

```elm
classifyDirect canType s0 =
    case pureGo s0 Dict.empty canType of
        PureDone mono        -> Ok ( mono, s0 )          -- fully ground: zero cost
        NeedsStore           -> classifyStepwise canType s0   -- rare: fall back
```

Simplest correct first cut: `pureGo` returns `Maybe MonoType`, `Nothing` when ANY var
in the type is memo-bound; on `Nothing` fall back to the OLD `zonk∘load` path. That is
already the majority win (ground types dominate) and is trivially byte-identical.
Refine to the mixed walker only if profiles still show classify traffic.)

**Start with the simple cut**: `pureGo : S -> Dict Int Mono.MonoType -> Can.Type -> Maybe Mono.MonoType`
returning `Nothing` if any encountered `TVar`/record-ext var is in `s.memo`
(alias-subst hits do NOT count as memo hits). Memo-miss vars classify to residuals
per the table above. Fall back to `zonk∘load` on `Nothing`.

### Call sites
Only `Translate.classify` changes (all 42 uses flow through it). Also change
`callResultType`'s `classify callCanType` fallback — it goes through the same
`classify`, nothing extra to do.

### Edge cases to test explicitly (add to the byte sweep scrutiny)
- Record narrowing tests (`RecordNarrow*` family) — record-ext var bound in memo.
- Number-multi family (`LetNumber*`) — vars concretized mid-item must classify to the
  concretized type (memo-hit path).
- Holey alias with a var argument (aliasSubst + memo interplay).
- `TOpt.Int` literal typed by an unbound number var → `MVar v CNumber` (miss path).

### Gate
Battery A-E. Gate D must show **zero new MISMATCHes** vs baseline. Record the JS
profile (gate F) — expect `_Utils_update` and GC buckets to drop substantially.

### Rollback
`classify = Engine.andThen Store.zonkToMono (Store.loadType canType)` — one line.

---

## M2 — Ground fast paths + scheme/ABI caches

Precondition helper, **file `Store.elm` or `Translate.elm`**:

```elm
{-| True when the type contains no TVar anywhere (record exts and Holey alias args
included). Pure, allocation-free, early-exit. -}
groundCanType : Can.Type TypeIds.MVarId -> Bool
```
(Walk with a `List` worklist to stay stack-safe on deep types; `TAlias … (Holey inner)`
must check both `args` types and `inner`; `TRecord _ (Just _)` is `False` immediately.)

And the multi-stack guard used by M2a/M2b (the side-effecting instance-recording paths
must never be skipped):

```elm
noMultiInFlight : S -> Bool
noMultiInFlight s = List.isEmpty s.localMulti && List.isEmpty s.numberMulti
```

### M2a — Closed-scheme fast path for global calls and refs

**Where**: `Translate.translateGlobalCall` and `Translate.translateVarRef`.

**Closed-scheme detection**: `translateCall` already fetches
`lookupAnnotation global → Maybe (Can.Forall freeVars annType)`. A scheme is closed
when `Dict.isEmpty freeVars`. During bring-up, cross-check with
`KernelAbi.freeVarIds annType [] == []` behind the diff gate; if they ever disagree,
trust `freeVarIds` (the ids are ground truth post-AssignMVarIds) and file the
discrepancy. When there is no annotation (fallback to `funcMeta.tipe`), use
`groundCanType` on it.

**Cache**: add to `S` (Engine.elm):
```elm
, schemeMono : CoreDict.Dict String Mono.MonoType
  -- closed-scheme classification cache, keyed by TOpt.toComparableGlobal;
  -- GLOBAL (survives resetItem — a closed scheme classifies identically in every item)
```
(Do NOT reset it in `resetItem`. Update `initState` and `freshStore` untouched.)

**New call path** in `translateGlobalCall`, taken when the scheme is closed:

```
funcMonoType  = schemeMono cache hit, else Zonk.canTypeToMono s.superStatic annType
                (insert into cache)                                   -- pure, no store
for each (paramMono, arg) in zip (mFunctionParams funcMonoType) args:
    if groundCanType (TOpt.typeOf arg) then SKIP                      -- nothing to bind
    else Translate.demandUnify (TOpt.typeOf arg) paramMono            -- drives demand
         -- plus the enrichFromEnv varEnv unification IF the arg is a local ref with a
         -- varEnv binding and its canType is non-ground (copy the condition from
         -- argUnifyVar/enrichFromEnv; for ground canTypes enrich is a no-op — skip)
resultMono    = peelResult argCount funcMonoType                       -- ground
if not (groundCanType callCanType) then demandUnify callCanType resultMono
                                                   -- replaces unifyResultWithExpected:
                                                   -- binds the ITEM's vars to the result
monoArgs      = Engine.traverse translate args                         -- unchanged
specId        = enqueueSpec … funcMonoType                             -- unchanged
```

Guards to take the fast path: closed scheme ∧ `noMultiInFlight s` ∧ argCount ≤ arrow
count of `funcMonoType` (over-application falls back — the old path's `Fun1` peeling
handles it). Everything else falls through to the existing code **unchanged**.

`mFunctionParams`: peel `MFunction [p] rest` one arrow at a time (same shape
`peelResult` walks) — write one helper next to `peelResult`.

**`translateVarRef` fast path**: closed scheme → `MonoVarGlobal` with the cached
MonoType + `enqueueSpec`; skip `classify` entirely (after M1 classify is already cheap;
this still saves the zonk of memo-hit-free types and is 5 lines).

**Why byte-identical**: for ground args, the old path unified two identical ground
structures — no var can bind, outcomes identical. For non-ground args,
`demandUnify argCan paramMono` encodes the SAME param structure `monoTypeToVar` builds
from the scheme classification that `instantiate` would have loaded — same content,
same unify effect on the arg's vars. The result-side binding is preserved by the
explicit `demandUnify callCanType resultMono`. Residual ids: unaffected (ground types
have none; non-ground sides still go through the store exactly as before).

### M2b — Ground call-site memo for OPEN (polymorphic) schemes

**Where**: `translateGlobalCall`, taken when the scheme is open but
`noMultiInFlight s` ∧ every arg canType is ground ∧ `callCanType` is ground.

**Key**: `TOpt.toComparableGlobal global ++ "|" ++ String.join "," (List.map
Mono.toComparableMonoType groundArgMonos) ++ "->" ++ Mono.toComparableMonoType expectedMono`
where `groundArgMonos = List.map (Zonk.canTypeToMono s.superStatic << TOpt.typeOf) args`
and `expectedMono = Zonk.canTypeToMono s.superStatic callCanType` (all pure — ground).

**Cache**: `S.callMemo : CoreDict.Dict String ( Mono.MonoType, Mono.MonoType )`
(funcMonoType, resultMonoType), GLOBAL (not reset per item — see safety argument).

- Hit → skip instantiate/unify entirely; `translateArgsWith` reduces to
  `Engine.traverse translate args` (the stash is only for local-multi args, excluded by
  the guard); enqueue with the cached funcMonoType.
- Miss → run the EXISTING path, then insert
  `( zonked funcMonoType, resultMonoType )` into the cache before returning.

**Safety argument** (why a global cache is sound): with all inputs ground, the
instantiate+unify sequence touches only freshly-minted Points (ground types never call
`loadVar`, so the item memo is never read or written); `superStatic` is immutable; the
outcome is a pure function of (scheme, argMonos, expectedMono). The only side effect
besides the result is Point allocation — unobservable. Taint (`superTable`) is only
consulted for residuals, and ground inputs produce none.

**Instrumentation for sizing (temporary, keep out of the commit)**: count hits/misses
by threading two Ints in S while bringing the milestone up; verify on the compiler
self-compile that the hit rate is meaningful (expect ≫50% of open-scheme sites — Dict/
List/Maybe helpers at repeated element types). If it is <20%, stop: M2b is not paying
and should be dropped rather than carried as complexity.

### M2c — Kernel ABI cache

**Where**: `deriveKernelAbiTypeCall` / `deriveKernelAbiTypeRef` (Translate.elm).

Same ground trick: when every arg canType is ground, the derived ABI is a function of
`(kernelId, argMonos)`. Cache `S.kernelAbiMemo : CoreDict.Dict String Mono.MonoType`,
key `home ++ "." ++ name ++ "|" ++ joined arg keys`.

**Carve-out**: the preserveVars branch calls `remapEcoVarsFresh`, which consumes fresh
MVarIds — replaying from cache skips that consumption and shifts later fresh ids.
Those ids only appear in CEcoValue residuals (excluded from spec keys, MONO_003), so
this is runtime-benign byte-drift. Acceptance for M2c is therefore the WEAKER gate
(§0.4). If the byte sweep shows drift confined to MVar ids, accept; if spec-id ORDER
shifts (registry keys changed), a cached funcMonoType differs from the uncached one —
that is a bug, fix before landing.

### Gate
Battery A-E after each of M2a/M2b/M2c separately (separate commits). Byte expectations:
M2a/M2b identical; M2c per §0.4. Run gate F after M2 as a whole; expect the GC bucket
to drop again and `Store.loadType` self-time to shrink in the profile.

---

## M3 — One S-copy per store operation (bundle threading)

### Goal
`Store.loadType` / `zonkToMono` / `monoTypeToVar` / `instantiate` currently execute
~2 twenty-three-field S copies per TYPE NODE (freshVar's `liftIO` + `recordVar`'s
`modifyS`). Thread a small transient bundle instead; write back once per public call.
This attacks whatever `_Utils_update`/GC delta remains after M1/M2 (calls with
non-ground args still load structure).

### Implementation

**File `Engine.elm`** — add:

```elm
type alias StoreCtx =
    { store : IO.State
    , memo : Dict Int IO.Variable
    , revMemo : Dict Int TypeIds.MVarId
    , nextMVarId : TypeIds.MVarId     -- zonk's residualId can allocate
    }

{-| Run a store-threading computation with a single S read + write. -}
withStore : (StoreCtx -> Result Failure ( a, StoreCtx )) -> Step a
withStore f =
    \s ->
        case f { store = s.store, memo = s.memo, revMemo = s.revMemo, nextMVarId = s.nextMVarId } of
            Err e -> Err e
            Ok ( a, c ) ->
                Ok ( a, { s | store = c.store, memo = c.memo, revMemo = c.revMemo, nextMVarId = c.nextMVarId } )
```

**File `Store.elm`** — rewrite the INTERNALS of `loadType`, `monoTypeToVar`,
`zonkToMono` as plain `StoreCtx -> Result Failure ( x, StoreCtx )` recursions
(`loadTypeC`, `monoTypeToVarC`, `zonkToMonoC`); keep the existing public `Step`
signatures as one-line `withStore` wrappers so no call site outside Store.elm changes:

```elm
loadType canType = Engine.withStore (loadTypeC canType)
```

Mechanical notes:
- `freshVar` becomes `freshVarC : IO.Content -> StoreCtx -> ( IO.Variable, StoreCtx )`
  (UF.fresh cannot fail) — inline the `UF.fresh` call against `c.store`.
- `recordVar` becomes a pure `StoreCtx -> StoreCtx`.
- `loadVar` reads `superStatic`/`superTable` — those are NOT in the bundle (read-only
  globals): pass them once as extra arguments to the `*C` functions
  (`loadTypeC : Dict Int IO.SuperType -> … `) captured at the `withStore` wrapper from
  `s` — they are stable for the whole computation.
- `withMemoBindings` (alias params) operates on `c.memo` inside the `*C` world.
- `unifyStep` stays as-is (one `liftIO` per unify is already one S copy).
- `Engine.freshVar` (used by Translate for demand vars) keeps its Step form,
  reimplemented via `withStore`.

**Do not** change `S`'s shape — `resetItem`, harvest, Diff, Monomorphize all keep
working untouched. The bundle is transient.

### Why safe
Pure refactor: the same field reads/writes in the same order, batched. No semantic
surface. The gate is byte-identity (D) plus the suite.

### Gate
Battery A-E; gate F expected: `_Utils_update` bucket drops toward the subst level;
`(anonymous)` closure bucket shrinks (fewer `Engine.andThen` in the store layer).

---

## M4 — Data-structure swaps

### M4a — `revMemo`: Dict → Array (dense, zero-rooted per item)

Point indexes mint sequentially from 0 per item (`freshStore` starts empty arrays).
Change `StoreCtx.revMemo`/`S.revMemo` to `Array (Maybe TypeIds.MVarId)` where index =
point index.

**Alignment invariant**: every fresh Point must push exactly one entry. Implement by
recording at the MINT, not after: `freshVarC` takes the tag —
`freshVarC : Maybe TypeIds.MVarId -> IO.Content -> StoreCtx -> ( IO.Variable, StoreCtx )`
pushing `Nothing` for structure/demand mints and `Just mvarId` for `loadVar` mints
(replacing `recordVar`'s revMemo half; the memo half stays a Dict insert). Add a
debug-time assertion (comment, not code) that `Array.length revMemo == point count`.
NOTE: `Unify.unify` mints Points internally (`Unify.fresh` via the store) WITHOUT
going through `freshVarC` — so after a unify, the array may be SHORTER than the point
count. `residualId` must therefore treat out-of-bounds as `Nothing` (fresh engine id —
exactly what those internal points get today, since they were never in the Dict either).
Harvest iterates `Array.toIndexedList` filtered to `Just` — same UF.get per entry as now.

- `residualId`: `Array.get (pointKey var) rev |> Maybe.andThen identity`.
- `resetItem`: `Array.empty`.
- `harvestSuperTableExcept`: fold the array with index.

### M4b — `superStatic`: Dict → Array; `superTable` → static + taint split

`superStatic` is immutable after `initState` and MVarIds are sequential ints
(`Id.toComparable`, dense from 0). Replace BOTH super tables:

```elm
, superStaticArr : Array (Maybe IO.SuperType)   -- built once in initState
, superTaint : Dict Int ()                       -- harvested Number taints ONLY
```

- Build in `initState`: `Array.repeat (Id.toComparable mvarState.nextId) Nothing`
  then `Dict.foldl (\k v arr -> Array.set k (Just v) arr) …  mvarState.superVars`.
- `loadVar` mint content: `Array.get key arr` (out-of-bounds → Nothing — engine-fresh
  ids past nextId are plain flex vars, as today).
- `residualWithTaint` / classifyDirect residual rule:
  `Number` iff `Array.get key arr == Just (Just IO.Number) || Dict.member key taint`.
- `harvestSuperTableExcept` inserts into `superTaint` only (it only ever writes
  `IO.Number` — see its two arms).
- **Final Prune handoff**: find where the engine passes the merged super table to the
  shared `Prune.pruneUnreachableSpecs` (in `Monomorphize.elm`, assembly path — grep
  `superTable` there). Reconstruct the merged Dict at that single point:
  `Dict.foldl (\k _ acc -> Dict.insert k IO.Number acc) mvarState.superVars s.superTaint`
  — keep `mvarState.superVars` reachable for this by storing it (or the merged base)
  in S as `superStaticDict` alongside the array, OR rebuild from the array (one fold,
  once per compile — either is fine; storing the original Dict is simpler).
- Keep `Zonk.canTypeToMono` callers working: its `superVars : Dict Int SuperType`
  parameter should now be fed the STATIC dict (`superStaticDict`). Audit all callers
  (`grep -n "canTypeToMono" compiler/src/Compiler/MonoSolver/`) — M2 added several.

Byte expectations: M4a identical; M4b identical (same lookups, same answers).

### Gate
Battery A-E; profile shows `core.Dict`/`_Utils_cmp` slivers shrink — this milestone is
mostly memory-pressure hygiene; do not expect a large wall-clock move on its own.

---

## M5 — Harvest skip-flag + small wins

1. Add `S.itemSawNumber : Bool` (reset False in `resetItem`). Set True at every site
   that can put `FlexSuper IO.Number`/`RigidSuper IO.Number` CONTENT into the store:
   - `loadVar` mint when the static table yields `Just IO.Number`;
   - `Store.monoTypeToVar`'s `MVar _ CNumber` arm;
   - (audit: `grep -n "FlexSuper" compiler/src/Compiler/MonoSolver/*.elm` — any other
     construction site added later must set it too; leave a comment at the flag.)
   `Unify` merges preserve existing supers and never invent `Number`, so if no mint
   happened, no Point can resolve to Number and harvest is a no-op.
2. In `processItem`: skip `harvestSuperTableExcept` AND `nodeAnnotationIds` (the
   EverySet build) when `itemSawNumber == False`.
3. Byte-identical by the argument in (1); the diff gate confirms.

---

## M6 — Final measurement + bookkeeping

1. Re-run the full frontendstats Stage-7a A/B (warmup + 2 samples each engine).
2. Re-run the JS `--cpu-prof` A/B; capture the bucket table.
3. Append a run-log entry to `benchmarks/frontendstats.txt` (house format: description,
   raw samples, verdict) recording the solver-vs-subst gap before/after.
4. Update `plans/monosolver-performance.md` §1 with the new numbers and this plan's
   Status header with per-milestone results (measured, not estimated).
5. Full default-engine suite + solver bootstrap one last time.

---

## 7. Predicted effect per milestone (check against gate F)

| Milestone | Mechanism | Bucket it must move | Rough expectation* |
|---|---|---|---|
| M1 | no store round-trip at 42 classify sites | GC + `_Utils_update` | -40…-70 s of the 141.6 s native gap |
| M2a/b/c | no instantiate/unify at ground call sites | GC + `(anonymous)` | -20…-40 s |
| M3 | 1 S-copy per op instead of 2/type-node | `_Utils_update` + GC | -15…-30 s of what remains |
| M4 | O(1) dense lookups, fewer Dict allocs | Dict slivers, GC | -3…-8 s |
| M5 | skip per-item harvest fold | small | -1…-3 s |

*Native-seconds on the Stage-7a self-compile; wide ranges are honest — re-estimate
after each gate-F run and STOP when the marginal milestone stops paying (M4/M5 are
cheap enough to do regardless; M2b has an explicit kill criterion).

## 8. Risks and rollback

- Every milestone is one commit; revert = `git revert` of that commit. No milestone
  changes on-disk formats, config, or the subst engine.
- The solver is not the production default (`mono.engine` defaults to subst), so a
  regression that escapes the gates cannot affect default builds.
- Watch-item: the byte sweep count is the earliest drift detector — record it before M1
  and after every milestone in this plan's Status header.
- If gate E (bootstrap) fails at any milestone with a GC signature, suspect a
  fast-path skipping a unification that a number-multi/varEnv corner needed — the
  guards in M2 (`noMultiInFlight`, non-ground → demandUnify) are the load-bearing
  parts; re-read them before debugging elsewhere.

## 9. Deferred (do not do in this plan)

- Registry `toComparableSpecKey` string keys / `_Utils_cmp` (~9 s in BOTH engines) —
  shared-cost, separate plan; benefits subst too.
- UF three-array packing (`ioRefsWeight`/`PointInfo`/`Descriptor` → one record array) —
  shared with the live typechecker; only if post-M4 profiles still rank store ops.
- Full Step-monad defunctionalization of Translate — M3 captures most of the win.
- Junk-spec enqueue elimination (separate tidy-up, already tracked in the drop-in plan).

---

## A5 — Remove `IO` trampolines (loop/Step → direct tail-recursion) — THE FIRST REAL WIN (2026-07-10)

**Insight (user).** `System.TypeCheck.IO.loop` is already TCO'd to a while-loop (stack-safe), but the
loop-based iterators (`foldM`/`foldrM`/`traverseList`/`mapM_`/`traverseMapWithKey`) allocate ~4 EXTRA objects
PER ELEMENT that direct tail-recursion avoids: the `Step` ctor (`Loop`/`Done`), the loop-state tuple, and the
`map (\b -> Loop …)` closure — all ON TOP of the irreducible callback IO tuple + result cons. Unlike A1–A4
(which couldn't remove the irreducible per-bind tuple), THESE extras are removable while STAYING stack-safe
(the direct `go` is self-tail-recursive → while-loop).

**DONE + gated byte-identical (6/6 fixed inputs + corpus 466/51/0 + whole-compiler MLIR md5 identical):**
rewrote all 5 IO iterators to direct tail-recursive `*Go` helpers (no per-element Step/loop-tuple/closure;
same order + state threading; `mapM_`'s reversed-eval quirk preserved).

**MEASURED — RELIABLE NATIVE WIN (the CPU/dev-JS profiler is useless here: GC is 100% detached under (root),
and same-code dev-JS runs vary 110–175s from machine load).** Interleaved native Stage-7a subst A/B (cold
eco-stuff, alternating before/after to cancel drift): before (trampolines) 268.97/271.76/271.65 → **avg
270.8s**; after (iterators direct) 267.47/262.18/266.57 → **avg 265.4s** = **−5.4s / −2.0%, with clean
separation (every after-run < every before-run)**. MLIR byte-identical (md5 f31c3c3…). This is the FIRST
optimization all session to move absolute native time beyond noise — the trampoline extras are a genuine,
removable cost, unlike the per-bind tuple A1–A4 chased.

**REMAINING (bigger): 8 `IO.loop` spine sites, all in the typechecker** — `Solve.solveHelp` (constraint
solver, per-constraint, a CPS tree-walk with a `cont` continuation — hardest but hottest), and the linear
spine loops `constrainDeclsWithVars` (Module) + `consSpineStep` (Pattern) + let/binop/call/if/access spines
(Expression). Each is convertible to a direct tail-recursive `go` (the `Loop` cases become tail calls,
dropping the Step ctor + nested loop-state tuple/closure per element; stack safety preserved by the tail
call). Converting these should compound the win. IN PROGRESS.

**UPDATE — solveHelp CONVERTED (the constraint solver) + gated byte-identical.** Rewrote `Solve.solve` /
`solveHelp` → direct self-tail-recursive `solveGo` (250-line rewrite of the type inferencer's hottest loop):
`Loop` transitions became self-tail-calls of `solveGo` (state threaded via explicit `let`-bindings → TCO'd,
stack-safe), `Done` cases apply `cont` directly — dropping the `Step` ctor + the nested loop-state 3-tuple
that were rebuilt PER CONSTRAINT. Also `constrainDeclsWithVars` (Module spine) → direct. GATED: 6/6 fixed
inputs identical + FULL corpus 466 MATCH / 51 MISMATCH / 0 ERR (mismatch set identical to baseline) — the
constraint solver typechecks all 517 programs byte-identically. Native A/B of the combined
iterators+solveGo+constrainDecls pending. STILL REMAINING (smaller): 6 expression/pattern spine loops
(let/binop/call/if/access/cons) — same mechanical conversion.

**FINAL MEASURED — A5 combined (iterators + solveGo + constrainDecls) = −6.5s / −2.4% native, byte-identical.**
Interleaved native Stage-7a subst A/B (cold, alternating, same machine): before (all trampolines) 274.5/274.6/
274.8 → avg **274.6s** (±0.3s); after 269.4/267.1/267.9 → avg **268.1s** = **−6.5s / −2.4%**, clean separation
(every after-run < every before-run), MLIR byte-identical. Breakdown: iterators alone were −5.4s (measured
separately); solveGo+constrainDecls add ~1s more (the iterators already covered the foldM/forM_ INSIDE the
solver's CAnd/CLet, so the outer-loop Step/tuple removal is the smaller remainder). This is THE reliable
front-end win of the whole effort — the trampolines' per-element Step/loop-tuple/closure allocations were a
genuine, removable cost, unlike the irreducible per-bind tuple A1–A4 chased. REMAINING (optional, smaller):
6 expression/pattern spine loops (let/binop/call/if/access/cons) — same mechanical `IO.loop → direct go`
conversion, but per-chain-element over usually-short chains so marginal.

**A5 COMPLETE — `type Step`/`loop` REMOVED ENTIRELY (2026-07-10).** All 8 `IO.loop` sites converted to direct
self-tail-recursion: solver `solveGo` + `constrainDeclsWithVars` + the 6 expression/pattern spines
(let/binop/cons/access = clean self-recursion; call/if = "two-phase" so the width-bounded arg/branch walk now
returns a local `CallArgsOutcome`/`IfBranchesOutcome` the spine `go` inspects and self-tail-calls on — no
trampoline, no mutual tail-recursion, stack-safe). With no `IO.loop` callers left, `type Step state a =
Loop state | Done a` and `loop` were DELETED from `System.TypeCheck.IO`. GATED byte-identical: 6/6 fixed +
corpus 466/51/0 (mismatch set identical) — the entire constraint generator + solver typecheck all 517
programs byte-for-byte. Final native A/B (full removal) pending below.

**FINAL — full trampoline removal (all 8 `IO.loop` + 5 iterators + `Step` deleted) = −6.6s / −2.4% native,
byte-identical.** Interleaved native Stage-7a subst A/B (cold, alternating): before 269.4/269.4/267.7 → avg
**268.9s**; after3 263.9/261.7/261.3 → avg **262.3s** = **−6.6s / −2.4%**, clean separation, MLIR byte-identical.
The 6 spine loops added only ~0.1s over the iterators+solveGo (−6.5s) — the spines iterate per-chain-element
over usually-short chains, so their perf contribution is negligible; they were converted to enable the
COMPLETE removal of `type Step`/`loop`, which is the structural payoff. SUMMARY OF THE WHOLE EFFORT: A1–A4
(de-monadify / Dict→Array / point-free / IO.State) were all FLAT (the irreducible per-bind tuple); the ONE
real front-end lever was removing the `IO` trampolines' EXTRA per-element allocations (Step ctor + loop-state
tuple + map closure), directly tail-recursible while staying stack-safe — **−6.6s / −2.4%, byte-identical,
and `Step` is gone entirely.** Measurement lesson: CPU/dev-JS profiling was useless (GC detached under root;
±30-60s machine-load noise); only interleaved native A/B gave a trustworthy signal.
