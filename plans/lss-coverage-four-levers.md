# Four coverage levers — `lss.injTotal` + the transport gate

**Status: COMPLETE + FLIPPED DEFAULT-ON 2026-08-29 (user decision). Levers
1–3 shipped; lever 4 measured GO-for-design (§6.2) — its mechanism design is
the recorded follow-up, NOT part of this plan. Escape hatch
`ECO_MONO_LSS_INJ_TOTAL=0`.**
Date: 2026-08-28. Baseline: shipped-default coverage **83.10 %**
(positions=133,559, var=13,026, top=9,545). Sources:
`memory/lss-top-manufacturers-found.md` (the ⊤-manufacturer analysis that
produced levers 1–3) and the Aug 28 var decomposition.

---

## 0. The four levers, sized from the current census

| # | lever | target population | ceiling |
|---|---|---|---:|
| 1 | completion-join head re-stamp | 2,997 head-⊤ (kernel-ABI rebuild + slot-split→join) | +2.25 pp |
| 2 | deep-PAP successor completion | `papInject\|deep` d2=534 d3=44 d4=1 d5=5 → **584 producer sites** | ~+0.4 pp |
| 3 | Accessor + bare-`VarKernel` arms in `injectArgLambdaMember` | S.10 lockstep asymmetries (translate side missing both) | small; defect-class repair |
| 4 | ctor-payload transport (`knownElsewhere`) | `/c<n>`-path var = **6,830 positions (52 % of var)**; but `knownElsewhere` = only **607 arrows** | UNKNOWN — P0 reconciles positions↔arrows |

Levers 1–3 are one family — **finishing injection totality** (the paper's 𝒬 is
total; each lever writes an identity the analysis already possesses at a
position it already slots) — and ship under ONE flag `lss.injTotal`
(env `ECO_MONO_LSS_INJ_TOTAL`, hash token `lssIT`, default OFF, flip with the
user). Attribution inside the flag comes from per-lever census counters, not
per-lever flags (the papMembers+sigRootIdentity precedent).

Lever 4 is architectural. Its P0 is measurement-only; implementation happens
ONLY if the gate passes (§3.4). "To completion" for this plan = levers 1–3
shipped through the battery + lever 4's gate measured and the verdict recorded.

## 1. Lever mechanics

### 1.1 Completion-join head re-stamp

At the ONE place every spec's stored type is finalized —
`Monomorphize.elm:1491-1527`, the `completionJoin` write
`Registry.updateRegistryType specId joined s1.registry` — re-apply
`Translate.stampSelfSpine global joined` before the write. This heals BOTH ⊤
manufacturers at once: the kernel-ABI rebuild's hardcoded `LTop` (the store is
never read there, so no store-side fix can work) and the slot-split→join
`LSet ∪ LVar = LTop`. `stampSpineGo` replaces `LTop`/`LVar` with the
tautological singleton and NEVER overwrites an existing `LSet`
(`Translate.elm:4218-4230`), so the write is monotone and idempotent. The
member ids are the same `k|`/`c|`/`g|`/`p|` ids every other path mints
(`memberIdForDepth`, kernel-alias fold included), so joins stay one-identity.

Key availability: the site's `Registry.lookupSpecKey specId` currently
destructures `Just ( _, storedT )` — capture the key; stamp only for
`Mono.Global home name` keys (Accessor keys skip, counted). `Monomorphize`
imports `Translate` (`:46`) — `stampSelfSpine` is exported.

### 1.2 Deep-PAP successor completion

`injectPapMember` (`Translate.elm:4041-4076`) and its inference twin
`injectPapMemberInfer` (`LssInfer.elm`) stop at the residual HEAD
(`injectSpineMemberId 1 mid residualVar`), counting the rest as
`papInject|deep`. Finish the job with the walk that already exists:
`papSuccGoC` (`LssInfer.elm`, built for refPapSpine) writes a DIFFERENT member
per depth down a result chain. Mint `papMemberKey g d` for
`d ∈ argCount+1 .. declared-1` and run the walk from `residualVar` — its first
write lands in `residualVar`'s result arrow = depth `argCount+1`, exactly
right. `(f a) : X -> Y -> Z` then carries `{p|f|1}` at its head AND `{p|f|2}`
one deeper.

### 1.3 The two missing arms

`Translate.injectArgLambdaMember` (`:3890-3948`) has no `TOpt.Accessor` and no
`TOpt.VarKernel` arm — both fall into the silent `_ ->` no-op — while the
inference side mints for both (`a|<field>` at `LssInfer.elm:1433-1435`, `k|`
at `:1428-1431`). This is exactly the S.10 lockstep rule being violated, in
the walk where missing arms have twice shipped as defects (TrackedFunction
2026-08-23; kernel-alias 2026-08-26). Add:

- `TOpt.Accessor _ field _ ->` head-only `a|<field>` via
  `Engine.memberIdFor ("a|" ++ field)` + `injectSpineMemberId 1` (accessors
  are arity-1 chompers — "this arm stays 1 forever").
- `TOpt.VarKernel _ p home name _ ->` head-only
  `standaloneArgKernelMember ("k|" ++ home ++ "." ++ name) (p, home, name)`
  (kernels stay head-only; the `kernelToSig` inner-arrow hazard is `k|`-only).

### 1.4 The transport gate (lever 4)

The `/c<n>` var mass (6,830 positions; Decoder 1,308, apply 1,277, andThen
1,253, map 1,233, Ok 674, Err 617) is function values inside custom-type TYPE
ARGUMENTS — `Result e (a->b)`, `Decoder (a->b)`, State-shaped `apply`. The
probe (`LssGapCtorTypeArgFn`) proved the injection mechanism works LOCALLY;
the self-compile losses are the per-item store teardown, and constructors have
no signature channel to carry facts across items.

But `settled-var-arrows` says only **607 arrows** are `knownElsewhere`
(resolved concretely in some other item) against **16,978** `unknownEverywhere`.
Positions ≠ arrows: 6,830 positions could collapse onto few arrows or many.
**P0 must reconcile the two units before any architecture is attempted** —
if the knownElsewhere population maps to < ~1,000 registry POSITIONS, transport
cannot pay for architectural work and the verdict is NO-GO (recorded, with the
mass reattributed to unknownEverywhere = "nothing anywhere writes these",
which is body-tie/producer territory, not transport).

P0 instrument (ADJUSTED during lowering — AR-11): `MFunction`'s Int field is
a packed structural hash, NOT an ArrowId, so positions cannot be joined to the
knownElsewhere arrow set through the type tree. Position-accurate alternative
that needs no new analysis plumbing: emit `pos|` rows for COVERED positions
too (`k1`/`kN` kinds alongside `var`/`top`, still `arrowCensus`-gated). The
within-global transport candidate set is then computable post-hoc: positions
whose (global, path) is LSet in one spec and LVar in another — a direct
position-unit lower bound on what transport could recover. Cross-global flows
(producer→consumer pairs) are not captured; noted as the bound's direction.

GO options (recorded for the decision, NOT chosen here): (i) declaration-site
ctor payload facts (the reverted `lss-ctor-arrow-identity` P2, revived
narrowly), (ii) ctor-returning defs publish payload sets through the existing
sig channel, (iii) post-mono global solve — REJECTED precedent, would need new
evidence to reopen.

## 2. Paper fidelity (the §2 argument for the review)

The paper's 𝒬 is **total**: every λ (nested included) carries its identity in
its own arrow annotation, and instantiation/unification transport annotated
types wholesale. Levers 1–3 each close a place where Eco's defunctionalized 𝒬
is currently partial:

- **L1** is not a new analysis step — it repairs Eco-specific identity LOSSES
  (an ABI-rebuild that discards annotations; a join that cannot unify) by
  re-asserting the same tautology 𝒬 already asserted at registration. The
  paper has no join and no ABI rebuild; it never loses these. Re-stamping is
  convergence TOWARD the paper's invariant, not divergence.
- **L2** extends `p|g|d` to every nested-λ position of a partial application —
  the paper's `(f a)` has type `B −{λ₂}→ (C −{λ₃}→ D)` with BOTH inner sets
  from f's type. Head-only was the unfaithful approximation.
- **L3** injects identities for two value forms the paper's 𝒬 would cover as
  ordinary λs (an accessor IS a function value; a kernel reference is a named
  function value).
- **L4**'s gate measures whether Eco's item-scoped stores lose facts the
  paper's global unification would keep (`knownElsewhere` IS that loss,
  quantified) — the paper-faithful repair direction is transport, and the gate
  decides if the mass justifies it.

LSS_013 boundaries are respected everywhere: no lever claims an arrow beyond a
value's declared arity.

## 3. Phases

- **P1** — implement levers 1–3 + the P0 instrument, all under `lss.injTotal`
  (instrument under `report`+`arrowCensus`, flag-independent).
- **P2 (the measurement phase)** — probe micro-gates + self-compile census A/B
  (defaults vs `ECO_MONO_LSS_INJ_TOTAL=1`). Per-lever GO/NO-GO:
  - L1: head-⊤ owners (andThen/cons/succeed/…) fall to ~0 at `""` paths;
    coverage +≥1.5 pp; `top` falls by ≥2,000.
  - L2: `papInject|deepDone` ≈ 584; `/a0/r`-class var falls further.
  - L3: `argArm|accessor` + `argArm|kernel` > 0; no regression elsewhere.
  - L4 gate: `knownElsewherePos` read; verdict recorded.
  - Global guards: `top` must not RISE anywhere it isn't targeted;
    `specsMinted` within noise; join `rounds` bounded (no oscillation).
- **P3 (adjust)** — if a lever misses its gate, disable that lever's code path
  (comment-gated within the flag) and record; do not hold the others hostage.
- **P4** — battery: elm-tests + new differential suite; E2E both arms
  (`touch test/elm/src` first); Q-infer `diverge=0` both arms (Q-shadow
  baseline ≈70-79 sub-diverges — NOT a gate); flag-off byte-identity at probe
  scale; dispatch pair ONLY if coverage moves ≥2 pp (expect exactly neutral —
  L1's registry heads are not devirt inputs; devirt reads call-site zonks,
  which is why `ConsDevirtTest` passes with `cons`'s registry head ⊤ today).
- **P5** — record; flip decision with the user.

## 4. Adversarial review (verified against code before writing)

- **AR-1 — L1 stamps over ⊤ deliberately; soundness is the registration
  tautology.** `stampSpineGo` replaces `LTop`/`LVar`, keeps `LSet`. Replacing
  a join-manufactured ⊤ with `{g}` at spec-g's own head is the same claim
  regIdentity makes at registration — the value at the spec's head IS the
  global (kernel-alias → `k|`, ctor → `c|`), independent of what the body zonk
  failed to say. The ⊤ being replaced was manufactured by identity LOSS
  (ABI rebuild / join collapse), not by genuine unknowability — that is the
  §1.1 manufacturer analysis, verified in code.
- **AR-2 — L1 does not perturb the dirty/flush machinery.** The `changed` flag
  is computed by `joinAnnotationsChanged` BEFORE the stamp; stamping after
  does not mark dirty. That is correct: the stamp only enriches the stored
  type consumed by FUTURE demands and the coverage census; it is monotone and
  idempotent, so convergence arguments (LSS_010 finite lattice) are untouched.
  Risk recorded: a consumer translated in an earlier round saw the pre-stamp
  entry — acceptable, same staleness class as any join-round improvement.
- **AR-3 — L1 must skip Accessor spec keys** (`Registry.lookupSpecKey` can
  return `Mono.Accessor`); `stampSelfSpine` takes a `TOpt.Global`. Skip +
  count.
- **AR-4 — L1's `Nothing` lookup arm** (`Just (False, actualType)` fallback)
  stays unstamped — no stored entry means no demand ever registered; count it,
  expect ~0.
- **AR-5 — L2 key parity.** The successors mint `papMemberKey g d` — the same
  function refPapSpine and regIdentity use. `(f a)` passed onward and `f`
  referenced directly then produce ids that UNIFY (`p|f|argCount+1` etc.).
  Verified: `papSuccGoC`'s first write lands in the walked var's RESULT arrow.
- **AR-6 — L2 stays inside declared arity** (`d < declared`), so the deep walk
  cannot claim body-produced closures; identical LSS_013 bound as the head.
- **AR-7 — L3 accessor member is head-only and `a|`-keyed** — matching the
  inference mint exactly (`standaloneMember ("a|" ++ field)` =
  `standaloneMemberWith (\_ -> 1) (Engine.memberIdFor key)`); accessors have
  devirt/instance machinery from POST-001 — an `a|` singleton at an argument
  head is the same claim the inference side already publishes; no new class.
- **AR-8 — L3 VarKernel arm is the E9.2 one-identity rule applied to the last
  uncovered reference form**; head-only keeps the `kernelToSig` hazard
  unreachable. Bare `VarKernel` args exist mainly in kernel shim modules —
  expect a small counter, not a coverage jump.
- **AR-9 — one flag, three levers is an accepted trade.** Attribution comes
  from counters (`restamp|*`, `papInject|deepDone`, `argArm|*`); P3 allows
  per-lever disable without a flag split. Precedent: papMembers +
  sigRootIdentity flipped together.
- **AR-10 — the L4 gate is the plan's honesty clause.** 6,830 positions is
  NOT a recoverable estimate; 607 arrows says most of that mass is probably
  `unknownEverywhere` at position level too. No architecture before the
  reconciliation number exists.

- **AR-12 — L1 discards `stampSelfSpine`'s returned state, and that is sound
  by co-requirement.** `stampSelfSpine` is internally gated on `regIdentity`
  (off ⇒ L1 inert), and with `regIdentity` ON every spine member id was
  interned at registration (same keys: same global, same declaredArity, and
  under `rootFold` the ground key widens to the same comparable string) — so
  completion-time mints are always table HITS and the discarded state differs
  only by census counters. The alternative (threading state through the
  completionJoin let-chain) would restructure the whole spec-completion arm
  for zero semantic difference.

## 5. Lowering

- **Config**: `injTotal : Bool` after `refPapSpine`; default False; decoder
  `"injTotal"`; token `lssIT=`; env `ECO_MONO_LSS_INJ_TOTAL` +
  `applyLssInjTotalOverride` (Builder). Doc cites this plan.
- **L1** (`Monomorphize.elm` completionJoin block): capture the key; after
  computing `( changed, joined )`, if `s1.env.lss.injTotal` and key is
  `Mono.Global home name`: `Translate.stampSelfSpine (TOpt.Global home name)
  joined s1` → `Ok (stamped, s1b)` feeds `updateRegistryType`; `Err` falls
  back to `joined` (counted). Census: `restamp|applied`, `restamp|accessor`,
  `restamp|noEntry` via `Engine.bumpArgFlowCensus`.
- **L2** (`Translate.injectPapMember` + `LssInfer.injectPapMemberInfer`):
  after the existing head inject, if `injTotal`:
  `mintPapSuccessorIds g (argCount+1) declared [] |> papSuccGoC-walk from
  residualVar` (reuse `LssInfer.mintPapSuccessorIds` — widen its start-depth
  parameter use; it already takes `d` and `arity`). Counter
  `papInject|deepDone` per completed walk.
- **L3** (`Translate.injectArgLambdaMember`): two new arms before `_ ->`,
  both `injTotal`-gated, with counters `argArm|accessor` / `argArm|kernel`.
- **P0 instrument** (`Monomorphize.elm` posRows walker): emit `k1`/`kN` kind
  rows for covered arrows (was: uncovered only). `arrowCensus`-gated as today.
- **Tests**: `LssInjTotalTest.elm` — differentials: (1) a two-item fixture
  where a def's registry head reads ⊤ off / singleton on (L1); (2) deep-PAP
  `useIt (add3 10)` — `/a0/r` var off / `{p|add3|2}`-singleton on (L2);
  (3) accessor arg — off no member / on `a|`-singleton at the callee param
  head (L3); (4) LSS_013: beyond-arity arrow arm-identical; (5) producer
  convergence: L2's `/a0/r` id == the id at an explicit `((add3 10) 1)`
  producer position.
- **Probes**: `LssGapPapDeepArg` flag-on: its `/a0/r` var row disappears
  (micro-gate for L2). `LssGapReturnedClosure` flag-on: `pos|add||top` and
  `pos|add|/r|top` disappear (micro-gate for L1 — `Basics.add`'s spec head).

## 6. Results (2026-08-28)

### 6.1 P2 census A/B — all three levers GO

| | baseline (defaults) | `ECO_MONO_LSS_INJ_TOTAL=1` | delta |
|---|---:|---:|---:|
| coverage | 83.10 % | **88.07 %** | **+4.97 pp** |
| top | 9,545 | **3,664** | **−5,881 (−62 %)** |
| var | 13,026 | 12,314 | −712 |
| k1 | 80,896 | 87,728 | +6,832 |
| kN | 30,092 | 30,238 | +146 |
| positions | 133,559 | 133,944 | +385 |

- L1 OVERSHOT its 2,997-head target ~2×: the re-stamp heals the full
  self-spine on every completed spec, not only heads. Micro-gates: both
  probes' ⊤/var rows vanish entirely (LssGapPapDeepArg AND
  LssGapReturnedClosure read 100 % covered flag-on).
- L2: `papInject|deepDone = 786` (target 584 producer sites + infer twins).
- L3: `argArm|accessor = 41`, `argArm|kernel = 3` — small, as predicted.
- Guards: join `rounds=3`, `retranslations=591` (both unchanged — no
  oscillation); `byBudget` ~flat; flag-off probe artifact BYTE-IDENTICAL.
- Implementation deviation: the planned `restamp|*` counters were dropped —
  a consequence of AR-12's state-discard; L1's attribution is the `top`
  delta itself.

### 6.2 Lever-4 gate: GO-for-design

From the §1.4 instrument (covered `pos|` rows): **8,195 var positions
(66.6 % of remaining var) sit at (global, path) pairs concrete in a sibling
spec** — 8× the 1,000-position threshold. Owners: map 1,562, andThen 1,278,
apply 1,154, Decoder 832, Ok 818. CAVEAT recorded with the verdict: this is
an upper bound on knowable-KIND positions, NOT recoverable mass — copying
members across sibling specs is UNSOUND (different specs serve different
callbacks; that is what keyed specialization means). The mechanism must be
flow-based (§1.4 GO options i/ii); design is follow-up work, per this plan's
completion definition.

### 6.3 Battery

- elm-tests **13,387 / 12** (pre-existing dozen; all 5 `LssInjTotalTest`
  pins pass first time).
- E2E **1,711/1,711 BOTH arms** (+4 = the new probes; flag-on arm is a
  flag-on-built compiler).
- Q-infer `diverge=0` BOTH arms.
- Dispatch pair (both artifacts current source): `sat` −69 of 2.239 B
  (3e-8 — jitter), `typed` −5, **workload outputs BYTE-IDENTICAL**, wall
  within noise. Exactly neutral, as predicted (registry heads are not
  devirt inputs).

---

## 7. Lever 4 — the transport mechanism (design + implementation)

**Added 2026-08-29, after the §6.2 GO-for-design verdict.**

### 7.1 What the evidence already pins down

Facts established before this section (code + probes, not conjecture):

1. **The sig channel transports ctor-payload arrows end-to-end for Elm-bodied
   defs.** `loadTypeC` slots EVERY arrow, nested-in-type-args included
   (`Store.elm:314-335`, "LSS: slot every arrow"), and `loadTypeWithArrows`'s
   ordinal array (`:267-274`) therefore covers `/c<n>`-nested arrows. Probe
   `LssGapCtorTypeArgFn`: `mk`'s body-built payload member reaches `run`'s
   `/a0/c1` across defs — producer body walk → nested-ordinal fact →
   `applyFacts` at the consumer instantiation. There is NO structural hole in
   the channel.
2. **Direct call sites of licensed kernel combinators transport via type
   sharing.** The licensed `Transports` arm loads the type and runs
   `unifyCallShape` (inference, `LssInfer.elm:2049-2060`) and the translation
   side unifies real item-memo arg Points before the skipped poison
   (`kernelCallBoundary` doc). A shared annotation TVar (`value` in
   `map : (a -> value) -> Decoder a -> Decoder value`) makes the callback's
   result arrow and the result payload arrow ONE Point — so a site whose
   callback carries a member (post-refPapSpine) covers its own demand.
3. **Sibling-spec copying is unsound** (§6.2): different specs of `map` exist
   BECAUSE their callbacks differ.

Therefore the transportable-var mass (8,195 positions owned by
map/andThen/apply/Decoder — kernel-BACKED combinators) can only come from
sites where the transport chain breaks. The prime suspect: **kernel-alias
defs have EMPTY signatures.** `signatureFor` summarizes what a def's BODY
contributes; a kernel-alias body (`map = Elm.Kernel.Json.map1`) is a
`VarKernel`, contributes nothing, and the signature reads trivial/allflex.
When `map`'s CALL sits inside another polymorphic def (`andMap f d = map …`),
the enclosing def's signature must convey the param↔result linkage upward —
and an empty `map` signature drops it, so the chain dies one hop from the
direct site.

### 7.2-REVISED (P0 outcome): M1 is DEAD; the mechanism is M2 — close the
inference-side arg leak + the trivial-callee skip

P0 refuted M1's premise twice over. The kernel-pipeline probe AND an all-Elm
control fail IDENTICALLY (`makePair|/c0|top`, `consume|/a0/c0|var`, with the
Elm combinator `mapB` itself fully covered incl. `/r/r/c0`) — kernels are
exonerated. A direct-construction probe (`makePair2 = Box (Pair 1)`) fails
too (`/c0|var`, `sig|allflex`), with the payload ORDINAL present. The
signature scratch never receives the member. Two verified holes, both in
`LssInfer`, both inference-side only (translation-side transport works —
which is exactly why producers know locally and their sigs still say
nothing):

- **H2 — the A.1 arg leak, literal.** `TOpt.Call` walks `walkCall` FIRST
  (`LssInfer.elm:1367`) and the arg EXPRESSIONS after (`walkChildren`,
  `:1372`); `unifyParamsBestEffort` fresh-loads `TOpt.typeOf arg` (`:~2050`)
  BEFORE any member exists, and the walked args' points are discarded. The
  member minted during the later walk lands in a class never connected to
  the callee's param.
- **H1 — the trivial-callee short-circuit.** Ctors get `trivialSignature`
  (bodyless, `resolveUnit` doc `:494`), and the trivial guard short-circuits
  the apply/unify — so a ctor call never runs the shape unify at all: the
  payload member cannot enter the call's own type, hence never reaches the
  enclosing def's annotation slots.

**M2**: (a) restructure the Call arm to walk args first, collecting
WalkPoints, and unify `pParam` with the WALKED point (fallback to the type
load only for `WpNone`); (b) for trivial-signature callees whose type
mentions arrows (ctors with function payloads), still run the shape unify —
facts-free instantiation, transport by unification. Scope: `applyCalleeAt` +
`kernelCallBoundary`'s licensed arm; `localCalleeJoin` explicitly OUT
(its §7.4 family-Point discipline is separate; its doc already anticipates
this fix as future work). Rides `lss.injTotal`.

Paper fidelity of M2 is immediate: the paper never "loads a type twice" —
an argument's annotated type IS the unified type; H2 is a pure Eco
implementation artifact severing 𝒬's output from the instantiation, and H1
is a missing instantiation for ctor schemes (the paper instantiates every
constructor's ∀-type like any function). M2 removes both divergences.

Additional AR items:
- **AR-18 — order change moves member-id allocation order** (args walked
  before callee): artifact-affecting, flag-gated, same class as every
  injection change; keys stable per demand.
- **AR-19 — no double-walk**: the restructure must remove args from the
  post-`walkCall` `walkChildren` (func stays); double member writes are
  idempotent (LSS_005 total-join) but census counters would double.
- **AR-20 — poison ordering**: rowless/refused kernel paths poison AFTER the
  arg walk under the restructure; ⊤ absorbs the just-written members —
  identical final state to today (poison-after-inject is the recorded-safe
  direction).
- **AR-21 — cost**: one avoided fresh type load per arg with a walked point;
  the trivial-callee unify is guarded by `canTypeMentionsArrow` (ctor calls
  with arrow-free types — the overwhelming majority — keep the short
  circuit).

### 7.3-STATUS (2026-08-29): M2 implemented, micro-gate FAILED, re-gated
DEFAULT-OFF under `lss.argPoints` pending diagnosis

M2 was implemented in full (walkArgsCollect / walkCallWith / applyCalleeAtWith
/ unifyParamsWithPoints / kernelCallBoundaryWith + the VarEnum/VarBox ctor
arms) and the reproducers re-run at defaults. **Both probes unchanged**
(`makePair2|/c0|var`, `decodePair|/c0|top`). Instrumentation trail (temp
counters, since removed):

- `argleak|armEntered = 3` — the restructured Call arm runs for the three
  def-body top-level calls only; the NESTED `Pair 1` call never re-enters it,
  so at TOpt level the partial ctor application is evidently NOT a plain
  `Call` by the time the sig walk sees it (eta-expansion into `Function`?
  LocalOpt rewrite? — undiagnosed).
- `argleak|ptJust = 0 / ptNone = 4` — every collected point is `WpNone`:
  additionally, args whose TYPE is not a top-level arrow (Box-value carriers,
  e.g. `makePair2` passed as an argument) return `WpNone` from
  `standaloneMemberWith`'s `canTypeIsArrow` guard even though their type
  CONTAINS arrows — a second, independent reason the point transport starves.

Because `injTotal` is now default-ON, leaving unvalidated M2 code live at
defaults was unacceptable: M2's three gates were moved to a NEW flag
`lss.argPoints` (env `ECO_MONO_LSS_ARG_POINTS`, token `lssAP`, DEFAULT-OFF),
returning defaults to the fully-validated L1-L3 state. Diagnosis plan for the
next session: the JS fast loop (run the compiler's Elm under node) with
prints at the walkExpr arms to identify (a) the actual TOpt form of a partial
ctor application in the sig walk, (b) the right point for container-typed
args (the walked `meta.tipe` load rather than `WpNone`). The H1/H2 analysis
stands; the delivery mechanism needs the two answers above.

### 7.4-M3 (2026-08-29, the JS-loop answers + final mechanism)

The fast loop (guida.js under node, `Debug.log` in `walkArgsCollect`) answered
both open questions in three 60-second cycles:

- **(a) Partial ctor applications reach the sig walk as LET-BOUND LOCALS.**
  `Box (Pair 1)` is normalized to `let _v0 = Pair 1 in Box _v0` before the
  walk; the arg is `TrackedVarLocal _v0`, NOT a `Call` and NOT a lambda. The
  H1 ctor arm and H2 threading were necessary but aimed one binding upstream
  of where the value actually flows.
- **(the real point-killer)** `joinLetUse` FINDS `_v0` in letEnv — and then
  its cost guard (`sigFlow && not (canTypeMentionsArrow meta.tipe)`) returns
  `WpNone`, because a local USE's occurrence type is syntactically an
  unsolved MVar even when the solver knows it is an arrow. The guard was
  written to skip a slot-join load; it also discards the family point that
  is already in hand, free.
- **(b)** confirmed: container-typed reference args return `WpNone` from
  `standaloneMemberWith`'s `canTypeIsArrow` gate despite arrows inside.

**M3 (all under `lss.argPoints`, keeping M2's H1 arm + H2 threading):**

1. `joinLetUse` guard arm: return `Ok ( WpHonest rhsVar, s0 )` — hand back
   the FAMILY point without the load. Soundness: the §7.4 v1 policy already
   states "all uses of a let-bound function share one set (union over uses —
   sound)"; handing the hub to the param unify is the same sharing. A
   generalized local used at clashing types degrades through
   `unifyBestEffort`/`joinArrowSets`' divergence-poison — the sound
   direction (LSS_005 widening only; a cross-use union can never create a
   false singleton).
2. `walkExpr` reference arms (VarGlobal/VarCycle): when the occurrence type
   is not a top-level arrow but `canTypeMentionsArrow`, return
   `instantiateWithSignature`'s point (facts applied) instead of `WpNone` —
   container-typed references then transport their signature facts (payload
   ordinals included) into consumer params.

Paper fidelity: (1) is let-polymorphism's monomorphic-share case done the
way the paper's store does it (one value, one type, one ζ); (2) is scheme
instantiation at a USE — the paper instantiates every referenced def's
scheme wherever its value flows, argument positions included; returning
`WpNone` there was the infidelity.

### 7.5-VERDICT (2026-08-29): M3 probe-PROVEN, scale-NEGATIVE — lever 4
closes as NO-GO at defaults, mechanism preserved under `lss.argPoints`

M3 (family-point handoff in `joinLetUse` + signature instantiation for
container-typed references, both sides) was verified end-to-end on the probe:
`consume2|/a0/c0` flips var→**k1** (`argpt|refSig` fires; the referent's
signature walk is triggered by the REFERENCE, the payload fact publishes and
transports across the item boundary — the first time this chain has ever
closed). The producer's own spec shifts var→⊤ (one demand path still
arrives ignorant — residual, unpursued).

**Self-compile A/B: NET NEGATIVE.** vs the certified 88.07 % baseline:
coverage −0.21 pp (87.86 %), var +332, positions +422, k1 +62,
`argpt|refSig=815`, `argpt|refInst=586`. The consumer-side wins are real but
outweighed: forcing signature computation at every container-typed reference
pulls new walked units into the registry whose own uncovered deep positions
exceed the recovered ones on this corpus.

**Disposition (P3 rule): NO-GO for a default flip.** `lss.argPoints` stays
DEFAULT-OFF carrying the complete, probe-proven mechanism (M2 threading + H1
ctor arm + M3.1 family-point + M3.2/M3.3 reference instantiation) for future
work — e.g. a demand-driven variant that instantiates reference signatures
only where a consumer position is otherwise unresolved, which would keep the
wins without the dilution. The lever-4 investigation is COMPLETE: mechanism
identified via the JS fast loop (three 60-second cycles: let-bound PAPs, the
joinLetUse guard as point-killer, references never requesting signatures),
implemented, and measured. The measurement, not the implementation, made the
decision — which is what this plan's phase structure is for.

### 7.2-ORIGINAL (superseded): license-derived rep-linkage signatures (M1)

For a kernel-alias def carrying a `TypeFaithful { scope = Transports }` (or
verified `TransportsAs`) license, derive its signature FROM ITS ANNOTATION
instead of its (bodyless) body: load the annotation in the signature scratch
store — TVar memoization then gives shared ordinals the SAME rep — and
publish the resulting `ArrowFact`s. These facts carry **rep linkage, no
members** (`members = [], top = False`, shared `rep`): `applyFacts` at a
consumer instantiation then UNIFIES the linked slots, and members flow
through ordinary unification exactly as at a direct site. No member is ever
claimed that the license's variable-sharing graph does not imply.

Scope guard: ONLY for defs whose `kernelAliasOf` is licensed AND
`licenseApplies` verifies at the def's own annotation. Refused/rowless/Inert
kernels keep their empty signatures (Inert has no arrows to link).

### 7.3 Paper fidelity

In the paper every function — including an opaque-but-parametric one — has a
scheme `∀ᾱ,ζ̄. τ` whose set variables ζ̄ appear at EVERY arrow of τ, shared
wherever τ shares them; instantiation composes these schemes through nested
polymorphic calls, which is precisely how a set reaches
`Decoder (Int −ζ→ Pair)` two hops from where the callback was supplied. Eco's
sig channel IS its scheme mechanism; a kernel-alias def with an empty
signature is a scheme with its ζ̄ erased — a hole the paper does not have.
M1 restores exactly the paper's scheme for these defs: the license is the
parametricity proof that the annotation's sharing graph IS the kernel's set
flow ("the shared a/b/c Points ARE the flow edges" — the LSS_022 audit), so
publishing rep linkage derived from the annotation asserts nothing beyond
what the license already certifies. Technique differs (rep-linked ArrowFacts
for scheme ζ̄); the judgment is the paper's.

### 7.4 Adversarial review

- **AR-13 — soundness: linkage-only facts cannot create false singletons.**
  A rep-linkage fact unifies slots; it writes no members. A false singleton
  would need a member write, which comes only from the existing (audited)
  injection paths. Worst case is over-UNIFICATION (two slots merged that the
  kernel does not actually connect) — excluded by deriving linkage from the
  SAME annotation type the licensed call-site transport already unifies
  through; M1 adds no edges the direct-site path does not already create.
- **AR-14 — the `sig.trivial` early-out** (`applyFacts`:
  `if sig.trivial then Ok`) must not swallow M1's facts: a linkage-only
  signature has empty members everywhere and could classify as trivial.
  P0 must read `signatureFor`'s trivial computation and the fact publication
  path for kernel-alias defs; the implementation point is exactly where
  triviality is decided.
- **AR-15 — cost.** Signatures are memoized per global (`S.lssSignatures`);
  M1 adds one annotation load per licensed kernel-alias def (~66 Transports
  rows reachable), not per call. Negligible.
- **AR-16 — the ordinal contract (LSS_006) binds M1.** Facts pair with
  consumer loads BY MINTING ORDER over the SIGNATURE SOURCE type; M1 must use
  the same source-type selection (`stored annotation if present, else
  meta.tipe`) as `signatureFor` does today, or ordinals shear.
- **AR-17 — what M1 does NOT claim.** Data-threaded cross-item flows (a
  Decoder built in item A, carried through a record field, consumed in item
  C with no connecting call chain) remain uncovered — that residue is the
  genuinely architectural remainder; P0 sizes it as the gap between the
  probe-verified mechanism and the 8,195 bound, and it is OUT of this
  lever's scope (recorded, not attempted).

### 7.5 P0 (measure before building)

1. Read `signatureFor`'s kernel-alias handling + trivial computation
   (AR-14): confirm empty-signature behavior and locate the publication
   point.
2. Probe `LssGapKernelPipeline`: an `andMap`-style Elm def whose body calls
   a LICENSED kernel combinator with its own parameter as the callback
   (`step f d = Json.Decode.map f d`), consumed one hop away with a known
   callback. Expectation flag-off-of-M1: consumer `/c`-payload var (the
   chain dies at step's empty signature); an Elm-bodied control (`stepE`
   implemented without kernels) covered.
3. If (2)'s kernel arm is ALREADY covered, M1's premise is wrong — stop,
   re-attribute from the probe, adjust (the §P3 rule).

### 7.6 Lowering (contingent details verified in P0)

- New: `LssInfer.licenseLinkageSignature : TOpt.Global -> meta -> Step (Maybe Sig)`
  — guard `kernelAliasOf` + `factFor` `Transports`/verified `TransportsAs` +
  `licenseApplies` at the def's annotation; on pass,
  `Store.loadTypeIsolatedWithArrows` over the signature source type in the
  scratch context, `sigArrowFact` per ordinal (members empty, reps live),
  marked NON-trivial.
- Wire into `signatureFor`'s kernel-alias/allflex path so consumers pick it
  up through the existing memo + `instantiateWithSignature`/`applyFacts` —
  no consumer-side changes.
- Flag: rides `lss.injTotal` (same family — completing the scheme the same
  way L1-L3 complete 𝒬); census counter `sig|linkage` per published
  linkage signature.
- Tests: differential pin in `LssInjTotalTest` mirroring the P0 probe shape
  if fixture-expressible (kernel aliases need `makeKernelModule` — else the
  E2E probe is the differential).
- Battery: census A/B (the 8,195-bound owners must move: map/andThen/apply
  var falls), elm-tests, E2E both arms, Q-infer, dispatch pair if ≥2 pp.
