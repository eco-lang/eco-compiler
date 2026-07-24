# CAF Hoisting: Memoize Closed Expressions Inside Function Bodies

## Status: IMPLEMENTED + GATED, SHIPS DEFAULT-OFF (2026-07-24).
## Run V measured the workload wall NEGATIVE at both operating points
## (+1.5 % at mn=3, +0.9 % at mn=8) despite real allocation reduction
## (minors −9/−2) and a 1.13 MB smaller binary. Root economics: Run S/T's
## top-level wins converted EXISTING per-reference calls into guarded
## calls, while hoisting INTRODUCES a statepointed call + guard where
## HEAP_034's inline nursery bump had made small construction nearly free;
## the numerous hot candidates are small, the large ones cold. Census:
## dispatch-neutral to the digit (the plan's sat-drop prediction was wrong
## — the dispatch-heavy bodies were the bytes-excluded ones). All gates
## green (flag-on E2E 1635/1635, 3-leg fixed point byte-exact, unit tests,
## census cross-check +3 %). Full record: benchmarks/runtime-calls.md
## Run V. Revisit levers: caller-side fast path (removes the call from
## the hit path), profile-guided hoisting of hot large sites.
## (Original status: implementation-ready; every "verified:" note below
## was read from source, not assumed.)

## 0. Goal and evidence

Extend CAF memoization (plans/caf-memoization-implementation.md, CGEN_068)
below the top level. A *closed* expression inside a function body — one
referencing no locals bound outside itself, e.g.
`vals = [1,2,3] |> Array.fromList` inside `f x = …`, let-bound or inline —
is hoisted into a freshly minted nullary `MonoDefine` spec; the site
becomes a `MonoVarGlobal` reference. The existing slot machinery then
evaluates it once per process instead of once per call. **Zero codegen or
runtime changes** — the entire CAF backend (slots, guards, GC rooting,
`ECO_CAF_MEMO`) is reused unchanged.

Census (2026-07-24, `ECO_CAF_CENSUS=1`, self-compile, post-GlobalOpt graph):

```
specs=38,267  candidates=6,083 (maximal)  valueAbi=5,989 (98.5%)  candNodes=62,988
kinds:  call=3,756  let=1,816  tuple=317  list=174  record=20
sizes:  s1_2=37  s3_9=5,105  s10_49=669  s50plus=272
top heads: Bytes.Encode.U8=998  Bytes.Encode.F64=622  Maybe.Just=203
           Scheduler.succeed=167  Doc.reflow=105  composeR=103  parser atoms…
top specs: Reporting.Error.* (cold tail)  Intrinsics.basicsIntrinsic=54 (hot)
```

~360× the source-visible population. Semantics are sound: slots are lazy
(first-use init at the original site ⇒ evaluation timing preserved
exactly), and effect types are safe since
plans/task-purity-and-caf-guard-removal.md.

## 1. Resolved design decisions

### DQ1 — Budget: yes, layered policy, not one knob

Costs per hoisted spec: 8 B slot + ~6-instr guard + one `jit_roots` entry
+ one extra spec through codegen/lowering. Run S/T measured 1,558 slots at
+0.13 % binary and no root-scan signal; the pressure point is **spec count
through the backend** (38,267 today; +6 K pre-dedupe ≈ +16 %; lowering is
~14 s of Stage 7b — expect low-single-digit % lowering-wall growth,
measured in H3). Policy layers:

1. `minNodes` size floor (default **3**, on the ORIGINAL subtree size —
   see DQ7 layering note) — kills the 37 `s1_2` near-trivia. Guard-cost
   basis (verified, not estimated: the compiled guard shape is pinned by
   `test/codegen/caf_memo_basic.mlir` GUARD checks — addressof + load +
   icmp + cond_br + barrier-call + return ≈ 6 ops on the hit path, plus
   the thunk call at the site): a 2-node construction under HEAP_034's
   inline nursery bump costs a comparable handful of straight-line ops, so
   size-2 hoists are plausibly net-negative. The H3 sweep's `minNodes=2`
   leg VALIDATES this empirically rather than trusting the estimate
   (review requirement).
2. **Dedupe** (DQ2) — the 998 `BE.U8`-class duplications collapse to one
   spec per distinct shape; the main volume control, costs nothing.
3. `maxHoists` global safety valve (default **8192 — PROVISIONAL until H0
   reports the layered count and distinct-shape count**; review
   requirement: H0 is a hard prerequisite for trusting any default here).
   Stop minting when reached, count the overflow. Deterministic
   first-come cut in traversal order — a guardrail, not a tuner. If H0/H3
   show the cut binding at sensible settings, implement two-pass priority
   selection (collect → rank by `origSize × dupCount` → rewrite) BEFORE
   shipping default-on; NOT built otherwise.
4. Exclusions (§1 DQ6) each carry a census counter so their cost is a number.

### DQ2 — Dedupe: closure-free subtrees only, collision-impossible equality

`MonoClosure.lambdaId` is identity-bearing (LSS members, AbiCloning reps —
LSS_017/LSS_009 discipline): two structurally-equal closures with
different lambdaIds must NOT merge. Rule: subtrees containing ANY
`MonoClosure` are hoisted **per-site, un-deduped** (still sound — verbatim
move, no copy, lambdaId uniqueness preserved).

Closure-free subtrees dedupe by **region-zeroed structural equality**
(review upgrade — replaces the earlier hand-written `keyOf` serializer,
whose collision risk was its own worst hazard): `zeroRegions :
MonoExpr -> MonoExpr` rewrites every `Region` field (the ONLY non-semantic
payload in the tree: `MonoCall/MonoList/MonoTupleCreate/MonoVarGlobal/
MonoVarKernel/MonoAccessorValue`) to `A.zero`; two candidates merge iff
their zeroed trees are `==`. Elm structural equality is exact — CallInfo
(including AbiCloning stamps), types, literals, deciders all participate
automatically; differing stamps ⇒ unequal ⇒ no merge (safe, merely less
dedupe). Lookup structure: `Dict fingerprint (List (MonoExpr, SpecId))`
with `fingerprint = kindTag ++ sizeStr ++ Mono.toComparableMonoType ty ++
headName` — buckets stay tiny; `==` runs only within a bucket. Collisions
are impossible by construction; the residual cost is O(bucket) small-tree
comparisons per candidate.

### DQ3 — Placement: after MonoGlobalOptimize, verbatim move

New pass `Compiler/GlobalOpt/CafHoist.elm`. **Execution order in
`runGlobalOptPhase` (review-fixed, single source of truth):**

```
MonoGlobalOptimize.globalOptimizeWithStats
  → CafCensus report          (if cafMemo.census)          — PRE-hoist opportunities
  → CafHoist.run              (if cafMemo.hoist.enabled)
  → "caf-hoist:" stats line   (if hoist ran)
  → CafCensus report again    (if census AND hoist ran)    — POST-hoist residue,
                                prefix "caf-census(post-hoist):"
```

The pre-hoist census is the opportunity baseline; the post-hoist census is
the H2 collapse gate. Verified facts making verbatim-move sound:

- **CallInfo is purely per-node** (verified: Monomorphized.elm:1538-1550
  fields all derive from call-site + callee static type; AbiCloning stamps
  annotate the call expression itself, Expr.elm:2183-2197). A moved
  `MonoCall` compiles identically.
- **MonoCase `Jump` indices are case-local** (verified: jumps list lives
  in the MonoCase node, Expr.elm:6088 builds the lookup per-case). Move
  the whole case, jumps stay valid. Never renumber.
- **`MonoTailCall` cannot appear in a closed subtree** (verified: the
  walk counts the tail name as free; tail names are only bound by an
  enclosing `MonoTailDef`/`MonoTailFunc`).
- Nothing re-validates after GlobalOpt (verified: ValidateLayout and
  Prune run pre-inline; Backend consumes the graph directly).

### DQ4 — Bytes fusion: EXCLUDE pkg-`bytes`-headed candidates (verified refutation)

Direct reading of `BytesFusion/Reify.elm:210-310`
(`reifyEncoderHelpStrict`): the reifier recognizes `MonoCall` heads that
resolve to `Bytes.Encode`/Bytes-kernel, curried calls, and let-bound
locals via `exprCache` — **its wildcard arm returns `Nothing` for a bare
`MonoVarGlobal` operand**. (A fact-finder claimed fusion "sees through"
globals via `buildBodyLookup`; that arm exists only for MAP-FUNCTION
position, `reifyMapBody` — refuted for operand position.) Hoisting a
`BE.U8 5` operand would degrade it from a fully-reified constant store in
the fused loop (zero allocation — strictly better than memoization) to an
`EOpaque` thunk call (escape-hatch backstop, plans/bytes-fusion-escape-hatch.md
— fusion survives, quality drops). Same argument for decode fusion
(`tryInlinedDecodeFusion` matches let-RHS shapes at `MonoLet`,
Expr.elm:381). **v1 rule: a candidate is excluded when its ROOT head
resolves to package `bytes` (module `Bytes.Encode`, `Bytes.Decode`,
`Bytes`) or is `MonoVarKernel _ _ "Bytes" _ _`.** Candidates merely
*containing* deeper BE/BD nodes are allowed (rare; worst case EOpaque;
counted). This cuts the census's top cluster (~1,620 sites) — deliberate:
fusion beats memoization there. H3 includes a hoist-BE-anyway leg to
quantify what is left behind; a follow-up could teach
`reifyEncoderHelpStrict` a `MonoVarGlobal → buildBodyLookup` operand arm
and then lift the exclusion.

### DQ5 — Graph surgery: first-of-its-kind append, exact field list

Verified: **no existing pass appends specs post-mono** (staging wrappers
rewrite nodes in place; AbiCloning stamps only), so this is the canonical
recipe, copied from mono-time `Registry.getOrCreateSpecId`:

| Field | Action | Verified basis |
|---|---|---|
| `nodes` | `Array.push (Just (MonoDefine expr ty))` per hoist | buildSignatures/typeTables/emission are nodes-derived in all 3 backend paths (Context.elm:809, Backend.elm:63/149/267) — appended specs auto-covered |
| `registry.nextId` | += number minted (specIds = old nextId + k). ASSERT `nextId == Array.length nodes == Array.length reverseMapping` on entry; crash loudly if not (never observed; guards drift) | Registry.elm:51-71 |
| `registry.reverseMapping` | `Array.push (Just (Global (IO.Canonical ("eco","hoisted") "CafHoist") name, ty))`, name = `"hoist_" ++ String.fromInt ordinal` | specIdToFuncName → `CafHoist_hoist_<ord>_$_<specId>`; canonicalToMLIRName only dot-replaces (Names.elm:17) — MLIR-safe; missing entries would fall back to `unknown_$_N` (works, but named specs debug better) |
| `registry.mapping` | untouched | cleared at end of mono, never read post-GlobalOpt (verified: zero refs outside Registry.elm) |
| `callEdges` | untouched (`Array.empty`) | MonoInlineSimplify.optimize:900 already cleared it; sole post-GlobalOpt consumer is `buildBodyLookup`→`buildCallGraph`, which treats missing edges as non-recursive — correct for hoisted specs (they ARE non-recursive) |
| `specHasEffects` / `specValueUsed` | untouched (`BitSet.empty`) | both reset by MonoInlineSimplify:901; zero post-GlobalOpt consumers (verified by grep) |
| `nextLambdaIndex` | untouched | verbatim moves mint no lambdas |
| `main` / `ports` / `flagsDecoder` / `ctorShapes` | untouched | frozen |

Site replacement: `MonoVarGlobal A.zero newSpecId (Mono.typeOf subtree)`.
Codegen (`generateVarGlobal` arity-0 signature path) emits the direct
thunk call; `cafMemoQualifies` then gives the new spec a slot (bodies are
non-trivial and value-ABI by construction — §2). Closures INSIDE hoisted
bodies are compiled by the normal pendingLambdas/`Lambdas.processLambdas`
wave (verified: Expr.elm:951-1145, Backend.elm:91 — recursively drains).

### DQ6 — Eligibility (all must hold at a node)

1. Closed: empty free-name set (walk of §3; same discipline as
   `CafCensus.walkExpr` — names via `MonoVarLocal`, tail names, case
   scrutinees, destructor path roots, decider DtPath roots; binders via
   closure params+captures, let/tail defs, destructor names).
2. Candidate kind: `MonoCall`, `MonoLet`, `MonoIf`, `MonoCase`,
   `MonoDestruct`, `MonoRecordCreate`, `MonoRecordUpdate`,
   `MonoTupleCreate`, non-empty `MonoList`. (Never: literals, bare
   vars/globals/kernels, `MonoUnit`, `MonoAccessorValue`, `MonoClosure`
   roots — zero-capture closures are already interned, HEAP_033.)
3. `origSize ≥ minNodes` (original, pre-child-replacement size).
4. Value ABI: `Mono.typeOf` ∉ {MInt, MFloat, MChar, MVar _ CNumber}
   (HEAP_035 scalar-slot rule; 94 census sites skipped).
4b. **NOT function-typed** (added from the first flag-on corpus run:
   Combinator* tests SIGABRT'd + one wrong-result). A composed-function
   value (`composeR f g`) hoisted out of CALLEE position leaves the
   enclosing `MonoCall`'s staged CallInfo describing a callee shape that
   no longer exists — the runtime typed-apply arity assert fires.
   CallInfo is per-node (DQ3 holds) but it derives FROM the callee
   expression; the callee's shape must not change under it. v1 excludes
   ALL `MFunction`-typed candidates (position-blind — a positional
   refinement could readmit stored-not-called function values later).
   Counted as `skippedFnType`/`fnTypeExcluded`.
5. Not pkg-`bytes`-headed (DQ4).
6. No `MonoVarKernel _ _ "Debug" _ _` anywhere in the subtree (do not
   change inner `Debug.log` cardinality silently; the BitSets that once
   tracked this are dead post-GlobalOpt, so scan the subtree — it is
   already in hand).
7. Budget not exhausted (`maxHoists`).

Node kinds walked for hoisting: `MonoDefine (MonoClosure …)` function
bodies + capture exprs, and `MonoTailFunc` bodies (loop-invariant hoists —
the biggest per-call wins). Skipped entirely: nullary `MonoDefine` bodies
(already memoized whole), `MonoCtor/MonoEnum/MonoExtern/MonoManagerLeaf`,
ports (PORT_003).

### DQ7 — MAXIMAL hoisting via collect+replace (layered scheme FALSIFIED by H0)

H0/H1 measurements (2026-07-24, self-compile):

```
caf-census v1: eligible=4642 distinctShapes=3029 layered=12668
               closureContaining=332 bytesExcluded=1334 debugContaining=0
               scalarExcluded=94 belowMinNodes=37
layered smoke: hoisted=8192 (VALVE BOUND) sites=9930 deduped=1738
               skippedBudget=1068 out.mlir +8.7%
```

The originally drafted "layered" scheme (hoist bottom-up, parents over
rewritten children) inflated mint volume 2.1× over maximal (12,668
layered vs 4,642 maximal-eligible), bound the 8192 valve, and grew the
output +8.7 % — the plan's own tripwire (review requirement) fired.
REPLACED by true maximality with a clean two-phase design per body:

1. **collect** — pure bottom-up walk returning the ELIGIBLE-MAXIMAL
   candidate subtree VALUES: a closed+eligible node collects itself and
   discards nested collections; a closed-but-INELIGIBLE or open node
   passes children's collections through (eligible children of e.g.
   bytes-excluded parents still hoist). Skip counters bump here.
2. **replace** — top-down rebuild replacing any node structurally EQUAL
   to a collected candidate (structure-shared `==`, fails fast on
   constructor mismatch; per-body candidate lists average 0.16 entries),
   stopping descent at a replacement. Two equal maximal candidates in one
   body both match and share one deduped spec. Mint/dedupe/budget happen
   at replace time in deterministic traversal order.

No original-tree retention, no mint-undo, no dead specs, O(n) walks.
Bodies with empty collections (the overwhelming majority) return
verbatim.

### DQ8 — Determinism / fixed point

Traversal: `Array.foldl` over nodes in specId order; in-body traversal is
structurally fixed; ordinals and specIds assigned in encounter order;
dedupe map is keyed by `keyOf` strings but NEVER iterated for output
(lookups only) — no Dict-order dependence. No `Debug.toString` anywhere
(hand-written `keyOf`, §4) — no reliance on renderer stability. Result:
byte-reproducible output; bootstrap Stage 8c is the gate.

### DQ9 — Config / rollout

`CafMemoConfig` grows `hoist : { enabled : Bool, minNodes : Int,
maxHoists : Int }`; defaults `{ enabled = False, minNodes = 3,
maxHoists = 8192 }`. Env (Builder/Eco/Config.elm, the
applyLssDevirtFnOverride pattern): `ECO_CAF_HOIST=1|0`,
`ECO_CAF_HOIST_MIN_NODES=<n>`, `ECO_CAF_HOIST_MAX=<n>`. `Config.hash`
tokens ONLY when enabled: `cafh=1`, plus `cafhN=<n>`/`cafhM=<n>` when
non-default (artifact-affecting knobs must key caches; census flag stays
hash-excluded). Default-on decision after H4 numbers.

## 2. Pass specification — `Compiler/GlobalOpt/CafHoist.elm`

```elm
module Compiler.GlobalOpt.CafHoist exposing (run, Stats)

type alias Stats =
    { hoisted : Int          -- specs minted
    , sites : Int            -- sites replaced (≥ hoisted with dedupe)
    , deduped : Int          -- sites served by an existing spec
    , skippedBudget : Int
    , skippedBytes : Int     -- DQ4 exclusion count
    , skippedDebug : Int
    , skippedScalar : Int
    , origNodes : Int        -- Σ origSize over replaced sites
    }

run : Config.CafMemoConfig -> Mono.MonoGraph -> ( Mono.MonoGraph, Stats )
```

Internal state threaded through the rewrite:

```elm
type alias HoistCtx =
    { nextId : Int                   -- registry.nextId at entry, incremented
    , minted : List ( Mono.MonoExpr, Mono.MonoType )  -- REVERSED mint order
    , dedupe : Dict String Int       -- keyOf → specId (closure-free only)
    , stats : Stats
    , cfg : { minNodes : Int, maxHoists : Int }
    }
```

Core rewrite (bottom-up; returns rewritten expr + free set + ORIGINAL
size + whether subtree contains a closure / Debug ref / bytes node —
one fused walk, the CafCensus walk extended with the rebuild):

```elm
hoistExpr : HoistCtx -> Mono.MonoExpr -> ( Mono.MonoExpr, Info, HoistCtx )

type alias Info =
    { free : Set Name, origSize : Int, hasClosure : Bool, hasDebug : Bool }
```

Per constructor: rebuild with rewritten children (exact binder handling
copied from `CafCensus.walkExpr` — closure params+captures, MonoDef /
MonoTailDef, destructor name + path root, case scrutinees s1+s2, decider
DtPath roots, tail-call names; decider `Leaf (Inline e)` bodies are
REWRITTEN too, `Jump` untouched). After rebuilding node `e'` with info
`i`:

```elm
if Set.isEmpty i.free
    && eligibleKind e            -- §1 DQ6.2, checked on the ORIGINAL node
    && i.origSize >= ctx.cfg.minNodes
    && valueAbi (Mono.typeOf e)
    && not (bytesHeaded e)       -- DQ4: root head only
    && not i.hasDebug
then
    case ( i.hasClosure, Dict.get (keyOf e') ctx.dedupe ) of
        ( False, Just sid ) ->
            ( Mono.MonoVarGlobal A.zero sid (Mono.typeOf e), leafInfo, bumpDedup ctx )

        ( hasCl, _ ) ->
            if budgetLeft ctx then
                mint e' hasCl ctx    -- push (e', ty); site → MonoVarGlobal A.zero newSid ty;
                                     -- record key when not hasCl
            else
                ( e', i, bumpSkippedBudget ctx )
else
    ( e', i, ctx )
```

Note `keyOf e'` (the REWRITTEN form): child refs are globals, so two
parents whose children deduped to the same specs share keys — layering
composes with dedupe. `leafInfo` = the replacement's info
(`free = ∅, origSize = i.origSize` — the parent's floor still sees the
full original weight through `origSize` summation).

Node walk (`run`): fold nodes; for `MonoDefine (MonoClosure info body ty0) ty`
rewrite `body` AND each capture expr; for `MonoTailFunc params body ty`
rewrite `body`; all other node kinds pass through. After the fold, if
`ctx.minted` non-empty: append `List.reverse ctx.minted` as
`MonoDefine`s, extend `reverseMapping` in the same order with
`Global (Canonical ("eco","hoisted") "CafHoist") ("hoist_" ++ ordinal)`,
set `registry.nextId = ctx.nextId`. Entry assertion (crash):
`registry.nextId == Array.length nodes && Array.length reverseMapping == Array.length nodes`.

Report line (stderr, alongside the lss/inline reports in
`runGlobalOptPhase`; printed when `cafMemo.census || hoist.enabled`):
`caf-hoist: hoisted=… sites=… deduped=… skippedBudget=… skippedBytes=… skippedDebug=… skippedScalar=… origNodes=…`.

Wiring in `Builder/Generate.elm` `runGlobalOptPhase` (which already takes
the cafCensus flag; add the hoist config):

```elm
( hoistedGraph, hoistStats ) =
    if ecoConfig.cafMemo.hoist.enabled then
        CafHoist.run ecoConfig.cafMemo hoistedInput
    else
        ( hoistedInput, CafHoist.emptyStats )
```

placed AFTER `globalOptimizeWithStats`, BEFORE the census/report tasks;
`result.monoGraph = hoistedGraph`.

## 3. Dedupe machinery — `zeroRegions` + fingerprint buckets (supersedes the drafted `keyOf` serializer; see DQ2)

Hand-written serializer over `MonoExpr`/`MonoType` (no `Debug.toString` —
it renders Regions, which differ per site, and its stability is not a
contract). Rules:

- Regions: SKIPPED everywhere (`MonoCall/MonoList/MonoTupleCreate/
  MonoVarGlobal/MonoVarKernel/MonoAccessorValue` region params).
- Names, literals, field names, tags, kernel triples: rendered verbatim
  with type/constructor discriminator prefixes (`"c(" ++ … ++ ")"` style,
  unambiguous bracketing).
- `MonoVarGlobal` → `"g" ++ String.fromInt specId` (specIds are stable
  within one compile — keys are per-compile only, never persisted).
- Types via existing `Mono.toComparableMonoType` (already the registry's
  canonical type key).
- `CallInfo`: render every field (callModel tag, stageArities,
  initialRemaining, remainingStageArities, isSingleStageSaturated,
  callKind tag, evaluatorReturnType via toComparableMonoType,
  closureKind/captureAbi/fastEvaluator/fastPapPrefix rendered
  structurally). Differing stamps ⇒ different keys (DQ2).
- `MonoClosure`: unreachable in keyed subtrees (closure-containing
  subtrees never dedupe); `keyOf` may `crash` on it as a tripwire.
- Deciders/paths: full structural render (tests, DtPaths, jump ints).

Only called for closure-free candidates (bounded by candidate size; cost
is O(subtree) once per candidate).

## 4. Milestones

### H0 — Census upgrades — DONE 2026-07-24 (numbers in DQ7 above)
Counters landed in `CafCensus` (eligible/distinctShapes/layered/
closureContaining/bytesExcluded/debugContaining/scalarExcluded/
belowMinNodes). Outcome: falsified the layered scheme (DQ7 revised),
validated the valve default (maximal demand ≈3.4 K mints ≪ 8192 —
expected: 3,029 distinct closure-free + ~330 per-site closure-containing),
and confirmed Debug-containing candidates are ZERO on this tree.

### H1 — The pass
`CafHoist.elm` (§2) + `keyOf` (§3) + config/env/hash plumbing (§1 DQ9) +
`runGlobalOptPhase` wiring. Default OFF. Unit-level: a
`compiler/tests` TestLogic case building a tiny synthetic MonoGraph
(one function containing a closed `MonoCall`, one open call, one
closed-but-scalar, one closed-with-Debug) asserting Stats and the
rewritten graph shape (site → MonoVarGlobal; appended node; registry
lengths). Gate: `elm-tests` (modulo the known typechecker-track reds) +
flag-OFF full E2E byte-identical to pre-plan.

### H2 — Flag-on correctness
`ECO_CAF_HOIST=1` legs: full E2E (`--target full`), corpus, bootstrap
(4b + 8c byte-exact fixed points — determinism gate), tiny-nursery
`ECO_HEAP_VALIDATE` JIT leg (hoisted values crossing GC, the
caf_memo_gc.mlir class at scale). Census re-run flag-on: candidates
collapse to ≈ exclusions; `caf-hoist:` line archived here.

### H3 — Budget sweep
Cheap methodology (review addition): the sweep knobs are ENV VARS read by
the compiler process, so every cell runs on ONE hoist-capable binary —
per cell: cold self-compile with the cell's env → record the `caf-hoist:`
stats line (hoisted/sites/deduped/skipped* breakdown), output .mlir size,
slot count (`strings | grep -c __eco_caf`), and the LOWERING wall of that
output via `eco-boot-native out.mlir` (~2 min/cell, no chain rebuild).
Grid: `minNodes ∈ {2,3,5,8}` × `maxHoists ∈ {2048, 8192, ∞}` ×
{BE-excluded, BE-included}, pruned to the informative ~6-8 cells.
**Acceptance (review requirement): actual minted/deduped/layered totals
are compared against H0's predictions; a >±25 % deviation on the default
cell fails the milestone back into analysis** (either the census counters
or the pass have a bug — they share the walk, so divergence is a red
flag, not a shrug). Then ONE full chain rebuild at the chosen defaults for
the Stage-7a wall ×3 and H4. If the valve binds at sensible settings:
priority selection first (DQ1.3).

### H4 — Run V (Run W etc. as assigned) battery + decision
Methodology-conformant A/B vs the Run U binary
(benchmarks/runtime-calls.md: counters-lowered both sides, subst
workload, census-on, cold eco-stuff, interleaved ×3, GC stats from
captured stdout — the Run-T stdout lesson). Quantified predictions
(review requirement — direction and scale, stated before measuring):
`sat` must NOT increase (beyond tree-growth noise ~±0.01 %) and SHOULD
DROP — hoisted bodies' internal closure dispatches now run once per
process instead of per call. Scale bound: Run S removed −8.27 M
dispatches by memoizing 470 thunk-scale CAFs (whole decoder graphs);
here ~5-6 K far smaller bodies (Σ 62,988 nodes ≈ tens of nodes each,
many on cold paths) ⇒ predict `sat` −0.5 M to −10 M. Walls: −1–3 %
census-on, minors down (allocation elimination, the Run R/T pattern),
majors flat-or-down. Default-on iff every wall leg wins, `sat` does not
rise, and H3's lowering-wall growth stays < 2 %.

### H5 — Close-out
Invariant `CGEN_069` (hoisted-spec contract: append-only surgery field
list of §1 DQ5, layered-reachability guarantee, keyOf-dedupe closure-free
restriction, determinism requirements); docs (design doc §12 updated from
"future work" to shipped); memory; benchmark file *Next* paragraph.

## 5. Risks

| Risk | Mitigation |
|---|---|
| Un-noticed post-GlobalOpt consumer assumes `nodes`-parallel arrays (callEdges etc.) | verified consumers (§1 DQ5 table); entry assertions crash on length drift; H2 corpus + fixed point |
| Fusion regression despite root-head exclusion (BE nested deeper) | counted (`skippedBytes` counts root-level only; H0 adds contains-BE count); EOpaque backstop verified; H4 wall catches residue |
| Slot/root growth at 6 K scale | dedupe + floors + valve (§1 DQ1); H3 sweep before default-on |
| keyOf collision (two different exprs, one key) | unambiguous bracketed rendering + discriminator per constructor; collision ⇒ WRONG CODE (shared spec for different values) — H1 unit test includes near-miss pairs (same shape different literal/type/CallInfo); corpus is the broad net |
| Layered hoisting explodes slot count in pathological nests | layered-count census line (H0) before building; maxHoists valve |
| Hoisting moves a value into immortality that was huge and transient | same accepted CAF tradeoff; `minNodes` keeps floors low not ceilings — H3/H4 memory numbers (peak RSS in the battery timing files) decide |
| Compile-time cost of the pass itself | one fused walk per body + O(candidate) keyOf; report the pass wall in FEStats PhaseGlobalOpt (already timed) |

## 6. Budget question — direct answer (for the record)

Yes — but the census shows the binding constraints are *spec-count through
the backend* and *slot immortality*, not GC-root scanning. The layered
policy (floor + dedupe + valve + per-exclusion counters) turns "too much"
into measured dials, and H3 chooses them empirically. The valve default
(8192) exceeds the deduped expectation on today's tree, so in the normal
case it never binds; it exists so a pathological input (generated code,
elm-aws-codegen-class workloads) degrades gracefully instead of doubling
its spec count.
