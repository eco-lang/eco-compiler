# Monomorphization Performance Analysis

## Status: Q1–Q5 IMPLEMENTED & GREEN (2026-07-05) — 12,868 unit + 1,547 E2E, 0 failures

> **Q1** (identity-preserving `refreshConstraints`): a `hasStaleConstraint` pre-scan
> returns the input by reference in the common (no-stale-stamp) case — no deep copy.
> `TypeSubst.elm`.
> **Q2** (closing-pass gate): `MonoTraverse.anyNodeType` (a zero-alloc predicate
> mirroring `mapNodeTypes` position-for-position) gates the deep node rebuild;
> `Monomorphized.resolveNumberType` is now identity-preserving too
> (`typeHasResidualNumber` pre-scan).
> **Q3** (fuse close into Prune): the residual-number close now happens INSIDE
> `Prune.pruneUnreachableSpecs` as it copies live nodes / recomputes ctorShapes —
> the separate `resolveResidualNumbers` whole-graph pass is DELETED. Because nodes
> are closed before ctorShapes are recomputed from them, the ctorShapes-key desync
> of §6.1 is fixed by construction.
> **Q4** (Destruct dispatch strictness): `eagerLeaf`/`buildPartialContainer` probe
> are now gated behind the cheap `isNumberMultiTarget` scan and `&&`, so the common
> Destruct computes neither.
> **Q5** (`isNumberVar` de-box): direct `case` instead of `== Just IO.Number`.
>
> §5/§6 items remain open (larger ceiling; §6.2/§6.3 not yet addressed). Measurement
> deltas: see `gcstats2.txt` (Stage 8a) vs `gcstats.txt`.

**Date:** 2026-07-05 (post quiescence-before-defaulting + D7 + demand-replay retirement)
**Baseline data:** Stage 8a GC stats of the full bootstrap (`gcstats.txt`): 2,379,353,817 objects /
72,156 MB allocated; 737 minor + 23 major GC cycles; 82.44 s total GC/alloc time.
**Method:** four parallel code audits (Specialize hot-path frequencies; TypeSubst/mapper allocation
behavior; whole-graph pass inventory; existing-plan cross-reference), grounded against the mutator
object-kind histogram. Line numbers are current as of this date.

---

## 1. Executive summary

A small self-compile regression appeared after the quiescence work. The diagnosis:

1. **The single largest new cost is NOT the closing pass** — it is `refreshConstraints` running
   **unconditionally inside `enqueueSpec`, before the dedup check**, deep-copying the entire
   MonoType (~2–3 allocations per type node) on **every global reference and every global call in
   every specialized body** — the highest-frequency operation in the whole pass. It replaced
   `forceCNumberToInt`, which was the identity function (zero cost).
2. **The closing pass (`resolveResidualNumbers`) is the second contributor**: a one-time but
   complete **deep duplicate of the entire program AST** (~2E + 2T allocations for E expr nodes and
   T type nodes), including a fresh `CallInfo`/`ClosureInfo` record per call/closure — produced even
   when the program contains zero residual number vars.
3. **The D6 deferral widening** (`containsCEcoMVar` → `containsAnyMVar`) moved every numeric
   nested-call argument — the ubiquitous `f (i + 1)` shape — from the zero-extra-cost immediate
   path onto the allocating deferred path (one `ProcessedArg` + one `unifyExtend` walk each).
4. Smaller adds: the D7 gate admits more lets into seeding (each paying a key build); the new
   Destruct dispatch has **two strictness bugs** (work computed then discarded — §3.4); J1/J2 add
   two `superVars` probes per var-var unification (constant, minor).

**Why retiring demand replay didn't offset this:** replay only ever ran for number-multi-target
roots and gated number-lets — *rare* shapes in the compiler's own source. The additions above run
**unconditionally on universal paths**. Removing a rare O(body) analysis cannot pay for a new
O(type-copy) on every global reference.

All of the regression is recoverable, mostly with low-risk changes (§4). Beyond that, the audits
found substantial long-standing waste (§5) and two latent correctness hazards (§6).

---

## 2. Grounding against the Stage 8a allocation profile

Mutator allocations by object kind (self-compile, `gcstats.txt`):

| Kind | Objects | Bytes | Maps to |
|---|---|---|---|
| Custom | 644.6M (29.9%) | 16.9 GB | ADT cells — MonoType/MonoExpr/Can.Type copies (the type-copy paths below) |
| Closure | 590.0M (27.3%) | 24.8 GB | curried partial applications in hot walkers (`List.map (f env)` etc.) |
| Cons | 385.1M (17.8%) | 8.8 GB | list spines — `List.map` rebuilds, zip lists, fold accumulators |
| Tuple2 | 280.2M (13.0%) | 6.4 GB | plumbing tuples — `(MonoType, MVarEnv)`, `(Bool, MonoType)`, `(Subst, Env)` |
| String | 217.4M (10.1%) | 6.0 GB | `toComparableMonoType`/`toComparableSpecKey` key materialization |

The regression's signature should appear mostly in **Custom + Cons** (deep type/AST copies from
`refreshConstraints` and the closing pass) and slightly in Tuple2 (deferral machinery). If the
before/after comparison shows growth concentrated there, that confirms the ranking in §3.
Conversely, String/Tuple2 dominance is **long-standing** (keys and plumbing), not from this change.

---

## 3. The regression, ranked

### 3.1 `refreshConstraints` in `enqueueSpec` — unconditional deep copy, pre-dedup (largest)

`Specialize.elm:252` (inside `enqueueSpec`, :239–273): every call runs
`TypeSubst.refreshConstraints state.ctx.mvarEnv rawMonoType` **and** the full
`toComparableSpecKey` string build (via `Registry.getOrCreateSpecId`, Registry.elm:54) **before**
the `BitSet.member scheduled` dedup at :260. `enqueueSpec` has 10 callers; the hot three are the
`VarGlobal` handler (:2651), the monomorphic-call fast path (:2878), and the polymorphic-call path
(:2918) — i.e. **every global reference and call, per specialized copy**.

`refreshConstraints` (TypeSubst.elm:73–95) rebuilds unconditionally: fresh `MVar` even when the
constraint is unchanged (the overwhelmingly common case), fresh containers (`List.map` spines,
`Dict.map` full record-tree copies) even when nothing inside changed. A fully concrete type — the
norm — is **deep-copied wholesale**, ~2N–3N heap objects per call. Its replacement predecessor
(`forceCNumberToInt`) was identity.

The same unconditional copy runs at the other five key sites (:300, :982, :1071, :1205, :3722),
which are lower frequency (per instance-recording / per seed).

### 3.2 `resolveResidualNumbers` — whole-AST duplicate at close (second)

`Monomorphize.elm:251–284`: `Array.map (Maybe.map (Traverse.mapNodeTypes close)) graph.nodes` plus
`reverseMapping` copy plus `ctorShapes` rebuild. `mapNodeTypes`/`mapExprTypes`
(MonoTraverse.elm:512–693) allocate a fresh constructor for **every** expr node, re-tuple every
`(name, expr)` pair, and copy every `ClosureInfo` and `CallInfo` record — wide records, one per
closure/call in the program — regardless of whether any residual exists. `resolveNumberType`
(Monomorphized.elm:264–310) likewise deep-copies every composite type term. Cost ≈ **a full
duplicate of the reachable program AST (~2E + 2T allocations), turned into garbage in one burst**,
once per compile. This is the "extra final pass" hypothesis — real, but one-time; smaller in
aggregate than 3.1's per-reference copies.

### 3.3 D6 deferral widening — ubiquitous numeric args now allocate

`processCallArg` :4503–4519 (and PendingGlobal :4549): the trigger is now `containsAnyMVar`, so an
open-number result (`MVar _ CNumber`) defers where the old `containsCEcoMVar` did not. Marginal
cost per deferral: 1 `ProcessedArg` wrapper + 1 `unifyExtend` walk of the arg's canonical type +
substitution `Dict.insert`s + a discarded `applySubstFV` (:4508, computed only for the check).
Per-site small; aggregate meaningful because the shape (`f (i + 1)`, `g (a * b) c` — index/offset/
arity arithmetic) is everywhere in a compiler. Note the deferral itself is **correctness-motivated**
(the callee's param may bind the number to Float); the recoverable part is the discarded
`applySubstFV` and the general per-call arg-walk redundancy (§5.4), not the deferral.

### 3.4 New Destruct dispatch — two strictness bugs (small but pure waste)

Elm `let` bindings are strict, so in the `TOpt.Destruct` dispatch:
- `eagerLeaf = applySubstFV state subst destructorMeta.tipe` (:3906) computes for **every Destruct
  node** — including the majority whose root is not on the valueMulti stack, where it is discarded.
- `canRefinePath` (:3939) runs a **full `buildPartialContainer`** (threading a MonoState) for every
  Destruct whose root is on the stack, even when `isNumberMultiTarget`/`fieldIsScalarNumber` are
  false and the `&&` chain would short-circuit before needing it; the probe's result is discarded
  and `buildPartialContainer` runs again per instance inside `specializeNumberDestruct` (:1050).
- `eagerLeaf` is recomputed inside both `specializeNumberDestruct` (:978) and
  `specializeGeneralDestruct` (:2401); `getValueMultiRootFromPath` is walked in the dispatch
  (:3930) and again inside `specializeGeneralDestruct` (:2370).
- `exprReferencesLocal` (:1039) folds the **entire mono body with no early exit** per diverted
  destructure (MonoTraverse.foldExpr has no short-circuit); k-name patterns fold the body k times.

### 3.5 D7 gate widening + J1/J2 probes (minor)

The uniform gate admits every number-fixable polymorphic let into seeding: each pays a
`refreshConstraints` + `toComparableMonoType` seed key + stack push/pop (pop is cheap when no Float
instances recorded). J1/J2 add two `constraintOf` probes (`Dict.get` on `superVars` + `Just` boxes
via `isNumberVar`'s `== Just IO.Number` encoding, State.elm:132) per var-var/canonical-var merge —
constant-factor, log-bounded, on the hottest unify path but small.

---

## 4. Recovering the regression — quick wins (low risk, high confidence)

Ordered by expected recovered allocation per unit of effort:

**Q1. Identity-preserving `refreshConstraints`** (fixes 3.1 at all 6 sites at once).
The templates already exist in the same file: `resolveMonoVarsHelp`'s `(Bool, MonoType)` pattern
(:609), `listMapChanged` (:102), `dictMapChanged` (:128). A `refreshConstraintsHelp` returns
`(False, original)` when `constraintOf mvarId env == stamped` (a 2-tag enum compare) and when no
child changed — the common case allocates only short-lived flag tuples and returns the input
reference. Optionally add an allocation-free pre-scan (shaped like `containsAnyMVar`) answering
"any MVar whose stamp disagrees with the table?" to skip the walk entirely; types with no `MVar` at
all — most keys late in the fixpoint — exit immediately.

**Q2. Pre-scan gate for the closing pass** (fixes 3.2).
An allocation-free `nodeHasResidualNumber : MonoNode -> Bool` (a short-circuiting fold over the
same type positions `mapNodeTypes` covers — note `foldExpr` does NOT visit type slots, so this is a
new small walker) gating `mapNodeTypes`:
`if nodeHasResidualNumber n then mapNodeTypes close n else n`. Typical fully-concrete nodes return
by reference with zero allocation. (Full changed-flag propagation through `mapExprTypes` is
strictly better but touches ~25 arms; the pre-scan captures nearly all of the win.)

**Q3. Fuse the closing pass into Prune** (eliminates a full spine copy + traversal; fixes a latent
bug — see §6.1). Prune already rebuilds `nodes1`, `reverseMapping1`, and recomputes `ctorShapes`
via a deep walk (Prune.elm:100–177, Analysis.elm:559–597). The live-entry branch becomes
`Maybe.map (mapNodeTypes close)`; ctorShapes get closed at collection inside
`buildCompleteCtorShapes`. Requires threading `MVarEnv` into `pruneUnreachableSpecs` (both in
scope at the call site). Composes with Q2 (fused AND gated).

**Q4. Fix the Destruct dispatch strictness** (fixes 3.4). Reorder: test
`isNumberMultiTarget rootName state` first (cheap scan), compute `eagerLeaf`/`fieldIsScalarNumber`
only inside that branch, and make the path-refinability check either lazy (compute inside the
`&&`-guarded branch via a `case`) or — better — pass the already-built partial container into
`specializeNumberDestruct` so `buildPartialContainer` runs once, not twice. Hoist the dispatch's
`eagerLeaf`/root lookup into the callees via parameters.

**Q5. De-box `isNumberVar`** (trims 3.5 and every `constraintOf` probe everywhere):
replace `Dict.get ... == Just IO.Number` with a direct `case`; saves ~2 boxes + structural
comparison at the single highest call frequency in TypeSubst.

Each of Q1–Q5 is behavior-preserving by construction; the full suite (12,868 unit + 1,547 E2E)
gates each. Verification: re-run the bootstrap and diff `gcstats.txt` objects/bytes — the deltas
should land in Custom/Cons (Q1–Q3) per §2.

---

## 5. Long-standing opportunities (pre-existing, larger ceiling)

The audits confirmed most historical perf plans have **landed** (union-find path compression +
changed-flags in `resolveMonoVars`; Array-based `MonoGraph.nodes`/`callEdges`/`reverseMapping`;
BitSets; single-String spec keys; SchemeInfo cache; the annotateCallStaging exponential fix via
`extendSourceArityEnv`). What remains, ranked by estimated ceiling:

### 5.1 Spec-key strings — the String economy (≈10% of objects, 6 GB)
Every `enqueueSpec`/instance lookup materializes a full type string (hundreds–thousands of chars
for compiler-sized types) and compares it against long shared prefixes in a `Dict String`.
Open, already-scoped ideas: **hash-prefix keys** (`plans/hash-prefix-comparable-keys.md`, still
valid atop the single-String encoding) and per-lookup key-allocation removal
(`compiler-memory-efficiency-improvements.md` F13). A step further: intern `(Global, MonoType)` →
SpecId via a two-level structure (Global-keyed outer Dict, small inner map) so the type string is
built once per *distinct* type rather than once per *reference*.

### 5.2 Post-fixpoint pass fusion — 6 full node-array copies, ~15–16 traversals
Inventory (fixpoint-end → codegen-start): Prune spine copy → closing deep copy → InlineSimplify
(4 read-only full walks + `Array.toList` spine + deep rewrite + re-count) → GlobalOpt
`wrapTopLevelCallables` spine → `Rewriter` spine + deep rewrite → `annotateCallStaging` deep
reconstruction (rebuilds every composite expr even when `CallInfo` is unchanged) → codegen's two
lookup walks. Fusions that are safe: closing into Prune (Q3); InlineSimplify's 4 pre-walks into
one fold and the post-count into the rewrite; `wrapTopLevelCallables` into the inliner's output
fold; ProducerInfo + GraphBuilder (back-to-back read-only walks) into one. NOT safe:
Rewriter + annotateCallStaging (P5 reads other nodes' post-rewrite arities). Ceiling: ~3 fewer
full-graph copies and ~6 fewer traversals.

### 5.3 `applySubst` dead-env plumbing and friends (Tuple2 economy, 280M objects)
`applySubst` provably never modifies its env (verified across all arms), yet allocates a
`(MonoType, MVarEnv)` tuple per Can.Type node plus ~3 objects/element in `applySubstList`. An
internal non-threading `applySubstPure` (exported tuple API as a shim) removes N dead tuples per
conversion. Related: `findRootVar` allocates a 3-tuple even on the miss path (the most common
probe — fresh scheme vars); `normalizeMonoType`/`normalizeAndOccursCheck` rebuild containers
unconditionally (only their MRecord arms have changed-flags — an unfinished conversion; finish it);
`unifyHelp`/`unifyMonoMono` zip via `List.map2 Tuple.pair` at 5 sites (2k objects per structural
unify) instead of paired recursion; `extractParamTypes` is O(depth²) via `++`.

### 5.4 Per-call and per-reference redundancy in Specialize
- `refineSubstFromArgExprs` (:2818) runs `unifyExtend` per argument on **every** call — including
  fully-monomorphic callees where it cannot bind anything. Gate it on the callee's scheme having
  any vars.
- Each call arg's canonical type is walked up to **three times** (processCallArg `applySubst`,
  `refineSubstFromArgExprs`, pending-resolution `unifyExtend`).
- Every `VarLocal`/`TrackedVarLocal` reference pays `isLocalMultiTarget` + `isNumberMultiTarget`
  linear stack scans, and `isNumberMultiTarget` on a hit runs `KernelAbi.freeVarIds` — a full
  canonical-type walk allocating a List + Set — per reference. Cache the per-name verdict on the
  stack frame at push time (the frame's `defCanType` is fixed for its lifetime).
- `refineValueMultiForDestructorCall` (:1367) does `Dict.toList` of all instances per stack entry
  on **every call with a local callee**.
- The Let `useExprType` fallbacks **specialize the entire body twice** (:3254 vs :3313, also
  :3438, :3541) — the enrichment could be detected before the first specialization in most cases,
  or the first result reused when the enriched subst is unchanged.
- Gate/branch recomputation: `applySubstFV ... defCanType` computed 2–3× per number-let
  (:3643/:3675/:3845); `shouldUseValueMulti` does two `freeVarIds` walks and the D7 gate repeats
  one (:430/:3643); `localMultiInstanceCount` folds the stack twice (:3687–3688); per-instance
  `applySubstFV` duplicated between the defs fold and the varEnv fold (:3578/:3614, :3782/:3804).

### 5.5 Cross-cutting (cite, don't rediscover)
Open items from prior plans that this analysis re-confirms as live: unify-result caching
(`compiler-perf-optimizations.md` Item 6), union-find `Substitution` representation
(`typesubst-perf-refactoring.md` Phase C — today every binding pays O(log n) persistent-Dict path
copies, plus `findRootVar` compression writes), inliner fixpoint `exprEqual`/per-binding
`substituteAll` (`compiler-memory-efficiency-improvements.md` F24/F25), JS Builder O(n²) string
growth (F4 — affects the JS-target build, not the native self-compile), and the remaining
`Data.Map` dual-key users (F3).

---

## 6. Latent correctness findings (surfaced by the audits; not perf)

**6.1 ctorShapes key desync under residual closing.** `resolveResidualNumbers` closes ctorShape
`fieldTypes` but NOT the `ctorShapes` Dict **keys** (built from `toComparableMonoType` of the
`MCustom` pre-close, Analysis.elm:572). An `MCustom` carrying a residual number var in its args
would leave a key that no longer matches the closed node types at codegen lookup. Not currently
observed (all suites green — residual-in-MCustom-args is evidently rare/absent), but it is a trap.
Q3's fusion (close during Prune's rebuild, then collect shapes from already-closed nodes) makes
keys consistent **by construction** — the correctness argument for doing Q3 rather than only Q2.

**6.2 Empty callEdges at codegen.** `MonoInlineSimplify.optimize` empties `callEdges` (:180) and
nothing repopulates it; `Backend.buildBodyLookup` (:68/:153) then builds its recursion-exclusion
call graph from an empty edge set, making `isRecursive` all-False for the bytes-fusion reifier's
"excluding recursive specs" guarantee. Needs verification that the reifier has its own loop guard.

**6.3 Inconsistent instance keying.** `specializeGeneralDestruct`'s `instanceKey` (:2437) does NOT
apply `refreshConstraints`, unlike its twin in `specializeNumberDestruct` (:1070) and
`getOrCreateValueInstance` (:1205). Benign today only because the general path never runs for
tainted-number roots; should be unified when touching this code (or made moot by Q1's
identity-preserving refresh, after which refreshed == raw in the untainted case by reference).

---

## 7. Recommended sequence and measurement

| # | Change | Fixes | Effort | Risk | Expected effect |
|---|---|---|---|---|---|
| 1 | Q1 identity-preserving `refreshConstraints` | §3.1 | S | very low | largest single recovery; Custom/Cons ↓ |
| 2 | Q4 Destruct dispatch strictness reorder | §3.4 | S | very low | removes pure discarded work |
| 3 | Q2 closing-pass pre-scan gate | §3.2 | S–M | low | removes the one-time whole-AST copy |
| 4 | Q3 fuse closing into Prune (+ ctorShapes at collection) | §3.2, §6.1 | M | low-med | −1 full copy/traversal; key consistency by construction |
| 5 | Q5 `isNumberVar` de-box | §3.5 | XS | none | constant-factor on hottest probes |
| 6 | 5.4 gate `refineSubstFromArgExprs` + cache multi-target verdicts | pre-existing | M | med | per-call/per-ref recovery beyond the regression |
| 7 | 5.1 spec-key interning / hash prefix | pre-existing | M–L | med | attacks the 10%-of-objects String economy |
| 8 | 5.2 remaining pass fusions | pre-existing | M–L | med | −2 more full copies, −5 traversals |

**Measurement protocol:** the bootstrap is the benchmark. For each step: full unit + E2E suites
(green gate), then `cmake --build build --target bootstrap` and diff (a) Stage 7a wall/CPU/RSS from
the timing table, (b) `gcstats.txt` Stage 8a objects/bytes and the object-kind histogram. Steps 1–3
should visibly reverse the regression's Custom/Cons growth; anything that doesn't move the
histogram in the predicted direction is evidence the ranking is wrong and should pause the
sequence. (Precedent: `replace-mvar-with-js-dict.md` recorded −46% wall / −24% RSS with exactly
this before/after discipline.)
