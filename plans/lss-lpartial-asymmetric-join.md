# LPartial — the asymmetry-tolerant join (provenance Part C, built at last)

**Status: PLANNED + AR'd + LOWERED (2026-09-01). Commissioned by the user
("(a) unblock the flow repair") after flowConnect's double refutation
(lss-var-chain-roots.md §9.9/§9.11) named the join lattice as the
blocking dependency.**

Companion plans: `lss-var-chain-roots.md` §9 (the flow-repair arc this
unblocks), `lss-provenance-join-and-demand-sigs.md` Part C (where
LPartial was first recorded, 2026-08-29). Paper references via
`design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md`.

---

## §1 Concept — restore the paper's two-phase discipline

**The paper never joins two "complete" answers mid-inference, because
mid-inference NOTHING is complete.** During inference, set knowledge
accumulates as inclusion constraints `Q = {ℓ ⋸ α}` — LOWER bounds.
Completeness exists only after internalization (Fig. 7,
`S(Q,α) = {ℓ | (ℓ⋸α) ∈ Q}`), performed at generalization when the
variable's constraint set is closed. Eco's `LSet` conflates the two
phases: every set claims completeness the moment it is written, so when
a set meets a var at a join, the only sound answers under
eager-complete semantics are ⊤ (what `unionAnno` does — the L7 tax) or
information loss. **LPartial is the accumulation-phase state the paper
has and Eco lost**: `LPartial members` = "at least these members;
possibly more" — a Q-set in Mono clothing.

Three independent measurements bill the missing state's tax:
argFeedback's +45 conflict-⊤ (reverted), flowConnect v1.1's +46, and
flowConnect v2's IDENTICAL +46 — the last proving the conflicts arise
at CROSS-SITE DEMAND JOINS (one site's set meets another's var), which
no within-item discipline can reach. Every asymmetric-precision
mechanism pays this until the join tolerates asymmetry.

**Honest sizing:** the direct recovery is small — 112 conflict positions
at shipped defaults, 158 with flowConnect on; 28/52 of those sit in
cells where siblings hold sets. LPartial's value is NOT this class; it
is (a) removing the tax that has now refuted two mechanisms, (b)
PRESERVING the lower bounds that ⊤ currently destroys (a partial is
settle-recoverable; a ⊤ is not), and (c) making flowConnect
re-measurable on its merits — the arc's actual goal.

## §2 Design — v1 scope (deliberately narrow)

**New state:** `LPartial (List Int)` in `Mono.LambdaSetAnno`. Sorted
member list, same interning as `LSet`.

**v1 producers (exactly one rule):** the annotation-join layer.
`unionAnno`'s `(LSet xs, LVar _)` and `(LVar _, LSet xs)` arms — today
`topConflict` — become `LPartial xs`. Derived arms:

    LPartial xs ∪ LPartial ys = LPartial (xs ∪ ys)
    LPartial xs ∪ LSet ys     = LPartial (xs ∪ ys)   -- a complete side
                                                     -- does NOT restore
                                                     -- completeness: the
                                                     -- partial side's
                                                     -- unknown flows are
                                                     -- still unknown
    LPartial xs ∪ LVar _      = LPartial xs
    LPartial xs ∪ LTop k      = LTop k               -- ⊤ still absorbs:
                                                     -- a definitely-
                                                     -- unknown flow
                                                     -- caps the position

**v1 non-producers (explicit):** the STORE keeps complete semantics
(`LambdaSet1`/`LsSet` untouched; store var×set joins already adopt
without conflict). Signatures (`ArrowFact`) never carry partial — a
partial fact records as no-fact. `Store.monoTypeToVar` encodes
`LPartial` as a FRESH FLEX slot (members dropped at store re-entry,
counted) — conservative, sound, and keeps v1 out of the store
representation entirely.

**Identity-blindness (the §4.9/topKind precedent, and the B1 churn
lesson):** `annoHash`, `toComparableMonoType`, `eqLayout`/
`shallowLayoutKey`, `eqModuloTopLabel` treat `LPartial xs` exactly as
`LSet xs`. Partiality is CONSUMER metadata — join semantics, devirt
gating, promotion eligibility — never identity. SpecKeys must not split
on it.

**Consumer guards (the load-bearing edits):**
- `headAnno`/`singletonHeadMember`/AbiCloning `stampCall`/devirtPost:
  `LPartial [m]` is NOT a singleton — devirt never consumes a lower
  bound. (The miscompile class this prevents: promoting a partial to a
  direct call while an unrecorded inhabitant exists.)
- Settle strict cells (`varCtorRows`/`varLambda` collect walks): a
  partial contributor CONTAMINATES, same as var (it admits unknown
  flows).
- `varSucc`: an `LPartial` head does NOT license successor writes
  (successors reason from complete heads).
- `enrichAnno`/`enrichAnnotationsTopOnly`/`overlayAnnotations`/
  `recoverStoredSets`/`widenSets`/`joinAnnotations(Changed)`: arms added
  with lower-bound semantics (never upgrade partial→set; ⊤-heal never
  reads a partial as a set).
- Census: coverage line gains `part=`; pos rows emit `part@` with
  member count; `top kinds:` loses the conflict class by construction
  (the counter is EXPECTED to go to ~0 — that is the v1 differential).

**Deferred to v2 — PROMOTION (the paper's internalization):** at the
post-drain settle, an `LPartial` whose position passes a completeness
argument (all construction routes marked — the strict-cell/flex-mark/
license machinery that already exists) promotes to `LSet`. v1 never
promotes: maximally conservative, zero new soundness surface. The v2
design note: promotion is per-POSITION, runs where `settleCtorRows`
runs, and its GO gate is the measured count of promotion-eligible
partials after v1 + flowConnect ship.

**The flowConnect amendment (rides this plan):** re-battery flowConnect
under LPartial with its store write ⊤-SANITIZED — `deTopAnnos` on the
encoded type (every `LTop` becomes a placeholder `LVar 0`, which
`monoTypeToVar` encodes as fresh flex = a no-op at the target slot).
Under eager-complete semantics that sanitization was a lie; under
lower-bound accumulation it is exactly what a Q-constraint carries.
This addresses v2's ⊤ +703 (`topCarried` 280) at the source.

## §3 Adversarial review — against the code

**AR-P1 (blast radius is bounded and compiler-enforced).** ~10 files
carry `LambdaSetAnno` case arms (~70 sites: Monomorphized 33, Store 8,
Monomorphize census 17, AbiCloning 5, Engine/Translate/IO/MapTemplate/
LssFacts the rest). Elm's exhaustiveness checking turns the entire
radius into compile errors — every site is visited CONSCIOUSLY, none
can be missed silently. The hazard is not missing a site; it is
choosing the wrong arm semantics at one. Each arm follows one of three
rules: identity-blind (hashing/keys), lower-bound (joins/enrich), or
guard (devirt/settle/successors) — the review's checklist is the §2
table, applied file by file in the lowering.

**AR-P2 (the devirt guard is the soundness core).** Today
`LSet [m]` → devirt. A formerly-conflict position was ⊤ (devirt-
invisible); under v1 it becomes `LPartial [m…]` — if ANY singleton read
treats it as `LSet`, devirt fires on a lower bound = the
arrowSolverRoots false-singleton class. Every singleton consumer must
be enumerated: `singletonHeadMember`, `headAnno` pattern matches in
AbiCloning (:961, :1290), devirtGlobalTarget's annotation read,
MapTemplate's safeSpecs read, Borrow/LssFacts. The lowering lists each;
the battery's E2E is the empirical backstop, and one unit pin asserts
`LPartial [m]` is not stamped.

**AR-P3 (identity-blindness cuts both ways).** Hashing partial(xs) as
set(xs) means a spec can be keyed by one demand and read back
partial-annotated rows from another. Sound: partiality never affects
layout or ABI (annotations are set-metadata; `eqLayout`'s job is
layout), and devirt reads expression-level annos, not keys. What it
DOES mean: the census's `part=` count is row-level truth while
SpecKeys stay stable — exactly topKind's contract. VERIFY in battery:
spec count must not move on the v1 differential (`specs=` line).

**AR-P4 (zonk boundary drops are the honest price).** Demand types
carrying partials re-enter the store via `demandUnify`/`monoTypeToVar`
as fresh flex — the members are DROPPED at that boundary (counted:
`lpart|reencodeDrop`). Alternative (store-level partial content) is v2+
scope. Consequence: partials influence READBACK (census, settle,
devirt-guard) but not onward store flow — v1 partials are
терminal observations, which is precisely enough to (a) kill the
conflict manufacture and (b) preserve recoverable bounds.

**AR-P5 (retranslation idempotence).** LSS_010 flush rounds re-run
joins. All new arms are monotone (member lists only grow; partial never
upgrades itself) — idempotent by the same argument as set-union joins.

**AR-P6 (the reverse-direction hazard: LSet∪LPartial must NOT return
LSet).** Tempting "the complete side wins" is UNSOUND: the two sides
describe DIFFERENT flows into one position; the partial side's unknown
flows remain unknown after the join. The §2 table's
`LPartial ∪ LSet = LPartial` is load-bearing; a unit pin asserts it.

## §4 Adversarial review — against the paper

**Fidelity verdict: this REMOVES Eco's deepest lattice infidelity.**
The paper's Fig. 5 TIU accumulates constraints; Fig. 7 internalizes at
generalization; nothing in between ever claims completeness. Eco's
eager-complete `LSet` is the deviation — workable only while all
precision arrives symmetrically, which the three measured refutations
show it does not. `LPartial` = Q-accumulation; v2's promotion-at-settle
= internalization-at-quiescence (Eco's settle IS its generalization
moment — the one order-free window, the same argument that placed
every settle pass). v1 without promotion is a FAITHFUL PREFIX of the
paper's pipeline: accumulate now, solve later, never lie in between.

**The ⊤ interaction is Eco's own (paper has no ⊤):** `partial ∪ ⊤ = ⊤`
keeps ⊤'s "definitely unknown flows exist" meaning intact and keeps the
§4.9 neutrality contract (⊤ only ever widens/blocks; never licenses).

**The deTop sanitization becomes faithful under LPartial:** a
Q-constraint `ℓ ⋸ α` carries members only — there is no ⊤ to transport
in the paper's channel. Stripping ⊤ from flowConnect's encoded type is
the paper's channel semantics, sound exactly because the receiving
state no longer claims completeness.

**Net: APPROVED. v1 producers limited to the one join rule; promotion
deferred with its own gate; flowConnect re-battery is the arc's
measurement.**

## §5 Lowering — implementation-ready

Flag: **none for the lattice itself** — the new arms are semantics
corrections active whenever LSS runs; the DIFFERENTIAL is the conflict
census going to ~0 and `part=` appearing. (A flag would fork the
lattice — every downstream pin would need double arms. The B-side risk
is covered by the full battery + the E2E rails.) flowConnect keeps its
existing `lssFC=` flag for the re-battery.

1. `Monomorphized.elm`: `LPartial (List Int)` ctor; arms per §2 —
   `unionAnno` (the one producer + derived arms), `annoHash`/
   `toComparable*`/`eqLayout`/`eqModuloTopLabel` identity-blind with
   `LSet`, `headAnno`/`singletonHeadMember` guard, `enrichAnno`(+
   TopOnly)/`overlayAnnotations`/`joinAnnotations(Changed)`/
   `widenSets`/`recoverStoredSets`/`annoCovers`/`isTopAnno`(False)/
   `hasVarAnno`(True — a partial admits unknown flows, settle treats it
   as var-like)/`collectAnnoMembers`(members)/`annoCoverage`(new
   `part` bucket).
2. `Store.elm`: `monoTypeToVar` encodes `LPartial` as fresh flex +
   census `lpart|reencodeDrop`; `classifyGo`/readback arms untouched
   (store never produces partial in v1).
3. `Monomorphize.elm`: census walks (`posWalk` → `part@N`, coverage
   line `part=`, varfix/vf3/sigfact walks treat partial as
   contaminating-var); settle collect walks (`varCtorRows` cell rule,
   `varLambda` `varCellWalk`, `succSetFor` head rule) — partial blocks.
4. `AbiCloning.elm`: the two `LSet [ m ]` singleton matches stay
   `LSet`-only (adding a partial arm that DECLINES, with a census
   counter `lpart|devirtDeclined` so the guard is observable).
5. `MapTemplate.elm`/`Borrow/LssFacts.elm`: enumerate arms, guard as
   non-singleton/non-complete.
6. `Translate.elm` (flowConnect amendment): `deTopAnnos` (LTop → LVar 0
   walk, ~15 lines) applied to the encoded type in BOTH halves
   (`connectParamArg`, `connectLambdaResult`); census
   `flow|deTopped`.
7. Unit pins (one module): union-arm truth table incl. AR-P6's
   `LSet ∪ LPartial = LPartial`; devirt-guard pin (`LPartial [m]`
   never stamps); identity-blindness pin (`annoHash`/`toComparable`
   equal for partial/set).
8. Battery A (lattice v1, no flags): defaults census — EXPECT
   `conflict` ≈ 0 in `top kinds:`, `part=` ≈ old conflict count, specs
   stable (AR-P3), coverage/k1/kN otherwise UNCHANGED (the v1
   differential is bookkeeping, not movement); VALIDATE; E2E; elm-tests
   + overlapping-pin sweep (pins asserting `top@conflict` — grep for
   them first).
9. Battery B (flowConnect re-battery under LPartial + deTop): the
   §9.11 table re-measured — EXPECT conflict flat, ⊤ flat (deTop),
   var falling into k1/kN/part instead of ⊤; judged per L1 on named
   cells; flip decision with the user.

**Sequencing:** 1–7 one build; battery A; then 6's amendment is already
in — battery B immediately after A on the same binary (env flag arms).

## §6 BUILD RECORD (2026-09-01)

**Blast radius as built:** ~70 arm sites across 10 files, enumerated by
the compiler's exhaustiveness errors module by module; wildcarded
functions audited by hand (widenSets/recoverStoredSets/eqModuloTopLabel
correct by their existing defaults; `singletonHeadMember`'s wildcard IS
the devirt guard). 51/51 unit pins green pre-battery, including all
prior var-arc pins — zero behavioral casualties from the join change.
Two instructive defects caught BEFORE the battery:

1. **A silent patch no-op caught by its own pin.** The `enrichAnno`
   AR-P6 arms were applied by a replace with no assert against a stale
   copy of the function; pin 6 ("enrich never upgrades partial to set")
   failed and located it. Assert every replacement.

2. **The LSS_010 exactness law caught blanket-conservative `annoCovers`
   arms.** First battery B run hit the 100-round flush watchdog
   ("registry/actualType oscillation") at `variableToCanType`: my
   `annoCovers (LPartial _) _ = False` violated the documented law that
   covers must decide EXACTLY `unionAnno a b == a` — since
   `union(LPartial xs, LVar) = a`, the changed flag was falsely True and
   every hit re-marked the spec dirty, forever. The docstring predicted
   this failure mode verbatim. Fixed with exact arms
   (`LPartial xs` covers `LVar`, subset partials, subset sets; never ⊤;
   never covered by set/var), pinned as the "LSS_010 LAW" test over 9
   argument pairs. LESSON: for a lattice extension, "conservative" on a
   COVERS predicate is not conservative at all — it is a liveness bug;
   the only safe covers is the exact one.

## §7 BATTERY RESULTS (2026-09-01) — the lattice SHIPS; flowConnect's
## residual question is named

**Battery A (lattice v1 at defaults) — exactly the predicted
differential, twice reproduced:** conflict 112 → **28** (the LSet×LVar
manufacture ELIMINATED; the residual 28 = the deliberately-untouched
var×var arm), ⊤ −84 with **part=96** appearing in its place (the
formerly-destroyed information, preserved as recoverable lower bounds),
coveredBp IDENTICAL (9,154), var/k1/kN flat modulo source drift, wall
normal. Behaviorally clean: the join semantics correction costs nothing
and removes the thrice-measured tax.

**Battery B (flowConnect under LPartial + deTop) — both blockers
REMOVED:**

| | defaults | flowConnect on | (v2 for contrast) |
|---|---:|---:|---:|
| conflict | 28 | **28 flat** | +46 |
| ⊤ | 1,143 | **1,142 flat** | +703 |
| part | 96 | 142 (+46) | — |
| var | 10,947 | 10,867 (−80) | −692 |
| k1 | 99,681 | 99,081 (−600) | −672 |
| kN | 32,229 | 32,898 (+669) | +660 |
| `varlam\|wrote` | 596 | **45** | 45 |
| `topCarried` | — | **10** | 280 |
| wall | 13:19 | 13:40 (+2.6 %) | +4.4 % |

The conflict tax is gone (LPartial) and the ⊤ explosion is gone (deTop —
`topCarried` 280 → 10, partly because LPartial also stopped upstream
conflict-⊤ from contaminating lambda types in the first place). The
settle-decay thesis holds (596 → 45).

**What remains, and its changed interpretation:** k1 −600 / kN +669
(the `andThen` −481/+487 pattern). With conflicts and ⊤ ruled out, this
is no longer churn-by-artifact: flowConnect delivers EACH caller's
lambda interiors into SHARED specs (`keyed=False`: sets never fan out
specializations, demands JOIN), so under-informed per-single-caller
singletons honestly widen into true multi-inhabitant kN. Whether that is
a win is EXACTLY the GAP-6 question — kN has no dispatch consumer — and,
uncomfortably, it raises an open soundness-adjacent question about the
PRE-EXISTING k1s at shared-spec interiors (were they under-approximations
all along? devirt reads expression annos inside the ONE shared spec body
serving all callers; E2E has stayed green throughout, so any exposure is
guarded in practice by the instance-resolution layer — but the question
deserves its own probe, recorded here, not resolved).

**DECISIONS (presented 2026-09-01):**
1. **Lattice v1: SHIP** (it is unflagged semantics — shipping = keeping
   it in tree; gates below must be green).
2. **flowConnect: still NOT flip-worthy under L1 as written** — k1 −600
   at the named cells for var −80. The honest framing has improved
   (truth-widening, not artifact churn), but the L1 currency is k1 and
   the mechanism spends it. Its knowledge is not lost: the same
   interiors remain reachable via the settle passes' gated writes, and
   the flag stays for the day kN gains a consumer (sum lowering) — at
   which point honest kN becomes VALUE and this decision inverts.
3. **v2 promotion** gains its feedstock number: 142 partials on the B
   arm (96 at defaults) — small; promotion stays deferred until flow
   mechanisms that MANUFACTURE partials at scale exist.

## §8 THE COVERAGE LENS (user recalibration, 2026-09-01)

The arc's standing metric is COVERAGE — eliminating the var/⊤ residue.
The k1/kN composition is exploitation-side (its payoff waits for sum
lowering) and must not drive this arc's decisions. Re-reading §7 through
that lens:

| | pre-LPartial defaults | LPartial (A) | +flowConnect (B) |
|---|---:|---:|---:|
| coverage | 91.54 % | 91.54 % | **91.56 %** |
| var | 10,947 | 10,947 | **10,867 (−80)** |
| ⊤ | 1,227 | **1,143 (−84)** | 1,142 |
| part | — | 96 | 142 |
| uncovered total | 12,174 | 12,186 | **12,151 (−35 net)** |

- **LPartial v1 is coverage-NEUTRAL by design**: it converts 84 terminal
  ⊤ into 96 recoverable partials (uncovered either way; v1 never
  promotes). Its coverage value is an OPTION — realized only by v2
  promotion — plus the unblocking of flow mechanisms.
- **flowConnect, re-judged under coverage: weakly POSITIVE** — var −80,
  ⊤ −1, +0.02 pp — where before LPartial it was actively ANTI-coverage
  (+703 ⊤). The k1 −600 that drove §7's no-flip is coverage-irrelevant
  (k1 and kN are both covered).
- The remaining reservation is WALL, not precision: +2.6 % (consistent
  across three batteries: +2.3/+4.4/+2.6), over the ≤1 % phase budget,
  for −35 net uncovered. The flip decision under the coverage metric is
  the user's call with that trade stated plainly.
- **The coverage lever this plan actually creates is v2 PROMOTION**:
  partials ARE eliminable residue (⊤ never was). Feedstock today 96–142;
  it grows with every flow mechanism that ships.
