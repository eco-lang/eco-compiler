# Effect-polymorphic purity — a conditional Debug-freedom oracle

**Status: PLAN v2 — 2026-08-14** (v1 draft adversarially verified by a
4-lens review against the tree; 35 findings — 7 blockers among them —
integrated below; not implementation-started)

Replace `CsePurity`'s boolean per-spec "transitively Debug-free" verdict with
a **conditional** one: each spec's summary becomes *"Debug-free iff the
function values bound to parameter positions S are Debug-free"*, instantiated
at call sites by substituting argument provenance. One analysis, one fixpoint,
consumed by MonoCse, the `List.map` template licence, and every future rung-2
template licence.

This plan **subsumes three follow-ups** recorded in
`plans/list-map-mlir-template.md`:

- **F-1's oracle layer** (bodiless specs can never be safe — the
  `declinedDebug = 50` mislabel);
- **F-3** (lambda-set-directed callee verdicts — the over-conservative
  `declinedHigherOrder`);
- **F-4** (argument-position taint — the HOF laundering soundness hole).

If this plan is executed, F-1(oracle)/F-3/F-4 are implemented AS ITS
CONSUMERS, not separately; the Phase-3 landing commit annotates them as
subsumed in `plans/list-map-mlir-template.md`. F-1's counter-honesty layer
and F-2 (the LSS budget) remain independent items.

## Problem statement — three measured defects, one root

`CsePurity.analyze` (`compiler/src/Compiler/GlobalOpt/CsePurity.elm:87-150`)
computes a `Set Int` of safe SpecIds by a poison-propagation fixpoint whose
`scanBody` (`:175-198`) treats the application of a function-typed **local**
(parameter or capture) as invisible: `MonoVarLocal` contributes neither poison
nor a call edge. Three defects follow, all confirmed on the self-compile
(2026-08-14, `plans/list-map-mlir-template.md` §"CORRECTION"):

1. **Starvation.** `bodyOf` returns `Nothing` for
   `MonoCtor`/`MonoEnum`/`MonoExtern`/`MonoManagerLeaf`, and the `Nothing` arm
   (`CsePurity.elm:99-106`) inserts into **neither** `direct` **nor** `edges`
   — so bodiless specs can never be safe, and since `scanBody` records ctor
   sids as callees, the poison propagates to every caller. Measured:
   `safeSpecs` = 17,531 of 30,905 specs; all 50 of the map template's
   `declinedDebug` are this, zero are genuine Debug (the artifact contains no
   `Elm_Kernel_Debug_log`/`_todo` at all). The in-code comment justifying the
   arm ("nothing calls them as specs, so the conservative answer costs
   nothing") is false on both clauses and dies with this plan.
2. **Shape-blindness at callee position.** `MapTemplate.applyTargetOk` is a
   pure shape predicate: a `MonoVarLocal` callee poisons even when its own
   lambda-set annotation is a resolved clean singleton. Measured: 4
   `declinedHigherOrder` at LSS budget 64, 24 at budget 1024.
3. **Laundering at argument position — a live soundness hole.** A function
   value in ARGUMENT position is inert to the walk. Kernel-HOF variant
   (`\x -> List.sortWith g x`, `g` a captured logging comparator): the callee
   is `MonoVarKernel` home `"List"` ≠ `"Debug"` ⇒ Clean, `g` is inert,
   kernels are never inlined and consult no `safeSpecs` — **licensable on
   today's tree** when the set is singleton and stamped, and the comparator's
   Debug lines would reorder (a D-4a violation; latent only because
   `list.mapTemplate` is default-OFF). Global-HOF variant
   (`\x -> Maybe.map g x`) is currently masked BY defect 1 — `Maybe.map`
   references the `Just` ctor and is therefore "unsafe" — so **fixing defect
   1 without fixing defect 3 opens the hole**. The two must land atomically,
   which is what makes them one plan rather than two follow-ups.

## Goal

1. A per-spec, per-lambda-set-member summary
   `Verdict = Unsafe Cause | SafeIf (Set ParamIdx)` computed by ONE
   interprocedural fixpoint over the union graph of specs and members, with
   call-site instantiation substituting argument provenance — so
   `mapWith g xs = List.map (\x -> g x) xs` gets the summary "safe iff `g`
   is", dischargeable where `g`'s provenance is visible.
2. The laundering hole closed: every executed call checks its
   arrow-carrying arguments against the callee's per-parameter discipline —
   summaries for Elm callees, a new audited KernelFacts axis for kernels,
   all-conservative for unknowns.
3. `MonoCtor`/`MonoEnum` admitted as unconditionally safe (pure
   constructions); `MonoExtern`/`MonoManagerLeaf` stay unsafe.
4. A new per-kernel per-parameter KernelFacts axis
   (`hofParams : List HofMode`, `PInvokes | PStoresOnly | POpaque`) audited
   from C++ bodies under KERNEL_FACTS_001 discipline. `PStoresOnly` is the
   refinement that makes Task/Decoder-building callbacks licensable: a
   stored-not-invoked closure fires nothing during the call, and an
   element-order template preserves result order, so nothing observable
   moves.
5. Consumers migrated: `MonoCse`+`CseCensus` (signature-stable, with the
   scope-free instantiation semantics defined below), the `MapTemplate`
   licence (replacing all three of its ad-hoc components), with the legacy
   boolean oracle preserved verbatim behind an escape hatch for bisection.
6. Artifact-inert at default config (both artifact-affecting consumers are
   default-OFF), with a byte-identity gate proving it.

## Files touched

- `compiler/src/Compiler/GlobalOpt/CsePurity.elm` — reworked in place: the
  conditional lattice, transfer function, union-graph SCC fixpoint,
  member layer, instantiation API. The legacy `analyze` path is preserved
  verbatim (renamed `analyzeLegacy`) behind the flag. Module doc rewritten;
  the false bodiless-arm comment replaced with the measured evidence.
- `compiler/src/Compiler/GlobalOpt/KernelFacts.elm` — the `hofParams` axis:
  stored field, `HofMode` type, V9/V10 validation rules, 11 audited rows.
- `compiler/src/Compiler/GlobalOpt/MonoCse.elm` +
  `compiler/src/Compiler/GlobalOpt/CseCensus.elm` — oracle construction and
  the `admit` twins move to the new API in lockstep; the CSE_001 Float-reach
  refusal lands here (Phase 3.1).
- `compiler/src/Compiler/GlobalOpt/MapTemplate.elm` — `debugFreedom`,
  `scanLambdaBody`, `applyTargetOk` deleted; licence queries the oracle;
  counters re-plumbed (see Phase 3).
- `compiler/src/Compiler/Eco/Config.elm` — flag `condPurity : Bool` (default
  ON at landing) + conditional hash token `condp=1` (see Flag & rollback;
  **not `cpur` — that token is TAKEN** by kernel-opt-12's `callPurityAttrs`,
  `Config.elm:726`). Registration follows the house 5-point checklist
  (kernel-opt-13's warning): exposing list, EcoConfig field appended at the
  END of the record, default row, POSITIONAL decoder apply in the same order,
  hash-token arm, env-override chain link — the decoder is positional and a
  misordered insertion silently mis-decodes every later field.
- `compiler/src/Builder/Eco/Config.elm` — `ECO_COND_PURITY` env read
  (uniform on/off parsing; NOTE the confusability with the existing
  `ECO_CALL_PURITY` — document both side by side) + `ECO_PURITY_REPORT`
  (output-only census).
- `compiler/src/Builder/Generate.elm` — census print site AND
  `runGlobalOptPhase` threading: `MonoCse.run` today receives only
  `{ minCost, maxPerDef }` (`Generate.elm:973-975`) and `CseCensus.report`
  only a label + minCost + graph (`:1036`) — both need the flag (or the
  `EcoConfig`) plumbed so `analyze` can route legacy/conditional.
- `design_docs/invariants.csv` — KERNEL_FACTS_001 amendment (Phase-1 commit,
  same commit as the field — the invariant as written PROHIBITS stored-field
  additions: "A consumer may add further COMPUTED projections to the module
  but may not add a stored record field"; the amendment is what licenses
  `hofParams`); a new OPT row for the oracle's soundness contract and the
  CGEN_078(a) licence-authority note (both in the Phase-3 rewire commit).
- `kernel-opt-status.md` — dated section at Phase-4 close (house state
  file).
- `benchmarks/kernel-opt.md` — Phase-0 baselines and Phase-4 census tables
  recorded there per the house protocol.
- Tests: KernelFacts validation suites (extend the kernel-opt-07 golden),
  oracle unit suites, E2E fixtures + codegen cases (Phase 3 list).
- `plans/list-map-mlir-template.md` — F-1(oracle)/F-3/F-4 annotated as
  subsumed, in the Phase-3 landing commit.

## Flag & rollback

- **`ECO_COND_PURITY`** (config `condPurity`, default **ON** at landing;
  `=0` is the escape hatch). One flag, front-end only — there is no backend
  half, so the two-layer bisection convention does not apply.
- **Legacy-mode projections are DEFINED, not implied.** Under
  `ECO_COND_PURITY=0`, `analyze` routes to `analyzeLegacy` (today's oracle,
  byte-for-byte) and the new API projects as: `specVerdict sid` =
  `SafeIf ∅` if `sid` is in the legacy set else `Unsafe COpaque`;
  `memberVerdict _` = `Unsafe COpaque` **always**. Consequence, stated
  plainly: the escape hatch does NOT reproduce today's `mapTemplate`-on
  licensing (today's three ad-hoc components no longer exist after Phase 3)
  — it reproduces something strictly MORE conservative (every licence
  declines), which is sound, keeps the laundering canaries green, and is
  exactly what a bisection arm needs. A Traps bullet forbids advertising it
  as behaviour-preserving for flag-on templates.
- **Hash token `condp=1`** appears iff
  `condPurity && (cse.enabled || list.mapTemplate)`. Rationale: the oracle
  affects ARTIFACTS only under those two flags (`MonoCse.run` is gated at
  `Builder/Generate.elm:973`; `MapTemplate.derive`'s artifact-affecting call
  sites self-gate on `list.mapTemplate` in `Generate/MLIR/Backend.elm`).
  Two additional consumers are output-only and contribute no token:
  `CseCensus.report` under `ECO_CSE_REPORT` (`Generate.elm:1032-1036` →
  `CseCensus.elm:163`) and the report-only `MapTemplate.derive` under
  `ECO_LIST_REPORT` (`Generate.elm:1095-1098`) — both also pay the analysis
  cost, which Phase 4's cost measurement includes. The conjunction keeps
  every default cache entry byte-stable while separating flag-on artifacts
  from their old-oracle ancestors. **This cross-flag conjunction is a NOVEL
  convention** — every existing conditional token (`lchunks=1`, `lcons=1`,
  `lmapt=1`) self-gates on its own feature flag only. Two consequences,
  recorded: (a) any FUTURE third artifact-affecting consumer of the oracle
  must extend the conjunction in the same commit or caches alias; (b) the
  token arm gets a comment naming this rule.
- Rollback = flip the default. `analyzeLegacy` is not scaffolding to delete
  later; it is the permanent bisection arm until a deliberate removal item.

## The analysis

### Summary lattice

```elm
type Cause
    = CDebug    -- a genuine Debug.* reference is on the poison path
    | COpaque   -- anything else unprovable (opaque global, blocked member,
                -- widened set, staged call, fixpoint bailout, ...)

type Verdict
    = Unsafe Cause
    | SafeIf (Set Int)   -- 0-based positions into the spec's/member's OWN
                         -- param row; SafeIf Set.empty = unconditionally safe
```

**Ordering** (v1-review blocker fix — the draft had this inverted, which
would have made the member meet INTERSECT condition sets and mis-license):
`SafeIf s1 ⊑ SafeIf s2` **iff `s1 ⊇ s2`** — more conditions = lower;
`Unsafe _` is bottom, below every `SafeIf`. The fixpoint seeds optimistic at
top (`SafeIf ∅`) and verdicts only DESCEND: condition accumulation is
descent, `Unsafe` absorbs. **Meet = `SafeIf (s1 ∪ s2)`** (union, never
intersection) with `Unsafe` absorbing. Chain height per node is
(#params + 2), so termination is structural.

**Cause is metadata riding outside the ordering** — both `Unsafe` forms are
the single lattice bottom. Cause-merge rule: `CDebug` dominates (any Debug on
any contributing path makes the combined cause `CDebug`), so the
`declinedDebug` counter never under-counts genuine Debug. Fixpoint bailout,
blocked members, and every other conservative arm carry `COpaque`. Accepted
limitation, recorded: one bit cannot distinguish a blocked-member decline
from a genuinely opaque callback — if Phase 4's counter reconciliation needs
that split, add a third cause then, not now.

Conditions are NOT restricted to `MFunction`-typed positions: a position
whose type is `MVar _ CEcoValue` can hide an arrow
(`Monomorphized.elm:247-253`), and the transfer function generates a
condition on whatever position gets applied or flows into an obligation.

### Provenance classification (the instantiation currency)

```elm
type Provenance
    = ProvClean          -- proven transitively Debug-free, unconditionally
    | ProvCond (Set Int) -- Debug-free IFF the ENCLOSING summary-holder's
                         -- listed param positions are; ProvCond ∅ ≡ ProvClean
    | ProvUnsafe Cause   -- everything unprovable
```

(`ProvCond` replaces the draft's `ProvParam i`, which could not express the
plan's own headline — a closure argument `\x -> g x` whose capture `g` is
the caller's param 0 is neither the param itself nor unconditionally clean;
it is `ProvCond {0}`. `ProvParam i` survives as the special case
`ProvCond {i}`.)

**The uniform discharge discipline** (one rule, ALL instantiation arms —
the draft stated three mutually inconsistent variants): when a callee
demands position `j` be Debug-free, classify `args[j]`:

- `ProvClean` — discharged;
- `ProvCond S` — the condition set `S` transfers wholesale into the
  CALLER's accumulating summary (sound for every invocation timing:
  a condition demands the VALUE be transitively Debug-free, which covers
  invoke-now and store-invoke-later alike);
- `ProvUnsafe c` — the caller's verdict becomes `Unsafe c`.

`classifyArg : Env -> Scope -> MonoExpr -> Provenance`, where

```elm
type alias Scope =
    Dict Name { prov : Provenance, verdict : Maybe Verdict }
```

threaded through the walk (MonoCse's binder-env is the precedent for WHY —
raw name matching à la `countLocalUses` is unsound under rebinding — but its
`List (Int, Name)` shape carries no provenance and is NOT reusable as-is).
`verdict` is present for arrow-typed bindings and is the binding's
**callable summary** (conditions over the binding's own params, captures
discharged at the binding site); `prov` is the binding's value-provenance.
Nested `MonoClosure` is a scope boundary — inner bodies see only
captures+params (`Generate/MLIR/Lambdas.elm:173-178`), so the env is rebuilt
from the closure's capture/param rows on entry.

| arg shape | provenance |
|---|---|
| `MonoVarLocal` = own param `i` | `ProvCond {i}` |
| `MonoVarLocal` = let-bound in scope | the stored `prov` |
| `MonoVarGlobal sid`, spec arity ≥ 1 (bare reference mints a value) | `ProvClean` iff `specVerdict sid == SafeIf ∅`; `ProvUnsafe` otherwise (a spec with residual conditions may NOT flow as a value — v1's no-PAP-forwarding) |
| `MonoVarGlobal sid`, spec arity 0 | **NOT a mint — nullary references EVALUATE** (see the transfer function); as a VALUE its provenance is that of its result: `ProvClean` iff `SafeIf ∅` |
| `MonoVarKernel home _` | `ProvClean` iff `home /= "Debug"` — a bare kernel reference mints a PAP; its invocation discipline is enforced at every `MonoVarKernel`-headed call (below) and, for kernel-origin members, by the member layer's `OriginKernel` arm |
| `MonoClosure info body` | walk `body` in a fresh scope; discharge capture conditions at THIS site against the enclosing scope; residual conditions over the ENCLOSING params → `ProvCond` of that set; any undischargeable capture → `ProvUnsafe` |
| non-arrow-typed expr (per `arrowAnnos`, arrows nowhere, `MVar` counts as arrow) | `ProvClean` **as a value** — but its EVALUATION is still walked by the ordinary recursion (a nullary Debug CAF passed as an Int argument poisons through the recursion, not through provenance) |
| arrow-typed anything else | resolve `headAnno (typeOf arg)`: `LSet ms` ⇒ `ProvClean` iff every member's verdict is `SafeIf ∅`, else `ProvUnsafe` (member conditions are not dischargeable at a bare flow position); `LTop` ⇒ `ProvUnsafe COpaque` |

`arrowAnnos : MonoType -> List LambdaSetAnno` walks the type; **`MVar` is
treated as "may contain an arrow"** and contributes an `LTop`, or the
erased-poly path reopens the laundering hole. **`MCustom` recurses its TYPE
ARGUMENTS, which is NOT field coverage** (corrected 2026-08-14 after the
list-map follow-ups review found the same wording error in both plans):
`MCustom Int Canonical Name (List MonoType)` carries instantiated type
arguments — `Dict k v` with a function `v` IS seen, but a closure stored in
a CONCRETE field (`type Wrap = Wrap (Int -> Int)`) is invisible. In THIS
plan the exposure is confined to the unaudited-kernel and bare-flow ladder
paths — global callees are covered structurally, because the extraction and
application happen inside the callee's own body, where its summary sees the
applied local and generates the condition. Record the residual; a v2 of
`arrowAnnos` can consult ctor-shape/layout metadata for arrow-kinded
fields. `arrowAnnos` is a pure type walk and is a **Phase-0 deliverable**
(the census needs it before the analysis exists).

### Transfer function (per body; one walk; scope threaded)

Extends `scanBody`. State: current verdict (descending; conditions
accumulate; `Unsafe` absorbs, `CDebug` dominating) + the `Scope`. Cases:

- `MonoVarKernel _ _ "Debug" _ _` → `Unsafe CDebug` (the only genuine
  direct poison).
- `MonoVarKernel` other, value position → clean (PAP mint; the value-flow
  discipline is the receiving call's / member layer's business).
- `MonoVarGlobal sid`, value position, **spec arity ≥ 1** → clean for
  evaluation (referencing a function runs nothing); the referenced verdict
  matters only when the value flows into an invocation, which `classifyArg`
  covers. Arity comes from the spec node's param row
  (`MonoClosure closureInfo` params / `MonoTailFunc` params), not from the
  type.
- `MonoVarGlobal sid`, value position, **spec arity 0** → **instantiate
  `specVerdict sid` as a saturated zero-arg call.** A bare reference to a
  nullary spec IS an evaluation: `generateVarGlobal`
  (`Generate/MLIR/Expr.elm:658-697`) lowers it as a direct call of the
  thunk — the body runs at every reference, or at first touch under CAF
  memoization (CGEN_068; CGEN_069 excludes Debug-referencing exprs from
  CafHoist for exactly this reason). The draft's blanket
  "referencing runs nothing" was a v1-review blocker: `f x = if x then a
  else b` with `a`,`b` nullary Debug CAFs must NOT be `SafeIf ∅`.
- `MonoCall _ func args _ callInfo` → **all args always recurse as ordinary
  expressions first** (their evaluation effects count regardless of any
  invocation discipline below — this sentence applies to EVERY callee arm,
  kernel arms included). Then resolve the callee:
  - **`MonoVarGlobal sid`, first-stage saturated**
    (`callInfo.isSingleStageSaturated`; the `isDirectSaturated` shape,
    `Borrow/Constrain.elm:931-946`): instantiate `specVerdict sid` under the
    uniform discharge discipline. Non-condition args have already recursed.
  - **`MonoVarGlobal sid`, args < first stage** (pure PAP mint, arity ≥ 1):
    no body runs ⇒ clean as an evaluation; the VALUE's flow is governed by
    the `classifyArg` rows (a conditioned spec flowing as a value is
    `ProvUnsafe` — v1 declines PAP condition-forwarding; the unit suite pins
    the `let p = f debugF in p x` shape, which must come out `Unsafe`).
  - **over-application / staged** (`remainingStageArities` non-trivial):
    `Unsafe COpaque`, counted (`declinedStaged` in the census). v1 does not
    model multi-stage position mapping. (The draft cited the borrow census's
    `poisoningCallSites=46,621` as sizing here — that counter measures
    saturated calls forcing owned args, NOT staged sites; the citation was
    wrong and is dropped. `declinedStaged` itself is the sizing instrument,
    which is why it exists from Phase 2 day one.)
  - **`MonoVarKernel home name`**: `home == "Debug"` → `Unsafe CDebug`.
    Else fetch `hofParams` and apply the invocation discipline **over
    whatever argument prefix is supplied — saturated or mint** (a partial
    kernel application like `List.sortWith debugCmp` checks its one supplied
    arg NOW; obligation-at-mint is deliberately conservative so soundness
    never rests on the ladder's behaviour for kernel PAPs): audited row →
    per supplied position, `PInvokes`/`POpaque` demand discharge per the
    uniform discipline; `PStoresOnly` adds NO invocation obligation (the
    arg's evaluation was already walked). Unaudited axis (`hofParams == []`)
    or unlisted kernel → every arrow-carrying supplied arg (per
    `arrowAnnos`, `MVar` included) demands discharge.
  - **`MonoVarLocal` = own param `i`**: add condition `i`; arrow-carrying
    args of this call discharge under the uniform discipline (`ProvCond`
    transfers — sound, because a condition demands transitive
    Debug-freedom of the value, covering whatever the unknown callee does
    with it).
  - **`MonoVarLocal` = let-bound**: the scope entry's stored **callable
    verdict**, instantiated against these args under the uniform
    discipline; no stored verdict (non-arrow or unprovable binding) →
    `Unsafe COpaque`.
  - **`MonoClosure`**: walk the closure body inline in the extended scope
    (beta-style; the immediately-applied-lambda case).
  - **anything else** (case result, record access, …): the ladder —
    `headAnno (typeOf func)`: `LSet ms` ⇒ meet the members' verdicts (union
    of conditions, `Unsafe` absorbing) and instantiate against these args
    under the uniform discipline, **but only when the call saturates the
    member's own first-stage arity** — a partial application of a member
    value leaves conditions with no corresponding args, so it is
    `Unsafe COpaque` (counted with `declinedStaged`). Condition indices
    always refer to the member's FULL own param row, never a partial
    prefix. `LTop` ⇒ `Unsafe COpaque`.
- `MonoTailCall name args _` → **a saturated call to its named target, not
  a bare self-edge** (v1-review blocker: tail calls REBIND the target's
  parameters — `loop f n = ... loop (\x -> Debug.log "boom" x) (n-1)`
  must poison, and the draft's "self-edge; SCC handles it" missed the
  args entirely). Instantiate the target's in-flight verdict against the
  tail-call args (by the target's param order) under the uniform
  discipline; args recurse as ordinary expressions. Two targets exist:
  the enclosing spec itself (the SCC's in-flight table serves the verdict)
  and a local `MonoTailDef` (its callable verdict from the scope entry,
  below).
- `MonoLet (MonoTailDef name params body) …` → the tail def is walked
  INLINE in the spec's scope extended with its own params: the tail def's
  OWN params are classified via the ladder on their type annotations
  (never `ProvCond` over the spec's row — they are a different binder
  space); references to ENCLOSING spec params still generate spec
  conditions. The binding's scope entry stores the callable verdict thus
  derived (conditions over the tail def's own params). `MonoTailCall` to it
  instantiates that verdict.
- `MonoLet (MonoDef name rhs) …` → walk `rhs` (evaluation effects count),
  then store the scope entry: `prov` = `classifyArg` of the RHS; `verdict`
  (arrow-typed bindings) = the RHS's **callable summary** — for a
  `MonoClosure` RHS, the body's verdict with captures discharged at the
  binding site; for a PAP-mint RHS, `Unsafe COpaque` under v1's
  no-forwarding (the unit-suite shape above); for a bare clean global,
  its `specVerdict`. Never store the RHS's evaluation contribution as its
  callable verdict — the two are different quantities.
- All remaining constructors (`MonoIf` branches+final, `MonoCase` deciders
  via `foldDecider`, `MonoDestruct`, containers, record ops) recurse
  exhaustively — the arm list must stay exhaustive exactly as
  `CsePurity.foldChildren` (`:313-371`) is today, so a new `MonoExpr`
  constructor breaks the compile rather than being silently skipped.
- Bodiless specs (fixing defect 1): `MonoCtor`/`MonoEnum` → `SafeIf ∅`;
  `MonoExtern`/`MonoManagerLeaf` → `Unsafe COpaque`.

### Fixpoint — ONE pass over the union graph

**A single fixpoint over the union graph of specs AND members** (v1-review
blocker: the draft sequenced "specs first, then members", but the transfer
function's ladder arm consults member verdicts — mid-spec-fixpoint the
member table would not exist, and any optimistic reading there ships
unrevisited optimism into settled spec verdicts, which is unsound; a
pessimistic reading would re-break F-3. The union graph dissolves the
ordering question).

Nodes: SpecIds ∪ member ids. Edges: `MonoVarGlobal` instantiations,
tail-call targets, ladder-resolved member references, member-instance
bodies' references (both directions). Driver: the Borrow SCC shape
(`Borrow.elm:364-571` — collect edges, `Graph.stronglyConnCompInt`, fold
reverse-topologically; acyclic nodes solve once; cyclic SCCs seed optimistic
`SafeIf ∅` and iterate to fixpoint with `maxIter = 20`, bailing out to
`Unsafe COpaque` — `Borrow.elm:120,532`; Borrow itself copied the SCC
utilities from MonoInlineSimplify, so copying again is the house pattern,
~150 lines). Everything descends from optimistic top, meets union
conditions, `Unsafe` absorbs — monotone on a finite lattice, so convergence
is structural; Borrow's observed 2-3 iterations per SCC (`Borrow.elm:70`) is
the expected regime.

### Member verdicts (nodes of the same fixpoint)

- **Closure members** (`LssFacts.buildInstances`,
  `Borrow/LssFacts.elm:76-118`, reused as-is): per instance, walk the body;
  conditions may accumulate over the member's own params AND its captures.
  Capture conditions discharge **at the creation site** against the
  enclosing scope — a capture expr is a `(name, MonoVarLocal name ty, _)`
  reference into the enclosing scope
  (`Monomorphize/Closure.elm:143-191`) — under the uniform discipline:
  `ProvClean` discharges; **`ProvCond S` makes the instance's verdict
  conditional on the ENCLOSING spec's positions `S` — which is only
  meaningful where that spec's summary is being built, i.e. during the
  enclosing body's walk (this is exactly how `mapWith`'s `List.map` call
  transfers `g`'s condition). For the member's CONTEXT-FREE verdict (what
  the ladder and `memberVerdict` serve), a `ProvCond`-captured instance is
  `Unsafe COpaque`** — a context-free verdict cannot reference another
  spec's param space. Instance meet = union of conditions over the
  member's own params, `Unsafe` absorbing. Adopted/wrapper-homed members
  are blocked → `Unsafe COpaque` (inherit the LssFacts discipline).
- **Standalone members** (v1-review major: the draft had NO arms here, and
  its "zero instances ⇒ Unsafe" trap would have re-broken F-3 — kernel-alias
  and global members have no closure instances BY CONSTRUCTION). Resolve
  through `lssMemberOrigins`:
  - `OriginKernel home name` → `Unsafe CDebug` iff `home == "Debug"`, else
    the verdict derived from `hofParams` (conditions on the
    `PInvokes`/`POpaque` positions of ITS param row; unaudited ⇒ conditions
    on every arrow-carrying position per the kernel's declared arity when
    known, else `Unsafe COpaque`);
  - `OriginGlobal g` → the resolved spec's `specVerdict` (via the
    `matchGlobal` layout match, `LssFacts.elm:278-290`; unresolved/ambiguous
    ⇒ `Unsafe COpaque`);
  - `OriginCtor`/`OriginAccessor` → `SafeIf ∅`;
  - a miss in BOTH `byMember` and `origins` → `Unsafe COpaque`.
- Subst engine: the member layer's instance tables may still build
  (`srcLambda` persists regardless of engine — do NOT use `byMember`
  emptiness as a subst detector), but on all-`LTop` graphs `headAnno` is
  never `LSet`, so the ladder resolves nothing and answers
  `Unsafe COpaque`; `lssMemberOrigins` IS empty under subst
  (`Monomorphized.elm:1405`). The param-obligation layer still functions
  syntactically; consumers decline exactly as their existing subst-engine
  arms do.

### v1 policy decisions (recorded, revisitable)

- Instantiation only at first-stage-saturated calls (specs, members alike);
  staged/over-application is `Unsafe COpaque`, counted as `declinedStaged`
  — which is also the sizing instrument for whether a v2 staged model is
  worth building (no pre-existing census measures this population).
- No PAP condition-forwarding: a conditioned spec/member flowing as a VALUE
  is `ProvUnsafe`; only `SafeIf ∅` values flow clean.
- Context-free member verdicts never range over another spec's params
  (`ProvCond` captures poison the context-free verdict; the condition
  transfers only inside the enclosing body's own walk).
- Kernel `hofParams` obligations are checked at every
  `MonoVarKernel`-headed call over the supplied prefix, mint included.
- Two axes stay separate: this oracle answers **Debug-freedom of
  evaluation** (the D-4a obligation). Kernel `cseSafe` (merge/erase licence)
  remains the independent per-site check in `isSafeExpr`
  (`CsePurity.elm:207-233`); `hofParams` feeds ONLY the Debug-freedom axis.
  `PStoresOnly` in particular is NOT a merge licence.

## The KernelFacts axis

KERNEL_FACTS_001 (`design_docs/invariants.csv:643`) makes the table the only
source of per-kernel semantic facts, forbids consumer-side name lists, and —
quoted accurately — states *"A consumer may add further COMPUTED projections
to the module but may not add a stored record field"*. **The `hofParams`
stored field is therefore admissible only via the KERNEL_FACTS_001 amendment
itself, which lands in the same Phase-1 commit as the field** (house
convention: invariant changes ride the commit that makes them true).

```elm
type HofMode
    = PInvokes     -- the C++ body may apply this argument during the call
    | PStoresOnly  -- the C++ body stores it (heap/task cell) and provably
                   -- never applies it before returning
    | POpaque      -- audited row, this position not determined

-- in KernelFacts, after `params`:
, hofParams : List HofMode   -- [] == HOF axis NOT audited (sentinel, the
                             -- `params` borrow-axis convention)
```

Validation additions (`rowErrors`, after V8):

- **V9**: `hofParams /= [] && params /= []` ⇒ lengths equal.
- **V10**: any `PInvokes` ⇒ `callsBackIntoElm` (V5 then already forces
  `GcUnbounded` and `totality /= Total` — the constraint system composes).

Phase-1 audits — the rows with function-typed arguments, each with its C++
evidence anchor (v1-review correction: `sortBy` and `sortWith` invoke the
user callback at DIFFERENT sites and must not share an anchor):

| row | verdict | evidence |
|---|---|---|
| `JsArray.foldl` / `foldr` / `map` / `initialize` | `PInvokes` on the callback | `elm-kernel-cpp/src/core/JsArrayExports.cpp:463ff` (map applies per element; re-anchor each row at audit) |
| `List.map2` | `PInvokes` | `elm-kernel-cpp/src/core/ListExports.cpp` (audit anchor) |
| `List.sortBy` | `PInvokes` — the user callback runs in the KEY-EXTRACTION loop before the sort (`callUnaryClosure`); the comparator inside `std::stable_sort` compares precomputed keys via `Utils::compare` and never calls user code | `ListExports.cpp:~700-706` |
| `List.sortWith` | `PInvokes` — the user comparator runs INSIDE `std::stable_sort` | `ListExports.cpp:779`, `callBinaryClosure ~:790` |
| `String.all` | `PInvokes` | `StringOps` audit anchor |
| `Scheduler.andThen` / `onError` | `PStoresOnly` (continuation stored in the task cell, never applied — `Scheduler::taskAndThen` builds `Task_AndThen` and returns; `runtime/src/platform/Scheduler.cpp:149-152`) | anchor as cited |

`Bytes.encode`/`decode` take closure-CARRYING values (Encoder/Decoder), not
function params — `POpaque` at audit or deferred. Kernels absent from the
table entirely (`Json.Decode.map*/andThen`, `String.map/filter/foldl/foldr`,
`List.map3-5`) stay conservative until audited; each later audit is an
independent, incremental strengthening under the existing discipline.

## Approach

### Phase 0 — censuses and baselines (no artifact-affecting change)

1. **`arrowAnnos` lands here** (a pure ~30-line type walk with unit tests;
   the census below needs it and Phase 2 reuses it — the draft had it in
   Phase 2, which made this census unimplementable as ordered).
2. **Payoff sizing BEFORE building** (`ECO_PURITY_REPORT=1`, output-only,
   printed beside `[list-combinators]`): count specs with ≥1 arrow-carrying
   param (`arrowAnnos` over param rows; no such census exists —
   `hasCalledFunctionParam`, `MonoInlineSimplify.elm:1540-1560`, is the
   reusable called-vs-stored distinction); count first-stage-saturated call
   sites passing arrow-carrying args; count call sites whose callee is one
   of the HOF kernel rows. These bound the conditional-summary population
   and the discharge opportunities.
3. Record baselines in `benchmarks/kernel-opt.md`: elm-tests count
   (13,085/12 known red), full E2E count (1,664), the CSE census line under
   `ECO_CSE_REPORT=1` (`specs=30905 safeSpecs=17531` is the standing
   reference), the `[map-template]` stats line at LSS budget 64 AND 1024
   (both already recorded in `plans/list-map-mlir-template.md`), and — under
   `ECO_CSE=1` — the MonoCse merge count (`81` is the kernel-opt-13
   reference).
4. Reproduce the laundering hole by hand ONCE (an `ECO_LIST_MAP_TEMPLATE=1`
   compile of a `\x -> List.sortWith g x` callback; confirm it licenses and
   record the emitted op) — the Phase-3 canary pins this; no red fixture
   lands now.

### Phase 1 — KernelFacts axis (table-only; artifact-inert)

1. Add `HofMode`, the `hofParams` field (default `[]` in `unaudited` and
   `auditedPure` bases), V9/V10, **and the KERNEL_FACTS_001 amendment in
   the same commit**.
2. Audit the rows per the table above; every changed row re-anchors its
   `evidence`.
3. Extend the KernelFacts unit/golden suites (kernel-opt-07's seven suites;
   the golden count grows and the growth is the review artifact).
4. Gate: elm-tests green (modulo the standing 12); no compiled-output change
   anywhere (no consumer reads the axis yet).

### Phase 2 — the oracle (flag exists, default OFF until Phase 3)

1. `CsePurity.elm` rework: `Cause`/`Verdict`/`Provenance`/`Scope`,
   `classifyArg`, the transfer function, the union-graph SCC driver
   (copied), the member arms, and the API:

   ```elm
   analyze       : Config.EcoConfig -> Mono.MonoGraph -> Oracle  -- routes legacy/conditional
   isSafeExpr    : Oracle -> MonoExpr -> Bool                    -- signature UNCHANGED
   isSafeCall    : Oracle -> MonoExpr -> Bool                    -- signature UNCHANGED
   specVerdict   : Oracle -> Int -> Verdict
   memberVerdict : Oracle -> Int -> Verdict                      -- MapTemplate's query
   ```

   **`isSafeExpr` semantics, defined precisely** (the draft's "no plumbing
   changes needed, binders in hand" was a v1-review blocker — with the
   signature unchanged, no binder env reaches `isSafeExpr`; MonoCse's
   `binders` are depth+name pairs without provenance, `collect` seeds them
   empty (`MonoCse.elm:207-211`), and the CseCensus twin has none at all):
   `isSafeExpr` instantiates with a **scope-free** `classifyArg` — globals
   (`specVerdict`), kernels, inline closures, non-arrow types, and the
   type-annotation ladder are classifiable; **any `MonoVarLocal` (or
   otherwise unprovable expr) in an obligation position is `ProvUnsafe`**;
   and **at a CSE site only a fully discharged `SafeIf ∅` admits — residual
   or transferred conditions ALWAYS decline** (there is no caller summary
   under construction at a CSE site to transfer into; admitting a
   `ProvCond` there would merge two occurrences that each invoke the
   enclosing function's arrow param — halving a possibly-logging callback's
   invocation count, an OPT_DEBUG_ORDER_001 D-2 violation).
2. **Transitional legacy-view accessor** (v1-review major — the phase
   boundary is otherwise unbuildable): Phase 2 also ships
   `safeView : Oracle -> Set Int` = the sids whose verdict is **exactly
   `SafeIf ∅`**, and the UN-rewired consumers (`MonoCse`'s current
   `oracle.safeSpecs` field read; `MapTemplate.elm:511`'s direct
   `env.purity.safeSpecs` read) compile against it unchanged. This
   projection keeps `Maybe.map` conservative during the window in which the
   ctor fix has landed but the MapTemplate rewire has not — `SafeIf ∅`-only
   is strictly tighter than "any SafeIf" — so **the two-bugs-cancel trap
   stays closed through the phase boundary**; a sentence in the code says
   exactly this.
3. Import note: `CsePurity` gains `Borrow.LssFacts`. Verified acyclic
   against the transitive closure — `LssFacts` imports `Monomorphized`,
   `Data.Id`, `Borrow.KernelSigs`, `Borrow.Mode`, `Borrow.Sig`,
   `Staging.Rewriter`, `Monomorphize.MonoTraverse` (the FULL list; the
   draft's shorter list was wrong), and nothing in that closure imports
   `CsePurity` (its only importers are `MonoCse`, `CseCensus`,
   `MapTemplate`). Both module docs get the anyone-importing-CsePurity-
   from-Borrow/-recreates-the-cycle warning.
4. Census line
   `[cond-purity] specs{safe= cond= unsafeDebug= unsafeOpaque=} members{safe= cond= unsafeDebug= unsafeOpaque= blocked=} calls{instantiated= discharged= transferred= declinedStaged=} scc{cycles= maxIter= bailouts=}`
   under `ECO_PURITY_REPORT=1`.
5. Unit suites (TestLogic style, small hand-built graphs), one per transfer
   arm that changed behaviour: direct Debug; ctor-referencing spec now safe;
   **nullary-CAF reference instantiates** (the `if x then a else b` shape);
   condition generation on param apply; condition transfer through a
   saturated call; `ProvCond` closure argument (the `mapWith` shape,
   end-to-end through the `List.map` summary); **tail-call rebinding
   poisons** (the `loop` shape); **`let p = f debugF in p x` is `Unsafe`**
   (PAP-mint callable verdict); MonoTailDef param-space separation; kernel
   `PInvokes` obligation; `PStoresOnly` non-obligation BUT arg-evaluation
   still walked (`Scheduler.andThen (Debug.log "x" k) t` poisons); kernel
   obligation at a PARTIAL kernel application; unaudited-kernel
   conservatism; ladder saturation gate (under-applied member declines);
   standalone member arms (kernel alias clean, kernel-Debug poison, ctor
   clean, global delegate); MVar-hides-arrow poison; capture discharge
   clean/`ProvCond`/unsafe; instance meet UNIONS conditions (the
   two-instance counterexample from the review, pinned); cause dominance
   (`CDebug` wins a meet); SCC cycle convergence + bailout-to-`Unsafe`.
6. Gate: elm-tests; and with the flag FORCED ON in a scratch config (both
   consumers still on `safeView`), the full E2E battery green in both
   `list.mapTemplate` states.

### Phase 3 — consumers (ONE commit: rewires + fixtures + default flip)

Mid-landing failure protocol: revert the WHOLE commit — never land the
fixtures, the rewires, or the flip separately (the fixtures encode the
post-rewire semantics and are red against any partial state).

1. **MonoCse/CseCensus**: both `admit` twins move from `safeView` to the
   conditional `isSafeExpr` (lockstep rule: `MonoCse.elm:578-580`).
   **In the same commit, implement the CSE_001 Float-reach refusal in both
   twins** — CSE_001 (invariants.csv) requires MonoCse to "refuse candidates
   whose result type can reach a Float" BEFORE the pass is ever enabled (the
   Run-R NaN-sharing miscompile); that refusal does not exist in
   `MonoCse.elm`/`CseCensus.elm` today and was partially masked by exactly
   the ctor starvation this plan removes (ctor-built Float-capable results
   were all "unsafe"). Un-starving without the refusal walks the `ECO_CSE=1`
   gate leg straight into the known miscompile. The
   `ContainerEquality*Float*` test family joins the named expectations of
   that leg.
2. **MapTemplate**: delete `debugFreedom`/`scanLambdaBody`/`applyTargetOk`;
   the licence gate becomes: singleton member → `memberVerdict` —
   `SafeIf ∅` licenses; `SafeIf S` (undischargeable at a spec-body licence)
   declines as **`declinedCondition`** (new counter); `Unsafe CDebug`
   declines as `declinedDebug` (finally truthful); `Unsafe COpaque` as
   **`declinedUnsafeCallback`**. Gate-3 reconciliation becomes
   `licensed + declinedDebug + declinedUnsafeCallback + declinedCondition +
   declinedWidened + declinedMultiMember + declinedEngine + declinedChunksOff
   + declinedShape + declinedNoStamp == recognized`.
3. **Fixtures and their PINS** (v1-review major: a licensed Debug-free
   callback is observationally IDENTICAL to the declined foldr path — that
   is D-4a's whole point — so a behavioural `.elm` fixture CANNOT pin the
   positive direction; every "must license" case pins via the census
   and/or a codegen CHECK, the mechanism the list-map plan's Outcome
   owed-item (b) already records):
   - `ListMapTemplateLaunderedDebugTest.elm` — kernel-HOF laundering canary
     (`List.sortWith` with a captured logging comparator): behavioural pin
     (foldr order both flag states). RED on the pre-fix tree by design;
     lands only in this commit.
   - A global-HOF laundering variant (non-inlinable helper applying a
     captured function) — behavioural pin; covers the F-1-interaction case
     the ctor bug currently masks.
   - `ListMapTemplateCtorCallbackTest.elm` (`\x -> Just x` + a custom-ctor
     callback): behaviour pin PLUS a `test/codegen/` case with a
     `CHECK: eco.list.map` on its emitted spec PLUS the census expectation
     below.
   - `ListMapTemplateStoresOnlyTest.elm` (Task-building callback through
     `Scheduler.andThen`): behaviour pin + census expectation.
   - Conditional-discharge positive (`mapWith` + clean named function):
     unit-suite pin (the end-to-end `ProvCond` case) + census expectation;
     the Debug variant extends `ListMapTemplateCapturedDebugTest`.
4. Gate: full E2E battery in: default; `ECO_LIST_MAP_TEMPLATE=1`;
   `ECO_CSE=1`; `ECO_COND_PURITY=0` alone; and
   `ECO_COND_PURITY=0 ECO_LIST_MAP_TEMPLATE=1` (this leg exercises the
   defined legacy projection: every licence declines, canaries stay green —
   it does NOT reproduce old licensing, per Flag & rollback).

### Phase 4 — measurement + default decision

1. **Byte-identity at default config** (the load-bearing gate): pre-change
   vs post-change binary on the independent corpus (`test/stress-elm`, the
   corrected Gate-2 method from `plans/list-map-mlir-template.md` — the
   self-compile corpus grows by this plan's own source, so self-compile
   byte-identity is unsatisfiable by construction; use corpus-independent
   identity + additive-only symbol reconciliation on the self-compile).
2. **Licence-pool acceptance criteria, numeric** (v1-review major — "measure,
   do not predict" is not an acceptance test):
   - `declinedDebug == 0` exactly, at budgets 64 and 1024 (zero Debug in
     this source closure is an established fact);
   - the old 50 mislabelled declines are EXACTLY absorbed by
     `licensed + declinedUnsafeCallback + declinedCondition` (reconciled
     per-population, both budgets);
   - **regression criterion**: no site licensed by the OLD oracle-set
     becomes unlicensed except sites the new kernel-argument obligations
     genuinely convict — enumerate any such sites by hand (expected ≈ 0 on
     this corpus) before accepting;
   - the CSE census re-run records the new safe-spec figure (from 17,531).
3. `ECO_LIST_MAP_TEMPLATE=1` full battery + flag-on bootstrap fixed point
   (licensing changed ⇒ Stage-8c must reconverge; the list-map plan's
   Gate-6 method) + one heap-validate flag-on leg (more sites templated; no
   new lowering, but the population grows — cheap insurance).
4. **Wall protocol**: the oracle is front-end-only and both artifact
   consumers stay default-OFF, so the full `benchmarks/kernel-opt.md`
   GC-counter A/B is **deliberately waived** for the default config (one
   sentence in the run entry records the waiver and the trigger for
   revisiting: any default-ON proposal for `list.mapTemplate` or
   `cse.enabled` re-runs it). What IS measured: FE time of `analyze` on the
   self-compile under `ECO_LIST_MAP_TEMPLATE=1` (and once under
   `ECO_PURITY_REPORT=1` alone for the census paths); >2s triggers a perf
   sub-item before any default-ON.
5. Default decision for `condPurity` per the criteria above; KEEP-ON is
   expected since default config is artifact-inert. Record the outcome
   here either way; add the dated section to `kernel-opt-status.md` and the
   run entry to `benchmarks/kernel-opt.md`.

## Traps & risks

- **The two-bugs-cancel trap** (the reason this is one plan): admitting
  ctors as safe without the argument-position rule opens the global-HOF
  laundering path. Both live in one transfer function here, and the
  Phase-2 `safeView` projection (`SafeIf ∅`-only) keeps the trap closed
  through the phase boundary; Phase 3 is one commit.
- **The lattice direction is load-bearing**: meet must UNION condition sets
  (`Unsafe` absorbing). An intersection meet — the natural reading of the
  v1 draft's inverted ordering — mis-licenses two-instance members (the
  review's counterexample is a Phase-2 unit test). If an implementation
  disagreement arises, the unit test wins.
- **Nullary references evaluate.** Any "bare reference is clean" reasoning
  must check the spec's arity; CGEN_068/069 document the thunk-call
  lowering. The `if x then a else b` CAF shape is the pinned regression.
- **Tail calls rebind.** `MonoTailCall` is an instantiation site, never a
  bare edge.
- **Erased polymorphism hides arrows**: `MVar _ CEcoValue` params/args are
  arrow-carrying for every rule (`arrowAnnos` yields `LTop` for `MVar`).
- **Scoping**: raw name matching is insufficient — thread `Scope`;
  `MonoClosure` is a boundary; `MonoTailDef` params are a separate binder
  space from the spec's row.
- **CseCensus twin drift**: the census `admit` mirror moves in the same
  commit as MonoCse's (`MonoCse.elm:578-580` names the rule) — and neither
  twin has (nor gets) a binder env: the CSE-site semantics are scope-free
  by definition (Phase 2.1).
- **CSE_001 composes with this plan**: un-starving ctor-built specs exposes
  Float-capable CSE candidates; the Float-reach refusal lands WITH the
  widening (Phase 3.1), never after.
- **SpecId staleness**: consumers derive the oracle from the graph THEY
  hold (post-CafDedupe/CafHoist for emission consumers — the Borrow rule,
  `Borrow.elm:255-259`); never compute once mid-pipeline and carry forward.
- **KERNEL_FACTS_001 discipline**: no consumer-side kernel name lists — the
  transfer function reads ONLY `hofParams`; unlisted/unaudited ⇒ the
  conservative arm. Audits only strengthen; every row change re-anchors
  evidence; the invariant amendment rides the Phase-1 commit.
- **Axis separation**: `hofParams` feeds Debug-freedom only. Feeding it
  into merge/erase decisions would need its own soundness argument —
  explicitly out of scope.
- **Staged/curried calls**: `MonoCall` arg count alone says nothing —
  always consult `CallInfo`; the ladder arm has the same saturation gate as
  the direct arm.
- **The escape hatch is not behaviour-preserving for flag-on templates**
  (defined projections, Flag & rollback) — never advertise it as such; its
  gate legs assert the CONSERVATIVE behaviour.
- **Bailout direction**: fixpoint non-convergence at `maxIter` poisons
  (`Unsafe COpaque`); never ship an optimistic residue.
- **Import cycle watch**: `CsePurity → Borrow.LssFacts` is acyclic today;
  anything later importing `CsePurity` from the `Borrow/` subtree recreates
  the cycle — noted in both module docs.

## Dependencies

`LssFacts` (buildInstances + the resolution ladder), `KernelFacts` +
KERNEL_FACTS_001 (amended Phase 1), `CallInfo` staging metadata (GlobalOpt
phase 5), the SCC utilities (copied, per house precedent), `MapTemplate` +
`eco.list.map` (landed, `plans/list-map-mlir-template.md`), LSS solver
engine for the member layer (subst degrades gracefully). Composes with, but
does not depend on, F-2 (the LSS budget): the two multiply — the budget
grows the pool this oracle can then license precisely.

## Expected impact

Honest framing: **a precision-and-soundness foundation, not a pool
expander.** The map-template licence pool stays bounded by the LTop/budget
wall (F-2 moves that more than this does). What this buys:

- The D-4a licence becomes actually sound (laundering closed) — a
  prerequisite for ANY `list.mapTemplate` default-ON decision and for every
  future rung-2 template licence (`map2`, `filter`, `filterMap` inherit the
  oracle for free).
- The 50-spec mislabel population becomes licensable, with the Phase-4
  numeric acceptance criteria as the proof (`declinedDebug == 0`; exact
  absorption of the 50).
- `safeSpecs` un-starves for flag-on CSE (from 17,531/30,905) — dark today,
  but every future CSE revisit inherits the honest oracle, WITH the CSE_001
  Float guard finally implemented.
- `PStoresOnly` opens the Task/Decoder-building callback family.
- The false `CsePurity` comment and the three ad-hoc MapTemplate licence
  components are deleted — one oracle, one soundness argument.

## Gates

1. elm-tests green (standing 12 only) after every phase; KernelFacts golden
   growth reviewed at Phase 1.
2. Phase-2 unit suites all green — including the lattice-direction
   counterexample, the nullary-CAF shape, the tail-call rebinding shape,
   and the PAP-mint let shape; fixpoint convergence stats printed and sane
   (zero bailouts on the self-compile).
3. Full E2E battery at Phase 3+: default, `ECO_LIST_MAP_TEMPLATE=1`,
   `ECO_CSE=1` (with the `ContainerEquality*Float*` family called out),
   `ECO_COND_PURITY=0`, and `ECO_COND_PURITY=0 ECO_LIST_MAP_TEMPLATE=1`.
4. Byte-identity at default config on the independent corpus; additive-only
   reconciliation on the self-compile.
5. `[map-template]` reconciliation with the new counter set, exact; the
   Phase-4 numeric acceptance criteria (declinedDebug == 0; absorption of
   the 50; no un-enumerated licence regressions).
6. Laundering canaries green (and demonstrably red against a pre-fix
   compiler — run once in Phase 0, recorded, not landed red).
7. Flag-on bootstrap Stage-8c fixed point; heap-validate flag-on leg.
8. FE analysis cost recorded (consumer paths AND census-only paths); >2s on
   the self-compile triggers a perf sub-item before default-ON.

## Outcome

_To be filled after implementation._
