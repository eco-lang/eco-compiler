# LSS Fidelity 3 — Signature Set-Flow (GAP-2), Re-Census, and the Completeness Follow-Ons (GAP-4/5/6/7, GAP-9 repair)

**Status: COMPLETE (2026-08-20).** Drafted 2026-08-17; lowered to
implementation-ready detail and adversarially verified against HEAD, then
executed the same day. All phases landed or decision-recorded — see
§Results: A recorded, B landed (default-OFF), C done (+133, not material),
D done (Run X; **sigFlow NOT flipped** — the §A.2 FromArrow re-open
criterion fired on the −26.7% fast-coverage regression), E landed, F landed
(v1 rows; further rows are the standing audit backlog), G closed (GAP-6
NO-GO CONFIRMED), H parked with numbers. Invariants LSS_020/LSS_021 added;
LSS_004/LSS_017 amended.
Third of three plans implementing the gap register of
`design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md`. Scope is unchanged
from the 2026-08-17 draft:

- **GAP-2** — the empty signature channel (all signatures trivial at every census).
  Phases A–C.
- **The re-census** — the deciding artifact for everything downstream. Phase D.
- **GAP-7** — the two `VarCycle` precision seams. Phase E.
- **GAP-4** — kernel per-param set-flow facts, incremental. Phase F.
- **GAP-6** — the sum-lowering decision gate (decision procedure, not implementation). Phase G.
- **GAP-5** — the `maxSetSize` knob. Phase G rider.
- **GAP-9 (repair half)** — per-use let-set separation. Phase H: **PARKED on
  measurement 2026-08-21** (`plans/lss-per-use-let-separation.md` §2.R — both
  halves measure empty on both sigFlow arms).

Prerequisites: plans 1 and 2 landed (MONO_030 watchdogs + LSS_018 μ-tie guard the
fan-out this plan creates; LSS_019 grounding makes the members this plan transports
resolvable at the caller's zonk).

All code references verified at HEAD 2026-08-20. Anchor by function name if lines
drift; §0.3 is the drift table against the 2026-08-17 draft, §0.4 the corrections
from the verification round.

---

## §0 — Deltas from the 2026-08-17 draft (read first; these are load-bearing)

The draft's decisions all stand. Several of its *mechanisms* do not survive contact
with the code at HEAD; the phases below are written against reality.

### §0.1 The B.2 sketch transports nothing as written — the walk must become value-returning

The scratch memo is keyed by `MVarId` **only** (`Store.LoadCtx.memo : Dict Int
IO.Variable`, `Store.elm:69`; sole memoized path `Can.TVar → loadVarC`,
`Store.elm:180-182,292-315`). Every ground structural node mints a **fresh Point on
every `loadType` call** (`structC`/`freshVarC`, `Store.elm:275-286`; deliberate per
LSS_006 — the `unifySlotWithSetC` comment at `Store.elm:931-935` says so in as many
words). Consequence: the draft's literal edit,

```elm
joinArrowSets (loadType (TOpt.typeOf b)) (loadType meta.tipe)
```

joins two *freshly minted, mutually disconnected* Points — at every ground type it
unions two empty slot families and transports **nothing**. The only Points connected
to what the walk actually did are the ones the walk itself loaded and still holds
(the `letEnv` values, the member slot arrays, each arm's own loads).

**The lowered mechanism: `walkExpr` returns the Point it loaded for the expr's own
type**, tagged with an honesty class (§B.0), and every new join targets a
*returned* Point, never a re-load. Traced end-to-end in §B.0 against the
`chooseHandler` unit-test expectation: it produces exactly the "one UF class → rep
= smallest ordinal" signature the draft demands. The Let/Destruct joins of the
draft's B.2 collapse into free propagation (zero extra loads).

### §0.2 The plan-1 fidelity counters no longer exist

`FidelityStats` (`muTied`/`widenedByLet`/`localMultiBypass`) was **removed
2026-08-18** after its one-shot census (Engine.elm:160-167 comment; plan 1 §7.5.1).
The frozen numbers: `muTied = 0`, `widenedByLet = 672`, `localMultiBypass = 469`
against `topSiteShapes local = 7,361` (Run J, `benchmarks/lss-opt.md:408-410`; the
672 is also recorded at the `poisonBoth` comment, LssInfer.elm:1221-1226, and the
469 at `unifyParamsCollect`'s comment, Translate.elm:2943-2949). Therefore:

- New counters go in a **new** `SigFlowStats` sub-record (template:
  `GroundingStats`, Engine.elm:153-156 — sub-records dodge the 32-slot record
  GC-scan cap noted at Engine.elm:144).
- Census-only counters bump **gated on `lss.report`** (plan 1 §7.6,
  user-directed); the policy counter `widenedBySigSize` bumps unconditionally
  (same class as `widenedBySize`/`widenedByKernel`, unconditional at HEAD).
- Phase D's `widenedByLet`/`localMultiBypass` rows are **frozen Run-J numbers**;
  Phase H is sized by them plus D's residue, and plan 1 §7.4 records H as
  "leans PARK".

### §0.3 Draft-ref drift table and current baselines

| symbol | draft ref | HEAD |
|---|---|---|
| `canTypeIsArrow` | LssInfer :1230-1240 | :1235-1245 |
| `injectArgLambdaMember` wildcard | Translate :3111 | fn :3091-3130, wildcard :3129-3130 |
| `kernelToSig` misalign comment | Translate :3129-3137 | Translate :3147-3150 (+ LssInfer :666-670); fn in `Compiler/GlobalOpt/Borrow/LssFacts.elm:344-364` |
| `deriveKernelAbiTypeWith` | Translate :3222 | :3240-3339 (poison hook :3339) |
| `poisonKernelArrowsThen` | Translate :3329 | :3347-3358 |
| `unifyParamsCollect` local-multi arm | Translate :2930-2947 | :2941-2965 (`freshVar0` :2950-2954) |
| `translateArgsWith` | Translate :2975-3002 | :2993-3020 |
| `enrichLocalMultiUses` | Translate :4798+ | :4816-4856 (call site :4773) |
| Engine raw-mint doctrine | Engine :254-258 | doc :287-290; raw fallback + `unqualifiedLambdaMints` bump :344-349 |

Current baselines for Phase D deltas — plan 2 G3 era (Run W) unless marked:
`widened: bySize=43 byKernel=4,062 byBudget=36,693`; `grounding: grounded=4,955
deferred=11`; sets zonked 366,222; members 42,738; `devirtDirect=3,984
devirtKernel=771`; AbiCloning `dispatchUpgraded=3,568 declinedNoInstance=1,378`;
out.mlir 13,557,262 B; E2E denominator 1,682. **Signatures: 9,651 memoized (9,651
trivial) — Run J 2026-08-18 (`lss-opt.md:410`); the mapping doc's 8,673/8,673 is
the E0.5 unkeyed census of 2026-07-16 — re-read the exact count from the B.7/D
flag-off leg before computing deltas.** `topSiteShapes global=14,143 local=7,361
kernel=3,785` is the pre-plan-2 all-keyed census (2026-08-14; `local` recurs
unchanged in Run J) — re-read at D's flag-off leg.

### §0.4 Corrections from the verification round (2026-08-20, five-lens adversarial review)

1. **TailDef bodies are arg-stripped** (`TypedOptimized.elm:362`: the expr is the
   body *after* peeling the args; the type is the full function type). A naive
   root/rhs join would `poisonBoth` every tail-recursive def (shape mismatch
   App vs FunL) or mis-pair ordinals. Fix: peel `List.length args` arrows off the
   full-type Point before joining, and bind the args while there (§B.1, §B.2).
2. **Every def body is a `Function` carrying `Just lamId`**
   (`AssignMVarIds.elm:587-617`, run unconditionally), and `injectLambdaMember`
   stamps that raw id on the body's spine slots — so the root join would make
   EVERY ≥1-param def's signature nontrivial with its own raw `l|` member,
   killing the `trivial` short-circuits (`applyFacts` :199,
   `Translate.lssFastOk` :2398-2412) globally and flooding Phase C with declines.
   Fix: filter the member's own self-id at signature readback (§B.1.f) — it is
   redundant there (callers already get the def's identity via `g|` standalone
   spine injection, which grounds under LSS_019, and via `injectArgLambdaMember`
   translate-side).
3. **Partial hub joins are a miscompile vector**: joining only the branches the
   walk can see (`if b then Basics.negate else r.handler` — the `Access` branch is
   blind) publishes a `top=False` singleton that claims completeness; the caller
   grounds and devirt-stamps `negate`, executing the wrong function when the other
   branch flows. Empty facts are sound (consumers default to ⊤-on-read); PARTIAL
   non-empty facts are not. Fix: the three-valued `WalkPoint` honesty rule — a hub
   publishes members only when EVERY branch is honest, else it poisons (§B.0/§B.2).
4. **B.3 must not whole-type-unify the shared letEnv family** (§7.4: no whole-type
   unification across generalization boundaries; `unifyCallShape` is whole-type and
   its first divergent use would concretize the family). Fix: a slot-only
   `joinCallShape` for local callees (§B.3); `unifyCallShape` remains only where it
   operates on isolated instantiations (`applyCalleeAt`).
5. **The F.2 ordering claim was inverted**: on the call path the poison hook runs
   AFTER `unifyParamsWithArgExprs` (`Engine.andThen f step` runs `step` first,
   Engine.elm:675-683; composition at Translate :2862-2865 + :3339). The
   translate-side code comment :3342-3345 is itself stale — fix it in passing. The
   PSFApplies skip still works (a never-poisoned slot is clean regardless of
   order); §F.2 states the true order.
6. Smaller: stale signatures baseline (→ 9,651, §0.3); the §D LTop formula
   subtracts `widenedBySize` only; three C++ evidence anchors drifted (§F.1);
   E.1's Cycle arm also deepens the VarGlobal/VarEnum/VarBox mint sites for
   cycle-member globals (intended, §E.1); H.2's soundness argument restated as a
   writer inventory (§H.2); fixture types must be built-ins or use the
   unions-capable builder (§B.6); `full`'s clean (not `check`) deletes
   eco-boot/eco-stuff state (§Execution order).

Other §0 corrections carried from the first lowering pass: the plan-1 counters
(§0.2); `walkCall` already has a `VarCycle` arm (:753) so E.1 is mint-side only;
H.1's drafted `injectArgLambdaMember` call is a no-op for local-multi args (§H.1);
`kernelToSig` location (§0.3); `KernelSetFacts` mirrors `KernelFacts.elm`
(`(Name, Name)` keys, mandatory evidence — it already has map2/sortBy/sortWith
rows with stale anchors to fix); map2-5 result rows must be `PSFOpaque`
(PAP-of-callback hazard, §F.1).

---

## Phase A — GAP-2 diagnosis: why every signature is trivial

### A.1 The mechanism of the leak (verified against the code, record before repairing)

`LssInfer`'s inference walk relies on the item memo for intra-def flow ("shared
MVarIds already carry the flow" — `walkExpr`'s `_` arm, :735-739). That is true only
for **type variables**: `loadVarC` memoizes per-MVarId (`Store.elm:292-315`), and
every **ground** structural type mints fresh Points per load (`loadTypeC`
:178-272; LSS_006 makes this deliberate). Since flows connect only through held
Points or explicit unification, each of the following is a distinct leak:

1. **Params are never connected.** The `Function` arm loads `meta.tipe` fresh
   (:623-634); param names are never bound to any Point, so a body occurrence of
   param `f` at ground type (`Msg -> Model`) loads a fresh `FunL` disconnected from
   both the lambda's own head type and the annotation slots (`joinLetUse` no-ops on
   names absent from `letEnv`, :1084-1096).
2. **The def's own annotation slots are never connected to the body.**
   `loadMemberSlots` discards the loaded root (`Ok ( ( _, slots ), s1 )`, :487) and
   `walkMembers` starts every body walk with `CoreDict.empty` (:503).
3. **Control flow is never connected.** `If`/`Case`/`Destruct` take the structural
   `_` arm; and the `Let` arm's hub (`rhsVar = loadType defType`, :715-719) is
   itself a fresh load disconnected from the RHS walk's Points at ground types.
4. **Calls of local function values transport nothing.** `walkCall`'s wildcard
   (:762-763) skips non-global callees.

Polymorphic (TVar-linked) positions DO connect — which is why `rep` linkage exists
at all — but Elm bodies overwhelmingly flow function values through ground-typed
positions. This, not a missing representation, is the empty channel.

**Recorded residue (in scope for Phase D's honesty split, NOT for repair here):**
`unifyParamsBestEffort` loads each *argument's* type fresh (:832), so an
argument's member mint — injected by the child walk into a *different* fresh load
(:993) — never reaches the callee instantiation on the inference side. The
translate side covers it (`injectArgLambdaMember` at the real call). This leak is
pre-existing, unchanged by B, and — note well — it is what makes `WpOpaque`
call-result Points *empty-or-honest rather than partial* (§B.0); an inference-side
fix of this leak must re-visit that argument (write into the family/letEnv Point,
never only the fresh arg load).

> **CLOSED 2026-08-23 by LSS_026(d)** (`plans/lss-gap2-callarg-transport.md`
> §3.4), under `lss.callArgFlow ∧ lss.sigFlow`, for **global-callee and
> local-callee** arguments. `walkExpr`'s Call arm now walks the args FIRST and
> keeps their `WalkPoint`s; `walkCall → applyCalleeAt → unifyCallShape →
> unifyParamsBestEffort` threads them through, and `flowArgWp` flows each
> `WpHonest`/`WpOpaque` point INTO the param position (directed,
> `flowArrowSetsSig`'s orientation) — exactly the "write into the family/letEnv
> Point" this note demanded, rather than into the fresh arg load. The same step
> runs in `joinCallArgs` for letEnv-family callees.
>
> **Residues that remain open:** the KERNEL boundary (v1 deliberately passes
> `[]` there — the audited LSS_021/022 rows already define param semantics, so
> an extra flow would either duplicate or contradict them), and the fresh-load
> residue at positions the loader never enumerates (tyvar positions mint no
> slot — the §6 loss item).
>
> **And the B.0 premise this note states is now load-bearing in a second way.**
> "`WpOpaque` is empty-or-honest rather than partial" is exactly what makes it
> safe to FLOW FROM. That safety used to rest on the leak; it now rests on
> LSS_026(a) instead, which is the stronger footing: an empty (flex) source no
> longer vanishes from a members-carrying readback, it widens it to ⊤. So the
> honesty classes survive the repair of the leak that originally justified
> them — see the B.0 re-argument below.

### A.2 On the mapping doc's `FromArrow` proposal — scope decision, recorded

Unchanged from the draft, and re-verified at HEAD: `instantiateLss` applies facts
at instantiation (`Translate.elm:2744` via LssInfer:115-132) strictly **before**
`unifyParamsCollect` (:2749) — a directed `FromArrow` applied at instantiation is
a snapshot read taken before the args exist, and later joins into the source slot
would not propagate. An under-approximated set is a wrong-singleton miscompile
risk (sets must over-approximate; LSS_005 only licenses widening). The paper's own
TIU unifies set variables symmetrically; symmetric-first is the *faithful*
mechanism and `FromArrow` would EXCEED the paper. **Decision:** symmetric flow
completion only. `FromArrow` is parked with this analysis attached; re-open ONLY
if Phase D shows symmetric param-pollution killing a material singleton population
(measure: `sizeHist` 2-share at param arrows attributable to branch joins).

## Phase B — GAP-2 repair: flow completion in the inference walk

All edits in `Compiler/MonoSolver/LssInfer.elm` unless noted. Every **new** join is
set-slot-only (`joinArrowSets` unifies only FunL slot Points via
`Store.unifyBestEffort`, :1122-1133) — no whole-type unification across
generalization boundaries (design §7.4; B.3 deliberately uses a slot-only call
shape for exactly this reason). Every effectful addition is gated on
`s.env.lss.sigFlow` read inline (config at `s.env.lss`, Engine.elm:473; no
threading needed). Flag-off, the store-operation sequence is byte-for-byte
today's — verified claim-by-claim in the review round (§0.4).

### B.0 The value-returning walk with honesty classes (the enabling refactor; flag-off inert)

```elm
type WalkPoint
    = WpNone                 -- no point: containers, literals, TailCall, blind
                             -- locals, wildcard — value's inhabitants untracked
    | WpHonest IO.Variable   -- point whose slot contents are COMPLETE-or-⊤ for
                             -- this value (injected identities, letEnv-linked
                             -- flow, or an already-poisoned hub)
    | WpOpaque IO.Variable   -- a real point with possibly-incomplete slots
                             -- (call results)

walkExpr : LetEnv -> TOpt.Expr TypeIds.MVarId -> Step WalkPoint
```

Per-arm returns (arms not listed: `_` arm → `walkChildren` then `WpNone`):

| arm | returns | notes |
|---|---|---|
| `Function`/`TrackedFunction` | `WpHonest funcVar` | funcVar already loaded today (:624, :637); lambda identity injected — complete |
| `VarGlobal`/`VarEnum`/`VarBox`/`VarCycle`/`VarKernel`/`Accessor` | `WpHonest funcVar` when `canTypeIsArrow` held (the load `standaloneMemberWith` already does, :987-998), else `WpNone` | standalone identity injected — complete (spine to injection depth; beyond-depth slots are flex ⇒ EMPTY facts, sound) |
| `VarLocal`/`TrackedVarLocal` | `WpHonest useVar` when in `letEnv` (load :1091), else `WpNone` | family honesty is the let channel's own invariant (rhs join + poison-on-divergence) |
| `Call` | `WpOpaque callVar` (or `WpNone`, §B.3) | callee facts + local rep application; empty-or-honest at HEAD per the A.1 residue note |
| `Let` | the body's `WalkPoint`, verbatim | propagation — subsumes the draft's Let join with zero loads |
| `Destruct` | the body's `WalkPoint`, verbatim | new explicit arm `TOpt.Destruct _ body _ -> walkExpr letEnv body s0`; identical store ops to today's `_` arm (directChildren = `[body]`, :1337-1338) |
| `If`/`Case` | `WpHonest hub` when the hub was loaded (joined OR poisoned — ⊤ is honest), else `WpNone` | §B.2 |
| `TailCall` | `WpSelf` (children walked as today) | **implementation refinement (as built):** a tail call's value IS the value under construction — in a hub it contributes no NEW inhabitants (the μ-equation X = b₁ ∪ … ∪ X solves to the union of the other branches), and any hub containing it is itself joined into the def's result class by the enclosing walk, making the self edge redundant. `WpSelf` is skipped by hubs WITHOUT forcing poison (a `WpNone` TailCall would ⊤ every function-returning tail loop for nothing) and treated as no-point everywhere else |

**Join acceptance rules** (the soundness core — §0.4(3)):

- **Hub joins (If/Case)**: publish members only if EVERY branch value returned
  `WpHonest` or `WpSelf` (`WpSelf` branches are skipped, not joined); if ANY
  branch is `WpNone`/`WpOpaque`, load the hub and `Store.poisonArrowSets` it
  instead (⊤ is the honest summary of a partially visible value). Rationale: a
  mixed join yields a non-empty set that claims completeness while a blind
  branch's runtime inhabitants are invisible — the false-singleton devirt
  vector.
- **Single-source joins** (member-root §B.1, lambda-result §B.1, Let-rhs §B.2):
  accept `WpHonest` **and** `WpOpaque`; skip on `WpNone`. A single opaque source
  cannot mix members with blindness — its slots are empty-or-honest (A.1 residue
  note), and empty facts are sound.

  > **B.0 RE-ARGUED 2026-08-23 (LSS_026).** The clause above rests on "empty
  > facts are sound", which in turn rested on the A.1 leak keeping opaque slots
  > empty rather than partial. LSS_026(d) repairs that leak, so the premise had
  > to be re-established on its own terms — and it now is, more strongly:
  > **LSS_026(a) makes empty *sources* honest by construction.** A resolution
  > that reaches an unconstrained (flex) inflow while carrying members no longer
  > silently drops it; it resolves ⊤. So accepting a `WpOpaque` point as a
  > single source cannot manufacture a false completeness claim even once those
  > points stop being empty. The acceptance rule is unchanged; its justification
  > moved from "the leak protects us" to "the resolver refuses to claim
  > completeness it does not have", which is the direction that survives further
  > repair.
  >
  > The hub rule above is untouched: symmetric MIXING of opaque points in a
  > join stays banned. LSS_026(d) adds only a one-way edge into a callee's param
  > position, which is not a hub.
  >
  > And the shape neither rule can see — a BLIND argument, where no edge is
  > created at all — is why LSS_026(d) is publish-or-poison rather than
  > publish-or-skip: `WpNone`/`WpSelf` at an arrow-mentioning argument writes ⊤
  > to the param position (`argFlowWpPoisoned` counts it).

The refactor itself performs **no new store operations** (returning already-loaded
Points is free), so it ships ungated; only the joins are flag-gated. Signature
changes ripple to: `walkChildren` (still discards), `walkMembers` (§B.1),
`walkCall` (§B.3), `joinLetUse` (returns `WalkPoint`; §B.1 guard),
`standaloneMemberWith`/`standaloneMember` (return `WalkPoint`),
`poisonCallBoundary` (returns its result Point, :856-861), and `unifyCallShape`
(:801-813) — which now returns its `callVar` (:808-812; safe: its current Ok
value is unit and its sole consumer ignores it) but is otherwise untouched and
stays confined to `applyCalleeAt`'s isolated instantiations (§B.3).

**Mechanism trace (the B.6 test-1 expectation, `chooseHandler b f g = if b then f
else g` at ground `Bool -> H -> H -> H`, `H = Int -> Int`):** root `R` loaded by
`loadMemberSlots` mints slots; ordinals by `loadTypeC` post-order mint: 0 =
f-param arrow, 1 = g-param arrow, 2 = result-H arrow, 3-5 = spine arrows
(verified). B.1 joins `R ~ funcVar` (slots pairwise-unified) and the Function arm
binds `f ↦ funcVar.param1`, `g ↦ funcVar.param2`. Walking the If: `VarLocal f`
loads `F1`; `joinLetUse` unifies `F1.slot ~ funcVar.param1.slot ~ R.ord0`; same
for `g`. All branch values are `WpHonest` (letEnv locals) → the If arm loads hub
`HB` and joins each returned Point: `F1.slot ~ HB.slot ~ F2.slot`. The Function
arm descends `funcVar` 3 arrows to `resVar` and joins `resVar ~ HB`:
`R.ord2.slot ~ resVar.slot ~ HB.slot ~ R.ord0.slot ~ R.ord1.slot` — one UF class
over ordinals {0,1,2}. `zonkSigGo`'s `repOrdinal` (UF.equivalent over slots,
:587-606) yields `{rep=0}` at ordinals 1 and 2: rep = smallest ordinal,
`trivial = False`. (Ordinals 3-5 carry only the def's own self-id, which §B.1.f
filters — without the filter every ≥1-param def goes nontrivial, §0.4(2).)

### B.1 Root and param binding

a. `loadMemberSlots` (:476-488): keep the discarded root —
   `List ( String, IO.Variable, Array IO.Variable )`.
b. `UnitMember` (:257-261) gains `tailArgs : List Name` — `resolveUnit`'s Cycle
   `TailDef` arm (:347-348) fills it with the arg names
   (`List.map (\( A.At _ n, _ ) -> n) args`); every other member: `[]`. This is
   the §0.4(1) peel input: a TailDef member's body is arg-stripped while its
   `sigType` is the full function type.
c. `inferUnitInScratch` (:458-473): zip members with the root triples (same order
   by construction) into `walkMembers`.
d. `walkMembers` per member with a body, flag-on:

```elm
-- (1) peel + bind: descend root |tailArgs| arrows, binding each arg name to its
--     param Point (empty for non-TailDef members); joinTarget = spine position
--     reached (the full root when tailArgs == []).
-- (2) walk the body with that env.
-- (3) single-source join: WpHonest p / WpOpaque p -> joinArrowSetsSig joinTarget p
--     (skip when the peel stopped early); WpNone -> skip.
case bindParamsFromSpine m.tailArgs root CoreDict.empty CoreDict.empty s0 of
    ( env0, maybeTarget, s1 ) ->
        case walkExpr env0 body s1 of
            Err e -> Err e
            Ok ( wp, s2 ) ->
                case ( maybeTarget, wpPoint wp ) of      -- wpPoint: WalkPoint -> Maybe Variable, WpNone -> Nothing
                    ( Just target, Just p ) -> joinArrowSetsSig target p s2 |> andThenContinue
                    _ -> continue s2
```

   Flag-off: today's `walkExpr CoreDict.empty body` exactly.
e. **Param binding lives solely in the `Function`/`TrackedFunction` arms** (the
   draft's bind-from-root is redundant once the root join unifies the slot
   families — UF transitivity, verified). Flag-on arm shape:

```elm
TOpt.Function srcLam params body meta ->
    case Store.loadType meta.tipe s0 of
        Err e -> Err e
        Ok ( funcVar, s1 ) ->
            case injectLambdaMember (List.length params) srcLam funcVar s1 of
                Err e -> Err e
                Ok ( _, s2 ) ->
                    if s2.env.lss.sigFlow then
                        let
                            ( letEnv1, maybeRes, s3 ) =
                                bindParamsFromSpine (List.map Tuple.first params)
                                    funcVar CoreDict.empty letEnv s2
                        in
                        case walkExpr letEnv1 body s3 of
                            Err e -> Err e
                            Ok ( wp, s4 ) ->
                                case ( maybeRes, wpPoint wp ) of
                                    ( Just resVar, Just bodyPt ) ->
                                        case joinArrowSetsSig resVar bodyPt s4 of
                                            Err e -> Err e
                                            Ok ( _, s5 ) -> Ok ( WpHonest funcVar, s5 )
                                    _ -> Ok ( WpHonest funcVar, s4 )
                    else
                        case walkExpr letEnv body s2 of
                            Err e -> Err e
                            Ok ( _, s3 ) -> Ok ( WpHonest funcVar, s3 )
```

   (`TrackedFunction` identical with `\( A.At _ n, _ ) -> n`.) The result join is
   single-source: accepts Honest and Opaque body Points.
f. **Self-member filter at signature readback (§0.4(2), decision recorded).** Per
   member, compute `selfId : Maybe Int` — `Just (Engine.srcLambdaKey lamId)` when
   the body is `TOpt.Function (Just lamId) …`/`TrackedFunction (Just lamId) …`,
   else `Nothing` — thread it through `zonkSignatures` into `zonkSigGo`, and drop
   it from every fact's members (`List.filter (\m -> Just m /= selfId) ms`) before
   the B.4 cap check. Rationale: the id is the def's own identity stamped on its
   spine slots by `injectLambdaMember`; transporting it through signatures is
   strictly redundant (callers already receive the def's identity via the
   `standaloneMemberWith` `g|` spine injection — which GROUNDS under LSS_019 —
   and via `injectArgLambdaMember` translate-side) and strictly harmful (raw `l|`
   ids decline at AbiCloning per LSS_017; the `trivial` short-circuits die
   globally; Phase C/D metrics drown). Inner-lambda ids are NOT filtered — those
   are genuine body contributions. Alternative (keep the self-id, re-baseline the
   trivial metric) recorded and rejected for the cost reasons above.
g. The shared descent helper (total; store reads only; `seen` mirrors
   `spineGoC`'s defensive alias-cycle guard :1039-1081; `Store.arrowParts`
   handles Fun1+FunL but NOT Alias, Store.elm:771-781 — the Alias arm here is
   mandatory; single-hop `Link` name assumption documented in §E.1):

```elm
bindParamsFromSpine :
    List Name -> IO.Variable -> Dict Int () -> LetEnv -> Engine.S
    -> ( LetEnv, Maybe IO.Variable, Engine.S )
bindParamsFromSpine names v seen letEnv s0 =
    case names of
        [] ->
            ( letEnv, Just v, s0 )
        n :: rest ->
            let
                key = Engine.pointKey v
                ( store1, desc ) = UF.get v s0.store
                s1 = { s0 | store = store1 }
            in
            if CoreDict.member key seen then
                ( letEnv, Nothing, s1 )
            else
                case desc.content of
                    IO.Alias _ _ _ real ->
                        bindParamsFromSpine names real (CoreDict.insert key () seen) letEnv s1
                    _ ->
                        case Store.arrowParts desc.content of
                            Just ( pParam, pRest ) ->
                                bindParamsFromSpine rest pRest (CoreDict.insert key () seen)
                                    (CoreDict.insert n pParam letEnv) s1
                            Nothing ->
                                -- Erased/over-shadowed head: remaining params stay
                                -- untracked — today's behavior, sound.
                                ( letEnv, Nothing, s1 )
```

   Shadowing: `Dict.insert` overwrites — correct (innermost wins). **Reuse
   `letEnv`; no parallel paramEnv** — the existing `VarLocal` arms (:701-705 →
   `joinLetUse`) join every param occurrence for free.
h. **`joinLetUse` cost guard, flag-on only** (§0.4(6) cost correction): with
   params in `letEnv`, `joinLetUse`'s unconditional `loadType meta.tipe` (:1091)
   would fire at every bound-name occurrence program-wide. Flag-on, skip the load
   when `not (canTypeMentionsArrow meta.tipe)` (an arrow-free join writes no
   slots — semantics-free skip). Flag-off path untouched.

### B.2 Control-flow joins (If/Case hubs; Let completion)

New explicit arms replacing the `_` fallthrough for `If` and `Case`. Child-walk
order is EXACTLY today's `directChildren` order (If: `c1,b1,…,finally`,
:1324-1325; Case: `deciderExprs decider ++ jumps`, :1340-1341) so flag-off is
inert; flag-on appends one hub load + joins (or one poison) per arrow-bearing
If/Case:

```elm
TOpt.If branches finally meta ->
    case walkIfPairs letEnv branches [] s0 of        -- conds discarded, branch WalkPoints collected, source order
        Err e -> Err e
        Ok ( branchWps, s1 ) ->
            case walkExpr letEnv finally s1 of
                Err e -> Err e
                Ok ( finalWp, s2 ) ->
                    joinCfHub (finalWp :: branchWps) meta s2

TOpt.Case _ _ decider jumps meta ->
    case walkCollect letEnv (deciderExprs decider ++ List.map Tuple.second jumps) [] s0 of
        Err e -> Err e
        Ok ( wps, s1 ) ->
            joinCfHub wps meta s1
```

```elm
joinCfHub : List WalkPoint -> TOpt.Meta TypeIds.MVarId -> Step WalkPoint
joinCfHub wps meta s0 =
    if not (s0.env.lss.sigFlow && canTypeMentionsArrow meta.tipe) then
        Ok ( WpNone, s0 )
    else
        case Store.loadType meta.tipe s0 of
            Err e -> Err e
            Ok ( hub, s1 ) ->
                if List.all isHonest wps then
                    -- join every branch Point into the hub (all are WpHonest)
                    joinAllSig hub (List.map honestPoint wps) s1
                        |> returning (WpHonest hub)
                else
                    -- §0.4(3): any blind/opaque branch ⇒ ⊤ is the only honest
                    -- summary. Poison + bump widenedByCf.
                    Store.poisonArrowSets hub s1
                        |> alsoBumpWidenedByCf
                        |> returning (WpHonest hub)
```

**Let arm completion** (leak A.1(3)): flag-on, connect the letEnv hub to the RHS
walk. `Def` (defType == rhs type — verified no-regression at TVar positions:
poison on FlexVar content is a no-op):

```elm
TOpt.Def _ name rhs defType ->
    case walkExpr letEnv rhs s0 of
        Err e -> Err e
        Ok ( rhsWp, s1 ) ->
            case Store.loadType defType s1 of
                Err e -> Err e
                Ok ( rhsVar, s2 ) ->
                    case sigFlowJoin (wpPoint rhsWp) rhsVar s2 of   -- single-source: Honest|Opaque join, None skip
                        Err e -> Err e
                        Ok ( _, s3 ) ->
                            walkExpr (CoreDict.insert name rhsVar letEnv) body s3
```

`TailDef` is NOT identical (§0.4(1) — the rhs is the arg-stripped body at the
*result* type; `defType` is the full function type). Flag-on order for TailDef:
load `defType` → `rhsVar`; `bindParamsFromSpine argNames rhsVar` → `( env',
maybeRes, _ )` (binds the tail args — closing leak 1 for local loops — and finds
the spine-end); walk the rhs with `env'`; single-source-join `maybeRes` against
the rhs's returned Point (skip if the peel stopped early); bind `name → rhsVar`;
walk the body. Flag-off: today's exact sequence (walk rhs first, then load
defType, no binds/joins).

The Let arm returns the **body's** WalkPoint verbatim; same for `Destruct`.

**The guard** — new file-local predicate, verbatim copy of the translation-side
"mentions" form `Translate.canTypeHasArrow` (:2416-2442 — TLambda → True; TVar →
False; TType/TTuple → any; TRecord → any over `\(Can.FieldType _ t) -> t`; TAlias
Filled/Holey chase; TUnit → False):

```elm
canTypeMentionsArrow : Can.Type TypeIds.MVarId -> Bool
```

`TVar → False` is deliberate: a pure-TVar position either already connects via
the MVarId memo or is generalized (a join would only poison).

### B.3 Local-callee calls — slot-only (§0.4(4))

`walkCall` gains `letEnv` (sole caller is the Call arm, :649-655) and two arms
before the wildcard. Do NOT route through `unifyCallShape` — that is whole-type
unification (`unifyBestEffort pParam argVar`, :837), and applied to the *shared*
letEnv family Point of a generalized let it concretizes the family on first use
(§7.4 violation; `unifyCallShape` stays only on `applyCalleeAt`'s isolated
instantiations). Instead, a slot-only call shape:

```elm
-- in walkCall (now: LetEnv -> func -> args -> meta -> Step WalkPoint):
TOpt.VarLocal name _ ->
    localCalleeJoin letEnv name args meta s0
TOpt.TrackedVarLocal _ name _ ->
    localCalleeJoin letEnv name args meta s0

localCalleeJoin letEnv name args meta s0 =
    if not s0.env.lss.sigFlow then Ok ( WpNone, s0 )
    else case CoreDict.get name letEnv of
        Nothing -> Ok ( WpNone, s0 )
        Just fVar ->
            -- joinCallShape: descend fVar's spine one arrow per arg
            -- (UF.get + arrowParts + Alias chase, bindParamsFromSpine-style):
            --   per arg, when canTypeMentionsArrow (TOpt.typeOf arg):
            --     loadType (typeOf arg) → argVar; joinArrowSetsSig argVar pParam
            --   at the spine end, when canTypeMentionsArrow meta.tipe:
            --     loadType meta.tipe → callVar; joinArrowSetsSig spineEnd callVar;
            --     return WpOpaque callVar
            --   (early spine stop or arrow-free call type → WpNone)
            joinCallShape fVar args meta s0
```

The result-side join is the payload (`let g = chooseHandler b f h in g x` — the
family's result-arrow members reach the site). The arg-side joins transport
little today (the A.1 arg-load residue) but are cheap, harmless, and become live
if that leak is ever fixed. Global/cycle/kernel callee arms unchanged
(`applyCalleeAt` :750-754, `poisonCallBoundary` :756-760 — until Phase F); the
`VarGlobal`/`VarCycle` arms return `WpOpaque callVar` by having `unifyCallShape`
return its `callVar` (:808-812; its current Ok value is unit and its sole
consumer ignores it — verified safe). The Call arm of `walkExpr` returns
`walkCall`'s WalkPoint and then runs today's `walkChildren letEnv (func :: args)`
unchanged.

### B.4 The signature-channel widening rider + counters (mandatory, same change)

`zonkSigGo` (:531-581) applies no size cap — dormant while signatures are
trivial, live the moment B lands. Edit the `LsMembers` branch (:572-575),
composing with the B.1.f self-filter:

```elm
IO.Structure (IO.LambdaSet1 (IO.LsMembers ms0)) ->
    let ms = filterSelf selfId ms0 in                    -- B.1.f
    if s2.env.lss.sigFlow && List.length ms > s2.env.lss.maxSetSize then
        -- bump sigStats.widenedBySigSize on s2 (unconditional counter)
        { rep = rep, members = [], top = True }
    else
        { rep = rep, members = ms, top = False }
```

(`maxSetSize` reachable exactly as the whole-type cap reads it,
Store.elm:1135/:1408. Members stay ascending end-to-end — `LsMembers` is
ascending by construction and `List.filter` preserves order — so
`applyFactsGo` → `unifySlotWithSet`'s contract holds; verified across every union
path.)

**Counters** (per §0.2): new sub-record on `LssStats` (Engine.elm:103-145 +
`emptyLssStats` :249-251 extended in lockstep):

```elm
type alias SigFlowStats =
    { widenedBySigSize : Int   -- unconditional (policy event, rare)
    , widenedByCf : Int        -- report-gated: hub poisons + poisons inside the new sigFlow joins
    , kernelFactHits : Int     -- report-gated: Phase F fact-row applications
    }
-- LssStats gains: , sigStats : SigFlowStats
```

Engine helpers (idiom = `bumpWidenedByKernel`, :416-422): `bumpWidenedBySigSize`
(plain); `bumpWidenedByCf` / `bumpKernelFactHit` (each internally
`if s.env.lss.report then … else s`).

**Attribution:** `joinArrowSets` gains an `onPoison : Engine.S -> Engine.S` first
parameter, applied by `poisonBoth` once per event; `joinLetUse` passes `identity`
(the let channel's number is frozen Run-J data; Phase H may re-tag);
`joinArrowSetsSig = joinArrowSets Engine.bumpWidenedByCf` is used by every join
this plan adds. `joinArrowSetsList`/`joinArrowSetsPairs`/`poisonBoth` thread the
parameter. (Phase H.2 later widens this parameter into a poison *mode*; design
for the parameter, don't over-build it now.)

**Report** (`renderLssReport`, Monomorphize.elm:134-244): extend the `widened:`
line (:217) with `" bySigSize=" ++ …`; add after `grounding:` (:236):
`"sigflow: widenedByCf=" ++ … ++ " kernelFactHits=" ++ …`.

### B.5 Flag, cost, gates

**Flag wiring** — `lss.sigFlow : Bool`, default `False`, env
`ECO_MONO_LSS_SIG_FLOW`, hash token `lssSF=` non-default-only. Exactly these
edits (pattern = `groundStandalones`; the JSON decoder is a POSITIONAL apply
chain — append LAST or two flags silently swap, comment at Config.elm:669-671):

1. `Compiler/Eco/Config.elm` :261-262 — `, sigFlow : Bool` last in `LssConfig`,
   LSS_020-citing doc comment.
2. :294-295 — `, sigFlow = False` last in `defaultLss`.
3. :674 — append last in `lssDecoder`:
   `|> D.apply (D.optionalField "sigFlow" D.bool defaultLss.sigFlow)`.
4. Hash LSS block after :948 — muTie-style two-way token:
   `if lss.sigFlow /= defaultLss.sigFlow then [ "lssSF=" ++ (if lss.sigFlow then "1" else "0") ] else []`.
5. `Builder/Eco/Config.elm` after :1678 — `applyLssSigFlowOverride`, clone of
   `applyLssGroundOverride` (:1658-1678) targeting `{ lss | sigFlow = … }`.
6. Same file: `applyEnvOverrides` chain after :159 (binder `cfg4e3`) + doc row at
   :80-84.
7. Consumption: `s.env.lss.sigFlow` inline (no Env/S/initState changes).

**Artifact-affecting under keying** (signature members reach caller
instantiations → annotations → keys) — hence the token and the full battery.

**Cost model (corrected — verify at B-battery, not after D):** flag-on load
classes are (a) one hub load per arrow-bearing If/Case (guarded), (b)
`joinLetUse` loads at `letEnv`-bound occurrences — with params now bound this is
the dominant class, mitigated by the B.1.h `canTypeMentionsArrow` occurrence
guard (arrow-free param uses skip the load entirely), (c) `joinCallShape`'s
guarded arg/result loads at local-callee sites, (d) TailDef `defType`
loads/binds. Everything else is UF.gets and joins on already-loaded Points; the
value-returning refactor itself adds zero. Separately, the `trivial`
short-circuits (`applyFacts` :199, `Translate.lssFastOk` :2398-2412) run less
often as signatures go nontrivial — the B.1.f self-filter keeps that population
honest (only defs with REAL flow go nontrivial), but the slow-call-path share
still grows; watch the full-build wall (`PhaseMono` is blind on kernel-package
builds — fast-census loop first, then native).

### B.6 Tests

**Unit — new `compiler/tests/TestLogic/Monomorphize/LssSigFlowTest.elm`** (no
registration: elm-test-rs auto-discovers under the `compiler/tests` symlink).
Skeleton = `MuTieTest.elm` (suite / HARNESS / FIXTURE); fixtures via
`Compiler.AST.SourceBuilder.makeModuleWithTypedDefs "Test" [ …, testValueDef ]`
(builders: `lambdaExpr` :263, `ifExpr` :277, `callExpr` :270, `varExpr` :189,
`tLambda` :727, `tType` :734, `pVar` :343; **use built-in types only — `H = Int
-> Int` — or switch to `makeModuleWithTypedDefsUnionsAliases` :843; plain
`makeModuleWithTypedDefs` emits no type declarations and the pipeline
typechecks**); run via

```elm
Pipeline.runSolverMonoWithLimits Config.defaultLimits
    { defaults | enabled = True, keyed = True, sigFlow = flag } fixtureModule
```

Assertions are graph-observable: fold `graph.registry.reverseMapping`
(`Array (Maybe ( Global, MonoType ))`, Monomorphized.elm:1677; MuTieTest.elm
:174-189 precedent) to the fixture global's stored demand `MonoType` and inspect
arrow annotations (`MFunction Int LambdaSetAnno …` :239, `headAnno` :1088,
`LambdaSetAnno = LTop | LSet (List Int)` :858-860 — all exposed). Cases:

1. `chooseHandler b f g = if b then f else g` at
   `Bool -> (Int->Int) -> (Int->Int) -> (Int->Int)`, caller passes two distinct
   lambdas → flag-on: result-arrow anno of the stored demand is `LSet` with
   exactly 2 members (rep links transported both); flag-off: no set.
2. Body-lambda member transport (as built: `mk2 s = if s then λ₁ else λ₂` —
   two lambda literals meeting in the hub, chosen over the draft's
   `mk f = \x -> f x` because an uncurrying canonicalization could merge the
   inner lambda into the def's own self-filtered id) → result-arrow demand
   anno is a 2-member `LSet` flag-on only (raw `l|` ids; NOT filtered — only
   the def's own self-id is; caller-side fate is Phase C's subject).
3. Negative control `apply f x = f x` (polymorphic) → flag-on/flag-off stored
   demands identical (the self-filter makes this hold; without it every def goes
   nontrivial — §0.4(2)).
4. **Honesty pin (§0.4(3))**: `pick b r = if b then negate else r.handler` (or
   a Call in the blind branch) → flag-on the result-arrow demand anno is `LTop`,
   NOT an `LSet` singleton — asserts the hub poisons on mixed branches. This is
   the anti-miscompile regression test; do not skip it.
5. **TailDef pin (§0.4(1)) — as built**: a top-level self-tail-recursive,
   FUNCTION-RETURNING def (`countdown n k = if n == 0 then k else countdown
   (n - 1) k` at `Int -> (Int->Int) -> (Int->Int)`, caller passing a named
   global) → flag-on the result-arrow demand anno is a 1-member `LSet` (the
   caller's `k` member via rep transport — pins the arg-peel, the root-spine
   arg binding, AND `WpSelf`: a broken peel poisons the whole signature and a
   `WpNone` tail call poisons the hub, both of which read `LTop` here);
   flag-off it is `LTop`. (The draft's Int-result local-loop variant asserts
   nothing — an arrow-free If never loads a hub.)
6. A `> maxSetSize` signature arrow (fixture LssConfig `maxSetSize = 1`, 2-lambda
   join) → demand `LTop` AND report contains `bySigSize=1` — via a new
   `runSolverMonoWithReport` twin of `TestPipeline.runSolverMonoWithLimits`
   (:429-444; set `report = True`, return the `Maybe String`; add to exposing
   list :1-25).

Single-file run:
`PATH=/work/build/toolchain/bin:$PATH /work/build/toolchain/bin/elm-test-rs --project /work/build/compiler/build-xhr --fuzz 1 /work/build/compiler/build-xhr/tests/TestLogic/Monomorphize/LssSigFlowTest.elm`

**E2E — new `test/elm/src/LssSigFlowTest.elm`** (zero CMake edits — directory
glob through the configure-time symlink; MUST have top-level `main`). House style
= `LssSharedSpecJoinTest.elm`: doc comment citing this plan + LSS_020; a
`chooseHandler`-style def; a caller passing a lambda through it into a call site;
`Debug.log`-based `-- CHECK:` behavior assertions plus `-- CHECK-MLIR:` /
`-- CHECK-MLIR-NOT:` structure assertions (the 2-member site does NOT emit a
`$cap` direct call — honest join, no false singleton; a single-branch variant
still devirts/stamps; exact MLIR patterns pinned from the actual `--emit=mlir`
output at implementation time — `{{regex}}` supported, CheckPatterns.hpp:31-33).
Flag-on legs: `ECO_MONO_LSS_SIG_FLOW=1` in the build env, purge
`build/test/*/eco-stuff`, `touch` the fixture (env-blind harness cache).

### B.7 Battery (flag-on gate for the B default-off landing)

1. `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt` — ONCE;
   grep the file. Flag-off leg first: E2E 1,682/1,682, out.mlir byte-identical to
   the pre-change binary's (the refactor + gated joins must be flag-off inert).
2. Flag-on leg (`ECO_MONO_LSS_SIG_FLOW=1`, eco-stuff purged, fixtures touched):
   suite green; self-compile bootstrap fixed point; `LssSharedSpecJoinTest`
   (LSS_010) green; `joinRounds` in normal band (baseline 3);
   `unqualifiedLambdaMints = 0`; `widenedByBudget` vs 36,693 recorded (fan-out
   early warning); `signatures:` trivial count recorded (the self-filter should
   keep the trivial share high — a collapse toward 0 trivial means the filter is
   not working).
3. Suites serial (`~/.eco` typed-artifacts race); never re-run — grep
   `/tmp/test_output.txt`.

## Phase C — signature-transported members meet Fix B (verify, don't assume)

Post-B, signatures can carry raw `l|` ids of **body-internal** lambdas (the
self-id is filtered, B.1.f; inference-phase mints are deliberately raw —
Engine.elm:287-290; LSS_017 makes raw singletons decline at AbiCloning:
unstampable-but-sound). With plan 2, `g|`/`c|` signature members are provisional
and ground at the *caller's* zonk (plan 2 §9: `zonkSigGo` reads slots directly —
as-built). The fork plan's §8 open item activates HERE:

- **C1 (census):** count sites whose singleton is a signature-transported raw
  lambda — `declinedNoInstance` upticks (baseline 1,378; `bumpNoInstance`
  AbiCloning.elm:1475-1481) with the member id in `declineByMember` (:1172;
  report `member:count:repSyms`, Builder/Generate.elm:1218). If material, the
  recorded v2 is enqueue-time qualification (fork plan §8: "qualify at the moment
  the callee spec id is created … rewriting demand types before keying") — file
  as its own plan; do NOT improvise it here.
- **C2 (invariant):** amend LSS_017's row, filling the magnitude from C1:
  "AMENDED <date>: under lss.sigFlow (LSS_020) signatures are a live raw-l|
  channel for body-internal lambdas (<C1 count> declined-singleton sites on the
  self-compile); the decline path is the enforced handling; enqueue-time
  qualification is the recorded v2 if that mass is material."

## Phase D — the re-census (the §8 pivot point)

One instrumented self-compile — fast-census loop first (stage-1 JS compiler; 1/3
cost, reproduces the native census), native to confirm — `ECO_MONO_LSS_REPORT=1`,
flag-on vs flag-off same binary, archived in §Results as the next Run letter in
`benchmarks/lss-opt.md` (Run X). The numbers that gate everything downstream
(live counters unless marked FROZEN):

| number | source | gates |
|---|---|---|
| unconstrained-⊤ share = `setsZonked − Σ sizeHist − widenedBySize` (no in-code LTop line; LsTop and FlexVar zonks bump `zonked` with no hist entry, the over-cap arm bumps `zonked`+`widenedBySize`; **byKernel/byBudget/bySigSize are NOT zonk-accounted — do not subtract them**; the ⊤ bucket includes poison-written LsTop slots, so attribute component (iii) with the `widened…` counters alongside, not inside, the formula) | report | aim-1 scorecard; GAP-2 success = material drop from the 89.3%/E0.5 shape |
| `signatures: N memoized (M trivial)` | report :215 | GAP-2 success metric (baseline 9,651/9,651 Run J; re-read flag-off leg; 8,673 is the E0.5 figure) |
| `sizeHist` k≥2 mass + `multiSetSiteHist` | report :216 + AbiCloning census | **GAP-6 decision input** |
| `widenedBySize` / `widenedBySigSize` | report :217 | **GAP-5 decision input** |
| `widenedByBudget` | report :217 | budget-policy check vs plan 1 B3 (Run N; 36,693 baseline) |
| `widenedByLet = 672`, `localMultiBypass = 469` | **FROZEN Run J** — RE-MEASURED 2026-08-21: 690 (sf-off) / 2,013 (sf-on), and 455 | **Phase H sizing** — DONE, verdict PARK (`plans/lss-per-use-let-separation.md` §2.R) |
| `widenedByCf` + `topSiteShapes local` residue | new counter + AbiCloning census (baseline local=7,361, pre-plan-2 era — re-read) — RE-MEASURED un-gated 2026-08-21: local=17,332 but only 12.5% of ⊤ sites | **Phase H sizing** — DONE, verdict PARK; the ⊤ mass is global/kernel-callee, not local |
| `topSiteShapes` split | AbiCloning census (print Generate.elm:1233) | escape-floor vs reachable residue |
| dispatch stamps (`dispatchUpgraded`, `declinedNoInstance`, `declinedBlocked`) + runtime dispatch census | GlobalOpt census + `benchmarks/runtime-calls.md` Run-M protocol (`ECO_DISPATCH_STATS=1`, counters-lowered binary, cold Stage 7a, non-perturbation gate) | non-regression + payoff (baseline fast coverage 13.22%) |

Honesty rule (mapping doc §6): keep the three unconstrained-⊤ components
separate — (i) signature channel (now repaired — measure the residue, including
the A.1 arg-position leak for both global and local callees), (ii) let/local
(Phase H's input), (iii) escape-by-soundness floor (IO bind continuations — no
analysis helps; do not chase).

**Default-flip decision rides D:** flip `sigFlow = True` (+ token to the =0 side,
`defaultLss`, module docs, LSS_020 row) only if D shows material precision gain
at acceptable spec growth; otherwise the flag waits on the plan-1 B3 budget
question.

## Phase E — GAP-7: the two `VarCycle` seams (small, battery-gated, no flag)

*(Correction vs draft: `walkCall` already routes `VarCycle` callees to
`applyCalleeAt` (:753). The seams are mint-side depth and the Translate arm.)*

1. **Head-only cycle mints** (`walkExpr` VarCycle arm, :683-689). Blocker: the
   `declaredArityOf` `Link` arm recurses with the *target* global, so the member
   name is gone before the `TOpt.Cycle` node is reached (cycle members map as
   `member → Link(_M$first group)`, LssInfer.elm:87-92). Thread the sought name:

```elm
declaredArityOf : TOpt.Global -> Int -> Engine.S -> Int
declaredArityOf ((TOpt.Global _ name) as g) fuel s =
    declaredArityGo name g fuel s

declaredArityGo : Name -> TOpt.Global -> Int -> Engine.S -> Int
declaredArityGo sought g fuel s =
    if fuel <= 0 then 1
    else
        case HashMap.get TOpt.globalHash (==) g s.env.toptNodes of
            Just (TOpt.Ctor _ arity _) -> arity
            Just (TOpt.Box _) -> 1
            Just (TOpt.Link target) ->
                -- `sought` stays the ORIGINAL name across hops: correct for the
                -- documented single-hop member→Link(group) pattern; a multi-hop
                -- chain through a differently-named global floors at 1 (sound).
                declaredArityGo sought target (fuel - 1) s
            Just (TOpt.Define (TOpt.Function _ params _ _) _ _) -> List.length params
            Just (TOpt.TrackedDefine _ (TOpt.Function _ params _ _) _ _) -> List.length params
            Just (TOpt.Cycle _ valueDefs funcDefs _) ->          -- NEW (E.1)
                cycleDefArity sought valueDefs funcDefs
            _ -> 1

cycleDefArity : Name -> List ( Name, TOpt.Expr TypeIds.MVarId ) -> List (TOpt.Def TypeIds.MVarId) -> Int
cycleDefArity sought valueDefs funcDefs =
    -- funcDefs: Def _ n body _ (n == sought) → params of a Function/Tracked-
    -- Function body, else 1; TailDef _ n args _ _ _ (n == sought) → length args.
    -- valueDefs hit → 1. Not found → 1.
```

   The VarCycle arm swaps `(\_ -> 1)` for
   `spineDepthForGlobal (TOpt.Global home name)` — riding `lss.spineArity`
   exactly as the VarGlobal arm (S.10; :923-929 gates and floors at 1, so with
   the default `spineArity = False` E.1 is dormant). **Blast radius note
   (intended, symmetric):** the Cycle arm also deepens the
   VarGlobal/VarEnum/VarBox mint arms (:674/:678/:681) and
   `Translate.standaloneArgMember` (:3141) for *cross-module references to cycle
   members* (they are VarGlobals whose node is `Link(group)`) — all through the
   one shared function, both sides in lockstep, covered by the same battery.

2. **`injectArgLambdaMember` has no VarCycle arm** (Translate.elm:3091-3130,
   wildcard :3129-3130): insert before the wildcard, mirroring the VarGlobal arm
   WITHOUT the kernel-alias fold (`kernelAliasOf` can never return Just for a
   cycle member — Link→Cycle→wildcard):

```elm
        TOpt.VarCycle _ home name _ ->
            standaloneArgMember ("g|" ++ TOpt.toComparableGlobal (TOpt.Global home name))
                (TOpt.Global home name) canVar
```

   A cycle member passed as a function argument then transports its member like
   any global (and grounds at zonk per LSS_019 — `standaloneMemberIdFor` records
   it provisional). Update the now-false half of the :683-689 comment ("the
   translation-side twin has no VarCycle arm at all").

Artifact-affecting under keying (new members) → standard battery (`--target
full`, bootstrap fixed point, census delta noted — E.2 is live immediately, E.1
only under `spineArity`). The specialization unit stays per-member — LSS_010
flush IS the demand-driven equivalent of the paper's §6.3; do not unify the spec
unit.

## Phase F — GAP-4: kernel per-param set-flow facts (incremental, audit-driven)

Calibration today: LSS_004 poisons every kernel/port/debug-crossing arrow
(`byKernel = 4,062`); `List.map/foldl/foldr/filter` are plain Elm and already
unpoisoned; kernel-backed HOFs are `map2-5`, `sortBy`, `sortWith` (shipped core
`List.elm:437-504`).

### F.1 The fact table

New module `Compiler/MonoSolver/KernelSetFacts.elm` — deliberately parallel to
`Compiler.GlobalOpt.KernelFacts` (the audited-facts precedent: `(Name, Name)`
lookup :236-238, mandatory C++ `evidence` strings, "unknown ⇒ consumer keeps its
own default") and to the planned `hofParams` of
`plans/effect-polymorphic-purity.md`. Separate tables so each audit stands alone.

```elm
module Compiler.MonoSolver.KernelSetFacts exposing (ParamSetFlow(..), KernelPlan, planFor)

type ParamSetFlow
    = PSFOpaque      -- default: this position's arrows poison (today's behavior)
    | PSFApplies     -- kernel only CALLS the functional param (never stores/returns
                     -- it): its arrow slots need NO poison — the set stays whatever
                     -- the caller knows; the kernel adds no inhabitants
    | PSFTunnels     -- kernel returns the param (or stores it into the result):
                     -- its arrows join the RESULT's matching arrows (set-slot-only,
                     -- symmetric joinArrowSets — consistent with §A.2)

type alias KernelPlan =
    { params : List ParamSetFlow   -- Elm-visible params, in order
    , result : ParamSetFlow        -- PSFOpaque = poison result (today); PSFApplies = skip
    , evidence : String            -- C++ file:function:lines, mandatory
    }

planFor : Name -> Name -> Int -> Maybe KernelPlan
planFor home name arity =
    -- Dict.get ( home, name ) facts, and ONLY if List.length plan.params ==
    -- arity (mismatch ⇒ Nothing ⇒ full poison).
```

Initial rows (2026-08-20 C++ audit; shared driver `kernelListMapN`,
ListExports.cpp:432-590 — callback rooted and applied via
`eco_apply_closure_eval` at :567-569, result built from returns only; cite these
in each row's `evidence` and commit message, one kernel per commit):

| key | params | result | evidence |
|---|---|---|---|
| `("List","map2")` | `[PSFApplies, PSFOpaque, PSFOpaque]` | `PSFOpaque` (PAP-of-callback hazard, §0.4) | `ListExports.cpp:Elm_Kernel_List_map2:592-600 → kernelListMapN:432-590 (apply :567-569)` |
| `("List","map3")` | `[PSFApplies, PSFOpaque ×3]` | `PSFOpaque` | `:602-611` |
| `("List","map4")` | `[PSFApplies, PSFOpaque ×4]` | `PSFOpaque` | `:613-623` |
| `("List","map5")` | `[PSFApplies, PSFOpaque ×5]` | `PSFOpaque` | `:625-639` |
| `("List","sortBy")` | `[PSFApplies, PSFOpaque]` | `PSFOpaque` | `Elm_Kernel_List_sortBy:759-831 (callUnaryClosure :787; keys feed stable_sort only :805-825)` |
| `("List","sortWith")` | `[PSFApplies, PSFOpaque]` | `PSFOpaque` | `Elm_Kernel_List_sortWith:832-895 (callBinaryClosure :873; result via listFromPermutation :885)` |

v1 ships no `PSFTunnels` rows (sortBy/sortWith's list-param→result permutation is
the future refinement; opaque result is sound). Extend by the `kernelMissHist`
census top entries (report "kernel whitelist misses", Monomorphize.elm:241 — a
heat proxy for hot kernel-HOF boundaries). Audited next-candidate verdicts on
file: `String.map/filter/any/all/foldl/foldr` and `JsArray.map/initialize` are
apply-only (PSFApplies-eligible); **`Scheduler.andThen/onError/binding/receive`
STORE the callback into the returned Task (Scheduler.cpp:144-162) — never add
PSFApplies rows for them** (copy KernelFacts.elm:33-38's rejected-storage
precedents into the module doc). While here: fix KernelFacts.elm's stale
sortBy/sortWith evidence anchors (:677/:751 → ListExports.cpp:759/:832).

### F.2 Consumers of the table (both sides consult `planFor` — LSS_006-style two-sided discipline)

**Inference side** — `walkCall`'s kernel arm un-wildcards the identity
(`TOpt.VarKernel _ _ home name _ -> kernelCallBoundary home name args meta s0`;
`VarKernel A.Region prefix home name meta` per TypedOptimized.elm:159 — home/name
at positions 3/4, matching the `"k|" ++ home ++ "." ++ name` mints at
LssInfer:691/Translate:3117. VarDebug keeps plain `poisonCallBoundary`; those are
the only two `poisonCallBoundary` callers):

```elm
kernelCallBoundary home name args meta s0 =
    case KernelSetFacts.planFor home name (List.length args) of
        Nothing ->
            poisonCallBoundary args meta s0     -- incl. partial applications
        Just plan ->
            -- zip args with plan.params:
            --   PSFOpaque  → load arg type + poisonArrowSets (poisonArgList body, :869-886)
            --   PSFApplies → nothing (no load; the arg expr is still walked by the
            --                Call arm's walkChildren — member mints unchanged)
            --   PSFTunnels → load arg type; joinArrowSets vs the result load
            -- result row: PSFOpaque → load meta.tipe + poison (as :856-861); else
            --   load only if some PSFTunnels needs it.
            -- bump widenedByKernel ONCE iff any position poisoned (keeps the
            -- counter's meaning); bump kernelFactHits (report-gated).
```

**Translation side** — `poisonKernelArrowsThen` (:3347-3358) gains the kernel
identity; both callers hold `kernelId : ( String, String )`
(`deriveKernelAbiTypeWith` composes it at :3339; `deriveKernelAbiTypeRef`
:3235-3237):

```elm
poisonKernelArrowsThen : ( String, String ) -> IO.Variable -> Step IO.Variable
-- lss off: unchanged pass-through. lss on:
--   descend funcVar's spine (UF.get + arrowParts + Alias chase) counting arrows;
--   planFor home name <arrows found up to List.length plan.params>:
--     Nothing (no row, or the spine has fewer arrows than the row's params —
--       i.e. a partially-applied or reshaped scheme) → poisonArrowSets funcVar +
--       bumpWidenedByKernel (today's behavior)
--     Just plan → per param position: PSFOpaque → poisonArrowSets on that param
--       var; PSFApplies → skip; PSFTunnels → joinArrowSets vs the spine-end
--       result var; result row per plan.result. bump kernelFactHits.
-- The two sides may disagree on a partial kernel application (inference sees the
-- call's arg count, translation the scheme's spine): both then fall back to full
-- poison independently — sound; the asymmetry is accepted and recorded here.
```

**Ordering (corrected — §0.4(5)):** on the call path the composition
`Engine.andThen poisonKernelArrowsThen funcVarStep` (:3339) runs the step FIRST
(`Engine.andThen`, Engine.elm:675-683), and `deriveKernelAbiTypeCall`'s step
already contains `unifyParamsWithArgExprs` (:2862-2865) — so poison runs AFTER
arg unification, before zonk. A PSFOpaque position's poison therefore
deliberately reaches the arg-shared family (today's semantics); a PSFApplies
position simply never poisons — the skip needs no ordering assumption. Fix the
stale doc comment at :3342-3345 ("before it is … unified with args") in the same
change.

- Census: `widenedByKernel` should drop per landed row (baseline 4,062);
  `kernelFactHits` records applications.

### F.3 The `kernelToSig` prerequisite (only if `k|` spine injection is wanted)

`k|` members are head-only at all three mint sites (LssInfer:666-670, :691-695;
Translate `standaloneArgKernelMember` :3147-3155) because `kernelToSig` —
**`Compiler/GlobalOpt/Borrow/LssFacts.elm:344-364`** — decomposes only the top
`MFunction` (:334-341) and would pair the FULL declared `ksig.params` mode list
against a residual param row at an inner arrow. Fixing that alignment is a
PREREQUISITE for `k|` spine injection and NOT required for F.1/F.2 (which only
remove poison). Keep it a separate optional step: fix the alignment, add a
regression test on a 2-stage kernel type, THEN extend the kernel mint arms past
depth 1. If not done, record head-only as the standing calibration.

Each F increment: `--target full` + census delta + the kernel's own E2E tests; no
flag (poison removal is behavior-neutral by LSS_005 — annotations/tiers only —
but artifact-affecting under keying → battery per increment; batch rows after the
first two prove the pattern).

## Phase G — GAP-6 decision gate and GAP-5 rider (decision procedure, not code)

Inputs: Phase D's k≥2 numbers. Procedure (mapping doc §8: "GAP-2 first,
re-census, only then revisit M5"):

1. If multi-member sets remain ≈0.8%-of-arrows-shaped and cold in
   `multiSetSiteHist` → record **NO-GO CONFIRMED** for sum lowering in
   `design_docs/monomorphization/capture-union-representation.md` (append a dated
   section citing Run X) and CLOSE GAP-6 — the M5 evidence then stands on its
   own, no longer "downstream of GAP-2".
2. If k≥2 is now material → re-open via
   `design_docs/monomorphization/multiset-defunctionalization-design.md`, whose
   §7 defines the deciding census (Run-M harness; plannability bar: closure-mode
   apply events ≥ ~1% of dispatch events AND top ~20 sets ≥ half); that becomes
   its own plan. Do not build lowering inside this series.
3. **GAP-5 rider:** only in case 2 (a default-on multi-member consumer exists or
   is being built), raise `maxSetSize` (JSON-only knob, `mono.lss.maxSetSize`,
   Config.elm:666 — no env var; it DOES hash, `lssS=`) and re-census
   `widenedBySize`/`widenedBySigSize`; in case 1, leave it at 8 and note why in
   §Results. (G-1 MapTemplate's multi-member arm is default-off and Borrow's meet
   is call-site-only — neither forces the raise; say which consumer flipped if
   one does.)

## Phase H — GAP-9 repair: per-use let-set separation (sized, then built or parked)

**OUTCOME 2026-08-21: SIZED, AND PARKED.** The census ran on its own plan
(`plans/lss-per-use-let-separation.md` §2.R), both `lss.sigFlow` arms, and both
halves measure empty. H.1: the channel moves no content use→rhs — `intoRhs` and
`both` are 0, and both the exact-lower-bound and the upper-bound sibling measures
are 0/0/0, over a real multi-use population (371 sf-on / 2,018 sf-off bindings
used more than once). H.2: `poisonUseFault = 0` — all 2,703 poison events across
the two arms are rhs-at-fault (2,653) or shape divergence (50), i.e. exactly the
arm whose per-arm soundness argument REQUIRES poisoning both sides — and each
destroys zero rhs set slots. H.1's local-multi half re-measures 455 (frozen 469)
and stays E4a's. The frozen trigger numbers below are superseded: 672 → 690
sf-off (validating the instrumentation), and `topSiteShapes local` 7,361 → 17,332
un-gated but only 12.5% of the ⊤ mass, which is 64.9% global-callee and 21.1%
kernel-callee. Nothing in this phase was built.

Trigger: the FROZEN Run-J numbers (`widenedByLet = 672`, `localMultiBypass = 469`
vs `topSiteShapes local = 7,361`) plus Phase D's `widenedByCf` and local-⊤
residue. Plan 1 §7.4 records this phase as **leaning PARK** — if the combined
mass is not material against the remaining unconstrained-⊤, park with the
numbers recorded.

If built (both halves artifact-affecting under keying → standard battery each):

1. **Local-multi bypass — corrected mechanism (§0.4).** The draft's
   `injectArgLambdaMember arg freshVar0` is a no-op: the local-multi arm
   (Translate.elm:2941-2965) fires only for local refs (`localMultiArgName`
   :3025-3045 requires `accessedLocalName`), and `injectArgLambdaMember` has no
   `VarLocal` arm. In preference order: (a) verify whether E4a's
   `enrichLocalMultiUses` overlay (:4816-4856, from `buildLocalDefs`'
   re-translated instance types) already closes GAP-9b at the USE — if the Run-X
   census shows member-bearing overlay types feeding the instances, H.1 is DONE;
   (b) if not, enrich `freshVar0` from the local's environment annotation — the
   deliberate skip is `enrichFromEnv` (:3160+, comment :3164-3167); lifting it
   for the local-multi arm imports the local's zonked set (over-approx union —
   sound) into the per-use instantiation, which `translateArgsWith`'s
   `zonkToMono freshVar0` (:3004-3015) records per-instance. Census: a
   re-instrumented one-shot `localMultiBypass` (report-gated) should collapse
   toward 0.
2. **Per-use let sets in inference — asymmetric poison (supersedes the draft's
   isolated-copy sketch; an isolated re-load carries no members, §0.1, so
   joining against it equals not joining — the actual objective is directional
   poison).** Widen B.4's `onPoison` parameter into a mode: `PoisonBoth` (every
   caller except `joinLetUse`) vs `PoisonUseOnly` (`joinLetUse`, flag-on): on
   divergence, poison only the use-side subtree.

   **Soundness (writer inventory — the recursion-order argument alone is
   incomplete):** (i) at a divergence point no slot at-or-below it on that path
   has been unified (the FunL arm unifies slots *before* recursing, so shared
   ancestors joined symmetrically exactly as today; the divergent node itself is
   never FunL×FunL) — so switching modes loses no *existing* member write in
   either direction, only the incoming ⊤; (ii) *future* writes into the use-side
   subtree cannot silently miss the family because every writer that injects
   real inhabitants into a let value's arrows targets the FAMILY Point
   (`joinLetUse` and B.3's `joinCallShape` both go through `letEnv`), HOF-
   signature injections are severed from both sides by the A.1 arg-load residue,
   and CF-hub writes into use slots describe the conflated branch value, not the
   let value. **This inventory is load-bearing: any future change that writes
   inhabitants into a USE-side load (e.g. an inference-side fix of the A.1 arg
   leak) must write into the family Point instead, or PoisonUseOnly becomes
   under-approximating.** Use-side semantics stay exactly today's; the family is
   simply never poisoned by uses. Counter `letPoisonAsym` (report-gated) counts
   remaining true incompatibilities. Fixtures: one let-bound function used at
   two layouts (compatible use keeps a real set; flag-off both read ⊤), plus a
   divergent use whose surrounding context later receives sig members (asserts
   no false-narrow set forms).

## Invariants delta (this plan)

- **LSS_020**;Monomorphization;LambdaSets;implemented;Under lss.sigFlow (env
  ECO_MONO_LSS_SIG_FLOW, hash lssSF= non-default-only) the inference walk is
  value-returning with a three-class honesty contract (WpNone/WpHonest/WpOpaque)
  and connects ground-typed intra-def flow to signature slots: member-root joins
  (TailDef roots arg-peeled), param binding via the lambda's own spine into
  letEnv, lambda result-position joins, If/Case hub joins (canTypeMentionsArrow-
  guarded; a hub PUBLISHES members only when every branch is WpHonest, else it
  POISONS — partial joins are a false-singleton miscompile vector), Let rhs
  joins, and slot-only local-callee call-shape joins — all set-slot-only (never
  whole-type unification across generalization boundaries, design §7.4). The
  def's own self lambda-id is filtered at signature readback (redundant with
  standalone g| spine injection, which grounds per LSS_019); signature readback
  applies the maxSetSize policy (widenedBySigSize). Symmetric joins are the
  paper's TIU semantics — directed inclusion (FromArrow) deliberately NOT
  implemented (snapshot reads under-approximate: applyFacts precedes arg
  unification). Flag-off the walk performs today's store-operation sequence
  exactly;Compiler/MonoSolver/LssInfer.elm walkExpr/walkMembers/
  bindParamsFromSpine/joinCfHub/joinCallShape + tests:
  compiler/tests/TestLogic/Monomorphize/LssSigFlowTest.elm +
  test/elm/src/LssSigFlowTest.elm
- **LSS_021**;Monomorphization;LambdaSets;implemented;Kernel arrows poison per
  KernelSetFacts — PSFApplies params keep their sets, PSFTunnels params join the
  result (symmetric, set-slot-only), everything else (every PSFOpaque position,
  every kernel without a row, every arity-mismatched boundary) poisons as
  LSS_004. Inference (kernelCallBoundary) and translation
  (poisonKernelArrowsThen, which runs AFTER arg unification on the call path —
  the skip needs no ordering assumption) consult ONE table function
  (KernelSetFacts.planFor, (Name,Name)-keyed); each row cites its audited C++
  source in a mandatory evidence field (KernelFacts.elm discipline);
  callback-storing kernels (Scheduler.andThen class, Scheduler.cpp:144-162) are
  recorded as rejected rows;Compiler/MonoSolver/KernelSetFacts.elm +
  Compiler/MonoSolver/LssInfer.elm kernelCallBoundary +
  Compiler/MonoSolver/Translate.elm poisonKernelArrowsThen
- Amend **LSS_004** to reference LSS_021 as its calibrated refinement; amend
  **LSS_017** per Phase C2 (magnitude from C1).

## Execution order

A (recorded in this rewrite) → B.0-B.6 (flag-off mechanism + wiring + unit
tests; flag-off byte-identity gate) → B.7 battery (flag on) → C (census +
LSS_017 amendment) → D (re-census, archive as Run X, default-flip decision) → E
(seams; battery) → G (decision on D's numbers) → F (kernel rows, incremental,
interleavable after D) → H (sized by D + Run J; build or park) → invariants rows.

Test discipline throughout (CLAUDE.md): each suite ONCE with
`2>&1 | tee /tmp/test_output.txt`; grep the file; suites serial; purge
`build/test/*/eco-stuff` between E2E legs; `touch` fixtures before flag-on legs
(env-blind harness cache); `--target full` after any Elm-side change (`check`
consumes stale .mlir) — and note it is `full`'s clean that wipes
eco-boot.js/eco-stuff state, so re-seed the JS bootstrap before fast-census legs;
fast-census loop (stage-1 JS) before native re-measures.

## Risks

- **Precision-driven fan-out**: nontrivial signatures push members into more
  keyed demands → spec growth. MONO_030 watchdogs and LSS_018 μ-tie are the
  installed guards; `widenedByBudget` (baseline 36,693) is the early signal. If
  growth is hot, `sigFlow` stays a flag until the plan-1 B3 budget question is
  settled.
- **Symmetric pollution** (A.2): params gain branch-mates' members → some
  singletons become honest 2-sets. Correctness-direction, but it can regress
  stamped-dispatch counts — the Run-M census bounds the cost; the FromArrow
  re-open criterion is defined in A.2.
- **Walk cost**: the dominant flag-on class is `joinLetUse` loads at bound-name
  occurrences (params!) — mitigated by the B.1.h occurrence guard — plus guarded
  hub/call-shape loads and the shrinking `trivial` short-circuits. Measure at
  B-battery, not after D.
- **Honesty-rule over-poisoning**: the all-WpHonest hub rule converts mixed
  branches to ⊤ (counted by `widenedByCf`). That ⊤ mostly reproduces today's
  end-state (blind = ⊤-on-read), but it can absorb caller-side rep-link benefits
  at those positions. If D shows hub-poison dominating the CF channel, the
  refinement is a finer per-position honesty join, NOT publishing partial sets.
- **Kernel fact errors** (F): a wrong PSFApplies row that lets a stored callback
  keep a narrow set is a miscompile vector — hence per-row C++ citation
  (mandatory evidence), per-row battery, default-opaque, the arity-mismatch
  full-poison rule, and the recorded Scheduler-class rejections. When in doubt, a
  kernel keeps LSS_004 poison.

## Results

### Phase A + B — LANDED 2026-08-20 (default-OFF, `lss.sigFlow = False`)

**What shipped** (all as specified in §B, including the §0.4 corrections and
the `WpSelf` refinement recorded in §B.0):
`Compiler/MonoSolver/LssInfer.elm` (WalkPoint walk, root join + TailDef
arg-peel, param binding, self-id filter, If/Case hubs with the
all-honest-or-poison rule, Let rhs joins, slot-only `joinCallShape`,
`onPoison` attribution, sigFlow-gated `zonkSigGo` cap);
`Engine.elm` (`SigFlowStats` sub-record + `bumpWidenedBySigSize` /
`bumpWidenedByCf` / `bumpKernelFactHit`, the latter two report-gated);
`Monomorphize.elm` (report lines); `Compiler/Eco/Config.elm` +
`Builder/Eco/Config.elm` (flag, JSON, `lssSF=` token, `ECO_MONO_LSS_SIG_FLOW`);
`TestPipeline.runSolverMonoWithReport`;
`tests/TestLogic/Monomorphize/LssSigFlowTest.elm` (7 tests — 2-set rep
transport, body-lambda member transport, polymorphic negative control, the
HONESTY poison pin, the TailDef peel/WpSelf pin, the bySigSize rider);
`test/elm/src/LssSigFlowTest.elm` (behavior pins valid both flag states —
`b: 11` is the runtime anti-miscompile check).

**B.7 battery (all green):**
- Unit suite: 13,133 passed / 12 failed — the 12 are the pre-existing
  typechecker node-grounding gates (baseline 13,126/12; +7 = the new tests).
- Flag-off `--target full`: **1,683/1,683** (baseline 1,682 + new fixture).
- Flag-on E2E leg (`ECO_MONO_LSS_SIG_FLOW=1`, eco-stuff purged, fixtures
  touched): **1,683/1,683**.
- Flag-on FULL bootstrap (`ECO_MONO_LSS_SIG_FLOW=1 cmake --build build
  --target full`): **1,683/1,683** — the compiler self-compiles under
  sigFlow through the watchdogs, and the sigFlow-BUILT compiler passes the
  whole suite (behavioral-correctness gate for the new annotations).
- Flag-off byte-inertness: by construction (every effectful addition gated;
  value-returning refactor adds no store ops) + census zeros below; the
  frozen-corpus byte gate is unsatisfiable across compiler-source changes
  (two binaries / one corpus — established methodology note).

**Self-compile census, one default-built binary, cold Stage 7a, both
workload flag states (2026-08-20):**

| number | flag-off | flag-on | reading |
|---|---|---|---|
| signatures | 9,687 memoized (**9,687 trivial**) | 9,687 memoized (**9,293 trivial**) | **394 signatures (4.1%) go nontrivial — GAP-2's channel is OPEN**; the B.1.f self-filter keeps the trivial fast path alive (without it ~every ≥1-param def would flip) |
| sizeHist k=1 | 64,238 | **95,537** | **+31,299 singleton sets** — the precision payload |
| sizeHist k≥2 | 808/303/123/57/35/14/23 | 813/301/129/56/36/14/23 | k≥2 mass essentially unchanged (GAP-6 input unchanged so far) |
| sets zonked | 367,603 | 405,826 | more fact-reached slots |
| widened bySize / byKernel / byBudget / bySigSize | 43 / 4,065 / 36,788 / 0 | 43 / 4,142 / **38,737** / **0** | budget +1,949 (+5.3%) — modest precision fan-out, watchdogs quiet; **the B.4 rider never fires on this corpus** (no signature arrow exceeds 8) |
| sigflow: widenedByCf | 0 | 5,329 | the new joins' ⊤ source, now counted (Phase H / D input) |
| joinRounds / retranslations | 3 / 595 | 3 / 603 | normal band |
| devirtDirect / devirtKernel | 3,989 / 772 | 3,989 / 772 | no mono-level dispatch regression (gains are AbiCloning/Phase-D territory) |
| grounding grounded / deferred | 4,966 / 11 | **12,555** / 11 | signature-transported provisional members grounding at caller zonks — LSS_019 composing as designed |
| unqualifiedLambdaMints / muTied | 0 / 0 | 0 / 0 | clean |
| out.mlir | 13,592,155 B | 13,622,196 B | +30,041 B (+0.22%) — artifact-affecting as expected |

(Flag-off census matches the pre-change shape — all-trivial signatures,
widenedByCf=0, devirt/grounding at tree-growth-adjusted baselines —
confirming flag-off inertness at the census level.)

### Phase D — DONE 2026-08-20 (Run X, `benchmarks/lss-opt.md`) — **sigFlow stays DEFAULT-OFF**

Two separate A/B measurements, each under its own file's protocol:

1. **Cost/precision — Run X in `benchmarks/lss-opt.md`** (that track's protocol:
   both arms BUILT and MEASURED solver+LSS, flag set at build and workload, one
   cold run per arm). Wall **316.9 → 328.3 s (+3.6%)**, and the census attributes
   it to the analysis doing more work rather than to slower code (sets zonked
   +10.4%, slotsMinted +5.1%, flex set-writes +39%, join-noop 2,156 → 22,074);
   GC agrees — majors 13 = 13, promoted −0.14%, RSS flat, minors +1.5%.
   Precision rows: 394 signatures nontrivial, singletons 64,311 → 95,620,
   grounded 5,014 → 12,602, byBudget +5.3% (watchdogs quiet),
   `widenedBySigSize = 0` (the B.4 rider never fires on this corpus),
   `widenedByCf = 5,329`, `declinedNoInstance` +133 (→ Phase C1), k≥2 and
   `multiSetSites` unmoved (→ Phase G), out.mlir +30,042 B (+0.22%).
   Earlier same-binary workload-flag legs measured the ⊤-share at
   **82.14% → 76.11%** (member-carrying arrows 17.9% → 23.9%).
2. **Payoff — Run-M dispatch census** (`benchmarks/runtime-calls.md` protocol:
   counters-lowered solver-built binaries, cold subst workload so the JOB stays
   constant while the binary changes; `sat+fast` identical both legs = pure tier
   shift; byte-identical workload output = LSS_005 behavioral gate PASS):
   **fast coverage 8.30% → 6.08% (−22.6M stamped events, −26.7% rel).**

**Default-flip decision: NOT FLIPPED.** The precision gain is real and the
costs are absorbable (byBudget +5.3%, out.mlir +0.22%, wall +3.6% and
attributable to analysis work) — but the
one live consumer regresses: symmetric rep-links + honest hubs union
per-branch/per-param flows, so honestly-singleton SITES read
honest-but-multi DEF-level sets and AbiCloning declines their stamps. This
is Risk 2 measured at runtime, and it means **the §A.2 FromArrow re-open
criterion has FIRED**: the recorded path to precision-without-pollution is
directed/per-site fact application (the deferred-constraint flavor §A.2
priced as "the paper's full Q machinery") — filed as
`plans/lss-directed-set-flow.md` (the flip's prerequisite); the Phase F
expressiveness ceiling's successor is filed as
`plans/kernel-parametricity-license.md`. Until then `sigFlow` is a fidelity flag: ON for
census/consumer work (Borrow reads honest sets; grounding 5,014 → 12,602),
OFF for the shipping stamp pool.

### Phase C — DONE 2026-08-20 (census C1 + amendment C2)

C1 rode the Phase D instrumented legs (AbiCloning census, flag-off →
flag-on, same binary): `declinedNoInstance` 1,380 → 1,513 (**+133**);
`declineByMember` top-20 is exactly the predicted population — raw-`l|`
signature-transported body-internal lambdas (`Terminal_Main_lambda_*`, 11
declined sites each). Against 3,579 `dispatchUpgraded` sites and 394
nontrivial signatures the declined-singleton mass is **NOT material** —
enqueue-time qualification (fork plan §8 v2) stays PARKED. C2: LSS_017's
row amended with the measured magnitude (invariants.csv, dated 2026-08-20).

### Phase G — GAP-6 CLOSED: NO-GO CONFIRMED (2026-08-20)

With the signature channel LIVE, k≥2 did not move: sizeHist k=2..8
808/303/123/57/35/14/23 → 813/301/129/56/36/14/23; AbiCloning
`multiSetSites` **`2->2 3->1 5->1` in BOTH flag states**. The M5 evidence is
no longer "downstream of GAP-2" — dated section appended to
`design_docs/monomorphization/capture-union-representation.md` §6.
GAP-5 rider: `maxSetSize` stays 8 (no default-on multi-member consumer
exists; `widenedBySigSize = 0` on the self-compile — the rider never fires).

### Phase E — LANDED 2026-08-20 (both seams; battery green)

`declaredArityOf` → name-threaded `declaredArityGo` + `TOpt.Cycle` arm +
`cycleDefArity` (single-hop Link assumption documented in-code); the
`VarCycle` mint arm rides `spineDepthForGlobal` (dormant at the default
`spineArity = False`); `Translate.injectArgLambdaMember` gained the
`VarCycle` arm (no kernel-alias fold — unreachable for cycle members).
Battery: units 13,133/12-pre-existing; `--target full` **1,683/1,683**.
Census delta (E+F combined leg, default workload): members interned +67,
`devirtDirect` 3,989 → 4,000, `grounded` 4,966 → 5,014 — cycle-member args
now transport and ground as designed.

### Phase F — LANDED 2026-08-20 (v1 rows; battery green)

`Compiler/MonoSolver/KernelSetFacts.elm` (6 audited rows: map2-5 callback
`PSFApplies` + `PSFOpaque` elsewhere incl. results — the PAP-of-callback
hazard; sortBy/sortWith comparator `PSFApplies`; Scheduler-class rejections
recorded in the module doc); consumers on BOTH sides through the one table
(`LssInfer.kernelCallBoundary` via arity-checked `planFor`;
`Translate.poisonKernelArrowsThen` via `rowFor` + spine descent, kernelId
threaded from `deriveKernelAbiTypeWith`; `PSFTunnels` wired both sides, no
v1 rows); the stale `:3342-3345` ordering doc corrected in place;
`KernelFacts.elm`'s stale sortBy/sortWith evidence anchors refreshed
(:677/:751 → :759/:832). Census: **`kernelFactHits = 169`** row
applications on the self-compile; `byKernel` 4,065 unchanged (correct — the
counter means "boundaries that poisoned" and partial rows still poison
their opaque positions; the precision effect is the callback slots
SURVIVING the boundary, visible in the devirt/grounding movement above).
F.3 (`kernelToSig` inner-arrow alignment) deliberately NOT built — head-only
`k|` stays the standing calibration per this plan's own text. Invariants:
LSS_021 added; LSS_004 amended.

### Phase H — PARKED with numbers (2026-08-20)

Trigger evaluation per §H: the let/local channel's addressable mass is
frozen Run-J `widenedByLet = 672` + `localMultiBypass = 469`, plus
`topSiteShapes local = 7,487` flag-on (24% of the 31,139 ⊤-annotated call
sites) — against a total ⊤ bucket of 308,874 zonked slots and the NEW
honesty-rule ⊤ (`widenedByCf = 5,329`, which per-use separation cannot
address — it is the price of honest hubs, refinable only by a finer
per-position honesty join). Single-digit-percent addressable share ⇒
**PARK**, matching plan 1 §7.4's lean. If revived: §H.1's first step is the
`enrichLocalMultiUses` verification (option a), then the asymmetric-poison
mode (§H.2) — both mechanisms are fully specified above and the B.4
`onPoison` parameter is already the H.2 seam.
