# LSS stage-anchor writers — construction-anchored stage naming for `l|` heads

**Status: PLANNED (2026-09-02). Successor to plans/lss-var-chain-roots.md
§9.14, which closed M2/lamStages UNBUILT and named "construction-anchored
inference repairs" as the only principled route to the stageVar class.**

**Metric: LSS COVERAGE (var/⊤ residue elimination), per the arc's standing
recalibration. Gate policy: small-gates (§5.2 of the parent plan) — any
sound improvement passes; the binding gate is soundness.**

Baseline (defaults, m2ref 2026-09-02, build-kernel corpus):

    coverage: positions=144165 k1=99106 kN=32904 var=10867 top=1146
              part=142 coveredBp=9156
    m2stage:  stageVar=142 bodyVar=274 arityMix=0 noHome=0


## §1 WHY — source replication, not pipe repair

The flow-repair arc established (parent plan §9.1–§9.15) that depth
knowledge — what sits BEYOND a lambda's head arrow — is minted exactly
once, at the lambda's own translation, and travels only by unification
across five hop families (argument, binder, data, join, item-boundary).
Every hop is a filter; a depth-9 chain clears only if ALL its pipes are
sound. flowConnect, varCtorRows, and LPartial each repaired one pipe, and
the residue duly concentrated in the chains that still cross an
unrepaired one. Head knowledge survives the same journeys because it has
REDUNDANT CARRIERS — member injection re-fires at references, argument
sites, and joins; it is re-derivable, multi-writer knowledge.

The corpus evidence (2026-09-01/02 queries over m2ref.log `pos|` rows):
the stage-hole class is dominated by single lambdas whose HEADS ride
long journeys perfectly while their next arrow goes var:

    mid 1180: 727 rows across 147 specs — a Json.Decode lambda stored
              INSIDE Decoder/Err ctor payloads at depth 7–9
              (pos|Decoder|/a0/r/c1/r/r/r/r/r/r/r|k1:l;1180;…)
    mid 5295: 124 rows across 124 specs — one lambda at map|/a0
    mid 9752:  17 rows across  17 specs — a 2-param foldl callback,
              hole at /a0/r (the second stage)

Every one of these positions is k1-headed over a var interior: the head
transport system already delivers to the site; the depth never arrives.

This plan does NOT repair another pipe. It adds NEW WRITERS — anchored
producers that re-derive stage knowledge locally wherever the head
lands, from facts that are unambiguous at the anchor. The requirement
inverts: instead of "the depth survives all N hops from the lambda's
birth," it becomes "the HEAD survives to the nearest anchor site" —
which the 142 satisfy by construction. This converts stage knowledge
from the perishable single-source class into the re-derivable
multi-writer class — the same property that lets heads survive.

The family precedent already ships: for `g|` heads,
`mintPapSuccessorIds`/`papSuccGoC`/`papSuccWrite`
(LssInfer.elm:2858–2943) anchor p|g|d successor members on a referenced
global's spine within declaredArity, and the store's shared result
Points transport them onward "with no new transport machinery" (the
papSuccWrite docstring). The probe proves it end to end:
`pos|useStage|/a0|k1:p;…mkAdd3v;1` (test/elm/src/LssGapLambdaStages.elm,
MEASURED section). The missing family member is the same anchored write
for `l|` heads. Per LSS_013's shipped convention these writes use the
lambda's OWN mid ("a PAP of m is still m") — no new member ids, no
identity split (the M2 kill's first horn, §9.14, stays respected).


## §2 WHY M2's WRITER DIED, AND THE ONE FACT THAT REVIVES IT

M2's settle-time own-mid hole-fill was killed (§9.14) on ALIGNMENT
ambiguity: a row fragment `Int -> (Int -> Int)` with head {l|m} cannot
tell "one more stage of m" from "q's arrow" — the arity-2-returning-
closure killer (`mkAdd3v = \a b -> \c -> …`) makes the type identical
either way, and filling with m writes a FALSE member onto q. The
current m2stage census (Monomorphize.elm, `m2StageWalk`) inherits the
same gap: it counts stageVar on `home.arity >= 2` alone, never deciding
WHICH stage the observed arrow is. So an unknown fraction of the 142
are boundary rows a sound writer must refuse. That fraction is itself a
P0 deliverable.

The ambiguity is killed by ONE new fact, recordable exactly where it is
unambiguous — at the lambda's own birth injection:

**F2 (the qSpine fact):** at `injectLambdaMemberQualified arity srcLam
funcVar` (LssInfer.elm:173), additionally record

    mid  →  { arity : Int, qSpine : Int }

where qSpine = the curried spine length of the value's type BEYOND the
first `arity` arrows — i.e. the returned q's own top-level arrow count,
measured on the funcVar store spine chasing aliases (papSuccGoC-style).
Both inputs are in hand at that call site today (arity is literally its
first parameter).

**The alignment theorem.** For a k1 head {l|m} observed at any arrow
position, let T = the observed successor-arrow chain length from that
arrow INCLUSIVE. The value there is stage k of m (k unknown) with
a − k within-arity arrows remaining, and T = (a − k) + s where
s = qSpine(m). Therefore

    r = T − s          (within-arity arrows remaining, from here)

is decidable WITHOUT knowing k. Arrows 1..r from the position carry m
(LSS_013 own-mid); arrows r+1.. belong to q. Checked against the killer:
mkAdd3v has a=2, s=1. Stage-1 fragment at useStage /a0: T=2 ⇒ r=1 ⇒
write arrow 1 only, /a0/r untouched — exactly right (/a0/r is q's, and
the probe shows flowConnect naming it k1 m<inner> independently).
Home row stage-0: T=3 ⇒ r=2 ⇒ arrows 1–2, arrow 3 (q's) untouched.

**Soundness direction of errors.** Over-write requires observed T
exceeding the true spine — impossible on a zonked row or resolved store
spine. Under-observation (flex tail hiding arrows) reduces T, reduces r,
under-writes: conservative. The ONE unsound direction is qSpine recorded
TOO SMALL at birth (inflates r, writes m onto q — the false member). So
the exactness rule: if the birth-time walk past `arity` arrows ends on a
flex var, record qSpine = UNKNOWN and both writers decline that mid
(counter `sa|qspineFlex`). Re-registration of the same mid with a
different qSpine ⇒ poison the fact + `sa|qspineConflict` (LSS_024
layout-qualified mids should make this impossible; the counter is the
assert).


## §3 DESIGN — one fact, two writers

### F0 — config restructure (MUST come first: the 32-slot trap)

`Config.LssConfig` is AT the 32-field record GC-scan cap (lamStages as
field 33 broke Stage 6 native lowering at BOOTSTRAP — parent plan §9.14
trap note). New flags MUST net out ≤ 32:

- Fold the three settle flags into a sub-record:
  `settle : { varSucc : Bool, varCtorRows : Bool, varLambda : Bool }`
  (32 → 30 fields).
- Add `stageAnchor : { rowFill : Bool, papSite : Bool }` (31 fields).
- Hash tokens: existing lssVS/lssVC/lssVL strings UNCHANGED (tokens are
  independent of record shape); new tokens lssSAr/lssSAp.
- Env overrides: existing three keep their names; new
  ECO_MONO_LSS_STAGE_ANCHOR_ROW_FILL / _PAP_SITE in Builder/Eco/Config.
- Neutrality gate for the restructure alone: byte-exact typed artifacts
  + full test battery before any writer lands.

### F2 — fact recording (inert, always-on)

As §2. Recording is cheap and consumer-gated, so it ships unflagged
(inert without W1/W2); report-gated counters sa|qspineExact /
sa|qspineFlex / sa|qspineConflict.

### W2 — `lss.stageAnchor.rowFill` (settle-time row writer)

The m2stage census walk, promoted to a writer with the alignment
theorem installed. Post-drain settle pass over spec rows:

- Trigger: arrow anno `LSet [m]`, m an `l|` mid with exact facts {a, s},
  a ≥ 2 (a = 1 is bodyVar/q territory — varLambda/flowConnect's, never
  ours).
- Compute T from the row's concrete MonoType arrow chain; r = T − s.
- For successor arrows at depths 2..r whose anno is `LVar _`: write
  `LSet [m]`. Claim VAR cells ONLY — never touch LSet/kN (already
  covered; unioning risks false members), never LPartial (v1 declines,
  counter), never LTop.
- Decline counters: sa|rowBoundary (r ≤ 1 — the census position is
  actually q's boundary, M2's would-have-been false member),
  sa|rowNoFact, sa|rowNotVar.
- Mechanism: direct row rewrite in the settle family — NOT
  enrichAnnotations (AR-V2, parent plan §4.1: never use
  enrichAnnotations for var writes).
- Chain placement: writes are EXACT (construction-anchored), so they
  belong before widened writers claim slots, and before the final
  settleVarSuccessors so successor chains can extend off newly named
  stages. Exact position is battery-tested — §8.4 lesson: settle order
  is a precision decision (coarse-first churned k1 −1,269 once).

### W1 — `lss.stageAnchor.papSite` (translate-time store writer)

The live-store half, at the partial-application site itself — the site
the user-quoted charter names: at `let step = mkAdder 5` the analysis
knows the callee head, m's facts, and that exactly j args were supplied.

- Site: translateIndirectCall's partial arm (the m2|lamPartialApp
  counter site, Translate.elm:2051; 491 sites at last census).
- Trigger: callee head `LSet [m]`, `l|` mid, exact facts {a, s}.
- Compute the CALLEE's r_callee = T_callee − s from its type at the
  site; the result value's within-arity arrows = r_callee − j.
- Write m into the result's first (r_callee − j) arrow slots via the
  papSuccGoC/unifySlotWithSetC store-write pattern. Store result Points
  are shared with downstream consumers (Unify's FunL×FunL subUnifies
  res1 ~ res2), so ordinary unification transports the fact onward —
  the same free-transport property the papSuccWrite docstring names.
- Skip `g|` heads entirely (mintPapSuccessorIds already owns them;
  double-writing would fight the p|g|d convention). Decline kN /
  LPartial / ⊤ / no-fact, with counters sa|siteKn / sitePartial /
  siteTop / siteNoFact.

W1 and W2 are complementary, not redundant: W1 writes into the LIVE
store during translation and rides unification to positions the census
never names; W2 repairs settled rows post-hoc where store transport
already failed. The battery runs them as separate arms (the §8.4/§8.5
lesson: per-mechanism arms catch what combined arms pass).

### v1 exclusions (v2 candidates, listed so they are decisions not gaps)

- kN heads with UNANIMOUS {a, s} across members: sound to write all
  mids ("a PAP of each m is still that m") — declined in v1, counted.
- LPartial heads: successor writes would need LPartial slot support —
  declined in v1, counted.
- Cross-member g|+l| mixed heads: declined.


## §4 P0 — measure before building the writers

Order: F0 restructure → F2 recording + counters → census run. All
counters lss.report-gated (and arrowCensus-gated where per-row).

1. Birth side: sa|qspineExact / Flex / Conflict — how much of the mid
   population has usable facts.
2. Row side (W2 ceiling): re-run m2stage with the alignment split —
   sa|rowWould (r ≥ 2 and successor var) vs sa|rowBoundary vs
   sa|rowNoFact vs sa|rowNotVar. rowBoundary is a RESULT either way: it
   measures the fraction of the 142 that was never soundly fillable
   (the false members M2 would have written).
3. Site side (W1 ceiling): split m2|lamPartialApp=491 by callee head:
   sa|siteL1 / siteG / siteKn / sitePartial / siteTop / siteVar /
   siteNoFact.

**GATE (small-gates policy): GO if sa|rowWould + sa|siteL1 ≥ 50.**
NO-GO ⇒ write the split into this plan, close the stageVar class with
the number (the census stays as tracker), proceed to the parent plan's
ORDER 6 re-census with the class explained.


## §5 BUILD ORDER

- ORDER 0: F0 config restructure + neutrality gate (byte-exact
  artifacts, full battery).
- ORDER 1: F2 fact recording + all P0 counters; run P0; GO/NO-GO.
- ORDER 2: W2 rowFill behind lss.stageAnchor.rowFill (default OFF).
- ORDER 3: W1 papSite behind lss.stageAnchor.papSite (default OFF).
- ORDER 4: battery (§6) + unit differentials + probe re-measure.
- ORDER 5: flip decision presented to the user.


## §6 BATTERY + TESTS

Same-source arms (same-day baselines drift — parent arc lesson):
baseline / rowFill-only / papSite-only / both. Judge on:

- coverage line (var, top, part, coveredBp) — the arc's metric;
- ⊤ by provenance kind, WATCHING conflict (the +46 churn signature that
  killed flowConnect v1.1/v2 pre-LPartial; LPartial should absorb
  LSet×LVar at W1's store writes, but this is pinned, not assumed);
- m2stage decay: stageVar must SHRINK by ≈ sa|rowWould in the rowFill
  arm — exact accounting expected, unexplained residue investigated;
- settle counters (varsucc|/varlam| deltas — do successor chains extend
  off newly named stages?);
- k1/kN composition (report, don't gate — exploitation-side);
- dispatch A/B: expected NEUTRAL (precision-side work; a move is a
  finding);
- wall clock.

Soundness gates (binding): elm-tests, full E2E (`--target full` — flag
arms must delete bin/eco-compiler{,.mlir} per arm; env vars are not
ninja inputs), byte-exact self-compile bootstrap.

Unit differentials: off-vs-on per writer, pinning ALL overlapping flags
(settle.varSucc/varCtorRows/varLambda, flowConnect, both stageAnchor
flags) — the papMembers/sigRootIdentity lesson. Fixture needs the
mkAdd3v shape (a=2, s=1) so the boundary-refusal arm is exercised, a
plain arity-2 lambda (s=0) for the fill arm, and a flex-tail case for
the qspineFlex decline. One-module fixtures cannot manufacture the
cross-item classes (§5.1) — corpus counters are the differentials.

Probe: re-run test/elm/src/LssGapLambdaStages.elm MEASURED section per
arm; its rows must stay identical (they are already 100% covered — any
change means a writer overstepped in-item).


## §7 ADVERSARIAL-REVIEW SEEDS (for the AR pass, against code AND paper)

- AR-A1: qSpine EXACTNESS at birth — prove funcVar's result region is
  fully resolved at injectLambdaMemberQualified time, or show the flex
  detection is airtight (the one unsound error direction, §2).
- AR-A2: mid↔qSpine stability across specs — verify LSS_024 layout
  qualification actually pins q's spine length per mid; the conflict
  counter must be zero on the corpus.
- AR-A3: alias chasing — T-counting on rows (MonoType) and spines
  (store) must chase Alias like papSuccGoC, without consuming depth.
- AR-A4: interaction with deTopAnnos' negative LVar ids — W2 claims
  LVar cells regardless of sign; confirm negative ids carry no
  additional meaning at claimed positions.
- AR-A5: W1 double-write vs existing machinery — prove g|-skip is
  total; prove no site is both a refspine|inject target and a W1 target
  for the same slot.
- AR-A6: settle-chain placement — run the order variants; pin the
  chosen order with the §8.4 rationale.
- AR-A7: flush safety — W2 is post-drain only; W1's store writes go
  through unifySlotWithSetC (same-slot union semantics); confirm no
  covers-law (LSS_010) surface is touched (no new lattice forms).
- AR-A8: LPartial at the written cell — unionAnno(LVar, LSet [m]) at a
  W1-shared Point must not manufacture conflict; cite the LPartial
  producer rule; pin in the unit differential.
- AR-A9: kernel boundary — confirm declines at kernel-absorbed heads
  are counted, not silently dropped.
- AR-A10: paper check — §8's fidelity claim reviewed against the
  paper's T-Abs/T-App treatment of curried application.


## §8 PAPER FIDELITY

In the paper's curried world, every intermediate arrow of a nested
abstraction carries its own lambda-set variable, populated at the
abstraction's typing (T-Abs) and carried by unification through each
application (T-App) — partial application is just T-App once, and the
result type's set is already populated. There is nothing to "repair":
the per-stage sets exist by construction. Eco's mono-uncurry collapses
nested lambdas into one multi-param item (parent plan §9.1: "the paper
never uncurries"), so intermediate stage arrows exist only as row
positions whose sets were never independently constrained. LSS_013's
own-mid convention is eco's reconstruction of the paper's identity
("a PAP of m is still m"); the stage-anchor writers finish the
reconstruction — they re-establish, from construction facts (arity,
qSpine, args-supplied), exactly the per-stage set population that
T-Abs + T-App give the paper for free. The deviation is
representational, not semantic, matching the §9.10 justification
precedent for flowConnect.


## §9 EXPECTED YIELD, HONESTLY

Ceilings are small and known: W2 ≤ 142 minus the boundary fraction;
W1 ≤ 491 sites feeding store transport (which may reach beyond the
census class — the Sep 1 l|-head/var-child query found 216 rows — plus
whatever varSucc chains extend off newly named stages). This is a
small-gates mechanism: its value is (a) closing the last NAMED var
class with either writes or an exact refusal count, (b) completing the
anchored-writer family (g| has papSucc; l| gets stageAnchor), and
(c) de-noising the parent plan's ORDER 6 re-census, which follows this
work either way.


## §10 REFERENCES

- plans/lss-var-chain-roots.md §9.12–§9.15 (M2 GO-misread, LSS_013
  correction, NO-GO, probe pinning), §5.1/§5.2 (fixture lessons, gate
  policy), §8.4/§8.5 (settle-order precision, per-mechanism arms).
- plans/lss-lpartial-asymmetric-join.md (the join lattice this builds
  on; LSS_010 covers law).
- compiler/src/Compiler/MonoSolver/LssInfer.elm:173
  (injectLambdaMemberQualified), :2858–2943 (mintPapSuccessorIds /
  papSuccGoC / papSuccWrite — the g| family precedent + the shared-
  Point transport argument).
- compiler/src/Compiler/MonoSolver/Translate.elm:2051
  (m2|lamPartialApp site), :1650 (classifyLambdaHead).
- compiler/src/Compiler/MonoSolver/Monomorphize.elm (m2StageWalk — the
  census that becomes W2; lambdaHomesOf — the arity authority).
- test/elm/src/LssGapLambdaStages.elm (the reference rows; regression
  pin).
- design_docs/invariants.csv — LSS_006, LSS_010, LSS_013, LSS_024;
  FORBID_* before touching codegen-adjacent paths.
