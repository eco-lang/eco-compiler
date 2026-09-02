# LSS var elimination — chain-root writes

**Status (2026-09-01): Phases 1/2/4v2 SHIPPED DEFAULT-ON (varSucc,
varCtorRows, varLambda); Phase 3 v1+v2 REFUTED and REMOVED (§8.5); the
live arc is §9 FLOW REPAIR — recover lost edges instead of settle
reconstruction. §§0–5 below are the original 2026-08-31 plan, kept for
the record; results live in §4.x, §8.x, §9.**

Successor plan to `lss-ctor-arrow-identity.md` (CLOSED — see its §13), which
ends with the var pool fully attributed (§12–§12.2 there). This plan turns
that attribution into an ordered attack on the remaining 13,389 var
positions. Paper references use `design_docs/auto-borrow-inference/
lss-paper-fidelity-mapping.md` (Brandon et al., PLDI 2023).

---

## §0 Concept

A `var` position is a flex set-slot that **no write ever reached** (Aug 27:
100 % causeFlex, edgeEmpty=0 — propagation cannot fix it; the writes are
MISSING, not stuck). In the paper there are no ⊤ and no orphaned variables:
inference is complete (Thm 4.1), so a variable with no inclusion constraints
is internalized to the **empty set** (Fig. 7 — `S(Q,α) = {ℓ | (ℓ⋸α) ∈ Q}`,
∅ when Q has nothing) and lowering gives it an empty sum: provably
uninhabited. Eco cannot internalize var to ∅ — our inference is INCOMPLETE
(the fidelity mapping's own verdict on Thm 4.1), and the liveness census
proves it: **42.7 % of var arrows are applied at runtime**. Var is therefore
the measurable distance from Thm 4.1: each mechanism below restores one
class of constraint that the paper's single unification world never loses.

The census gave the pool a shape that makes restoration tractable:

- **69.7 % of var is chain INTERIOR** — ~1.7-deep chains hanging from
  ≈2,900 roots. Write the roots; interiors are expected to follow through
  store unification (refPapSpine precedent) — expected, measured, never
  assumed.
- Every chain root has an attributed cause class (§1), and each class maps
  to one missing write.

**FORBIDDEN baseline move:** never internalize var to ∅ (the paper's rule
requires the completeness theorem we do not have; a value flows through
42.7 % of these positions — ∅ would be an instant arrowSolverRoots-class
miscompile).

## §1 Census evidence (2026-08-31, shipped defaults; instruments live in
## Monomorphize.elm posRows — spec-idx 5th field + `k1:<memberkey>` naming)

Chain-root attribution of all 13,389 var (climb each chain per spec
instance to its first non-var parent):

| chain-root class | var mass | share | mechanism |
|---|---:|---:|---|
| inside ctor payload (5,956; +tuple 121/record 56/list 30) | 6,163 | 46.0 % | M-C |
| `k1:p → /r` PAP successor never written | 2,426 | 18.1 % | M-A |
| `k1:l → /r` known-lambda result never transported | 1,412 | 10.5 % | M-B |
| rooted at ⊤ | 1,142 | 8.5 % | out of scope (⊤ book) |
| `k1:g → /aN` argument of known global | 861 | 6.4 % | M-D |
| `k1:c → /aN` ctor-argument arrow | 634 | 4.7 % | M-C |
| `k1:g → /r` global result | 383 | 2.9 % | M-A/M-row |
| registry-row root / kN-rooted / misc | 368 | 2.7 % | M-A (kN member-wise) |

Root cells to watch (success is k1/kN LANDING HERE, per the arc's L1):
`andThen` 771 roots, `map` 450, `foldl` 282, `apply` 204, `map3` 197,
`Decoder` 165, `Ok` 152, `Cerr` 100. Top M-A parents: `p|Dict.insert|1→/r`
(65), `p|TTuple|1→/r` (37), the Config record-alias family (22×5),
`p|Eerr|2→/a0` — overwhelmingly curried ctor/record PAPs within declared
arity.

## §2 The vehicle: post-drain settle sweep

All mechanisms run as **one post-drain settle phase** (between `drain` and
`assembleRawGraph`, exactly where `settleCtorRows` lives), iterated to a
bounded fixpoint. Rationale, inherited from the destrAnno soundness hole
(AR-D2): translation-time reads see PARTIAL state — order-luck false
singletons; post-drain, unions are complete and the sweep is order-free.
Two write targets:

- **Store writes** (`unifySlotWithSet`) where the flex slot still exists —
  these CASCADE through unification into chain interiors.
- **Registry-row rewrites** (`Registry.updateRegistryType`, the
  settleCtorRows precedent) for row-level positions.

**Load-bearing consequence:** `devirtPost` (E9.5, DEFAULT-ON) reads final
rows and WILL act on every set this sweep writes. Settle-written singletons
trigger real devirt at lowering. Therefore every write rule below must be
exact-or-superset — under-approximation is the arrowSolverRoots miscompile
class, not a precision loss. This is why each mechanism carries a
completeness gate.

## §3 Order of attack

Ordered by soundness-headroom × size, not size alone.

### Phase 1 — M-A: PAP/global successor writes (~2,800 direct + cascade)

**The write:** at any final position holding `{p|X|k}` (or `{g|X}` ≡ k=0)
whose result-arrow slot is flex, write `{p|X|k+j}` (j = args consumed at
that arrow), **iff `k+j < declaredArity(X)`**. kN positions write
member-wise, **all-or-nothing**: every member must have a defined successor
(within arity, pap-able kind) or the position is skipped — a partial
successor set excludes real inhabitants.

**Why sound unconditionally:** the claim is type-level identity, not flow:
any value at that position is the result of further-partially-applying a
`p|X|k` value, and that IS `p|X|k+j` — wherever the application happens,
including inside kernels. No escape analysis needed. Beyond arity the
result belongs to X's body (LSS_013's boundary) — never written by M-A.

**Why the gap exists:** `injectPapSuccessors` (refPapSpine) fires only at
STANDALONE REFERENCES (Translate.elm:3985). Heads that arrive via producer
PAP injection, projections, sig transport, or completion joins get no
successor walk. M-A is refPapSpine's completion from "reference spines" to
"all settled positions", using the same `p|g|d` ids (`papMemberKey`) so all
paths unify (E9.2 one-identity).

**Arity source:** `declaredArityOf` (fuel-chased). Its known `_->1` floor
defect UNDERSTATES arity — which makes M-A skip writes, the safe direction.
Verified in AR-V3.

### Phase 2 — M-C(rows): ctor-row var extension + retrofit gate (~6,800
### class ceiling, this phase takes the row layer)

**The write:** extend `settleCtorRows` to enrich var payload positions of
ctor registry rows from the sibling-spec union — but ONLY under a new
**all-sets completeness rule**: the union cell must have received a SET
from EVERY sibling spec at that position (any ⊤ or var contributor ⇒ skip).
`enrichAnnotations` cannot express this (its `(LSet,LTop)→LSet` arm SILENTLY
drops ⊤ contributors — fine for ⊤-healing readback, fatal for var writes);
the var write path needs its own fold that tracks contributor completeness.

**Retrofit (AR-V1):** shipped `settleCtorRows` already CAN flip var
positions on ⊤-gated rows (`enrichAnno (LVar, LSet ys) → LSet ys`) with no
completeness check. Empirically inert today (var was exactly 13,389 on both
flip arms) — latent by luck, not by construction. Phase 2 puts the all-sets
gate on BOTH the ⊤-row var side-writes and the new var-gated rows.

**Kernel-construction license (AR-V5):** kernels construct Elm ctors
(`Ok`/`Err` from Json — the HEAP_046 lesson; `Decode.succeed f` stores an
ARROW payload). Elm-side unions cannot see those constructions. Ctors
constructible from kernel code get NO var-writes unless the kernel
parametricity license (LSS_022 machinery) covers the constructing kernel.
P0 measures how much of the class survives this gate.

### Phase 3 — M-row: use-side enrichment from member rows (g|/c| heads;
### covers `k1:g → /r` beyond arity, feeds the M-C class's use rows)

**The write:** a settled position holding singleton `{g|X}` (or `{c|X}`)
enriches its ENTIRE nested arrow type from the union over ALL of X's
registry rows (`Engine.specIdsForGlobal` — the SpecTally.ids widening
exists for exactly this shape). Union over all specs = the paper's unsplit
global store. Same all-sets rule per position. kN heads: enrich only where
ALL members resolve to rows and every row contributes a set.

**Escape caveat (AR-V6):** a member's row aggregates ANALYZED flows. Args
fed through un-analyzed appliers (kernel HOFs) never reached the row — so
/aN enrichment from rows carries the M-D escape hazard and is EXCLUDED from
Phase 3 (result-side positions only: what X returns is determined by X's
bodies, which are always Elm). /aN stays in Phase 5.

**Ordering:** Phases 2→3 iterate as one fixpoint (rows must settle before
uses read them; a position fixed in round n enables children in round n+1).
Bounded rounds with a changed-flag; chains are ~1.7 deep, expect ≤4 rounds.

### Phase 4 — M-B: known-lambda results (1,412 + cascade), agreement-gated

A `{l|mid}` singleton head with flex result: the lambda's result set is a
property of its ONE body — but per-instantiation analysis may qualify
members differently per host spec, and `lambdaQualified` records only the
FIRST-minting spec (diagnostics), so no unique authoritative row exists
(AR-V4). Sound v1 gate: aggregate ALL settled positions holding `{mid}` as
head; write the flex ones from the union **iff zero positions hold ⊤ or
var results for that mid elsewhere disagreeing** — i.e. the mid's result is
globally agreed. P0 measures the agreement rate; if low, M-B waits for a
real lambda-home authority (bigger change, out of this plan's v1).

### Phase 5 — M-D: argument feedback (861), license-gated, LAST

The reverted `argFeedback` channel, resurrected as a settle write: enrich
`/aN` of `{g|X}` heads from X's rows' param sets. Carries BOTH histories:
the churn lesson (broad enrichment diluted k1 −82 — the k1-singleton-head
gate bounds it) and the escape hazard (AR-V6 — args via kernel HOFs never
reached rows). Requires a licensing argument per member (LSS_022-style:
member never escapes to un-analyzed appliers) before any write. If the
license kills most of the 861, record and close — the class is 6.4 %.

**Out of scope:** ⊤-rooted 1,142 (the poison/abi/decl book — separate
arc); `k1:k` kernel heads (2).

## §4 P0 — instruments BEFORE mechanisms (the arc's L2)

One census extension, one run, four counters (all `lss.report`-gated):

- `varfix|mA|would` / `|beyondArity` / `|knPartial` — M-A candidates,
  within/beyond arity, kN all-or-nothing failures. **GO ≥ 1,500 would.**
- `varfix|mC|complete` / `|contaminated` / `|kernelCtor` — ctor-row var
  cells whose sibling union is all-sets vs ⊤/var-contaminated vs
  license-blocked. **GO ≥ 1,000 complete.**
- `varfix|mB|agree` / `|disagree` — lambda-mid result agreement rate.
  GO judged on the ratio, not a floor.
- `varfix|hazard|fixBvarflip` — positions shipped `settleCtorRows` would
  flip TODAY without the all-sets gate (the AR-V1 exposure, quantified).

Plus the standing differential-fixture discipline: a unit test whose
off-arm ASSERTS the var (multi-ctor + phantom-var fixture; assert a
position the off-arm actually leaves flex — the §9.7 trap), and whose
on-arm asserts the exact expected set, not just "some set".

### §4.1 P0 RESULTS (2026-08-31)

**mC and mB were decidable OFFLINE from the existing per-instance census
log (vp2.log) — no code needed; mA and the hazard needed in-compiler
counters (varfix census block in `renderLssReport`, arrowCensus-gated).**

**mC (ctor-row var, sibling-union completeness at (global,path) cells):**
4,133 var on ctor rows → **setOnly 2,181** (≥1 set, zero ⊤ contributors)
/ contaminated 255 / noInfo 1,697. Per-global setOnly: Decoder 882, Ok
740, Err 246, Cerr 110, Eerr 86. **GO (≥1,000 met)** — subject to the
kernel-construction license design (Ok/Err ARE kernel-constructed —
HEAP_046 — but kernel constructions carry decoded DATA; whether any
kernel can inhabit an ARROW-typed payload spec is exactly what the
license must establish. `Compiler.Json.Decode` is the compiler's own pure
Elm — its Decoder ctor is kernel-free, and it is the biggest row.)
noInfo 1,697 = no sibling knows: needs upstream phases first, out of
Phase 2's reach.

**mB (lambda-mid result agreement): NO-GO in v1 form.** 5,749 l-mids with
arrow results: 5,064 agreeable, 1 conflicting, 1 ⊤-polluted — agreement
is nearly universal — but the **writable var mass is only 65**: for 683
mids NO position anywhere knows the result. The `k1:l → /r` chain class
(1,412) is not an un-transported-knowledge problem, it is
knowledge-that-was-never-read-back — the lambda's body analysis result
never reaches ANY position. Phase 4 is CLOSED in v1 form; the
lambda-home authority (read the mint-site body type directly) is the v2
shape, redesign required before any build.

**mA (in-compiler varfix census, self-compile):**
`mA|would1=1,030 mA|wouldN=0 mA|beyond=333 mA|noSucc=819`. The three
buckets reconcile exactly with the offline attribution (noSucc 819 = the
l-parent /r class to the digit; would1+beyond 1,363 ≈ the 1,328 p/g /r
direct roots + drift): **1,030 direct sound successor writes, 75.6 % of
the pap-able class within declared arity.** Named Phase-1 success cells
(`varfixg`): map3=197, Cerr=90, chompAndCheckIndent=62, Eerr=58,
andThen=54, map=51, apply=44, map4=43, foldl=42, pure=38.

**GATE ACCOUNTING (honest):** §4's "GO ≥ 1,500 would" was MISCALIBRATED
when written — it conflated direct candidates with chain mass, and the
offline data available at plan time already bounded direct p/g /r roots
at ≈1,328, making a 1,500 direct gate arithmetically unreachable. The
number that matters: 1,030 direct sound writes with a chain-cascade
ceiling of ≈2,100 var (75.6 % of the 2,809 p+g /r chain mass), on the
plan's cheapest and only unconditionally-sound mechanism.
RECOMMENDATION: GO for Phase 1, with the cascade ratio as the build's
measured output (AR-V8). Recorded rather than silently re-gated.

**hazard|fixBvarflip = 0.** The AR-V1 latent exposure is empirically ZERO
on today's corpus — shipped `settleCtorRows` would flip no var position.
No standalone retrofit ships; the completeness gate still goes in WITH
Phase 2 as constructive protection (zero-by-corpus-luck is not
zero-by-construction).

**Probe sanity:** LssGapCtorRebuild emits all-zero varfix counters — no
false positives at probe scale.

### §4.3 BUILD-TIME FINDINGS (2026-08-31, during Phase 1/2 implementation)

**Phase 2a design RESOLVED — the license is the EXISTING boundary
discipline, not a new deny-list.** Traced end-to-end: every route by which
a function value can enter a ctor payload is marked before it can demand a
row. Elm constructions with arrow args always take the slow path
(`lssFastOk`, AR-D2(2) verified) and leave a set or honest ⊤; kernel-borne
values are marked at the boundary by LSS_021/022 (TypeFaithful/Positional
transport correct sets) or LSS_004 (poison ⊤) — and a licensed kernel
"introduces no function-valued inhabitants of its own" is an audited
license term. The ⊤-contributor gate therefore inherits kernel
completeness from the same trust base all of LSS rests on. Defense in
depth: per-module write-attribution counters (`varctor|mod|<module>`) —
an elm/* module gaining writes is the audit flag. No yield sacrificed.

**AR-V10 (found during test design) — the zero-⊤ gate alone is UNSOUND;
var contributors are NOT always benign.** The wrap class:
`wrap f = Mk 1 f` — the construction transports the PARAM's unresolved
flex into the row (argFeedback is reverted, so the caller's lambda ℓ2
never lands anywhere). The row reads var while ℓ2 is a real inhabitant;
a zero-⊤ cell union would write a set EXCLUDING it. Fix shipped with
Phase 2b: the slow path marks ctor SPECS whose construction transported a
flex arrow (`Engine.markFlexCtorSpec`, read from `lssStats.flexCtorSpecs`);
a cell is contaminated by ⊤ anywhere OR var on a MARKED spec's row.
Destructure-only var rows stay benign (nothing could inhabit them without
marking some row — that is AR-D2's completeness argument, now with its
missing leg closed). If the flex later resolves, the row shows a set and
the mark is moot — conservative in exactly the safe direction.
Consequence for shipped `settleCtorRows`: its ⊤-heal never had this gate
either — the AR-V1 retrofit (`enrichAnnotationsTopOnly`) now prevents ALL
var flips on the heal path by construction.

**Consumer scope verified:** `AbiCloning.stampCall` (devirt incl. E9.5
devirtPost) reads EXPRESSION-level annotations (`Mono.typeOf func`), not
registry rows. Settle writes are consumed today by the census and by
whatever future exploitation reads rows (sum lowering will). The
soundness discipline above is for those future consumers — "unconsumed
today" is an accident of the pipeline, not a license (the destrAnno flip's
zero dispatch delta is the same fact from the other side).

### §4.4 PHASE 1 + 2b BATTERY (2026-08-31) — BUILT, MEASURED, ALL GATES
### GREEN (default-off, flip with user)

Same-binary env-flag A/B (`ECO_MONO_LSS_VAR_SUCC=1
ECO_MONO_LSS_VAR_CTOR_ROWS=1` vs defaults), self-compile corpus:

| | off | on | delta |
|---|---:|---:|---:|
| var | 14,144 | **11,424** | **−2,720 (−19.2 %)** |
| k1 | 95,919 | 97,693 | **+1,774** |
| kN | 31,007 | 31,953 | +946 |
| top | 1,207 | 1,207 | 0 (neutrality holds) |
| coverage | 89.21 % | **91.12 %** | **+1.91 pp** |
| wall | 7:59.5 | 8:06.2 | +1.4 % (≤ noise) |

**Accounting closes to the digit:** `varsucc|wrote1` 1,478 +
`varctor|wrote` 1,242 = 2,720 = the var delta exactly — every settle
write eliminated one var, nothing else moved. k1 took 65 % of the gain
(L1 satisfied: precision, not churn). Cascade ratio for M-A: 1,478
written / 1,030 P0 direct = **1.43×** (deeper rounds pay). `varsucc`
hit its 8-round fuel cap while still writing — small residue available
from a fuel bump (recorded, not yet taken).

**Named cells (var off→on):** map3 197→**0**, Cerr 110→20, Eerr 86→28,
chompAndCheckIndent 74→12, Decoder 1,656→**744** (kN 453→1,175 — the
cell unions land as accurate multi-member sets), Ok 1,634→1,522,
andThen 2,147→2,047, map 3,195→3,007, apply 1,631→1,520, foldl 446→404.

**The flex gate is live at scale:** `varctor|skipFlexVar` = **1,563**
protected positions (the AR-V10 wrap-class hazard is real and common);
skipTop 465, skipNoInfo 1,156. Write attribution: Compiler.Json.Decode
898 (pure Elm, kernel-free — as the 2a design predicted), Result 256 +
Maybe 1 + Bytes.Decode 10 (elm/* families riding the boundary argument —
flagged in the audit channel per §4.3), Terminal.Terminal.Chomp 33,
Compiler.Reporting.Result 23, misc 21.

**Gates:** ECO_MONO_VALIDATE clean; E2E 1,717/1,717 BOTH arms;
elm-tests 13,394 passed / 12 failed (the standing pre-existing set; +4 =
the new pins: two additive-only invariance pins + enrichTopOnly pins).

Residual var book after these two phases: 11,424 — dominated by the
Phase-3 feedstock (noInfo cells + beyond-arity results + the andThen/map
interiors whose roots are l|-class or cross-cell).

### §4.5 FLIPPED DEFAULT-ON (2026-08-31, user decision) + Phase 3 P0

Both flags default-on. Post-flip defaults: positions=142,511 k1=97,855
kN=32,019 **var=11,426** top=1,211, coverage **91.13 %**; settle counters
byte-identical to the A/B on-arm. Defaults E2E 1,717/1,717; elm-tests
back to the standing 12 after TWO overlapping-flag pin casualties were
repaired (LssInjTotalTest + LssRefPapSpineTest: their off-arms assert an
LVar at /a0/r — the exact position varSucc now writes; pinned
varSucc/varCtorRows OFF per the differential-pin rule; second arc flip
with casualties after destrAnno's zero — the rule keeps earning).

**Phase 3 P0 (varfix3 census, post-flip defaults): v1 = NO-GO, would=0.**
The classification is EXHAUSTIVE to the digit (sums to 11,426 = every
residual var):

| class | count | share | meaning / redirect |
|---|---:|---:|---|
| noHead | 3,939 | 34.5 % | no result-side head context — arg-subtree / row-root positions (M-D/Phase 5 territory) |
| otherHead | 3,339 | 29.2 % | nearest head contains l\|/k\|/a\| members — the LAMBDA class → **M-B v2 authority is now the largest addressable mass** |
| papHead | 2,926 | 25.6 % | nearest head is p\| — beyond-arity PAP results; enrichable from the global's row at OFFSET k (body-determined = result-side safe) → **Phase 3 v2, the promising piece** |
| contamVar | 987 | 8.6 % | g\|/c\| head, row-union has a var contributor — strict rule blocks; needs a pass-through/purity mark (the ctor flex-mark analog for function results) |
| contamTop | 235 | 2.1 % | ⊤-contaminated cells (the ⊤ book) |
| would / noInfo / shapeMiss / headNoRows | 0 | — | **nothing writable under v1** |

**Why would=0 is informative, not disappointing:** wherever a g\|/c\|
head's rows uniformly know a result cell, TRANSPORT ALREADY DELIVERED it
to the use positions — the store does its job; the residue sits exactly
where the rows do not uniformly know either. Cross-spec row enrichment
for g\| heads has no gap to close. The residual book's real shapes are
the p\|-offset class (v2, alignment work), the lambda-authority class
(#64), and the arg-side/no-context mass (#65's license question).
Phase 3 v1 CLOSED unbuilt; its census machinery (varfix3) stays as the
class tracker. **The two successor mechanisms are designed in §8**
(Phase 3v2 offset alignment, Phase 4v2 lambda-home authority), each
with its own P0 gate.

### §4.2 P0 phase verdicts

| phase | P0 verdict | evidence |
|---|---|---|
| 1 M-A successors | **GO (recommended)** | 1,030 direct sound writes, cascade ceiling ≈2,100; gate miscalibration recorded above |
| 2 M-C ctor rows | **GO** | setOnly 2,181 ≥ 1,000; license design required (Ok/Err kernel question); hazard=0 |
| 3 M-row enrich | gate deferred | its feedstock (mC noInfo 1,697 + beyond 333) sized; own gate after Phases 1–2 cascades measured |
| 4 M-B lambdas | **NO-GO v1** | writable=65; v2 lambda-home authority is a redesign |
| 5 M-D args | untested | license design first, class is 6.4 % |

## §5 Gates and success metrics

- Success per phase = **k1/kN landing at the named §1 root cells** and the
  **cascade ratio** (interiors resolved ÷ roots written). Bare coverage is
  quoted but never decides (L1).
- E2E 1,717 both arms; elm-tests incl. new differentials; ECO_MONO_VALIDATE;
  byte-identical workload outputs on the A/B rail.
- Dispatch A/B recorded-not-gated (three precision mechanisms in a row
  measured neutral; expectation is neutral again — the coverage goal stands
  on its own per the 2026-08-31 re-centering).
- Wall budget: ≤ +1 % per phase (settle sweep is post-drain, bounded
  rounds; argFeedback's +1.4 % was translation-time — different regime).
- Flags: one per phase (`lss.varSucc`, `lss.varCtorRows`, `lss.varRowEnrich`,
  `lss.varLambda`, `lss.varArgs`) so every A/B attributes cleanly; each
  default-off until its own battery; flip decisions with the user.

### §5.1 Differential-fixture finding (2026-08-31, Phase 1/2 build)

**A one-module pipeline fixture CANNOT manufacture this plan's target
classes.** Four fixture designs measured all-covered on the OFF arm:
mono and poly HOF consumers for the /a0/r spine class, and mono/poly +
indirection ctor shapes for the payload class. Cause: within one item
there is ONE store — unification connects arg↔param spines completely —
and the default-on producer machinery (papMembers head injection +
injTotal L2 deep-PAP completion) covers every producer spine a single
module can express; a never-constructed second instantiation is PRUNED
before the registry the tests read. The corpus var pool is a CROSS-ITEM
phenomenon (which is also the cleanest confirmation yet that the class
attribution is right: these are transport losses, not analysis blind
spots). DISCIPLINE ADJUSTMENT: the unit differentials become
additive-only invariance pins (settle must change NOTHING on covered
fixtures) + the AR-V1 helper pins; the corpus battery's settle counters
(`varsucc|wrote*`, `varctor|wrote`, `varctor|skipFlexVar` — the gate
FIRING at scale) and the named §1 cells are the real differentials. Test
1 of LssVarCtorRowsTest self-upgrades: if a future pipeline change makes
the fixture manufacture a var row, the pin FAILS with instructions to
promote it to a true differential.

---

## §6 Adversarial review — against the code

**AR-V1 (found a live latent hazard).** `enrichAnno (LVar, LSet ys) → LSet
ys` means shipped `settleCtorRows` can ALREADY write var payload slots on
⊤-gated ctor rows with no completeness check. The flip A/B happened to show
var exactly unchanged (13,389 = 13,389) — luck of the current corpus, not a
guarantee. DISPOSITION: Phase 2 retrofits the all-sets gate onto the
existing path; the P0 `fixBvarflip` counter quantifies today's exposure
first. If it is nonzero, the retrofit ships as a standalone fix ahead of
the rest.

**AR-V2 (enrichAnnotations is the wrong tool for var writes).** Its ⊤ arms
(`(LSet,LTop)→LSet`) silently drop ⊤ contributors — correct for ⊤-healing
(widening-only readback), UNSOUND as a var-write union (a dropped ⊤
contributor means unknown inhabitants the written set excludes, and
devirtPost will act on the false set). DISPOSITION: the var write path uses
a dedicated completeness-tracking fold; `enrichAnnotations` remains
readback-only. This is the plan's single most load-bearing line.

**AR-V3 (arity direction verified).** `declaredArityGo`'s `_->1` floor
UNDERSTATES arity ⇒ M-A's `k+j < arity` gate under-fires (skips writes) —
safe. The kernel-alias arm (Aug 26) covers `(::)`-class aliases. Residual
risk is an OVERSTATED arity somewhere; none known — pin with a unit test
asserting no successor is written at `k+j == declaredArity`.

**AR-V4 (lambda members have no authority).** `lambdaQualified : mid →
(raw, FIRST-minting spec)` is explicitly diagnostics-only; under LSS_024
several specs share one mid. There is NO unique settled row for `l|mid`.
DISPOSITION: M-B demoted to Phase 4 with the global-agreement gate;
"resolve via the member's home row" is recorded as the v2 shape (requires a
real lambda registry, out of scope).

**AR-V5 (kernel constructions poison M-C).** Kernels build `Ok`/`Err`
(HEAP_046) and store arbitrary payloads (`Decode.succeed f`). The
sibling-spec union sees none of it. The ⊤ book's `poison|ctor=307` is the
same channel showing up on the ⊤ side. DISPOSITION: the kernel-construction
license gate in Phase 2; the P0 `kernelCtor` counter sizes the loss.

**AR-V6 (rows under-approximate at escape points).** A member's registry
row aggregates flows the ANALYSIS saw. Values applied inside un-analyzed
appliers (kernel HOFs) contribute args the row never recorded — so
row-based /aN enrichment can under-approximate. Result-side enrichment does
not have this hazard (results are produced by the member's OWN Elm bodies).
DISPOSITION: Phase 3 is result-side only; /aN is Phase 5 behind an
LSS_022-style license.

**AR-V7 (spec keying is already committed).** Settle writes happen after
all SpecKeys exist; no new specs, no re-keying. Consumers are readback
(coverage), sigs of LATER compiles (typed-artifacts?—no: settle output is
per-compile registry, not cached back into inference), and `devirtPost`.
The destrAnno finding ("registry outcomes never depended on the early
stamps") says this late placement costs nothing we currently know how to
spend earlier. Recorded as a known ceiling: settle-derived sets cannot
influence specialization decisions.

**AR-V8 (cascade is a hypothesis, not a given).** Interiors follow roots
only where positions still SHARE live store slots at settle time. Rows
already read back into MonoTypes may hold detached copies. The cascade
ratio is therefore a per-phase MEASURED output; if it comes back ≪ 1, the
sweep needs a type-directed pass over row interiors (enrich nested
positions of the same row from the written parent — mechanical, same
soundness class) — recorded as the fallback, not built speculatively.

**AR-V9 (performance).** The sweep is O(rows × positions × rounds) over
~141 k positions, ≤ 4 rounds, allocation-light folds — the settleCtorRows
precedent measured free. Budget ≤ +1 % wall enforced per phase battery.

## §7 Adversarial review — against the paper

**Fidelity frame.** The paper has no settle phase and needs none: one
unification world (TIU, Fig. 5) reaches the least fixpoint online, and
Thm 4.1's completeness means every real flow left a constraint. Eco's
settle sweep is a RECONSTRUCTION of specific lost constraint classes at
quiescence. Verdict per mechanism:

- **M-A ≙ signature instantiation.** In L^annot, a def's full curried type
  carries sets at every arrow; instantiating `d⟨σ̄⟩` stamps the whole
  spine. `p|g|d` successors are established as "the paper's 𝒬 applied to
  the nested λs of the conceptually-curried global" (refPapSpine's
  reviewed mapping). M-A extends WHERE the stamp lands, not WHAT it
  claims — same ids, same semantics. **FAITHFUL.**
- **M-C ≙ product/sum component annotation.** Paper ctor payloads carry
  annotated types; construction unifies the payload's σ in, projection
  reads the same variable. Eco lost the linkage across items/specs; the
  post-drain complete union over all constructions is the unsplit-store
  value of that variable. The all-sets gate exists because Eco ALSO has ⊤
  (the paper does not) — where the paper would have a constraint, we may
  have ⊤, and the union must not pretend otherwise. **FAITHFUL, with the
  gate as the ⊤-world adaptation.**
- **M-B ≙ the λ's annotated type flowing with the value.** In the paper a
  lambda's type (with its result sets) travels by unification wherever the
  value goes. Eco's agreement-gated union is a conservative reconstruction;
  the per-instantiation qualification question (AR-V4) has no paper
  counterpart because the paper never splits. **PARTIAL — sound but
  deliberately incomplete; the v2 lambda-home authority would close it.**
- **M-D ≙ TIU at application** (arg type unifies into param type). The
  paper never loses these; Eco loses them at LSS_006 fresh loads and the
  kernel boundary. Row-union reconstruction is complete ONLY over analyzed
  applications — hence the license. **PARTIAL by necessity; the license is
  the soundness boundary the paper's closed world never needed.**
- **Internalize-to-∅ REJECTED** (§0): the paper's Fig. 7 rule is sound
  under Thm 4.1 completeness only. Eco measured 42.7 % of var arrows
  applied. Writing ∅ (or any under-set) where value flows exist is the
  false-singleton miscompile class. The plan's completeness gates are
  precisely the discipline that separates us from that rule's
  preconditions.
- **No-⊤ discipline respected:** no mechanism consults ⊤ kinds
  semantically (the §4.9 neutrality contract holds); ⊤ only ever BLOCKS
  var writes (completeness gates), never licenses them.

**Net AR verdict:** plan APPROVED for P0 with two mandatory amendments,
both already folded in above: (1) the var-write fold must be a new
completeness-tracking helper, never `enrichAnnotations` (AR-V2); (2) the
AR-V1 retrofit is quantified by P0 and, if exposed, ships first. The
mechanism most likely to disappoint is the cascade assumption (AR-V8) —
it is measured in Phase 1 before anything else is built on it.

---

## §8 THE POST-FLIP QUEUE — v2 designs for the two largest residual
## classes (2026-08-31, from the §4.5 exhaustive classification)

The §4.5 varfix3 classification reordered the queue on measured mass.
Neither item below existed as a designed mechanism before this section:
old Phase 3 (strict g|/c| row enrichment) is CLOSED with `would=0`, and
old Phase 4 (position-agreement lambda union) is CLOSED with
`writable=65`. These are their successors, each with its own P0 gate.

### §4.6 ORDER 3 — the "fuel cap" was a TRAVERSAL DEFECT (2026-08-31)

The §4.4 loose end ("8 rounds hit the cap while still writing") was not a
tuning knob. Bumping fuel to 16 wrote +374 more and **still reported
`rounds=16`** — the fixpoint was not converging, it was crawling. Two
defects in the Phase-1 walk each limited a chain to ONE depth per round:

1. **Bottom-up traversal.** `succType` descended into `result` BEFORE
   deciding the parent arrow's write, so a depth-d chain needed d rounds.
2. **Round-start key snapshot.** `midKeys` (mid → member key) was built
   once per round, so a successor member minted during the pass could not
   be resolved in that same pass — the next link had no key to read.

Fixed together: decide the write, then walk the REWRITTEN result
(top-down), and thread `( S, midKeys )` so a freshly minted successor is
immediately resolvable. Same write rule, same soundness — order only.

| | shipped (8, bottom-up) | fuel 16 only | **top-down + threaded keys** |
|---|---:|---:|---:|
| `varsucc\|rounds` | 8 (capped) | 16 (capped) | **2 (converged)** |
| `varsucc\|wrote1` | 1,478 | 1,852 | **2,090** |
| var | 11,424 | 11,050 | **10,812** |
| k1 | 97,975 | 98,349 | **98,587** |
| coverage | 91.14 % | — | **91.56 %** |
| wall | 12:59 | 12:59 | 12:50 (marginally faster — fewer rounds) |

**+612 writes over the shipped default, every one landing in k1, and the
accounting is again exact (2,090 − 1,478 = 612 = the var delta).** The
shipped Phase 1 was under-delivering by 29 % on a traversal-order bug
that the round counter had been reporting all along — the loose end was
worth chasing rather than closing with a constant. Fuel stays at 16 as a
runaway backstop only; convergence is now by exhaustion (monotone: each
round either writes, strictly shrinking a finite population, or stops).

### §5.2 GATE POLICY REVISED (user directive, 2026-08-31)

**GO gates drop to 50 (§8.1) and 80 (§8.2), and future P0 gates should be
sized the same way: "any small improvement", not a fixed large floor.**
Rationale, in the user's framing: there may only be small improvements
left to make. The plan's early gates (1,500 / 1,000 / 800 / 500) were
calibrated against the ORIGINAL 13,389-position pool, where a mechanism
worth building had to move thousands. After four mechanisms have landed
(successors, ctor rows, the traversal fix, and the ⊤-heal retrofit), the
residue is by construction made of smaller classes — so a gate sized for
the old pool now rejects everything that remains, which is the wrong
answer when the writes are sound and the marginal build cost is an extra
arm on an existing pass. Both outstanding mechanisms clear the revised
bar (`pwould` 617 ≥ 50, `lwould` 568 ≥ 80); §8.2 is a GO on its own gate,
not a concession. The gate that still binds is SOUNDNESS, not size: no
mechanism ships without its completeness rule, its guards, and the
accounting identity (writes == var delta).

### §8.4 SETTLE ORDER IS A PRECISION DECISION (measured, 2026-08-31)

The per-flag battery arms caught a regression that a combined arm would
have hidden. With `varRowEnrich` running BEFORE `varSucc` (the order in
which it was first wired):

| arm | var | k1 | kN | writes |
|---|---:|---:|---:|---:|
| base | 11,543 | 99,022 | 32,194 | — |
| `varLambda` | 10,946 (−597) | +587 | +10 | 597 |
| `varRowEnrich` | 11,538 (**−5**) | **−1,269** | **+1,274** | 2,129 |

2,129 writes for a net var movement of 5, and ~1,270 positions converted
k1 → kN: the argFeedback churn signature exactly (L1). Cause: the two
passes target the SAME parent class (pap-able heads), and the coarse
row-union claimed positions the exact successor write would otherwise
have filled with a singleton `p|X|k+j`. Both writes are sound; one is
precise and the other widened, and whichever runs first wins the slot.

**Rule adopted: the settle chain is ordered by PRECISION, not by
dependency.** `varSucc` (exact type-level identity) → `varLambda`
(single-body authority) → `varRowEnrich` (cross-spec union, coarsest) →
`varSucc` again, so spines extend from heads the coarse passes just
created. `varLambda` never collided: its `l|`-headed parents are not
pap-able, so the successor sweep skips them — which is why its arm shows
597 writes with 587 landing in k1.

**Methodology note:** this is the third time this arc that per-mechanism
attribution changed a verdict a combined measurement would have passed.
Always give each mechanism its own arm.

### §8.5 RESULTS AT THE CORRECTED ORDER — and Phase 3v2's real verdict

Four arms, one binary, same source (base var = 11,543 / k1 = 99,022):

| arm | writes | var | k1 | kN |
|---|---:|---:|---:|---:|
| base | — | 11,543 | 99,022 | 32,194 |
| `varLambda` | 597 | 10,946 (−597) | +587 | +10 |
| `varRowEnrich` | **5** | 11,538 (−5) | **unchanged** | +5 |
| both | 602 | 10,941 (−602) | +587 | +15 |

Perfectly additive (597 + 5 = 602 = the var delta, exact), no interaction,
and the base arm is identical to the pre-reorder base — so running
`varSucc` twice is idempotent on the default path, as its own convergence
implies.

**§8.2 / ORDER 5 — SHIPPABLE. 597 writes, 587 of them k1.** Landing
squarely on the monadic-continuation family: `andThen` var 2,093 → 1,765
(−328, k1 +320), `foldr` −43, `map` −38, `foldl` −27, `pure` −22 — the
same `System.TypeCheck.IO` chain §11 identified as ≈44–50 % of generic
dispatch (coverage there has never converted to a dispatch win while
GAP-6 binds, so this is a completeness gain, not a perf claim).

**§8.1 / ORDER 4 — NO-GO. Built, measured, 5 writes.** The census's
`pwould = 617` was an OVERCOUNT: it verified that an aligned cell existed
and was clean, but never that the use site and the rows structurally
AGREE. The pass adds that check — every row of the member global must
expose the same argument count at the aligned offset, and the use site's
arrow must match it — and ~99 % of the class fails it. The guard cannot
be relaxed: dropping disagreeing rows from the union would drop their
inhabitants too, which is an under-approximation and the false-singleton
miscompile class. So the 617 positions are real var that row unions
CANNOT soundly reach, because X's own specs do not structurally agree at
the aligned offset. Cost side: `varRowEnrich` also measured ≈ +36 s wall
(+4.6 %) for those 5 writes.

**Disposition (revised 2026-09-01, user directive):** `lss.varRowEnrich`
is REMOVED from the tree entirely — flag, env override, hash token,
`settleVarRowEnrich`, and `rowAlignPrefix` (~380 lines). The refutation
lives HERE, not in dead code; the successor direction (§8.6/§9) does not
reuse the alignment primitive, so keeping it would be inventory, not
insurance. The settle chain is now varSucc → varLambda → varSucc.
OPEN QUESTION for anyone revisiting: the pass does not yet distinguish
"rows disagree with each other" from "use site disagrees with the rows" —
one counter would say which, and only the second kind could conceivably
be repaired by aligning against the use site's own spine.

### §8.6 IF NOT ROW UNIONS, THEN WHAT? — techniques that could reach the
### 617 (design note, 2026-09-01)

**The lesson the two mechanisms taught together: AUTHORITY BEATS
AGGREGATION.** `varLambda` wrote 597 because it read ONE authoritative
source — the lambda's own body, the single place its result is decided.
`varRowEnrich` wrote 5 because it aggregated over every spec of a global
and then needed them to agree. Mono has already SPLIT each global into
specs whose flattened arities differ by demand (staged vs flat — the H6
arc), so "X's rows" is not one authority, it is many disagreeing ones.
Every candidate below is a way of recovering a single authority.

**1. Spec-resolved reading (removes the union entirely — strongest).**
If the use site can name WHICH spec of X its value came from, there is
nothing to union: read that spec's row. Today `p|X|k` names the global
and the supplied count, not the spec; LSS_024 already layout-qualifies
member ids, and `AbiCloning`'s devirt already picks a spec at a site by
`eqLayout` matching. Reusing that resolution here (or qualifying `p|`
members per instantiation) is the exact analog of what made `varLambda`
work, and it is the same refinement `lshapeMiss = 1,101` points at on the
lambda side. Cost: member-identity changes are invasive but precedented.

**2. Use-site-compatible filtering (cheap; ONE measurement decides).**
Keep only the rows structurally compatible with the use site instead of
demanding global agreement. This is NOT the unsound relaxation refuted
above: dropping rows arbitrarily drops inhabitants, but mono is
type-correct, so a row whose shape differs from the use site's describes
values that cannot sit at that position at all — non-inhabitants, not
lost ones. THE RISK, which must be measured before building: staged/flat
re-arity means one logical value can appear at two arities, and then a
genuine inhabitant looks incompatible. The counter named in the OPEN
QUESTION above (rows-vs-rows versus rows-vs-use-site) is exactly what
separates the safe case from the unsafe one.

**3. Restore the flow edge — PROBED, and the finding reframes the whole
question.** A scratch fixture (`compose2 g f = \x -> g (f x)`, i.e. two
params with a body-returned lambda, consumed by `List.map`) run through
the unit pipeline at shipped defaults gives:

    compose2 :: ((.)-{4}->.)-{5}->((.)-{4}->.)-{5+6}->(.)-{1}->.
    map      :: ((.)-{1}->.)-VAR1->([.])-VAR0->[.]

The body-returned lambda is member `{1}` in `compose2`'s own row — and it
ARRIVES at `List.map`'s `/a0` as `{1}`. **The flow mechanism is not
missing; it already works, and it is doing the heavy lifting.** The
beyond-arity result that the union could not reconstruct is delivered by
unification directly, with no alignment and no aggregation.

That reframes the residual: these positions are not "a class flow cannot
reach", they are "a class where the flow that normally reaches them was
LOST". Where does it get lost? Inside one item there is ONE store and
unification connects everything — which is exactly why §5.1 found that
one-module fixtures cannot manufacture the var classes at all (the same
fact from the other side). Across items the connection must be
re-established through SIGNATURES (`ArrowFact` / sigFlow), and the
provenance work measured signatures as **84 % trivial** — carrying no
facts. So the corpus's var residue is, on this reading, mostly the
signature channel failing to carry what the paper's `d⟨ᾱ⟩ : (Q ⇒ τ)`
carries by construction.

**Why staged currying stops mattering under flow.** The union had to
align paths across differently-shaped rows, which is where the shapes
collided. Flow never matches shapes: it connects one slot to another at
the moment both are known to be the same value. `add3 1` in a
flat-consuming caller and `add3 1` in a staged-consuming caller are
simply two positions, each unified with its own instantiation; they never
have to agree with each other, so the disagreement that killed §8.1
cannot arise. The shape problem was manufactured BY the reconstruction,
not by the program.

**The honest limit:** flow yields the CORRECT set, not necessarily a
singleton. Where two instantiations merge into one shared spec (the §11
`andThen` aggregation), the honest answer is multi-member — which is
precisely GAP-6 again, and another reason sum lowering is the standing
next lever rather than more precision work.

**Next step if this is picked up:** measure what signature facts carry at
the residual positions (are they trivial because the callee's own row is
var, or because the fact never installs?). That is a census question, not
a mechanism question, and it is the cheapest way to size the real lever.

**What will NOT help:** relaxing the agreement guard (unsound — the
refutation stands), and further census refinement (the class is already
exhaustively classified; more counters would only re-describe it).

**The honest possibility to hold open:** part of the 617 may be
unreachable by ANY technique because the disagreement is real — different
inhabitants at one member — in which case the sound answer is a
multi-member set, not a singleton. That is a coverage gain with no
dispatch value while GAP-6 binds, which is a reason to spend the effort
on sum lowering before spending it here.

### §8.0 P0 RESULTS FOR §8.1/§8.2 + THE ORDER-6 SPLIT (2026-08-31)

One census run (shipped defaults + the extended `varfix3`) settled all
three questions. **The classification remains exhaustive: the classes sum
to 11,424 = the var total to the digit**, and each predecessor bucket
splits exactly (old `papHead` 2,926 = pure-pap 701 + mixed 2,225; old
`otherHead` 3,339 = lambda 3,307 + kernel/accessor 32; old `contamVar`
987 = shared 643 + isolated 344).

*Baseline note:* var 11,426 → 11,424 and positions +144 vs the previous
run — the compiler compiles ITSELF, so adding census code grew the
corpus. The census is report-gated and cannot affect analysis; this is
the documented same-day source-drift trap, not a perturbation.

| class | count | reading |
|---|---:|---|
| `pwould` | **617** | §8.1 GO (gate ≥ 500) |
| `lwould` | **568** | §8.2 below its ≥ 800 gate — see verdict |
| `mixwould` | 2 | mixed-kind heads, negligible |
| `noHead` | 3,937 | unchanged; Phase-5 territory |
| `lshapeMiss` | 1,101 | lambda cellmap has no cell at the path — the v2 refinement (per-instantiation keying instead of merge-by-mid) |
| `contamVarShared` (all tags) | 3,515 | DEFINITE pass-through |
| `contamVarIso` (all tags) | 1,120 | no recorded route — a bound, not a license (§8.3) |
| `contamTop` (all tags) | 532 | the ⊤ book |
| `otherHead` | 32 | kernel/accessor heads only |

**§8.1 VERDICT: GO — `pwould = 617`.** Top globals: `p|map` 216,
`p|Ok` 144, `p|apply` 108, `p|andThen` 72, `p|pure` 72. Two structural
findings from the alignment itself: **no `alignFail` and no `pp` (partial
stage) classes appeared at all** — every `p|X|k` aligned, and k never
split a stage in the whole corpus. Partial-stage re-indexing is therefore
UNNECESSARY (measured 0), which removes the fiddliest piece of §8.1's
design; the alignment walk still gets its unit pins, but the
partial-stage case is dead code to be omitted, not built.

**§8.2 VERDICT (as revised by §5.2's gate policy): GO — `lwould = 568`
against the revised ≥ 80 bar.** The paragraph below records the original
≥ 800 reasoning as it stood when measured.

**§8.2 as first measured: the mechanism VALIDATED, the yield BELOW its
then-gate.**
`lNoRecord` never fired — **every `l|` head in the corpus found a table
entry** (30,544 mids recorded), which confirms the closure-node source is
the right authority and answers lowering question (1) empirically: the
store is not needed, the nodes persist. Table quality: 1,768 mids have an
arrow result, 1,267 clean / 501 contaminated. But `lwould = 568 < 800`.
Recorded as a NO-GO **on the pre-registered gate**, with the honest
qualifier that the gate assumed a STANDALONE build: §8.2's write pass is
the same settle machinery §8.1 now requires, so its marginal cost is an
extra arm in a pass being built anyway. Recommendation is to build both
together (1,185 direct writes plus cascade) — but that is a re-gate, so
it is the user's call, not a silent pass.

**ORDER 6 (§8.3 below): pass-through DOMINATES.** Of the 987 g|/c| var
contaminations, **643 (65 %) are definite pass-through** and 344 (35 %)
isolated; corpus-wide 3,515 vs 1,120. The mark costs NO new state.

### §8.3 ORDER 6 — the contamVar pass-through mark (DESIGNED + MEASURED)

**The test, and why it needs nothing new.** `LVar` ids are canonical per
slot within ONE entry's zonk (AR-v2-7). So within a single row, an id
appearing at BOTH a result-side position and an ARGUMENT position means
the body threads that parameter through to the result — a caller's lambda
is a real inhabitant, and the cell must stay blocked. No `ArrowFact.rep`
consultation, no new marks, no threading: a row-local walk over data the
census already holds. (Ids are NOT comparable across rows; the test is
strictly intra-row, which is exactly the scope it needs.)

**The honest limit — the isolated share is a BOUND, not a license.**
"No recorded inhabitant route" is not "no route": transport failure is
the very phenomenon this plan studies, so an isolated var may still hide
a real inhabitant whose set never arrived (a callee result that failed to
transport into the slot). Writing the sibling union there would exclude
it — the false-singleton class. Therefore:
- **shared (3,515) ⇒ block. Sound, cheap, and it is the majority.**
- **isolated (1,120) ⇒ still block**, but now with a measured ceiling on
  what a stronger argument could unlock.
- Unlocking requires a body-completeness mark — the function-result
  analog of `flexCtorSpecs`: a spec is result-complete when nothing
  var/⊤-annotated flowed into its result during translation. That is new
  translation-side state and is NOT justified by 1,120 positions today.

**Disposition:** the sharing test is adopted as the strict rule's
EXPLANATION (it says which blocks are principled) and as a census
classifier. No mechanism is built for the isolated share; the class is
parked with its number. ORDER 6 closes.

### §8.1 Phase 3v2 — papHead OFFSET ALIGNMENT (class mass 2,926, 25.6 %)

**The class.** Var positions whose nearest set-headed context is
`{p|X|k}`. `varSucc` already writes their within-arity `/r` HEADS; the
residue is everything the head identity alone cannot determine: the
beyond-arity result region (X's body result — `varsucc|skipBeyond`
events), data payloads inside results, and deeper spine content. All of
that IS determined by X's bodies, and X's registry rows carry it — the
v1 census just refused every `p|` head because alignment was unbuilt.

**The mechanism.** A `{p|X|k}` value's type is X's type after consuming
k arg slots. Align the use position against the row union by walking the
row's curried spine consuming k args (a stage of j args consumes
min(j, remaining); a stage split mid-way re-indexes the remaining args),
then parallel-walk under the SAME rules as v1: result-side descent only
— the value's own remaining `/aN` are X's params k+1.. = consumer-fed
(AR-V6), and args of arrows inside the body result are fed by whoever
applies those returned closures, so only `/r` and data hops descend —
and the STRICT all-sets cell rule (any ⊤ or var contributor blocks; no
pass-through mark exists for function results).

**Soundness.** Identical to v1 M-row: the aligned region is
body-determined; union-over-specs is the unsplit-store value; writes are
supersets. The only new surface is the alignment itself — a mis-aligned
path would enrich from the WRONG cell, so the alignment walk must be
pinned by unit tests on staged shapes (1-arg stages, n-ary stages, and
the partial-stage re-index case) before any corpus write.

**Honest prior.** v1's `would=0` for `g|` heads showed transport already
delivers whatever rows uniformly know — the same may hold here, since a
`g|X` head's cellmap ALREADY covered X's beyond-arity region and yielded
nothing. The difference: `p|`-headed USE positions were never measured
at all (v1 classed them unexamined), and their heads arrived via
channels (producer PAP injection, settle successors) that carry NO deep
content. Whether the deep content is also already-delivered is exactly
what the P0 answers. Expectation is NOT would≈2,926; it is "finally a
number".

**P0 (census-only, extends varfix3):** teach `vf3HeadCtx`'s `"p"` arm to
build the offset cellmap instead of `Err "papHead"`. Report:
`would / contamVar / contamTop / noInfo / alignPartial` (k splits a
stage — measure how often before deciding whether partial-stage
re-indexing is worth building) `/ alignFail`. GO gate: `would ≥ 500`
after the alignPartial split is known. NO-GO closes the class into the
contam/noInfo books like v1 did.

### §8.2 Phase 4v2 — the LAMBDA-HOME AUTHORITY (class mass 3,339,
### 29.2 % — the largest addressable class, twice-confirmed bottleneck)

**Why v1 died and what that means.** The mB P0 measured near-universal
agreement but `writable=65`: for 683 mids NO readback position anywhere
knows the result. §4.5 re-confirmed independently (`otherHead=3,339`).
The knowledge is not mis-transported — it never survives the item. A
lambda minted and consumed interiorly (let-bound, passed inline) appears
in NO registry row type: rows record spec params/results, not interior
values. The lambda's full inferred type exists exactly once — in the
host item's store at translation — and is discarded at `resetItem`.

**The mechanism: record the lambda's settled type at item completion.**
A side table `lambdaHomes : Dict mid MonoType-cellmap` in Engine state:
at each item's completion join (the one order-free window — the same
argument that placed Fix B and the settle passes post-drain), zonk the
type of every qualified lambda mid minted in that item and union-merge
it into the table with the completeness-tracking fold (⊤/var
contributors mark the cell, sets union). Under LSS_024 several specs
share one mid; the merge across instantiations is the unsplit-store
union — sound as a superset because every result closure of ANY
instantiation is minted in the lambda's one body and lands in some
instantiation's recorded type (a var/⊤ result at ANY instantiation
contaminates the cell, so incomplete instantiations block rather than
lie). Then a settle pass (`lss.varLambda`) enriches `l|`-headed var
positions from the table — result-side descent only, strict cells, kN
heads all-or-nothing across members (mixing with `g|/c|` members unions
their row cellmaps; any `k|/a|` member blocks).

**Lowering questions to answer BEFORE building (the P0's second half):**
(1) WHERE at item completion is `mid → IO.Variable` still available —
`specializeLambda`'s registration? the completion-join walk? — the
record hook must not retain store Points past the item (record the
ZONKED MonoType, never the variable). (2) Memory: one MonoType per mid
(≈35k mids corpus-wide from `internedCount`) — acceptable, but measure
RSS. (3) The table is compile-local Engine state — nothing rides the
typed-artifacts codec (the AR-1 precedent).

**P0 (two steps, recording is behavior-neutral):**
- Step A: build the RECORDING half only + a census line —
  `varlam|midsRecorded / cleanResult / contamResult / noRecord` — plus
  the would-count: `l|`-headed var positions whose table cell is clean.
  Recording is bookkeeping (no graph writes), so step A can ship
  ungated. **GO gate for step B: would ≥ 800** (a quarter of the class).
- Step B: the settle write pass, default-off, its own battery, flip with
  the user.

**Order:** §8.1's P0 first (census-only, one run, zero new state), then
§8.2 step A — both P0s can share one census run once §8.1's arm is
extended. The remaining §4.5 classes stay parked: `noHead` 3,939 behind
the Phase-5 license question, `contamVar` 987 behind a pass-through
mark, `contamTop` 235 behind the ⊤ book.

---

## §9 THE FLOW-REPAIR ARC (user directive, 2026-09-01) — recover lost
## edges instead of reconstructing at settle

**Standing directive:** tackle the residue (the 617 papHead class and
more) by REPAIRING FLOW — the paper's mechanism, where a use site's set
arrives by unification along the real producer→use edge — rather than by
further settle-time reconstruction. The §8.6 probe proved the mechanism
already works where the edge survives (`compose2`'s body-lambda `{1}`
arrives at `List.map`'s param with no union and no alignment); the
residue is where the edge is LOST. Three deliverables: (a) measure what
the signature channel actually carries at the residual positions, (b)
pin the edge-losing code shapes as fixtures, (c) design the repair from
the paper's signature discipline.

### §9.1 The pinned examples (LssFlowEdgeLossTest.elm) — and what the
### probes FALSIFIED on the way to them

The first fixture design assumed the loss was mono-vs-poly (an
α-instantiation story). Three scratch probes falsified that for this
shape and replaced it with something sharper. ONE consumer, two
producers, settle repairs OFF:

    useStep f seed = (f seed) 2            -- consumes a 2-stage function

    mkAdderC u = \a -> \b -> a + b + u     -- producer C: 1 declared param
    useStep (mkAdderC 1) 5                 --   CALL-RESULT argument

    mkAdder = \a -> \b -> a + b            -- producer V: 0 params (a VALUE)
    useStep mkAdder 5                      --   BARE-REFERENCE argument

Measured rows (settle off):

    mkAdderC :: (.)-{5}->(.)-{1}->(.)-{2}->.       full member spine
    useStep  :: ((.)-{1}->(.)-{2}->.)-...           arrives INTACT   (test 1)

    mkAdder  :: (.)-{4}->(.)-VAR->.                 the PRODUCER'S OWN row
    useStep  :: ((.)-{4}->(.)-VAR->.)-...           shares that var  (test 2)

**Finding 1 — flow is not the failure here.** In the failing case the
producer's own row lacks the inner member, and the consumer faithfully
shares the same variable. Flow delivered; there was NOTHING TO DELIVER.

**Finding 2 — the missing thing is a producer-side IDENTITY.** Producer
V's nested lambdas are collapsed by mono-uncurry into ONE two-arg
closure. The intermediate stage value — that closure with one argument
supplied, a LAMBDA-PAP — has no name in the member algebra: it is not an
`l|` member (not a whole lambda) and not a `p|g|k` member (its base is
not a global). The paper never meets this case because it never
uncurries — every λ keeps its own label and every stage is a λ. This is
also exactly what `varsucc|skipNoSucc` counts at corpus scale (1,900
events per round), and why the `l|`-parent chain class exists.

**Finding 3 — settle already covers the fixture at defaults** (test 3):
the folded root head is pap-able, so `varSucc` mints `p|mkAdder|1` and
writes it consistently in BOTH rows. The arc's success metric is test 2
flipping to sets WITH settle off — inference itself minting/delivering
the stage identity — at which point the pins expire loudly by design.

**Where the α/Q reading still stands:** this fixture no longer evidences
it, but the corpus-level `facts|extra` cell of the §9.2 census still
measures the α-born class directly; the hypothesis is unproven either
way until those numbers land. The candidate repairs now include a third:
**mint lambda-PAP stage identities at inference time** (`p|l:<mid>|k`
members — the uncurry-aware completion of the paper's per-λ labels),
which would make producer V's row carry its stages the way producer C's
already does.

### §9.2 P0 — the sigfact census (built, arrowCensus-gated)

For every residual var position, correlate with the row global's
signature. Cells (`sigfact:` line):

- `noSig` — the row's global was never inferred (no signature at all).
- `trivial|eq` / `trivial|extra` — signature exists but carries nothing
  (`trivial`), with the row having equal / MORE arrows than the scheme.
  Dominance here = hypothesis **H-R1**: the recording side loses facts.
- `facts|eq` — non-trivial signature, same arrow population: the channel
  carries facts yet the position stayed var — transport/apply defect.
- `facts|extra` — non-trivial signature, row has arrows the scheme never
  had: the **α-born class** (H-R2) — per-arrow facts can never cover
  these; only the Q route can.
- `factsNoQ` — non-trivial but `residual` empty: the Q half is unbuilt
  for this global's quantified variables.
- `factsRepOnly` — non-trivial purely by rep-linkage (no member/⊤ facts).

Plus `sigfactg:` — the top var-hosting globals with their signature shape
(`facts:12a/3q` = 12 scheme arrows, 3 Q constraints).

**The decision rule:** H-R1 dominant → fix signature RECORDING (facts
recorded before the def's knowledge settles; re-derive at completion).
H-R2 dominant → build the instantiation edge: when a type variable is
instantiated with an arrow-bearing type at a call, the fresh arrows must
unify with the CALLER's arrows for that value (the paper's Q-instantiation;
Eco's `residual` field is the prepared seam — §5.2/§5.3 of
plans/lss-paper-inclusion-constraints.md were built for exactly this).
Mixed → both, ordered by mass.

### §9.3 What repair must preserve

- **No settle reconstruction as the fix.** varLambda/varSucc/varCtorRows
  stay (they are sound and shipped), but the arc's goal is that inference
  delivers and the settle passes decay into no-ops — measurable as their
  `wrote` counters FALLING while var falls too.
- **The paper's discipline:** sets travel by unification at the moment
  the connection is real; nothing is matched by shape after the fact
  (§8.6's lesson — the shape problem was manufactured BY reconstruction).
- **Keying stability:** signature/instantiation changes move demand
  types, which move SpecKeys — expect cache-disjoint A/B legs and re-run
  the MuTie/overlap pins (the §4.5 pin-casualty lesson).
- **Honest ceiling:** flow yields the CORRECT set, not always a
  singleton; shared specs still aggregate (GAP-6). Success metric stays
  k1/kN at named cells + settle-counter decay, never bare coverage.

### §9.4 P0 RESULTS (2026-09-01) — the sigfact census decides the arc

Post-removal, post-flip defaults (varLambda now ON): positions=143,576,
k1=99,593, **var=10,574**, top=1,225 — coverage **92.02 %**. Settle
counters: varsucc 2,107 (3 rounds), varctor 1,263, varlam 597. Gates:
E2E 1,717/1,717; elm-tests 13,400 / the standing 12, zero new (the
corrected §9.1 pins pass). The sigfact classification is EXHAUSTIVE:
294 + 95 + 1,330 + 8,855 = 10,574 exactly.

| cell | var | share | reading |
|---|---:|---:|---|
| `trivial\|extra` | **8,855** | **83.7 %** | trivial sig AND instantiation-born arrows present |
| `trivial\|eq` | 1,330 | 12.6 % | trivial sig, same arrow population |
| `facts\|eq` | 294 | 2.8 % | channel carries facts, position still var |
| `facts\|extra` | 95 | 0.9 % | non-trivial sig + α-born arrows |
| `factsNoQ` | 7 | — | negligible |

Per-global: map=2,867, andThen=1,705, apply=1,470, Ok=1,436,
Decoder=790, Err=517, foldl=377 — ALL `triv:<n>a/0q` (trivial signature,
zero Q constraints).

**Interpretation — H-R1 (recording loss) is REFUTED as the main story,
with a twist.** A trivial signature at `map : (a -> b) -> List a ->
List b` is not a recording defect: it is the CORRECT signature for a
polymorphic HOF — its sets are CALLER-SUPPLIED per use, exactly the
paper's `α` with `Q` empty at the definition. The channel is not broken;
it is correctly empty, and the loss is on the APPLICATION side: the
caller's concrete knowledge never reaches the arrows born when its
instantiation meets the scheme (heads arrive — `argUnifyVar` — depth
does not). 96.3 % of residual var sits at trivially-signed globals; the
dominant 8,855 have instantiation-born arrows to boot.

**The repair, named (next design):**
1. **Deep instantiation connection** (the 8,855): when demand
   instantiation binds a type variable to an arrow-bearing type, unify
   the instantiation's fresh arrows with the arrows the CALLER holds for
   that value — deep, in the STORE (the paper's α-instantiation done
   fully; not annotation enrichment, which was argFeedback's churn).
   Shared specs then aggregate callers into honest kN by store union —
   correct by construction. The §8.6 probe and §9.1 test 1 show exactly
   this working where the connection exists.
2. **Lambda-PAP stage identities** (§9.1's finding; lives in
   `trivial|eq`): mint `p|l:<mid>|k` members so uncurried stage values
   have names, as every λ does in the paper.
3. `facts|*` (389): transport/apply defects, small — after 1 and 2.

### §9.5 DESIGN — the three repairs, grounded in the delivery matrix

The §9.4 numbers plus a code walk of the argument edge give a precise
picture of what each argument FORM delivers into a callee's param slot
today. `unifyParamsCollect` (Translate.elm) already unifies
`pParam ↔ argVar` DEEP — the store connection exists; the question is
what `argVar` carries, and it carries only what `argUnifyVar` puts there:
a FRESH `Store.loadType` of the arg's Can type (LSS_006 — structure with
unconstrained slots) plus per-form injections:

| arg form | delivered today | hole |
|---|---|---|
| local (`VarLocal`) | DEEP — `enrichFromEnv` unifies `monoTypeToVar boundType` into the load | only as good as the bound annotation (`enrich\|bare`); local-multi skipped by design |
| call result | DEEP — the inner call's own instantiation carries its sig facts into the value (§9.1 test 1: `{1},{2}` arrive) | — |
| reference (`VarGlobal`) | head member (`g\|/k\|`) + `p\|g\|d` successors WITHIN `declaredArityOf` | 0-param values (arity walk sees 0 → no successors); body-owned content beyond arity |
| **lambda literal** | **HEAD member only** (`injectArgLambdaMemberQualified`) | **the entire interior** — the lambda's result arrows stay fresh flex; the body's solved knowledge never reaches `canVar` |

The 8,855 `trivial|extra` positions live at `map`/`andThen`/`apply`/
`Ok`/`Decoder` — HOF and ctor rows whose arguments are overwhelmingly
lambda literals and references. The dominant hole is the lambda-literal
interior; the reference hole is §9.1's producer-identity case.

**Mechanism 1 — deep argument write-back (`lss.flowConnect`).** After a
lambda-literal argument is TRANSLATED (its MonoType then carries the
body's solved sets — heads, interiors, payload annotations), unify
`monoTypeToVar (Mono.typeOf monoArg)` into the param's store variable.
This is `enrichFromEnv`'s exact pattern (store-level, deep) applied at
the position where argFeedback tried annotation enrichment and churned.
Why the store version cannot reproduce the churn: argFeedback created
ANNOTATION copies (`enrichAnnotations`) on one side only, so later joins
met `LSet × LVar` at `unionAnno` — which is ⊤conflict (the +45, L7). A
store unify makes the two sides SHARE the slot: the flex adopts the set,
later readers see one variable, and `unionAnno` never meets the split
pair. Cross-caller aggregation at shared specs happens by store-join
union — honest kN, correct by construction. ⊤ in the lambda's interior
is NOT sanitized (argFeedback's `deTopAnnos` was an annotation-layer
necessity): the store join is the lattice's honest join, ⊤ provenance
rides `LsTop` kinds, and the var→⊤ conversions it may cause are measured
(`flow|topCarried`), not hidden.

Plumbing: `unifyParamsCollect` runs BEFORE args are translated, so the
param variable must be carried across — re-land the reverted
argFeedback's stash shape as a third `ArgStash` variant
(`StashParam IO.Variable`), stashed for lambda-literal args only in v1,
consumed in `translateArgsWith` after the arg's translation.

**Mechanism 2 — stage identities for uncurried lambdas
(`lss.lamStages`).** §9.1's producer hole: a multi-param lambda with a
STAGED type has interior stage values (the lambda applied to k < nparams
args — lambda-PAPs) that no member names; `varsucc|skipNoSucc` counts
the consequence. Mint `p|l:<qualifiedMid>|k` members for k in
1..nparams−1, written down the lambda's own type spine at
classification time — the uncurry-aware completion of the paper's
per-λ labels (`injectPapSuccessors`' exact shape, lambda-based key).
Where mono KEEPS lambdas nested, the inner λ's own `l|` mid is the
identity and mechanism 1 delivers it — no new name; the new kind exists
ONLY where collapse erased the inner λ.

**Mechanism 3 — `facts|*` (389).** Untouched until 1+2 land; re-census.

### §9.6 ADVERSARIAL REVIEW — against the code and the paper

**AR-F1 (paper, mechanism 1: FAITHFUL — this is the application rule).**
In L^annot the argument's type CARRIES its σ into TIU at the
application; Eco's Can.Type has no set slots, so Translate re-derives
connections, and the lambda-literal edge is simply one it never rebuilt.
The write-back restores exactly the σ-transport the paper's `App` rule
performs. It is NOT an approximation being added; it is a lost edge
being re-tied. The one adaptation is ⊤ (the paper has none): letting it
flow through the join is the §4.9-consistent choice (⊤ only ever widens,
never licenses).

**AR-F2 (code, mechanism 1): the anti-churn claim is structural, and
verifiable.** The L7 conflict manufacturer is `unionAnno (LSet, LVar) →
topConflict` at ANNOTATION joins of diverged copies. Store-level
`unifyStepBestEffort` resolves flex×set by adoption (the transport
everything else relies on — enrichFromEnv precedent) — no conflict path
exists. VERIFY IN BATTERY: `conflict` ⊤-kind count must not grow.

**AR-F3 (code, mechanism 1): ORDER. The write-back races nothing.** It
runs inside the same item's translation, before the call's
`funcMonoType` zonk (`Store.zonkToMono funcVar` happens after
`translateArgsWith` — verified order in `translateGlobalCallSlow`), so
the demand type the spec is keyed on already includes the written sets.
CONSEQUENCE, load-bearing: SpecKeys move ⇒ artifact-affecting flag, hash
token, cache-disjoint A/B arms, and the overlapping-flag pin sweep
(LssInjTotal/LssRefPapSpine class — expect casualties, budget for them).

**AR-F4 (code, mechanism 1): translation-time reads vs AR-D2.** The
destrAnno lesson said translation-time reads of AGGREGATES see partial
state. This mechanism reads NO aggregate: it reads the just-translated
argument's own MonoType — complete by construction the moment the
translation returns (the lambda's body was fully translated to produce
it). AR-D2 does not apply. What DOES apply is idempotence under
retranslation (LSS_010 flush rounds re-run items): the write-back must
be idempotent — set∪set = set, same slot — it is, by store-join
semantics.

**AR-F5 (code, mechanism 1): scope honesty.** v1 connects LAMBDA
LITERALS only. Local-multi args stay skipped (469 events, recorded);
`enrich|bare` locals stay (the leak|letAnno class); references beyond
arity stay (mechanism 2 / §9.1). The battery must therefore be judged on
the named HOF cells (`map`/`andThen`/`apply` var), NOT on total var.

**AR-F6 (paper, mechanism 2: FAITHFUL-adapted, with a completeness
obligation).** The paper labels every λ and never uncurries; stage
values do not exist there. `p|l:<mid>|k` extends the label algebra to a
value class the paper cannot express but Eco's runtime genuinely has
(the PAP of a collapsed lambda). The class is well-defined (all k-arg
PAPs of that λ). BUT the papMembers invariant binds: **injection
completeness**. A set containing `p|l:m|1` claims to cover ALL
inhabitants of its position; any route that constructs the stage value
WITHOUT minting the id makes downstream sets false — and settle's
strict-cell mechanisms (varLambda/varCtorRows) TRUST sets as complete,
so this is a real miscompile-adjacent hazard even while devirt ignores
originless members. Construction routes: (i) flowing the staged lambda
itself (covered by minting on the lambda's own spine), (ii) PARTIAL
APPLICATION of a lambda-valued expression at a call site (the
`injectPapMember` producer path covers GLOBAL partials only today).
v1 MUST cover both or not ship. The P0 sizes route (ii).

**AR-F7 (code, mechanism 2): the split-identity hazard is live TODAY and
the design must not widen it.** At shipped defaults, `varLambda` names
§9.1's stage value by the INNER lambda's mid ({7}), while a
p|-successor would name it `p|·|1` — two names for one value class
split sets and kill singletons at joins (the reason "spineArity" was
rejected in the refPapSpine arc, and the rootFold precedent: fold
identities at the root). RULE: nested-visible inner λ ⇒ the `l|` mid IS
the name (mechanism 1 delivers it); `p|l:` mints ONLY when no inner λ
exists (collapsed). The two cases are disjoint by construction —
verified per-lambda by whether the TOpt body is itself a Function
literal. A probe must confirm TOpt's actual shape for `\a -> \b -> e`
(collapsed vs nested) before the mint site is coded.

**AR-F8 (code, mechanism 2): devirt on stage members.**
`buildMemberOrigins` dispatches on `g|/c|/k|/a|` prefixes; `p|` and
`p|l:` fall through → no origin → `stampCall`/devirtPost cannot act —
safe-by-absence, same as `p|g|k` today. No AbiCloning change needed in
v1. Recorded ceiling: stage singletons are coverage without dispatch
value until a consumer exists (GAP-6 again).

**AR-F9 (both, the success metric).** The §9.3 charter: settle counters
must DECAY (varLambda's 597 and varSucc's writes should shrink as
inference delivers the same knowledge earlier) while var falls and ⊤
holds. A mechanism that only re-labels who writes (settle → inference)
with no var/k1 movement is a wash UNLESS the settle passes can then be
simplified — state that explicitly as an acceptable second-order win,
but the gate is var/k1 at the named cells.

**Net verdict: APPROVED to build in this order — mechanism 1 alone
first (it needs no new member kind and its battery is decisive), then
mechanism 2 behind its own flag once its P0 (route-(ii) sizing + TOpt
shape probe) answers AR-F6/F7.**

### §9.7 LOWERING — implementation-ready

**Mechanism 1 (`lss.flowConnect`, env `ECO_MONO_LSS_FLOW_CONNECT`,
token `lssFC=`, default OFF):**

1. `Compiler/Eco/Config.elm` + `Builder/Eco/Config.elm`: flag, default
   False, decoder field, hash token, env override (the varLambda
   boilerplate exactly).
2. `Translate.elm` `ArgStash`: add `StashParam IO.Variable`. In
   `unifyParamsCollect`'s `Nothing`-localMulti arm, when the flag is on
   AND the arg is a `Function`/`TrackedFunction` literal, return
   `StashParam pParam` instead of `StashNone` (everything else
   unchanged).
3. `translateArgsWith`: on `StashParam pParam`, translate the arg as
   today, then `Store.monoTypeToVar (Mono.typeOf monoArg)` and
   `unifyStepBestEffort pParam thatVar`. Census (report-gated):
   `flow|connLam` per write, `flow|topCarried` when the arg MonoType
   `hasTopAnno`, `flow|connNoop` when the arg MonoType has no arrows.
4. Battery (the standing template): same-binary env A/B; judge on
   `map`/`andThen`/`apply`/`pure`/`foldr` named-cell var/k1, `conflict`
   ⊤-kind non-growth (AR-F2), settle-counter DECAY (AR-F9), VALIDATE,
   E2E both arms, elm-tests with the overlapping-flag sweep (AR-F3:
   expect pin casualties; fix by pinning `flowConnect = False` in
   differentials that assert LVars at connected positions —
   LssFlowEdgeLossTest test 2 is the FIRST candidate: its pin must add
   the flag-off pin or flip its expectation, per its own design).
5. Flip decision with the user on the battery numbers.

**Mechanism 2 (`lss.lamStages`, token `lssLS=`, default OFF) — gated on
its own P0, built only after mechanism 1's battery:**

P0 (census-only, one run): (a) TOpt shape probe — count multi-param
`Function` literals whose Can type is staged deeper than their param
count vs nested `Function`-in-`Function` bodies (`flow|stagedLam` /
`flow|nestedLam`); (b) route-(ii) sizing — partial applications whose
callee expression is lambda-valued (`flow|lamPartialApp`). GO requires
(a) collapsed-form count material (≥ 200) AND (b) small enough to cover
completely, else the mechanism is incomplete-by-construction (AR-F6)
and stays unbuilt.

Build (on GO): mint in `classifyLambdaHead`'s site down the lambda's own
spine (`papSuccGoC` pattern, key `"p|l:" ++ qualifiedMid ++ "|" ++ k`),
PLUS the route-(ii) producer mint at `injectPapMember`'s lambda-valued
analog. `memberTarget`/`varfixPapable` parsers in Monomorphize gain the
`p|l:` arm (successor semantics: within the LAMBDA's nparams). AR-F7
guard: mint only when the TOpt body is NOT itself a Function literal.

**Sequencing:** M1 P0-battery → M1 flip decision → M2 P0 → M2 build →
re-census → mechanism 3 triage on the new residue.

### §9.8 M1 v1 MEASURED NULL — the broken link was one hop further in
### (2026-09-01)

The first build of M1 (param write-back only) measured EXACTLY NULL:
`flow|connLam = 8,555` write-backs fired and the on-arm was
BYTE-IDENTICAL to the off-arm (var 10,946 = 10,946, every named cell
flat, settle counters identical, conflict identical). The mechanism
transported faithfully — but the lambda's own MonoType carries only its
HEAD: `specializeLambda` zonks `monoType0` via `classifyLambdaHead`
BEFORE `translate body` runs, so the body's solved result sets never
reach the closure's type, and the write-back shipped 8,555 head-only
types the head injection had already delivered. The §9.5 delivery
matrix named the right hole (lambda interiors) but the wrong edge: the
break is INSIDE the producer, not at the argument edge — the same
producer-side lesson §9.1 taught for `mkAdder`, one level up. (The
argFeedback root-cause note said exactly this — "specializeLambda has
the same gap" — and the reverted `enrichLambdaResult` was its fix; the
review missed that the store write-back DEPENDS on it.)

**v1.1 = both halves under one flag** (the destrAnno Fix A+B precedent):
the PRODUCER half enriches the closure's own result region from its
just-translated body (`enrichClosureResult` — descend exactly `nparams`
stages, then `enrichAnnotations`; producer truth, no aggregate, AR-D2
clean, idempotent), and the existing param write-back transports it.
Nested lambdas cascade naturally: an inner closure's enriched type is
part of the outer body's type, which enriches the outer closure in turn.
EXPECTED if right: `varlam|wrote` 597 DECAYS (AR-F9's signal — the
settle pass reconstructs exactly this knowledge today) and the andThen/
map cells move at inference. The annotation-vs-store churn question
(this half IS annotation-level, like the reverted enrichLambdaResult)
is answered by the battery's AR-F2 conflict gate: if `conflict|elm`
grows, the half must move to store level (keep the loaded var in
classifyLambdaHead, unify post-body, re-zonk).

### §9.9 M1 v1.1 BATTERY (2026-09-01) — thesis PROVEN, join discipline
### WRONG; the pre-registered AR-F2 gate fired

Same-binary env A/B, both halves on (`flow|connLam` 8,555 transports,
`flow|lamResEnrich` 1,301 producer enrichments of 37,233 closures):

| | off | on | delta |
|---|---:|---:|---:|
| var | 10,946 | 10,870 | −76 |
| k1 | 99,640 | 99,036 | **−604** |
| kN | 32,212 | 32,881 | +669 |
| top | 1,227 | 1,272 | **+45** |
| `conflict` ⊤-kind | 112 | **158** | **+46 — AR-F2 FIRED** |
| `varlam\|wrote` | 597 | **61** | **−90 % — AR-F9 signal, the thesis** |
| wall | 13:08 | 13:26 | +2.3 % |

Soundness gates ALL green: VALIDATE ok, E2E 1,717/1,717 both arms,
elm-tests 13,400/standing 12, zero new failures, 20/20 unit pins.

**Reading.** The flow-repair thesis is PROVEN: inference now delivers
90 % of what the `varLambda` settle pass was reconstructing — the
knowledge reaches the right slots by real flow. But the producer half is
ANNOTATION-level (`enrichAnnotations` on the closure's type), and it
reproduced argFeedback's exact churn signature at the exact place §9.8
pre-registered: +46 conflict-⊤ (historic argFeedback: +45), k1 −604
with kN +669 (`andThen` k1 −481/kN +487), ⊤ +45. Diverged annotation
copies meet `unionAnno (LSet, LVar)` at later joins — L7, third
confirmation. The +2.3 % wall is also over the §5 budget.

**DECISION (presented 2026-09-01): NO FLIP for v1.1.** The
pre-registered remedy stands: move the producer half to STORE level —
`classifyLambdaHead` keeps the loaded variable instead of zonking it
away, the body's type is unified into its result slot POST-body
(`monoTypeToVar` + unify, the same discipline as the transport half),
and the closure type is zonked once at the end. Both sides then share
slots; no diverged copies exist for `unionAnno` to meet. v1.1 stays in
tree flag-off as the measured stepping stone.

### §9.10 v2 STATUS + PAPER JUSTIFICATION (user Q&A, 2026-09-01)

**Flag status: the store-level producer half COMPLETES `lss.flowConnect`
— same mechanism, same flag, no fork.** The mechanism has two halves.
The transport half (`StashParam` write-back into the callee's param
slot) is already store-level, measured conflict-clean alone (v1's null
arm: zero conflict growth), and stays as built. The producer half is
what v2 REPLACES: v1.1's annotation-level `enrichClosureResult` is
superseded by the store version — the RECORD of v1.1 stays (§9.8/§9.9,
the stepping stone that proved the thesis and located the fault), the
code does not. Flag stays default-off until v2's battery passes AR-F2;
then the flip decision returns to the user. flowConnect is therefore
BUILT-BUT-INCOMPLETE, not parked and not forked.

**Paper justification: v2 REMOVES a deviation rather than adding one.**
In L^annot the gap cannot exist, by the shape of the abstraction rule:

    Γ, a:Int ⊢ body : τ_body
    ─────────────────────────────  (T-Abs)
    Γ ⊢ λa.body : Int --{ℓ}--> τ_body

The body's type — with all its sets — is a literal SUB-TERM of the
closure's type. There is no transport step to get wrong. Worked example
(`mkAdder = \a -> (\b -> a + b)`):

- PAPER: inner λ gets ℓ₂ ⇒ `Int --{ℓ₂}--> Int`; T-Abs makes the outer
  `Int --{ℓ₁}--> (Int --{ℓ₂}--> Int)` — the inner set is in the outer
  type by rule shape.
- ECO TODAY: `classifyLambdaHead` loads the Can type fresh (slots
  s1, s2), injects the head into s1, ZONKS immediately — s2 still flex
  at snapshot ⇒ `Int -{ℓ₁}-> (Int -VAR-> Int)`. The inner member mints
  into a DIFFERENT load's slot during body translation, after the
  freeze. This is the broken T-Abs identity — what §9.1's probe and
  v1's null both measured.
- ECO v2: keep (s1, s2) alive; translate the body; unify the body's
  solved type into s2; zonk ONCE ⇒ the paper's T-Abs type,
  reconstructed by late unification instead of by rule shape — the
  standing "faithful to the analysis even if the method differs" clause
  applied literally.

v1.1 deviated MORE than today's code in one respect: it created a
SECOND COPY of the truth (annotation enrichment), where the paper has
one world — one σ-variable per position. Two copies meeting later is
what manufactured the +46 conflict-⊤; v2 is the return to the one-world
discipline, which is the structural reason the conflicts cannot recur.

**Residual deviations that remain even after v2 (pre-existing,
recorded):** (a) the ZONK CUTOFF — Eco snapshots the closure type at
construction; knowledge arriving later does not retroactively update
the snapshot (the paper's σ stay live to the end of inference); Eco
compensates at demand joins, where positions re-join. (b) ⊤ — the paper
has none; the store join may honestly widen to ⊤ where the body carries
it (measured by `flow|topCarried`).

### §9.11 M1 v2 (STORE-LEVEL) MEASURED — the structural claim REFUTED;
### flow repair is BLOCKED BEHIND THE JOIN LATTICE (2026-09-01)

v2 battery (same-binary A/B; store-level producer half via
`connectLambdaResult`/`peelParamsVar`, `classifyLambdaHead` keeping its
variable):

| | off | v1.1 on | v2 on |
|---|---:|---:|---:|
| var | 10,947 | −76 | −692 |
| k1 | 99,644 | −604 | **−672** |
| kN | 32,214 | +669 | +660 |
| top | 1,227 | +45 | **+703** (`topCarried` 280) |
| `conflict` | 112 | +46 | **+46 — IDENTICAL** |
| `varlam\|wrote` | 597→ | 61 | **45** |
| coverage (bp) | 9,154 | +3 | **±0 — EXACTLY FLAT** |
| wall | — | +2.3 % | +4.4 % |

Soundness gates all green (VALIDATE, E2E 1,717 both arms, elm-tests
13,400/standing 12, 20/20 pins). `lamResEnrich` 1,752, `peelMiss` 8.

**Finding 1 — the §9.10 structural claim is REFUTED.** The store version
manufactures the IDENTICAL +46 conflict-⊤. The conflicts never came from
diverged annotation copies within an item; they arise at CROSS-SITE
DEMAND JOINS — two call sites sharing a SpecKey, one arriving with a set
and the other still var, `unionAnno (LSet, LVar) = ⊤conflict`. That is
L7 in its ORIGINAL form ("precision added asymmetrically manufactures
⊤"), and no within-item discipline — annotation or store — can touch it.

**Finding 2 — honest ⊤ transport is expensive.** 280 lambda types carry
⊤ (their bodies touch ⊤-classed values); raw unification spreads it:
⊤ +703, var −692, coverage EXACTLY flat. Flow relabels var→kN/⊤ and
dilutes k1. Under L1 this is not a win at any threshold.

**Finding 3 — the settle passes were never a workaround.** Their strict
completeness gates (skip any ⊤/var-contaminated cell) are precisely what
raw TIU flow LACKS in a lattice with ⊤ and spec sharing. The paper can
afford raw flow because it has neither. `varLambda`'s 597 writes were
the GATED subset of exactly the knowledge flowConnect transports
ungated — same source, filtered at the read. Settle-time reconstruction
IS the ⊤-adapted form of the paper's transport.

**DECISION (2026-09-01): NO FLIP for v2 either; M1 closes REFUTED-AS-NET
-WIN.** Both flags' code stays (default-off) with this section as the
record. The arc's blocking dependency is now NAMED: the join lattice —
`unionAnno`'s LSet×LVar→⊤ and ⊤-absorption at asymmetric joins. That is
**LPartial, the provenance plan's Part C**, deferred since 2026-08-29
and now twice implicated (argFeedback's +45, flowConnect's +46 twice).
Any future flow-repair or M2 stage-identity work feeds the same joins
and pays the same tax until LPartial (or an equivalent
asymmetry-tolerant join) exists.

### §9.12 M2 P0 RESULTS (2026-09-01, on the repaired lattice) — GO

`m2|` census, post-LPartial post-flowConnect defaults:

| counter | count | meaning |
|---|---:|---|
| `stagedLam` | **24,046** | collapsed multi-param lambda translations (≥2 params, body NOT a lambda) — each has nparams−1 stage values with NO member identity |
| `stagedNested` | 586 | multi-param AND lambda body — mint param stages only (AR-F7) |
| `nestedLam` | 110 | 1-param nested — inner λ keeps its own mid, NO mint |
| `plainLam` | 12,512 | 1-param plain — out of scope |
| `lamPartialApp` | **491** | route-(ii): indirect partial applications constructing lambda-PAPs |
| `indirectSat` | 44,964 | saturated indirect calls (denominator) |

**Gate (a): GO by two orders of magnitude** (24,046 vs the ≥200 bar).
The collapsed shape is the overwhelmingly dominant multi-param form —
the AR-F7 split-identity hazard is confined to the 696 nested-body
translations, where the guard simply skips.

**Gate (b): 491 route-(ii) sites — bounded and coverable.** Two
lattice-era refinements to AR-F6's original "both routes or unbuilt":
(1) at sites where the callee head IS a known `l|` singleton, mint —
matching the existing `p|g|k` discipline exactly (which also only mints
at head-known sites); (2) at unknown-head sites the constructed value
flows as var, and under LPartial an annotation join with a stage-set
degrades to an HONEST partial instead of a false set — the lattice
absorbs route incompleteness at the annotation layer. The store-level
adoption background remains what it has always been for every member
class (p|g|k included); M2 inherits, not worsens, it.

**Yield expectation, honestly:** 24k is TRANSLATION events (per-spec,
duplicated), not positions. The var-book classes M2 writes into are the
lambda-headed residue (§9.4 otherHead ≈ 3,339 mass; the old `k1:l → /r`
chain class 1,412) — expect hundreds-to-low-thousands of var
eliminations, measured not assumed. The writes land at INFERENCE (the
lambda's own spine), so they flow everywhere the lambda flows and are
LPartial-safe at asymmetric joins.

### §9.13 M2 MID-BUILD CORRECTION (2026-09-01) — LSS_013 already names
### collapsed stages; the design pivots from minting to HOLE-FILLING

Partway into the M2 build, `papSuccWrite`'s LSS_013 docstring stopped
it: **the shipped convention is that a lambda's within-arity stage
arrows carry the lambda's OWN mid** — "a partial application of member
m is still m"; `classifyLambdaHead`/`injectLambdaMemberQualified`
spine-inject across the first `arity` arrows already. Consequences:

1. The P0's 24,046 `stagedLam` events are NOT 24,046 nameless-stage
   sites — most of those stages are already named by LSS_013 injection.
   The gate-(a) GO was a misread of the count's meaning.
2. Distinct `p|l:<mid>|k` members would UNION with the existing own-mid
   spine writes wherever both land — {l|m, p|l:m|1} two-sets on
   currently-COVERED arrows: an identity split against the lambda's own
   mid (AR-F7's hazard, one level up), k1 damage with no gain.
3. M2's real residue is the HOLES — l|-singleton heads whose `/r` is
   still var, i.e. positions where the LSS_013 injection or its
   transport did not land — and the paper/-convention-faithful fill is
   the lambda's OWN mid (write-if-flex, never union), not a new kind.

The `m2stage:` refinement census (report+arrowCensus-gated, like all M2
census work) splits exactly this: `stageVar` = l|-head, var `/r`, home
arity ≥ 2 (a genuine stage hole; the revised mechanism's target);
`bodyVar` = arity 1 (the `/r` is the BODY's result — varLambda/
flowConnect territory, NOT a stage); `arityMix`/`noHome` = unusable.
DECISION RULE: material `stageVar` ⇒ build the hole-fill (own-mid,
write-if-flex) + battery; `stageVar` ≈ 0 ⇒ M2 closes NO-GO with this
section as the finding (the class it targeted is already covered by
LSS_013 + varLambda + flowConnect).

**BUILD TRAP RECORDED (2026-09-01): `Config.LssConfig` is AT the 32-slot
record cap.** Adding `lamStages` as field 33 broke Stage 6 with
`'eco.construct.record' op field_count (33) exceeds Record's 32-slot GC
scan limit` (flowConnect had landed on exactly 32). The flag was removed
— it gated nothing yet — and the AbiCloning stats record was
preventively re-bundled (`devirtPost` sub-record, 33→30 there). THE NEXT
LSS FLAG MUST bundle: either a `varWrites` sub-record collecting the
var-arc flags (succ/ctorRows/lambda/flowConnect + future) or an
equivalent — one slot for the family, headroom restored. Same lesson as
Engine.S (lss-root-member-fold): flat records at the GC-scan cap fail at
BOOTSTRAP time, in the native lowering, not at typecheck.

### §9.14 M2 CLOSES NO-GO (2026-09-01) — the class is 142, and no sound
### mechanism exists for it under the shipped naming convention

The `m2stage:` refinement census (post-LPartial, post-flowConnect
defaults): **stageVar = 142, bodyVar = 274**, arityMix/noHome = 0.

- The genuine stage-hole class — l|-singleton heads of arity ≥ 2 whose
  `/r` is still var despite LSS_013's spine injection — is **142
  positions**, not the P0's misread 24,046. The 24k were translation
  EVENTS of already-named stages.
- bodyVar 274 = arity-1 heads with var results — `varLambda`'s own
  blocked-cell residue, not stages.

**And the 142 cannot be filled soundly at settle.** The own-mid fill
(LSS_013-consistent) is AMBIGUOUS on row fragments: a `{m}`-headed arrow
in a consumer row could be stage 0 of the whole lambda or a stage-k PAP,
and the two demand different fill depths. The killer case is the LSS_013
docstring's own example one level up: an arity-2 lambda whose body
RETURNS a closure — at a stage-1 fragment, "fill one arrow deep" writes
`m` onto the returned closure's arrow (`q`'s, not `m`'s): a false
member, the exact trap LSS_013's arity bound exists to prevent. The
shipped injection avoids this only because it writes at the lambda's OWN
load, anchored at stage 0 by construction, and lets unification
transport. Distinct per-stage ids (the original M2) would anchor
correctly but SPLIT identity against LSS_013's shipped own-mid writes
(§9.13). Both designs are dead; the census cannot even guarantee all
142 are stages (the same fragment ambiguity applies to the counter).

**DISPOSITION: M2 closed unbuilt.** The `lamStages` flag is already
removed (the 32-slot cap forced it out before the verdict — fitting).
The 142 stay in the var book, reachable in principle only by
construction-anchored inference repairs (the flowConnect family, which
anchors at the lambda's own translation). The census machinery
(`m2|`/`m2stage:` counters, report-gated) stays as the class tracker.
The instructive arc: P0 gate GO on a big number → mid-build invariant
check shrank it 170× → soundness analysis closed it. The gates worked,
in the right order, before any unsound write shipped.

### §9.15 THE SHAPES, PINNED AS E2E CODE (2026-09-02) —
### test/elm/src/LssGapLambdaStages.elm

The three §9.13/§9.14 shapes now exist as a small E2E probe with CHECKs,
compiled and measured: (1) `mkAdd3v` — the arity-2-lambda-returning-a-
closure anchoring killer; (2) `useStage` — the stage fragment crossing a
definition boundary; (3) `pickyWrap`/`pick` — the two-branch result that
generates the varLambda blocked-cell shape. MEASURED at probe scale:
100 % covered, var = 0, ⊤ = 0, and every position SOUNDLY named — the
stage fragment arrives as `k1:p|mkAdd3v|1` (the p|g|k successor anchors
it, because the lambda is globally rooted), q's arrow carries the INNER
lambda's own mid (flowConnect's producer half delivered it), and the
two-branch result reads an honest 2-member kN, not a false singleton.
Emitted MLIR: direct calls + papCreates throughout, no generic apply.

CONSEQUENCE FOR THE BOOK: the corpus 142/274 are these exact row shapes
with their transport broken across item/spec boundaries — the probe rows
are the reference picture of what construction-anchored repairs should
restore. The probe doubles as a REGRESSION pin: if these rows ever go
var/⊤ at probe scale, an in-item mechanism broke.

### §9.16 SUCCESSOR PLAN COMMISSIONED (2026-09-02) —
### plans/lss-stage-anchor-writers.md

The construction-anchored route §9.14 named is now written up as its own
plan: ONE new birth-time fact (mid → {arity, qSpine}, recorded at
injectLambdaMemberQualified where both are exact) makes stage/fragment
alignment decidable ANYWHERE via r = T − s — defusing the §9.14
alignment killer — and feeds TWO writers: rowFill (the m2stage census
promoted to a settle writer) and papSite (the l|-head counterpart of the
shipped p|g|d papSucc machinery at the m2|lamPartialApp site). Own-mid
per LSS_013 throughout; no new member ids. P0 gate: rowWould + siteL1
≥ 50 (small-gates policy). Config restructure comes FIRST (LssConfig at
the 32-slot cap — settle flags fold into a sub-record). ORDER 6's
re-census follows that plan's outcome either way.
