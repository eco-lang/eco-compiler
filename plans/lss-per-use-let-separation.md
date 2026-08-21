# Per-use let-set separation (Phase H / GAP-9 repair half) — census first

**Status: PROPOSED (2026-08-21, user-commissioned). Census (Phase 0) not
yet run — and this plan does not proceed past §2 without it.** This is the
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

## §3 Design sketch (contingent — do not build past Phase 0 without the GO)

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

## §7 Invariants delta (if built)

- NEW LSS_025: directed let-use boundary + PoisonUseOnly, gating and
  variance obligations as §3.
- AMEND LSS_023: the kept-symmetric list loses `joinLetUse` (and the
  §5.2 table's "per-use separation stays Phase-H-parked" note); the
  "re-argue variance at any new directed site" rule gains this site's
  argument.
- Fidelity mapping: GAP-9's repair-half row moves from "leans PARK" to
  measured GO/PARK with the Phase-0 numbers either way; §3.2's let-flow
  row cites this plan.
