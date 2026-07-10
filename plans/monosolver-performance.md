# MonoSolver performance analysis — where the 1.54× goes, and how to get it back

Date: 2026-07-09. Author: investigation following the solver-bootstrap GC-bitmap fix.
Status: ANALYSIS (no optimization implemented yet).

## 1. Headline measurements

Stage-7a methodology from `benchmarks/frontendstats.txt` (cold `eco-stuff`, warm `~/.eco`,
`build` preset, same binary, engine switched via `ECO_MONO_ENGINE`):

| Run                        | subst      | solver     | ratio  |
|----------------------------|------------|------------|--------|
| Native `eco-compiler` wall | 262.5 s    | 404.1 s    | 1.54×  |
| Dev-mode JS (`eco-boot.js`) wall | 141.6 s | 373.2 s  | 2.64×  |
| Peak RSS (native)          | 4.27 GiB   | 4.29 GiB   | ~1.0×  |

The engine is the only variable, so the **entire +141.6 s native delta is the
monomorphization phase**. The subst mono phase itself is small, so the solver mono phase
costs roughly 5-10× the subst mono phase, diluted to 1.54× by the rest of the front-end.

## 2. Where the time actually goes (V8 CPU profile, dev-mode JS, full self-compile)

`node --cpu-prof` over the whole front-end, self-time by function
(`scratchpad/analyze_prof.py`; dev-mode names, so every Elm function is visible):

| bucket                          | subst   | solver  | delta        | share of delta |
|---------------------------------|---------|---------|--------------|----------------|
| (garbage collector)             | 46.6 s  | 163.5 s | **+116.9 s** | 55%            |
| `_Utils_update` (record copy)   | 2.1 s   | 48.8 s  | **+46.7 s**  | 22%            |
| (anonymous) = monad closures    | 53.9 s  | 88.9 s  | **+35.0 s**  | 17%            |
| `A2` (curried apply wrapper)    | 7.8 s   | 16.2 s  | +8.5 s       | 4%             |
| `_Utils_cmp` (Dict compares)    | 8.6 s   | 9.3 s   | +0.6 s       | ~0             |
| **TOTAL front-end CPU**         | 129.7 s | 341.5 s | **+211.7 s** |                |
| MonoSolver modules' own self-time | —     | **2.2 s** | (1% of the delta) |          |

**Reading: the union-find, unification, and translation algorithms cost ~1% of the
slowdown. ~99% is allocation churn — record copies, closure allocation, and the GC
pressure they generate.** `Store.loadType`'s self-time is 1.0 s; the machinery invoked
*around* each of its steps costs two orders of magnitude more.

## 3. Cost anatomy (code walk)

### 3.1 The per-operation tax: a 23-field `S` copy per step

`Engine.S` is one 23-field record. Every `modifyS`, every `liftIO` (one per UF
operation batch), every `recordVar`, `insertVar`, `enqueueSpec` executes
`{ s | field = … }` → `_Utils_update` copies all 23 fields (~200 B) and the old copy
becomes garbage. `Store.loadType` on an N-node type performs ~2 S-copies **per type
node** (freshVar's liftIO + recordVar's modifyS). This is the measured +46.7 s of
`_Utils_update` plus a large slice of the +116.9 s GC delta. The `Step` monad's
`andThen` chains allocate a closure per bind — the +35 s of `(anonymous)`.

### 3.2 The per-expression tax: `classify = zonkToMono ∘ loadType`

`Translate.classify` (42 call sites — every Int/Float literal, every `VarLocal`
fallback, every var-ref, case/let/access/branch typing) loads the FULL canonical type
into the union-find — minting fresh Points for every *structural* node (3 persistent-
Array pushes each, via the IORef emulation in `System.TypeCheck.IO.State`) — solely to
read the structure back out with `zonkToMono` (UF.get per node, `revMemo`/`superTable`
Dict lookups per residual). For a monomorphic item this equals the pure
`Zonk.canTypeToMono` at ~100× the cost.

### 3.3 The per-call tax: instantiate + unify + zonk + serialize

`translateGlobalCall`, per call site:
1. `lookupAnnotation` — builds a `"pkg$Module.name"` String key, `DMap` get.
2. `instantiate funcCanType` — full structural load of the callee scheme (memo-bypassed
   → fresh Points for the whole type).
3. Per arg: `argUnifyVar` = full structural load of the arg's canType +
   `enrichFromEnv` (possibly `monoTypeToVar` — a full structural ENCODE of the
   varEnv-bound MonoType) + best-effort `Unify`.
4. `unifyResultWithExpected` — another load + unify.
5. `Store.zonkToMono funcVar` — full zonk of the callee type.
6. `callResultType` — possibly ANOTHER `classify callCanType`.
7. `enqueueSpec` — `toComparableSpecKey` serializes the whole MonoType to a String,
   then `Dict String` lookup.

A 3-arg call ≈ 5-6 full type loads/encodes + 3-4 unifications + 1-2 zonks + 1 type
serialization. The subst engine's equivalent is one `applySubst` walk with Dict lookups.

### 3.4 The store representation

`IO.State` emulates IORefs with four persistent `Array`s. `UF.fresh` = 3 Array pushes
(weight, descriptor, pointInfo); every `UF.get` = 2-3 Array gets; every `UF.set` =
persistent Array set (path copy). Costs are moderate individually but multiply against
3.2/3.3's operation counts, and every write allocates.

### 3.5 Auxiliary tables

- `memo : Dict Int Point` (MVarId→Point; sparse global key space) — insert per first
  var occurrence, get per repeat. Red-black rebalancing allocs.
- `revMemo : Dict Int MVarId` — **keyed by Point index, which is dense and
  zero-rooted per item** (points mint sequentially). Folded per item by
  `harvestSuperTableExcept` with a `UF.get` per entry.
- `superStatic` / `superTable : Dict Int SuperType` — MVarIds are sequential ints
  (dense, zero-rooted globally); `superStatic` is immutable after init.
- Registry `mapping : Dict String SpecId` — String keys built by serializing whole
  MonoTypes (`_Utils_cmp` ~9 s in BOTH engines — a shared cost, not the delta).

## 4. Ranked optimization plan

Ordered by expected-impact ÷ risk. Every tier ends with the same gate battery (§5).

### T1 — `classifyDirect`: stop fabricating store structure to read it back
**Expected: the single biggest win. Attacks ~all classify-site allocation.**
Replace `classify = zonkToMono ∘ loadType` with a read-only walk of the canType:
- `TVar v`: if `memo` holds a Point for `v` → zonk that Point (full fidelity, sees all
  unification results); else the var never touched the store this item → it is
  unbound: stamp `MVar v CNumber/CEcoValue` from `superStatic`/`superTable` directly
  (exactly `Zonk.canTypeToMono`'s rule, which the A/B gate already validated for
  monomorphic items).
- Structure (TType/TRecord/TTuple/TLambda/TAlias): recurse purely (Zonk.elm already
  implements every arm — including Holey-alias substitution); record-extension vars go
  through the same TVar rule and merge fields like `zonkRecordExt`.
- Zero store writes, zero Point minting, zero `S` copies: implement as
  `classifyDirect : Can.Type -> S -> MonoType` (read-only), wrapped once as a Step.
Semantic deltas to verify (both benign by design, both covered by the diff gate):
residual ids stamp the var's own id instead of the Point's first-minter id (ids are
dropped from spec keys — MONO_003); classify-only vars no longer mint Points (they
could never harvest Number taint anyway, since they never unify).
Sites: all 42 `classify` uses + `callResultType`'s fallback. Literals (`Int`/`Float`)
and `VarLocal`/`translateVarRef` dominate dynamically.

### T2 — Ground fast paths + scheme/ABI caches (the "cache schemes" idea, made safe)
**Expected: kills most remaining store traffic at call sites.**
Precondition helper: `groundCanType : Can.Type -> Bool` (pure, allocation-free,
early-exit). MVarIds are sequential ints; if the walk itself shows up hot, cache
groundness per meta.tipe in a small per-item table — measure first.
- **T2a Closed-scheme cache** (`S.schemeMonoCache : Dict String MonoType`, global,
  persists across items): a callee whose scheme has no free vars always classifies to
  the same MonoType. `translateVarRef` and `translateGlobalCall` skip `instantiate`
  entirely; `funcMonoType` comes from the cache (pure `canTypeToMono` on first use).
  Demand must still flow INTO var-carrying args: for each arg, if its canType is
  ground → skip; else `demandUnify argCanType paramMonoType` (the only store work
  left at such a site). Result type: `peelResult` of the cached type (concrete).
- **T2b Ground call-site memo** for polymorphic callees: when ALL arg canTypes and the
  callCanType are ground, the whole instantiate+unify outcome is a pure function of
  `(global, arg MonoTypes, expected MonoType)`. Memoize
  `key = global ⊕ toComparable args/result` → `(funcMonoType, resultMonoType)`.
  Repeated `List.map`/`Dict.get`-style call shapes hit this constantly.
  NOT applicable when any arg references a local-multi target or number-multi target
  (instance recording is a side effect) — guard with `accessedLocalName`/stack checks,
  which the call path already computes.
- **T2c Kernel-ABI cache**: `deriveKernelAbiTypeCall/Ref` re-instantiates the kernel
  scheme per site; same ground-key memo applies (respect the `suffixSelectingKernels`
  / Debug carve-outs and `remapEcoVarsFresh` behavior by caching AFTER the remap).

### T3 — Shrink the per-operation constant: stop copying 23 fields per step
**Expected: directly attacks the measured +46.7 s `_Utils_update` + its GC share for
whatever T1/T2 don't eliminate.**
- Bundle the per-item solver state into one sub-record:
  `item : { store : IO.State, memo : …, revMemo : …, varEnv : … }`. Rewrite
  `Store.loadType`/`zonkToMono`/`instantiate`/`monoTypeToVar` to thread
  **only the bundle** internally (plain `Bundle -> (a, Bundle)` recursion, no Step, no
  closures), with ONE `{ s | item = … }` writeback per public entry point. An N-node
  load then costs 1 S-copy instead of ~2N.
- This also removes most `Engine.andThen` closure allocation in the store layer
  (the +35 s `(anonymous)` bucket).
- Keep the public `Step` API; only the internals defunctionalize.

### T4 — Data-structure swaps (the Dict→Array suggestions)
- **`revMemo` → `Array (Maybe MVarId)`**: point indexes are dense and zero-rooted per
  item and mint sequentially — the textbook Dict→Array case. Push on mint (Nothing
  for structure Points, Just id for vars), O(1) get in `residualId`, direct fold in
  harvest. Removes a Dict insert per minted var and a Dict get per residual zonk.
- **`superStatic` → `Array (Maybe SuperType)`** indexed by dense global MVarId, built
  once at engine start (it is immutable): O(1) loadVar minting. `superTable` (static ∪
  harvested taint) can stay a Dict — or merge both into ONE table with a payload
  `{ static : Maybe SuperType, tainted : Bool }` (they are keyed identically and
  consulted at two well-defined sites), halving lookups where both are consulted.
- **`memo`** stays a Dict for now: keys are sparse in the global id space; its traffic
  collapses after T1/T2. Revisit only if post-T3 profiles still show it.

### T5 — Small structural wins
- **Harvest skip-flag**: track `sawNumber : Bool` per item (set when a
  `FlexSuper Number` is minted or produced by merge); skip
  `harvestSuperTableExcept`'s whole fold (revMemo × `UF.get`) when False — most items
  never touch a number var.
- `nodeAnnotationIds` builds an EverySet per item even when harvest is skipped — gate
  it behind the same flag.
- `translateArgsWith` list padding / `List.map2` chains — negligible; only touch if
  visible post-T3.

### T6 — Shared-cost items (help both engines, not just the gap)
- `enqueueSpec` serializes the full MonoType to a String per call site
  (`toComparableSpecKey`) and compares those strings in a `Dict String` — visible as
  `_Utils_cmp` ~9 s in BOTH profiles. An interned-key or structural-trie registry
  would shave several seconds from both engines. Orthogonal to the solver gap.
- `lookupAnnotation`/`toptNodes` DMap gets build composite String keys per call.

### T7 — Only if still needed: UF/store representation
Pack `ioRefsWeight`/`ioRefsPointInfo`/`ioRefsDescriptor` into one Array of a record
(1 push per fresh instead of 3, 1 get per read path). Shared with the live
typechecker — higher blast radius; do last, only if post-T1-T4 profiles still rank
store ops.

### Explicitly not worth it now
- `retranslateAt` re-translation for number/local-multi instances — by-design
  duplication, rare in practice.
- Rewriting the whole Translate layer off the Step monad — T3 gets most of the win at
  a fraction of the churn.

## 5. Validation gates (per tier)
1. `ECO_MONO_ENGINE=diff` A/B gate over the 812-program corpus (byte-graph compare +
   junk-regression guard) — catches any semantic drift from caching/fast paths.
2. Full E2E suite under `ECO_MONO_ENGINE=solver` (must stay 1567+/1567).
3. Solver bootstrap: JS 4b + native 8c fixed points green.
4. `frontendstats.txt` Stage-7a A/B timing re-run (cold eco-stuff protocol), plus the
   dev-JS `--cpu-prof` recipe below to confirm the GC/_Utils_update/closure buckets
   actually shrink.

## 6. Expected outcome
The delta decomposes as ~55% GC + ~22% record-copy + ~17% closures, all proportional
to store-operation count × per-operation allocation. T1+T2 remove the majority of
store operations (classify sites + ground call sites); T3+T4 cut the per-op constant
of what remains by ~an order of magnitude at the hot paths. A 3-5× reduction of the
mono-phase overhead is a reasonable target: **native Stage 7a from 404 s to
~290-310 s (within 10-20% of subst's 262 s)**; parity is a stretch goal that likely
needs T6/T7 too. Track each tier against gate #4.

## 7. Reproduction recipes
- Native A/B: §frontendstats.txt Stage-7a commands with `ECO_MONO_ENGINE=subst|solver`.
- Profile: `cd build/compiler/build-kernel && ECO_MONO_ENGINE=… node --stack-size=65536
  --max-old-space-size=12000 --cpu-prof --cpu-prof-dir=… bin/eco-boot-runner.js make
  --optimize --kernel-package eco/compiler --local-package eco/kernel=…/eco-kernel-cpp
  --output=/tmp/out.mlir /work/compiler/src/Terminal/Main.elm`
  (eco-boot.js is DEV-mode → full function names), then `analyze_prof.py` (aggregates
  self-time by function/module; script preserved in the session scratchpad).
