# Per-use let-set separation (Phase H / GAP-9 repair half) — census first

**Status: PARKED on measurement (2026-08-21). Phase 0 RAN — both arms, both
bounds — and BOTH halves of the repair measure EMPTY. The channel's
`intoRhs`/`both` are 0 and its `sibling`/`laterGrowth` pollution measures are
0/0/0 on the sigFlow-on AND sigFlow-off arms, so H.1 has nothing to direct;
`poisonUseFault` is 0 (every poison is the rhs-at-fault arm §3 says must stay
symmetric) and each poison destroys 0 rhs set slots, so H.2 has nothing to
spare. §§3-4 are NOT built. Numbers, method and the refuted priors: §2.R.**
This is the
"asymmetric treatment" residue left standing after LSS_023 directed the
call-site joins: the let channel (`joinLetUse`) still unifies
symmetrically, so a let-bound function's set is the UNION over all its
uses and one use's widening pollutes every other use AND the binding
itself. Lineage: GAP-9 (repair half) of
`design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md` §7;
Phase H of `plans/lss-fidelity-3-signature-flow-completion.md` (recorded
"leans PARK" in plan 1 §7.4 on frozen Run-J numbers);
`plans/lss-directed-set-flow.md` §5.2 keeps it symmetric by v1 policy and
its Phase-E wrap-up names `joinLetUse` **"the largest kept-symmetric
channel"**. All code references verified at HEAD 2026-08-21 (post-LSS_024,
post the `lss.layoutQualMembers` default flip).

**Why re-opened now.** The two deprioritizations that parked Phase H are
both resolved: the decline-log census refuted the raw-`l|` lever it was
queued behind, and the key-split de-stamp that then outranked it is FIXED
(LSS_024, 100.8% of the gap recovered — runtime-calls Run AC). Two
standing changes matter to this plan:

1. **The sizing numbers are stale.** `widenedByLet = 672`,
   `localMultiBypass = 469`, `topSiteShapes local = 7,361` are FROZEN
   Run-J data (benchmarks/lss-opt.md:408-410, 2026-08-18) — measured
   before LSS_019 grounding default-on, LSS_022, LSS_023, LSS_024, and
   the layoutQualMembers flip. Nothing may be sized from them; that is
   what Phase 0 is for.
2. **LSS_024 changes the payoff arithmetic in this plan's favor.** The
   sigFlow arc's lesson was that new precision mints annotation-keyed
   spec splits whose duplicate instances destroy the singletons the
   precision creates. Layout-qualified member identity absorbs
   annotation-only splits (their clones share one id; consumer slots stay
   singletons), so let-channel precision recovered by THIS plan no longer
   pays that tax — the prerequisite the sigFlow flip needed is the same
   one this plan needed.

Interaction with the `lss.sigFlow` default flip (in flight as Landing 2 of
the LSS_024 plan): under sigFlow, `bindParamsFromSpine`
(LssInfer.elm:2456-2487) binds PARAMS into `letEnv` too, so the channel's
population is much larger on that arm. The census runs on the
post-Landing-2 tree, both sigFlow arms.

---

## §0 The channel, precisely (code anchors)

- `LetEnv` (LssInfer.elm:945) maps let-bound names to the RHS's loaded
  set-slot variable. Populated at the Let/TailDef arms
  (:1093/:1129/:1132/:1145 — `CoreDict.insert name rhsVar letEnv`) and,
  sigFlow-on only, with function params via `bindParamsFromSpine`
  (:2456-2487, the B.1.h addition).
- Every bound-name OCCURRENCE (`VarLocal`/`TrackedVarLocal`,
  :1067/:1070) runs `joinLetUse` (:2018-2046): load the occurrence type,
  then `joinArrowSets identity rhsVar useVar` — a SYMMETRIC unification
  of set slots at matching arrow positions. The only guard is the
  sigFlow-on arrow-free skip (:2025-2030, cost-only, semantics-free).
- On structural divergence (a generalized position: either side a
  variable, or shapes differ) the walk calls `poisonBoth` (:2381) —
  ⊤ into BOTH sides' remaining arrow slots, i.e. one polymorphic use
  poisons the binding and thereby every other use.
- The channel is LIVE flag-independent of sigFlow (it predates LSS_020;
  only the letEnv population and the cost guard are sigFlow-sensitive).

Two pollution directions, and they are distinct populations:

- **use←rhs∪uses (sibling pollution):** the union makes every use see
  every other use's members/widenings. A consulted callee slot at use A
  reads a 2-set or ⊤ because use B fed the same binding elsewhere.
- **rhs←use (backflow):** a use-site widening writes back into `rhsVar`,
  polluting the binding's own arrows and any DOWNSTREAM read of the
  binding (including the def's signature readback under sigFlow).

The doc comment on `joinArrowSets` (:2049-2061) already anticipates this
plan twice: "per-use separation is the vNext upgrade, which is why this
stays a separate named function", and "Phase H.2 widens this parameter
into a poison MODE (PoisonUseOnly) — design for the parameter, don't
over-build".

**Expectation cap (record before measuring).** The GAP-9 register and the
E0.5 verdict (lss-dispatch-value-extraction.md:286-296) are explicit that
the `topSiteShapes local` mass is COMPOSITE, and one component —
IO bind continuations that escape into the returned value — is an
**escape-by-soundness floor**: "no analysis precision helps"; only the
shelved E8 defunctionalization-style transform would. Whatever fraction of
the local-shape LTop mass the census attributes to that class is
unrecoverable BY CONSTRUCTION and must be subtracted before any payoff
claim. The tier-roadmap lesson also binds here: static censuses collapse
at admissibility gates — no GO without dynamic heat.

## §1 The thesis

Union-over-uses is the let channel's derivation-tag conflation: it merges
per-use facts that the paper's per-use instantiation keeps separate
(§6.3 turns SCC members into let-bound lambdas and instantiates per use;
Elm's polymorphic `let` has no `L^src` counterpart, so this axis is "Eco's
own to get right" — fidelity mapping §3.2). The repair does NOT need the
original heavyweight conception (fresh per-use re-instantiation of the
binding's slot structure): LSS_023's directed machinery already provides
the exact primitive. Replace the symmetric boundary join with a DIRECTED
one:

- **use INCLUDES rhs** (`Store.addSlotSource` edges installed by the
  variance-aware directed walk — `flowArrowSets`' discipline: dst⊇src
  along result spines, operands FLIP at argument positions, container
  subtrees degrade to the symmetric join). Each use resolves the
  binding's members at read; use-side content never writes back into
  `rhsVar`, and sibling uses never see each other.
- **PoisonUseOnly** (H.2): structural divergence at a use poisons that
  use's slots only. The rhs keeps its precision for the uses that DO
  match. (Divergence caused by the rhs side itself — rhs a variable —
  must still poison the rhs: the poison-direction argument is per-arm,
  written out in §3.)

`localCalleeJoin` (:1394) is the in-tree precedent: the same channel
shape (a local name in callee position) was directed by LSS_023 and its
depollution pin (chooseHandler) is the model for this plan's §4 pin.

## §2 Phase 0 — the census (the gate for everything below)

One-shot instrumentation, decline-log discipline (recipe:
`/work/lss-decline-log-analysis.md`; the LSS_024 Phase-0 record in
`plans/lss-layout-qualified-members.md` is the worked example, including
the scanExpr-bypass consumer census and the LQ/MEMKEY dump joins).

**Instrumentation (all one-shot, removed after the run):**

1. A `joinLetUse`-only classified variant of `joinArrowSets`: before each
   slot-pair unification, resolve both sides' members and classify the
   event — `noop` (equal/subset), `intoUse` (use gains content — sibling
   pollution), `intoRhs` (rhs gains content — backflow), `poison`
   (re-measures `widenedByLet` on this tree). Counters plus a per-event
   log line `unit-global | let-name | class | |rhs| |use|` aggregated
   with counts (the Dict-of-lines device from the LSS_024 census).
   Split every counter by letEnv entry provenance (rhs-bound vs
   param-bound) to size the sigFlow interaction.
2. The consumer-side census re-run on the SAME tree: AbiCloning DL log
   with the scanExpr bypass (LTop + multiSet arms logged), plus the
   LQ/MEMKEY/SPEC dumps — so backflow-polluted bindings' member ids can
   be JOINED against consulted multi-set/LTop sites by id, and split
   demands classified.
3. `localMultiBypass` re-measure (Translate.elm:2943-2949 comment site) —
   GAP-9's other half rides along as a row, not a target.

**Arms:** the post-Landing-2 default tree; one cold self-compile per
sigFlow arm (JS loop per the fast-census memory — native parity is
established). Same-tree only; the frozen Run-J numbers appear in the
report ONLY as "stale prior" rows.

**Deliverables:**

1. The classified event table (noop / intoUse / intoRhs / poison ×
   rhs-bound / param-bound × sigFlow arm) — the raw size of the channel
   and of each pollution direction.
2. The candidate-site table: consulted sites (multiSet or LTop) whose
   sets are reachable from `intoUse`/`intoRhs`-classified bindings by
   member-id join — i.e. sites per-use separation could plausibly narrow
   to singletons. Explicitly subtract the E0.5 escape class (IO
   continuation shapes) into its own row.
3. **Dynamic heat for the candidates:** count-match the candidate sites'
   specs against the Run-AC dispatch census fps where the tree drift
   allows; if it does not, ONE counters-lowered native leg
   (runtime-calls methodology — remember: delete `bin/eco-compiler.mlir`
   + `bin/eco-compiler` per arm, env vars are not ninja inputs) to weigh
   the candidate population in events.

**Stop conditions (PARK with the numbers recorded, no substrate work):**

- `intoUse + intoRhs ≈ 0` — the unions are no-ops and separation buys
  nothing (the join is then pure cost, and a cheaper follow-up is
  deleting work, not directing it).
- Candidate sites exist but their dynamic weight is noise (the
  admissibility-gate lesson: a static population without heat is a
  parked plan).
- The candidate mass is dominated by the E0.5 escape-by-soundness class
  — record the E8 pointer and stop; no precision work recovers it.

**GO condition:** a non-trivial recoverable-singleton candidate set with
material event weight (the report must name the sites and their events,
LSS_024-Phase-0 style — mechanism pinned per site, not aggregate-only).

## §2.R Phase 0 — RESULTS (2026-08-21). Verdict: **PARK, both halves.**

One tree, one cold JS self-compile per `lss.sigFlow` arm (fast-census loop),
on the post-LSS_024 / post-both-flips default tree. All instrumentation
one-shot and removed after the run (tree verified byte-identical to
pre-instrumentation afterwards; `elm-tests` 13,186 pass / 12 fail = the
recorded pre-existing set, and necessarily pre-existing since the sources are
identical).

Raw dumps: `/work/lss-letuse-census-sfon.txt`,
`/work/lss-letuse-census-sfoff.txt` — the `LETUSE`/`MSMEM`/`SITE`
tab-separated lines are the per-site material behind every table below.

### 2.R.1 Method (and the one hole that had to be closed first)

The classifier is a READ-ONLY mirror of `joinArrowSets`' descent, run at
every `joinLetUse` **before** the real join, so the join it measures is
unperturbed. Slot resolution is `zonkSetSlot`'s own read-time resolution (a
verbatim twin of `Store.resolveSources`, so LSS_023 `LsFrom` edge graphs
resolve exactly as a zonk would) **minus** the LSS_019 grounding rewrite —
grounding rewrites member identities for annotation emission and would mint
ids as a side effect of measuring. Provenance (`rhs-bound` vs
`bindParamsFromSpine` param-bound) is carried on the `LetEnv` entry.

Two independent pollution measures, deliberately bracketing the answer,
because **one of them alone would have been worthless**:

- **exact lower bound (`sibling*`)** — per rhs slot, the members THIS
  channel pushed back from earlier uses, intersected with what a later use
  gains. Never charges the let channel for content another channel
  delivered.
- **upper bound (`laterGrowth*`)** — what the SHARED CLASS resolves to at a
  use, minus what it resolved to at the previous use of the same binding.
  This measure is REQUIRED: `Store.unifyBestEffort` **merges** the rhs and
  use slot UF classes at the first use, after which a write through ANY
  use's point is a write to the binding — and a pre-join snapshot of that
  use's own slot is structurally blind to it. A first pass that reported
  `intoRhs = 0` from the snapshot alone was not evidence; only the agreement
  of both bounds is.

Two recorded honesty caveats: (a) the corpus IS the compiler source, so the
census code sits in the corpus — measured effect, by re-running the sfon arm
before and after adding `laterGrowth`: every class count IDENTICAL, only
`miss` 33,464→33,473 and `skipArrowFree` 40,146→40,165 moved (a handful of
events; it also witnesses determinism). (b) The sfon `distinct bindings`
figure is a LOWER count — the sigFlow arrow-free cost guard (:2025-2030)
retires 40,165 occurrences before they can reach the join, so bindings whose
every occurrence is arrow-free are never seen.

### 2.R.2 Deliverable 1 — the classified event table

| axis | `sigFlow=1` | `sigFlow=0` |
|---|---|---|
| joinLetUse: joined / arrow-free-skipped / letEnv-miss | 2,494 / 40,165 / 33,473 | 9,505 / 0 / 66,627 |
| of joined: param-bound | 1,448 | 0 |
| set-slot PAIRS classified | 6,323 | 2,509 |
| `noop` | 2,946 | 1,819 |
| `intoUse` (of which ⊤-inherited) | 1,364 (17) | 0 (0) |
| **`intoRhs`** (of which ⊤-widening) | **0 (0)** | **0 (0)** |
| **`both`** | **0** | **0** |
| `poison` | 2,013 | 690 |
| — `rhsFault` / `shape` / **`useFault`** | 1,988 / 25 / **0** | 665 / 25 / **0** |
| — rhs slots destroyed (member / flex) | **0 / 0** | **0 / 0** |
| **sibling pollution, exact lower bound** (events / members / ⊤-inherited) | **0 / 0 / 0** | **0 / 0 / 0** |
| **sibling pollution, upper bound** (`laterGrowth`: events / members / wentTop) | **0 / 0 / 0** | **0 / 0 / 0** |
| param-bound slice: noop / intoUse / intoRhs / both / poison | 2,491 / 0 / 0 / 0 / 1,573 | — |
| distinct bindings / **multi-use** bindings | 1,162 / **371** | 5,207 / **2,018** |
| uses-per-binding tail | 2→176 … 12→5 | 2→1,237 … 12→10 |
| `localMultiBypass` (GAP-9b row) | 455 | 455 |

**This is not an empty population.** 371 (sfon) and 2,018 (sfoff) bindings
are used more than once, with tails out to 12 uses — exactly the shape
sibling pollution would need. It simply does not occur: no use ever
contributes to the shared class, at join time or afterwards, on either arm.
The 1,364 `intoUse` events are purely binding→use — the direction H.1's
directed edge PRESERVES — so directing this boundary is a no-op by
construction, not merely a small win.

**H.2 is refuted independently.** `useFault = 0`: every one of the 2,703
poison events across both arms is either rhs-at-fault (2,653 — the binding
side is a *variable*, the one arm §3 H.2 itself says must keep poisoning
both sides) or shape divergence (50). And every poison destroys **zero** rhs
set slots — when the rhs side is a `FlexVar` there are no arrows beneath it
to poison. `PoisonUseOnly` would change nothing anywhere.

### 2.R.3 Deliverable 2 — the candidate table (empty), and where the mass is

Consumer-side census re-run on the SAME tree with the `scanExpr` early-exit
BYPASSED, so the `LSet[2..]`/`LTop` arms finally see every node instead of
only nodes co-resident with a singleton-head call:

| axis | `sigFlow=1` | `sigFlow=0` |
|---|---|---|
| LTop consulted sites, total | 138,322 | 138,272 |
| — by callee shape: `global` | 89,767 (64.9%) | 89,789 |
| — `kernel` | 29,209 (21.1%) | 29,126 |
| — `local` | 17,332 (**12.5%**) | 17,334 |
| — `callResult` + `recordAccess` (the E0.5 escape proxy) | 1,426 (1.0%) | 1,434 |
| multi-set consulted sites (2→502 3→158 4→80 5→29 6→18 7→14 8→12) | 813 | 813 |
| distinct consulted multi-set member ids | 1,603 | 1,603 |

**Candidate set: ∅.** The let channel pollutes 0 member ids, so its
intersection with the 1,603 consulted multi-set member ids is empty on both
arms. There is no candidate table to weigh, and therefore nothing for the
E0.5 escape subtraction to bite on — the row is recorded (1.0% of ⊤ sites
are explicit escape shapes) but it is vacuous here.

**Mechanism pinned per site** (the §2 GO condition's format, reported for
the PARK). 348 producer specs are ALSO local-⊤ consumers, covering 10,432 =
60.2% of local-⊤ sites, and **all 23** multi-set consumer specs are
let-channel-touched — so the channel does reach the mass. In every one of
them its only event is poison:

| consumer spec | local-⊤ sites | multi-set member occurrences | let-channel events |
|---|---|---|---|
| `List.foldrHelper` | 1,260 | 370 | poison 36, intoUse 0, later 0 |
| `Compiler.Parse.Primitives.andThen` | 863 | 434 | poison 6, intoUse 0, later 0 |
| `Bytes.Decode.andThen` | 662 | 12 | poison 2, intoUse 0, later 0 |
| `Bytes.Decode.map3` / `map2` / `map` | 578 / 541 / 411 | 26 / 140 / 59 | poison 4 / 3 / 2, intoUse 0 |
| `Compiler.Json.Decode.apply` | 312 | — | poison 2, intoUse 0 |
| `List.map` | 255 | 184 | poison 2, intoUse 0 |
| `System.TypeCheck.IO.andThen` | 195 | 90 | poison 3, intoUse 0 |
| `List.foldl` | 193 | 566 | poison 6, intoUse 0 |

The mechanism is the same at every one: these are HOF/continuation families
whose `letEnv` entry is a **`bindParamsFromSpine` param**, and the param's
loaded slot is an unconstrained variable at the divergence point — the
`rhsFault` arm. Their ⊤ is the **empty signature channel (GAP-2)**, not
GAP-9's union-over-uses. Per-use separation cannot reach it; the parameter
never had a set for the uses to pollute.

### 2.R.4 Deliverable 3 — dynamic heat: NOT RUN, and why

Deliverable 3 weighs a candidate population in runtime events. The
population is empty (2.R.3), so its weight is zero by construction and a
counters-lowered native leg would be measuring nothing. Recorded rather
than skipped: no Run-AC count-match and no native leg were performed, and
the plan's `≥85%`-style acceptance never became applicable.

### 2.R.5 The frozen priors, re-measured — all three were misleading

| prior (FROZEN Run J, 2026-08-18) | re-measured 2026-08-21 | reading |
|---|---|---|
| `widenedByLet = 672` | `poison` = **690** (sf-off arm) / 2,013 (sf-on) | The sf-off arm reproduces the historical number on a bigger corpus — the instrumentation is validated against it. But the count was never the interesting quantity: split by fault, **0** of it is recoverable. |
| `localMultiBypass = 469` | **455**, both arms | Unchanged. Stays a row (§6 non-goal); E4a territory. |
| `topSiteShapes local = 7,361`, "the dominant residual callee shape" | **17,332 — but only 12.5% of ⊤ sites**; `global` 64.9% and `kernel` 21.1% dominate | **The "dominant" claim is an artifact of the `scanExpr` gate**: the old figure counted only nodes co-resident with a singleton-head call, which biased the shape mix. Un-gated, the ⊤ mass is overwhelmingly global-callee (E9.1 `lss.devirtFnGlobals` territory) and kernel-callee (LSS_004/LSS_021/LSS_022 territory). GAP-9's recorded footprint is corrected accordingly. |

### 2.R.6 What this closes, and what it re-ranks

- **Stop condition fired** (§2, first bullet, in its exact sense): the union
  moves no content between siblings in either direction, so separation buys
  nothing. §§3-4 are not built; `lss.letUseDirected` is never created.
- The join is not pure cost either — 1,364 `intoUse` events are real
  binding→use flow the sigFlow arm depends on. So the recorded "cheaper
  follow-up is deleting work" alternative does **not** apply to the join
  itself; the only deletable work here would be the 33,473+66,627 letEnv
  misses and the guard, which is a micro-optimization, not a lever.
- **Re-ranked ahead of this plan**, on this census's own evidence — with
  a correction recorded 2026-08-21 (same day, follow-up scoping): the ⊤
  mass is 64.9% `global`-callee and 21.1% `kernel`-callee, **but that
  table counts EVERY `MonoCall` whose head annotation is ⊤** (`stampCall`
  consults every call; kernel-callee sites are direct by construction), so
  it is NOT a dispatch measure and must not be read as one. The
  dispatch-relevant residue adjacent to it: `lss.devirtFnGlobals` (E9.1)
  has been DEFAULT-ON since Run L (2026-07-20) — "exploit E9.1" cannot
  mean flipping it — and the actual unexploited population is the
  **1,394 `declinedNoInstance` singleton sites** on this tree (this
  census's un-gated AbiCloning counters), the post-settle/arity classes
  E9.1's translate-time arm misses. Sized census-first in
  `plans/lss-post-settle-fn-global-devirt.md` — which PARKED the same day
  (admissible slice ≈0.24% of dispatch, upper bound). GAP-2's empty signature
  channel remains underneath the `local` remainder. None of them is this
  plan.

---

## §3 Design sketch (NOT BUILT — Phase 0 returned PARK; kept for the record)

- **H.1 — the directed boundary.** In `joinLetUse`, replace
  `joinArrowSets identity rhsVar useVar` with the LSS_023 directed walk
  installing use-includes-rhs edges (variance-aware; containers degrade
  symmetric; defensive arms fail toward ⊤, never toward skip). Producer
  gating: LsFrom must remain unreachable when `lss.sigFlow` is off
  (LSS_023's byte-inertness gate — the PSFTunnels lesson), so the
  directed let boundary is DOUBLE-gated: its own flag AND the sigFlow
  representation gate. Flag: `lss.letUseDirected`, env
  `ECO_MONO_LSS_LET_USE`, hash token `lssLU=` non-default-only,
  DEFAULT-OFF at landing. `bindParamsFromSpine` entries (param-bound)
  take the same directed treatment (H.3) — one mechanism, censused
  separately.
- **H.2 — PoisonUseOnly.** Widen `onPoison` into the mode the doc
  comment reserved: divergence attributable to the USE side poisons the
  use only; a variable/mismatch on the RHS side still poisons both (the
  binding genuinely is polymorphic there and every use must see ⊤ or the
  narrowing would be a lie). The per-arm direction argument must be
  written into the code comment at each `poisonBoth` call site converted
  — LSS_023's standing rule applies: **any new directed site must
  re-argue variance**, and a wrong-direction edge is the UNDER-
  approximation miscompile class, fail toward ⊤.
- **Soundness envelope:** LSS_005 covers all of it (annotations,
  spec counts, dispatch tiers move; observable behavior never). New
  singletons minted by this plan meet AbiCloning behind the LSS_024
  fence — behaviorally divergent same-layout instances decline
  `bodyMismatch` — and Borrow behind the BORROW_006 fence; no new
  representative-premise consumer is created.
- **Census wiring:** `lssStats.letUse = { edges, poisonUse, poisonBoth }`
  nested (the 32-slot cap discipline; `layoutQual` is the template).

## §4 Phases past the census (sketch, to be firmed by Phase-0 numbers)

1. Substrate flag-off byte-identical (two binaries / one frozen corpus —
   and remember every compiler edit moves the corpus: re-run BOTH arms
   after the last edit).
2. Pins, extending `LssSigFlowTest`/`LssDirectedFlowTest` style: a
   let-bound callback used at two sites where one use widens — flag-off
   both uses read the union/⊤; flag-on the clean use keeps its singleton
   (the chooseHandler-analogue depollution pin); a rhs-side-divergence
   fixture where BOTH uses still read ⊤ (the poison-direction pin);
   determinism ×2.
3. Measurement: lss-opt A/B (wall FLAT band, majors reported) +
   runtime-calls acceptance sized from the Phase-0 candidate table (the
   census PREDICTS the recoverable events; the runtime leg must confirm
   ≥ an agreed fraction — set it when the candidate table exists, the
   LSS_024 §6.2 ≥85% device).
4. Flip decision recorded separately, never coupled with anything else.

## §5 Risks

1. **Wrong-direction edges** — the under-approximation miscompile class;
   variance re-argued per site, containers degrade, defenses fail to ⊤.
2. **PoisonUseOnly under-poisoning** — the rhs-at-fault arm must keep
   poisoning both sides; pinned by the §4.2 poison-direction fixture.
3. **Resolution cost** — pull-at-read DFS over a larger edge graph at
   every zonk of a use slot; lss-opt wall is the check (≥3% band). The
   arrow-free cost guard (:2025-2030) stays.
4. **Fan-out** — narrower use sets are new annotation content in keyed
   demands; LSS_024 absorbs the annotation-only splits, and
   MONO_030/LSS_018 watchdogs stay armed. Spec-count movement is a
   recorded §4.3 output, not a surprise.
5. **Census honesty** — the instrumented classifier itself resolves slots
   early; it must use the same read-time resolution as zonk (no fresh
   semantics), and the one-shot code is removed before any gate runs.

## §6 Non-goals (recorded)

- The local-multi member-injection bypass (`localMultiBypass`,
  Translate.elm:2943-2949) — E4a territory, censused here as a row only.
- Full per-use re-instantiation of the binding (let-polymorphism
  replay) — superseded by the directed-edge design.
- The E0.5 escape-by-soundness class — E8's shelved transform, not
  precision work; the census subtracts it, this plan never touches it.
- No change to any flag default inside this plan.

## §7 Invariants delta — NONE (Phase 0 returned PARK)

No invariant changes. Recorded so the intent is not re-derived later:

- **LSS_025 is NOT minted** and its id is NOT reserved — nothing was built.
- **LSS_023 is UNCHANGED**: `joinLetUse` STAYS on the kept-symmetric list
  (§5.2 row "kept symmetric"), and the note there is updated from
  "per-use separation stays Phase-H-parked" to "parked ON MEASUREMENT" with
  a pointer to §2.R. Symmetric is not a v1 compromise at this site — it is
  measurably equivalent to directed, because the channel carries no
  use→rhs content in either bound.
- **Fidelity mapping GAP-9**: the repair-half row moves from "leans PARK"
  to **measured PARK**, and its recorded footprint claim
  ("`topSiteShapes local = 7,361` … the dominant residual callee shape") is
  CORRECTED by §2.R.5 — un-gated, `local` is 12.5% of ⊤ sites, not the
  dominant shape. The GAP-9(a) "counterless poison" criticism is
  DISCHARGED in substance: the poison was counted, and it is 100%
  rhs-at-fault with zero destroyed slots.
