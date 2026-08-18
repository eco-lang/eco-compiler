# LSS Fidelity 3 — Signature Set-Flow (GAP-2), Re-Census, and the Completeness Follow-Ons (GAP-4/5/6/7, GAP-9 repair)

**Status: PLAN (2026-08-17).** Third of three plans implementing the gap register of
`design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md`. This is "the big
one" (GAP-2) plus everything the mapping doc's §8 order gates behind it:

- **GAP-2** — the empty signature channel (8,673/8,673 signatures trivial; the
  largest component of the unconstrained-LTop mass). Phases A–C.
- **The re-census** — the deciding artifact for everything downstream. Phase D.
- **GAP-7** — the two `VarCycle` precision seams. Phase E.
- **GAP-4** — kernel per-param set-flow facts, incremental. Phase F.
- **GAP-6** — the sum-lowering decision gate (decision procedure, not
  implementation). Phase G.
- **GAP-5** — the `maxSetSize` knob. Phase G rider.
- **GAP-9 (repair half)** — per-use let-set separation, sized by plan 1's counters.
  Phase H.

Prerequisites: plans 1 and 2 landed (watchdogs + μ-tie guard the fan-out this plan
creates; grounding makes the members this plan transports resolvable).

References verified at HEAD 2026-08-17; anchor by function name if lines drift.

---

## Phase A — GAP-2 diagnosis: why every signature is trivial

### A.1 The mechanism of the leak (verified against the code, record before repairing)

`LssInfer`'s inference walk relies on the item memo for intra-def flow: "shared
MVarIds already carry the flow" (`walkExpr`'s `_` arm, :735-739). That is true only
for **type variables** — `loadVarC` memoizes per-MVarId (`Store.elm:292-315`), but
every **ground** structural type mints *fresh* Points per load (`loadTypeC`,
:178-272; LSS_006 makes this deliberate). Consequences, each a distinct flow leak:

1. **Params are never connected.** A def's top-level `Function` arm loads
   `meta.tipe` fresh; its param names are not bound to the annotation's param-arrow
   Points. A body occurrence of param `f` at a ground type (`Msg -> Model`) loads a
   fresh `FunL` — disconnected from the signature slot.
2. **Control flow is never connected.** `If`/`Case`/`Let`-body/`Destruct`-body take
   the structural-recursion arm — a branch returning a function value at a ground
   type contributes nothing to the def's result-arrow slot. (`chooseHandler b f g =
   if b then f else g` has a trivial signature today.)
3. **Calls of local function values are never connected.** `walkCall`'s wildcard
   (:762-763) skips non-global callees, so `f x` where `f` is a param transports
   nothing between `f`'s arrow slots and the call's args/result.

Polymorphic positions (TVar-linked) DO connect — which is why `rep` linkage exists at
all — but Elm bodies overwhelmingly flow function values through ground-typed
positions, so nearly nothing reaches the annotation slots. This, not a missing
representation, is the empty channel.

### A.2 On the mapping doc's `FromArrow` proposal — scope decision, recorded

The doc's repair sketch generalizes `ArrowFact.members` to
`List (Ground Int | FromArrow ordinal)` — a *directed* flows-into fact. Analysis
(record this; it is a deliberate refinement of the doc, not an omission):

- The paper's own inference cannot express directed inclusion between two set
  variables either: TIU **unifies** set variables symmetrically (146:10); `Q`'s
  `ℓ ⋸ σ` puts concrete members into a variable, never `α ⊆ β`. A branch join
  `if b then f else λ` pollutes `f`'s α with the λ's member in the paper exactly as
  symmetric slot unification does here. Symmetric-first is therefore the *faithful*
  mechanism, and `FromArrow` would EXCEED the paper.
- A directed `FromArrow` applied at instantiation time is **unsound as a snapshot
  read**: `applyFacts` runs before arg unification (`translateCall` /
  `applyCalleeAt` order), and even applied after it, later joins into the source
  slot would not propagate — an under-approximated set is a wrong-singleton
  miscompile risk (sets must over-approximate; LSS_005 only licenses widening).
  The only sound directed form is deferred constraint solving — the paper's full
  `Q` machinery — a much larger change with no consumer demanding it.

**Decision:** Phase B implements symmetric flow completion (`joinArrowSets`-style
set-slot-only unification — total, never fails, already exists). `FromArrow` is
parked with this analysis attached; re-open ONLY if Phase D's census shows symmetric
param-pollution killing a material singleton population (measure: `sizeHist` 2-share
at param arrows attributable to branch joins).

## Phase B — GAP-2 repair: flow completion in the inference walk

All edits in `Compiler/MonoSolver/LssInfer.elm` unless noted. Everything below is
set-slot-only (via `joinArrowSets` / `unifySlotWithSet`) — no whole-type unification
across generalization boundaries (that stays forbidden; see §7.4 of the design doc).

### B.1 Root and param binding

- `loadMemberSlots` (:476-488) currently discards the loaded root
  (`Ok ( ( _, slots ), s1 )`). Keep it:
  `List ( String, IO.Variable, Array IO.Variable )` (gkey, root, slots).
- `walkMembers` (:491-508) pairs each member with its root. For a member whose body
  is `TOpt.Function`/`TrackedFunction` (the normal `Define` shape):
  1. `joinArrowSets root bodyFuncVar` after the arm loads `meta.tipe` — connects the
     ground positions of the def's own head type to the signature slots.
  2. Bind params: descend the **root's** `FunL` spine (via `Store.arrowParts` +
     `arrowSetSlot`) in step with the param list, inserting each param name → its
     param-position Point into the walk's `letEnv`. The existing `VarLocal` /
     `TrackedVarLocal` arms (:701-705 → `joinLetUse`) then join every param
     occurrence for free — **reuse `letEnv`; do not add a parallel paramEnv.**
- Nested lambdas: extend the `Function`/`TrackedFunction` arms (:623-647) to bind
  *their* params from the just-loaded `funcVar`'s spine (same descent helper) before
  recursing into the body. One shared helper:

```elm
bindParamsFromSpine : List Name -> IO.Variable -> LetEnv -> Step LetEnv
-- UF.get; arrowParts → (pParam, pRest); insert name→pParam; recurse pRest.
-- Stops early on non-arrow content (over-shadowed/erased heads — sound: unbound
-- params simply stay untracked, today's behavior).
```

  Shadowing: `Dict.insert` overwrites — correct (innermost binding wins; Elm has no
  same-scope shadowing).

### B.2 Control-flow joins

Add explicit arms for `If` and `Case` (currently structural-only), and extend `Let`
(:707-733) and `Destruct`:

```elm
TOpt.If branches finally meta ->
    -- children first (walkChildren), then for each branch VALUE b (snd of each
    -- pair, plus finally): if canTypeMentionsArrow (TOpt.typeOf b) then
    --   joinArrowSets (loadType (TOpt.typeOf b)) (loadType meta.tipe)
TOpt.Case … decider jumps meta ->
    -- same over every Leaf(Inline e) of the decider (reuse deciderExprs) and every
    -- jump body
TOpt.Let / TOpt.Destruct ->
    -- existing handling PLUS join (typeOf body) ~ meta.tipe when arrow-bearing
```

`canTypeMentionsArrow : Can.Type TypeIds.MVarId -> Bool` is a new cheap syntactic
guard (recursive over the Can.Type; `TLambda → True`; alias-chase like
`canTypeIsArrow`, :1230-1240) — it keeps the added loads off the overwhelmingly
arrow-free majority of branches. Without the guard the walk would double its load
volume for nothing.

### B.3 Local-callee calls

`walkCall` (:747-763) gains:

```elm
TOpt.VarLocal name funcMeta ->        (and TrackedVarLocal)
    case Dict.get name letEnv of      -- letEnv now threads into walkCall
        Just fVar -> unifyCallShape fVar args meta
        Nothing   -> Ok ( (), s0 )
```

`unifyCallShape` (:801-813) already does exactly the right thing (best-effort param
unification + residual~result join). Threading: `walkCall` needs `letEnv` — change
its signature; the one caller is the `Call` arm (:649-655).

### B.4 The signature-channel widening rider (mandatory, same change)

The mapping doc's GAP-2 rider: `zonkSigGo` (:531-581) applies **no size cap** —
dormant while signatures are trivial, live the moment B lands. In the
`LsMembers ms` branch: if `List.length ms > s.env.lss.maxSetSize` then emit
`{ rep = rep, members = [], top = True }` and bump a new
`fidelity.widenedBySigSize` counter (plan 1's sub-record; add to the report line).
Also bump `fidelity.widenedByCf` from a dedicated wrapper around the control-flow
joins' `poisonBoth` calls so let-boundary poison (plan 1's `widenedByLet`) stays a
separately-readable number.

### B.5 Flag, cost, gates

- Flag: `Config.LssConfig.sigFlow : Bool` (default `False`; env
  `ECO_MONO_LSS_SIG_FLOW`; hash token `lssSF=1` when non-default). Artifact-affecting
  under keying (signature members reach caller instantiations → annotations → keys).
  Every B-edit is gated on it at the walk level (one check in `signatureFor` /
  `walkExpr` entry — when off, the new arms fall through to today's behavior; the
  cheapest formulation is to thread a `sigFlow : Bool` into the walk and branch at
  the six new join points).
- Cost model to verify at census: inference is once-per-global (memoized;
  `LssInfer` module doc) — added loads are bounded by arrow-bearing branch counts;
  `trivial` short-circuit population will SHRINK (that is the point), making
  `applyFactsGo` run at more call sites — watch mono wall (`PhaseMono` is blind on
  kernel-package builds — use the full-build wall + the fast-census loop).
- Unit tests (`tests/TestLogic/Monomorphize/LssSigFlowTest.elm`):
  - `chooseHandler b f g = if b then f else g` → result-arrow fact rep-linked to
    BOTH param arrows (one UF class → rep = smallest ordinal);
  - `compose`-shaped body → result arrow carries the body lambda's Ground member;
  - param-called (`apply f x = f x`) → no spurious members, signature may stay
    trivial (negative control);
  - a >maxSetSize signature arrow → `top=True` + `widenedBySigSize` bump.
- E2E fixture (`test/elm/src/LssSigFlowTest.elm`): a caller passing a lambda through
  a `chooseHandler`-style def into a call site — assert the site's set is the
  2-member join (honest, no false singleton), and a single-branch variant still
  devirts/stamps.
- Battery at flag-on: `--target full`; self-compile bootstrap fixed point;
  `LssSharedSpecJoinTest` (LSS_010) green; `joinRounds` in normal band;
  `unqualifiedLambdaMints = 0`.

## Phase C — signature-transported members meet Fix B (verify, don't assume)

Post-B, signatures can carry `l|` **raw** lambda ids (inference-phase mints are
deliberately unqualified — `Engine.elm:254-258`; LSS_017 makes raw singletons
decline at AbiCloning: unstampable-but-sound). With plan 2, `g|`/`c|` signature
members are provisional and ground at the caller — resolvable. So the Fix-B fork
plan's §8 open item ("signature-transported members stay raw — interesting only when
signatures stop being trivial") activates HERE:

- **C1 (census):** count sites whose singleton is a signature-transported raw
  lambda (they surface as `declinedNoInstance` upticks in AbiCloning's census with
  the member id in `declineByMember`). If material, the recorded v2 design is
  enqueue-time qualification (fork plan §8) — file it as its own plan; do NOT
  improvise it here.
- **C2 (invariant):** amend LSS_017's row to note signatures are now a live raw-id
  channel and the decline path is the enforced handling.

## Phase D — the re-census (the §8 pivot point)

One instrumented self-compile (fast loop first, native to confirm), archived in this
file's results section. The numbers that gate everything downstream:

| number | source | gates |
|---|---|---|
| unconstrained-LTop share (LTop minus widened counters, over `setsZonked`) | LSS report | aim-1 scorecard; GAP-2 success = material drop from 89.3%/E0.5-shape |
| signatures trivial % | report `signatures:` line | GAP-2 success metric |
| `sizeHist` k≥2 mass + `multiSetSiteHist` | report + AbiCloning census | **GAP-6 decision input** |
| `widenedBySize` / `widenedBySigSize` | report | **GAP-5 decision input** |
| `widenedByBudget` | report | budget-policy check (plan 1 B3 baseline) |
| `fidelity.widenedByLet` / `localMultiBypass` / `widenedByCf` | plan 1/B4 counters | **Phase H sizing** |
| `topSiteShapes` split | AbiCloning census | escape-floor vs reachable residue |
| dispatch stamps (`dispatchUpgraded` etc.) + runtime dispatch census (Run-M methodology) | GlobalOpt census + `benchmarks/runtime-calls.md` protocol | non-regression + payoff |

Honesty rule from the mapping doc (§6): keep the three unconstrained-LTop components
separate — (i) signature channel (now repaired — measure the residue), (ii)
let/local (Phase H's input), (iii) escape-by-soundness floor (IO bind continuations —
no analysis helps; do not chase).

## Phase E — GAP-7: the two `VarCycle` seams (small, battery-gated, no flag)

1. **Head-only cycle mints** (`LssInfer.walkExpr` VarCycle arm, :683-689): thread
   declared arity. Extend `declaredArityOf` (:932-955) with a `TOpt.Cycle` arm: dig
   `funcDefs` by name (`TOpt.Def _ name … / TailDef _ name …` → param count;
   `valueDefs` → 1). The VarCycle arm then uses `spineDepthForGlobal`-equivalent
   depth instead of `\_ -> 1` (respect the `lss.spineArity` flag exactly as the
   VarGlobal arm does — the seam fix rides the same soundness argument, S.10).
2. **`injectArgLambdaMember` has no VarCycle arm** (`Translate.elm:3111` wildcard):
   add one mirroring the `VarGlobal` arm — mint
   `g|<comparableGlobal (Global home name)>` via `standaloneArgMember` (kernel-alias
   fold does not apply to cycle members; keep the plain path). A cycle member passed
   as a function argument then transports its member like any global.

Artifact-affecting under keying (new members) → land with the standard battery
(`--target full`, bootstrap fixed point, census delta noted). The specialization
unit stays per-member — the mapping doc's verdict is that LSS_010 flush IS the
demand-driven equivalent of §6.3; do not unify the spec unit.

## Phase F — GAP-4: kernel per-param set-flow facts (incremental, audit-driven)

The calibration today: LSS_004 poisons every kernel/port/debug-crossing arrow
(`byKernel = 4,102` shipping); `List.map/foldl/foldr/filter` are plain Elm and
already unpoisoned; the gap is `map2-5`, `sortBy/sortWith`, Task/Process internals
(mapping doc GAP-4).

### F.1 The fact table

New module `Compiler/MonoSolver/KernelSetFacts.elm` (deliberately parallel to the
planned `hofParams` table of `plans/effect-polymorphic-purity.md` — same audit rows,
different axis; keep them separate tables so each audit stands alone):

```elm
type ParamSetFlow
    = PSFOpaque      -- default: the param's arrows poison (today's behavior)
    | PSFApplies     -- kernel only CALLS the functional param (never stores/returns
                     -- it): the param's own arrow slots need NO poison — its set
                     -- stays whatever the caller knows; the kernel adds no inhabitants
    | PSFTunnels     -- kernel returns the param (or stores it into the result):
                     -- param arrows join the RESULT's matching arrows (set-slot-only)

facts : Dict String (List ParamSetFlow)   -- "home.name" → per-param, missing = all-opaque
```

Audited from the C++ bodies in `elm-kernel-cpp`/`runtime` per kernel — each row's
commit message cites the audited source file+function. Start set (the mapping doc's
shopping list, one kernel per commit): `List.map2` … `map5` (PSFApplies on the
callback, opaque elsewhere), `List.sortBy`/`sortWith` (PSFApplies), then the
`kernelMissHist` census top entries in order.

### F.2 Consumers of the table

- `LssInfer.poisonCallBoundary` (:849-866): for a kernel with facts, poison only
  `PSFOpaque` params' loaded types; `PSFApplies` params skip the poison;
  `PSFTunnels` params `joinArrowSets` against the result's loaded type. The result
  poison (:856-861) is skipped only when every param is non-opaque AND the kernel's
  result row says so — encode the result as one more `ParamSetFlow` (last element).
- `Translate.poisonKernelArrowsThen` (:3329) / `deriveKernelAbiTypeWith` (:3222):
  same table, same rule, translation side. The two sides MUST consult one function
  (`KernelSetFacts.planFor : String -> Int -> …`) so inference and translation never
  disagree about which arrows poison (the LSS_006-style two-sided discipline).
- Census: `widenedByKernel` should drop per landed row; add
  `fidelity.kernelFactHits`.

### F.3 The `kernelToSig` prerequisite (only if `k|` spine injection is wanted)

`k|` members are head-only because `kernelToSig` misaligns at inner arrows
(`Translate.elm:3129-3137` comment; mapping doc GAP-4). Fixing that alignment is a
PREREQUISITE for `k|` spine injection and is **not** required for F.1/F.2 (which
only remove poison). Keep it a separate, optional step: fix the alignment, add a
regression test on a 2-stage kernel type, THEN extend `standaloneArgKernelMember` /
the kernel mint arms past depth 1. If not done, record head-only as the standing
calibration.

Each F increment: `--target full` + census delta + the kernel's own E2E tests; no
flag (poison removal is behavior-neutral by LSS_005 — annotations/tiers only — but
still artifact-affecting under keying → battery per increment; group rows into small
batches after the first two prove the pattern).

## Phase G — GAP-6 decision gate and GAP-5 rider (decision procedure, not code)

Inputs: Phase D's k≥2 numbers. Procedure (from the mapping doc's own ordering rule —
"GAP-2 first, re-census, only then revisit M5"):

1. If multi-member sets remain ≈0.8%-of-arrows-shaped and cold in
   `multiSetSiteHist` → record **NO-GO CONFIRMED** for sum lowering in
   `design_docs/monomorphization/capture-union-representation.md` (append a dated
   section citing the new census) and CLOSE GAP-6. The M5 evidence is then no longer
   "downstream of GAP-2" — it stands.
2. If k≥2 is now material → re-open via
   `design_docs/monomorphization/multiset-defunctionalization-design.md` (its §7
   already defines the deciding census); that becomes its own plan. Do not build
   lowering inside this series.
3. **GAP-5 rider:** only in case 2 (a default-on multi-member consumer exists or is
   being built), raise `maxSetSize` (JSON-only knob) and re-census
   `widenedBySize`/`widenedBySigSize`; in case 1, leave it at 8 and note why in the
   results section. (The G-1 MapTemplate multi-member arm is default-off and Borrow's
   meet is census-only — neither forces the raise on its own; say which consumer
   flipped if one does.)

## Phase H — GAP-9 repair: per-use let-set separation (sized, then built or parked)

Trigger: plan 1's `widenedByLet` + `localMultiBypass` census (and Phase D's
`topSiteShapes local` residue). If the combined mass is not material against the
remaining unconstrained-LTop, **park** with the numbers recorded — the design doc
already names this the vNext upgrade, not an obligation.

If built, the design (v1-scoped, mirroring machinery that exists):

1. **Local-multi bypass first** (it has translation-side machinery already): in
   `unifyParamsCollect`'s local-multi arm (`Translate.elm:2930-2947`), the fresh
   instantiation `freshVar0` is exactly a per-use slot family. Inject the argument's
   member into it when the arg is itself a member-bearing reference — i.e., call
   `injectArgLambdaMember arg freshVar0` (the injection the arm currently skips) —
   the per-use zonk (`translateArgsWith`, :2975-3002) then records the instance at a
   member-bearing type, and E4a's `enrichLocalMultiUses` (:4798+) transports it.
   This closes GAP-9(b) without touching inference. Battery-gated; census
   `localMultiBypass` should collapse toward 0.
2. **Per-use let sets in inference** (GAP-9(a), the harder half): replace the single
   `joinArrowSets rhsVar useVar` per use (`joinLetUse`, :1084-1096) with per-use
   slot families ONLY for uses whose structural join would poison (the current
   `poisonBoth` sites): on divergence, instead of poisoning both sides, load the RHS
   type **fresh** (isolated memo — `loadTypeIsolated`) and join against that copy,
   leaving the shared family clean. Uses that join cleanly keep sharing (union over
   uses stays the common case — cheap). This converts today's poison events into
   isolated-copy events; `widenedByLet` becomes the count of *remaining* true
   incompatibilities. Sound: a fresh copy under-shares (fewer joins), never
   under-approximates a set the consumer reads (each use reads its own family).
   Verify with a fixture where one let-bound function is used at two layouts.

Both halves artifact-affecting under keying → standard battery each.

## Invariants delta (this plan)

- **LSS_020** (Monomorphization;LambdaSets;implemented): Under `lss.sigFlow`, the
  inference walk connects ground-typed intra-def flow to signature slots —
  param-binding via the annotation spine into `letEnv`, control-flow joins
  (If/Case/Let/Destruct value positions, arrow-bearing only), and local-callee call
  shapes — all via set-slot-only joins (never whole-type unification across
  generalization boundaries). Signature readback applies the `maxSetSize` widening
  policy (`widenedBySigSize`); symmetric joins are the paper's TIU semantics —
  directed inclusion (`FromArrow`) is deliberately NOT implemented (snapshot reads
  under-approximate: unsound; see plan §A.2).
- **LSS_021** (Monomorphization;LambdaSets;implemented, per Phase F row): Kernel
  arrows poison per `KernelSetFacts` — `PSFApplies` params keep their sets,
  `PSFTunnels` params join the result, everything else (and every kernel without a
  row) poisons as LSS_004. Inference and translation consult one shared table
  function; each row cites its audited C++ source.
- Amend **LSS_004** to reference LSS_021 as its calibrated refinement; amend
  **LSS_017** per Phase C2.

## Execution order

A (record diagnosis) → B (flag-off mechanism + tests) → B-battery (flag on) → C
(census + LSS_017 amendment) → D (re-census, archive) → E (seams) → G (decision on
D's numbers) → F (kernel rows, incremental, interleavable after D) → H (sized by
counters; build or park) → default-flip `sigFlow` after D confirms value → invariants
rows.

Test discipline throughout (CLAUDE.md): each suite ONCE with
`2>&1 | tee /tmp/test_output.txt`; grep the file; suites serial; purge
`build/test/*/eco-stuff` between E2E legs; fast-census loop (stage-1 JS) before
native re-measures.

## Risks

- **Precision-driven fan-out**: nontrivial signatures push members into more keyed
  demands → spec growth. Plan 1's watchdogs and μ-tie are the installed guards;
  `widenedByBudget` is the early signal. If growth is hot, `sigFlow` stays a flag
  until the budget policy question (plan 1 B3 data) is settled.
- **Symmetric pollution** (A.2): params gain branch-mates' members → some singletons
  become honest 2-sets. This is a *correctness-direction* change (the singleton was
  only ever true because the channel was blind), but it can regress stamped-dispatch
  counts — the runtime dispatch census bounds the cost; the FromArrow re-open
  criterion is defined in A.2.
- **Walk cost**: bounded by the `canTypeMentionsArrow` guard + once-per-global
  memoization; measure at B-battery, not after D.
- **Kernel fact errors** (F): a wrong `PSFApplies` row that lets a stored callback
  keep a narrow set is a miscompile vector — hence per-row C++ citation, per-row
  battery, and the default-opaque rule. When in doubt, a kernel keeps LSS_004
  poison.
