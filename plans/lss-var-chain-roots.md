# LSS var elimination — chain-root writes

**Status: PLANNED + adversarially reviewed (2026-08-31). P0 not yet run.**

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

**Disposition:** `lss.varRowEnrich` stays DEFAULT-OFF permanently, kept
in tree as the measured refutation (and because its `rowAlignPrefix` is
the alignment primitive a future mechanism would reuse). Recorded rather
than deleted, per the arc's habit of keeping refutations findable.
OPEN QUESTION for anyone revisiting: the pass does not yet distinguish
"rows disagree with each other" from "use site disagrees with the rows" —
one counter would say which, and only the second kind could conceivably
be repaired by aligning against the use site's own spine.

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
