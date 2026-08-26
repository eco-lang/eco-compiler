# LSS `promote`: quantified set variables that survive instantiation

**Status: PHASE 0 RUN 2026-08-26 — NO-GO (verdict restated same day after an
adversarial pass). Do not build §1–§4.** Q1 passed (42.32 % of the `var` pool
is cross-item-recoverable, reproducing Run AK at HEAD). The NO-GO rests on
three legs (§0.2, "verdict RESTATED"): a cheaper mechanism (solver-root
identity) recovers a large share first; GAP-B's own defining probes are closed
by use-site mechanisms without `ᾱ`; and the design has NO paper counterpart —
L^src is simply typed, so 146:11's promote covers lambda-set variables on
existing arrows only. The original Q2 argument ("all new facts at
declared-arrow ordinals ⇒ underTypeVar does not dominate") was TAUTOLOGICAL and
is withdrawn; the corpus-level type-variable share of the residue remains
unmeasured. **The design sections below are retained as the record of what was
ruled out and why — start at §0.2, not at §1.**

This plan proposed the half of the paper's discharge machinery Eco has never
had: at the def boundary, *promote* the set variables that reach the signature
into `ᾱ` and export their constraints, so a caller can supply the answer the
definition does not have.

Sibling of `plans/lss-paper-inclusion-constraints.md`, which built `Q` (§5.1),
the scheme representation (§5.2) and the inference-boundary census (§5.6). This
plan is that register's §3.3 promote half, extracted because it is the only
piece of `d⟨ᾱ⟩ : (Q ⇒ τ)` that is neither built nor refuted.

Paper: Brandon et al., *Better Defunctionalization through Lambda Set
Specialization*, PLDI 2023 (146:10–11, §4.2.2, Fig. 6/7).

---

## §0 FOUR PRIOR REFUTATIONS — read before writing any code

This arc has repeatedly built the thing that looked necessary and measured it
neutral. Promote must justify itself against evidence none of these cover, or it
is the fifth.

| what was tried | result | where |
|---|---|---|
| `ᾱ` + `Q` in the signature (`quantified`/`residual`/`instantiateScheme`) | **BUILT, LANDED, byte-identical flag-on vs flag-off across 8 probes** | inclusion-constraints §5.2 |
| `S(Q,α)` internalization, retire the eager union | **MEASURED NEUTRAL, NOT BUILT** — `divergeSuper=0` over 110k classes: the minimal solution can never exceed the eager answer | §5.3 / §5.6.3 |
| "make signatures non-trivial" (78.8 % `allflex`) | **REFUTED** — a non-loss. Six probes transport anyway, because the two `a`s in `a -> b -> a` are ONE type variable and unification already ties their slots | §5.7.1 |
| ranks/pools for the generalization scope | **TRIED, REVERTED** — scope was the wrong question; the paper's criterion is occurrence-reachability | §5.0b |

Two of these bear directly on promote and must be stated in its own terms:

- **§5.7.1 refutes the intra-item motivation.** Within one work item, a set at a
  type-variable position transports without any signature help: `loadVarC`
  memoizes `TVar` by MVarId, so both occurrences of `a` load to the same Point
  and unification does what the signature would have said. That is the paper's
  own rule 3 (*"unification only ever equates set variables"*) and it is why
  `allflex` is not a defect.
- **§0.3 refutes the probe-level motivation.** `arrowIdentity` alone moved the
  §0 probes from `kN=0` to `kN≥1`; the mechanism was LSS_006 slot disjointness,
  not a missing set variable. It shipped 2026-08-25.

**So promote has exactly one unrefuted target: CROSS-ITEM.** `Engine.resetItem`
installs a fresh store per work item, so every within-item mechanism —
`arrowMemo`, the `TVar` memo, `Unify.merge` — dies at the item boundary. Across
items there are only two carriers: the registry demand type (caller → callee,
and it works — 64 % of fast dispatch by Run AK's `keyed=False` arm) and the
memoized `LssSignature`. The signature is the only carrier for anything the
caller does not already know, and it cannot state a relation at a position that
is not an arrow in the declared type.

### §0.1 The residual population — PHASE 0, and it gates everything

Run AK measured **43.6 % of the attributed `var` population sits at arrows that
resolve elsewhere in the run** — information that exists and is lost. That is
promote's prize, and the figure is **not usable as it stands**: it was measured
2026-08-24 under `ECO_MONO_LSS_ARROW_ROOTS=1`, before the `arrowIdentity` flip
(§5.A3) and before `classifyRef` (§5.4.5), both of which move this population
substantially. At shipping defaults the same counter reads 90.1 % *unknown
everywhere*, which the same memory records as a FALSE reading — occurrence ids
cannot tie a def's annotation to its body node's type, so the defaults arm
cannot see the sharing it is being asked to count.

Baseline at HEAD, 2026-08-26 (lss-opt Run AM, `ECO_MONO_LSS_REPORT=1`, both
arms of `lss.refIdentity`):

| counter | defaults | `+refIdentity` |
|---|---:|---:|
| `sets zonked` | 440,717 | 492,632 |
| `k1` | 159,735 | 195,033 |
| `kN` | 2,047 | 3,386 |
| `top` | 28,304 | 20,816 |
| `var` | 250,624 | 273,390 |
| multi-set ARROWS | 100 | 728 |
| `varArrows` / `setArrows` | 9,269 / 6,513 | 18,841 / 9,341 |
| `knownElsewhere` | 20,477 / 665 arr | 27,102 / 850 arr |
| `unknownEverywhere` | 186,438 / 8,604 arr | 202,566 / 17,991 arr |
| `Q-infer` partition `reaching` / `internal` | 13,411 / 92,935 | **identical** |

Two readings that are already load-bearing:

- **`Q-infer` is IDENTICAL across the `refIdentity` arms**, to the constraint.
  `refIdentity` is a translate-side change, so the inference census does not
  move — which is the cleanest available confirmation that the two censuses
  really are scoped to different phases (§5.6).
- **`reaching = 13,411 of 106,346 classes (12.6 %)** is the population promote
  would quantify. It is not small, and it is measured at the right boundary.

**PHASE 0 must answer three questions before any code is written:**

1. **How much of `var` is cross-item-recoverable at HEAD defaults + `refIdentity`?**
   Re-run the Run-AK arrow-keyed attribution (`settled-var-arrows`) under
   `ECO_MONO_LSS_ARROW_ROOTS=1` on the current tree, so the number is comparable
   to the 43.6 % and reflects both flips. **GO requires ≥ 20 % recoverable.**
2. **Of the recoverable population, how much sits at a TYPE-VARIABLE position?**
   That is the part only promote can carry; a set at a real declared arrow is
   already `rep`/`sources` territory and would be a cheaper fix. **GO requires
   `underTypeVar` to dominate;** if it does not, the correct plan is to
   strengthen `sources`, not to build ᾱ.

   **The instrument is NOT a classifier over `slots`** — an earlier draft said
   "at `zonkSigGo`, classify each unresolved position as `declaredArrow` vs
   `underTypeVar`", and that cannot work: a position under a type variable mints
   no slot, so it produces no row to classify. It has to be the §3.3 co-walk run
   in census mode at the call site — declared annotation against use-site type,
   counting positions where the instantiation has an arrow and the declaration
   has a `TVar`. That is new code, which is why this question is sequenced
   AFTER question 1 rather than beside it.
3. **What would the consumer do with it?** Report the projected `k1` / `kN`
   split of the recovered population. **If it is `kN`-dominated, promote is
   dispatch-NEGATIVE until sum lowering** (§5 gate 3) and must be sequenced
   after it, not before.

Record the answers in this file's §0.2 before opening §1. A NO-GO here is a
successful outcome for this plan.

### §0.2 PHASE 0 RESULTS — Q1 MEASURED 2026-08-26; **CONDITIONAL GO, and Q2 is now the deciding question**

One new leg, HEAD binary (`eco-lss-post`, the Run-AN/AO build), cold
`eco-stuff`, `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_REF_IDENTITY=1
ECO_MONO_LSS_ARROW_ROOTS=1`. Wall 6:48.64, RSS 11,065,928 kB, `Exit status: 0`.
Against the two Run-AM arms on the same tree:

| counter | defaults | `+refId` | `+refId +ARROW_ROOTS` |
|---|---:|---:|---:|
| sets zonked | 440,717 | 492,632 | 503,655 |
| `k1` | 159,735 | 195,033 | 202,244 |
| `kN` | 2,047 | 3,386 | **6,136** |
| `top` | 28,304 | 20,816 | 18,912 |
| `var` | 250,624 | 273,390 | 276,356 |
| multi-set ARROWS | 100 | 728 | **1,590** |
| `varArrows` | 9,269 | 18,841 | 18,638 |
| `setArrows` | 6,513 | 9,341 | 10,465 |
| attributed | 206,915 | 229,668 | 231,815 |
| **`knownElsewhere`** | 20,477 / 665 arr | 27,102 / 850 arr | **98,099 / 5,430 arr** |
| `unknownEverywhere` | 186,438 / 8,604 arr | 202,566 / 17,991 arr | 133,716 / 13,208 arr |
| **recoverable share** | **9.9 %** | **11.8 %** | **42.32 %** |
| signatures trivial | 9,523 | 9,523 | **8,554** |
| `slotsMinted` | 836,761 | 854,948 | **732,344** |
| `sigflow edges` | 177 | 177 | 64 |
| `union` | 24 | 1,342 | 3,567 |
| `topJoin` | 1 | 1 | 74 |

**CAVEAT ADDED LATER THE SAME DAY — the `ARROW_ROOTS` arm's ARTIFACT
MISCOMPILES.** The compiler self-compiled under `+refIdentity +ARROW_ROOTS`
lowers cleanly and then crashes 0.92 s into any `make` (3/3 reproductions;
controls in `plans/lss-solver-root-signature-identity.md` §0.5). The counters
below were computed by a GOOD binary running `ARROW_ROOTS` as a workload flag,
so they report what that analysis computed — but **that analysis is producing
something broken, so the 42.32 % and the 1,078 extra facts must not be treated
as sound information until the crash is diagnosed.** Q2's conclusion is
UNAFFECTED: it is a statement about WHERE facts appear in the enumeration
(declared-arrow ordinals), which is structural and independent of whether the
facts are correct. The NO-GO below stands on its own.

**Q1 — ANSWERED: 42.32 % (98,099 of 231,815 attributed readbacks), against a
stated GO threshold of 20 %.** Run AK's 43.6 % REPRODUCES at HEAD with both the
`arrowIdentity` flip and `classifyRef` landed, so the figure is neither stale
nor an artifact of the pre-flip tree. The pool promote exists to recover is
real and it is large.

**THE CONFOUND, and it must ride with every quote of the 42.32 %.**
`ARROW_ROOTS` is default-off and it is not merely an observability device: it
*coarsens*. `slotsMinted` falls 854,948 → 732,344 (**−14.3 %**), because arrows
the solver unified now share one slot. So the arm measures a DIFFERENT ANALYSIS,
not just a different observer, and this census cannot separate "information that
exists at shipping defaults and is lost" from "identity that only exists because
`ARROW_ROOTS` created it".

**What rescues the reading — partially, and it is an argument, not a
measurement.** The join `ARROW_ROOTS` uses is the *type checker's own
unification*, not one the census invents: two arrows share a root because the
solver proved them equal. In that sense the information genuinely exists at
shipping defaults and occurrence-keying discards it. And the reason
`ARROW_ROOTS` cannot simply be shipped is precisely the gap promote fills:
§5.2 measured that **slot sharing WITHOUT a per-use set variable trades the
context sensitivity that manufactures usable singletons** (−0.50 pp, 99 % at one
site). The paper has both halves — one α per signature position AND `d⟨β̄⟩`
freshening per use. `ARROW_ROOTS` is the sharing without the freshening.
**Promote is the hypothesis that you can have the sharing and keep the
context.** That is this plan's central bet and it is NOT yet measured.

**A counter that leans AGAINST the plan's own Q2 hypothesis, recorded because it
is the honest reading.** Trivial signatures fall 9,523 → **8,554** under
`ARROW_ROOTS`: 969 defs acquire something to say. If the missing relations were
predominantly at TYPE-VARIABLE positions, fixing arrow *identity* could not make
a signature non-trivial — those positions mint no slot and produce no fact at
all (§3.2). That 969 says a meaningful share of the recoverable pool sits at
**declared-arrow positions whose identity was wrong**, which is `rep`/`sources`
territory and a cheaper fix than `ᾱ`. It does not settle Q2; it raises the
prior that Q2 answers "no".

**Q2 — verdict RESTATED after the adversarial pass (2026-08-26, later the same
day). The original argument below contained a TAUTOLOGY and is withdrawn as
stated; the NO-GO survives on three corrected legs.**

*The flaw:* "every new fact is at a declared-arrow ordinal" is TRUE BY
CONSTRUCTION — `sigfacts` enumerates declared arrows, so facts cannot appear
anywhere else. §0.1's own instrument note says a `TVar` position mints no slot
and produces no row; the original verdict then used that very row-population as
evidence about `TVar` positions. It cannot be. What the measurement genuinely
shows is only that what `arrowSolverRoots` exposes lands in the existing
`ArrowFact` vocabulary — which is real, but does not bound the type-variable
share of the RESIDUE (`unknownEverywhere` = 133,716 under roots, cause
unquantified).

*The corrected NO-GO, on legs that hold:*

1. **A cheaper mechanism recovers a large share first** — root identity moves
   the recoverable pool 11.8 % → 42.3 % through the declared-arrow channel
   alone. Sequencing that first is simple cost/benefit, independent of Q2.
2. **The probes that DEFINED the type-variable problem are closed WITHOUT `ᾱ`.**
   GAP-B's own exhibits — `Task.succeed : a -> Task x a` (kN 0→4 under
   `arrowIdentity`, parent §0.3) and the bare-globals container (closed by
   `refIdentity`, §5.4.5) — resolved via USE-SITE mechanisms: the arrow
   materialises at the instantiation site, where occurrence/root identity and
   injection govern it. Probe-level, not corpus-level, but it is the direct
   evidence the tautology pretended to be.
3. **The design has NO paper counterpart — see the fidelity finding below.**

*Still open, and honestly labelled:* the corpus-level type-variable share of
the residual `var` pool is UNMEASURED. If the redirect stalls, measuring it
needs the §3.3 co-walk in census mode — the instrument this plan specified and
never built.

**FIDELITY FINDING (adversarial pass): promote-at-type-variable-positions was
an EXTENSION dressed as fidelity.** L^src is SIMPLY TYPED — its only
polymorphism is over lambda sets, so `d⟨ᾱ⟩` quantifies set variables on
EXISTING arrows. "A set under a type variable that becomes an arrow at
instantiation" (GAP-B) cannot arise in L^src at all; §1's quotation of 146:11
licenses lambda-set-variable promotion only, not this plan's design, and the
§3.3 co-walk has no paper analogue for the same reason. This STRENGTHENS the
NO-GO — building it would have been unfaithful novelty — while it weakens the
original Q2 evidence, which is why both corrections are recorded together.

*The original (flawed) argument, kept for the record:* `sigfacts` rows are
keyed per `(global, ORDINAL)` where the ordinal indexes arrows of the DECLARED
type, so they count exactly the positions promote would *not* be needed for.

| | defaults | `+refId` | `+refId +ARROW_ROOTS` |
|---|---:|---:|---:|
| `sigfacts` rows | 424 | 424 | **1,502** |
| `sig\|carrying` | 333 | 333 | **1,297** |
| `sig\|allflex` | 7,264 | 7,264 | **6,295** |
| `sig\|arrowfree` | 1,546 | 1,546 | 1,546 |
| `sig\|hasTop` | 78 | 78 | 84 |

The 969 signatures that stop being trivial produce **1,078 new facts, every one
of them at a declared-arrow ordinal**, and `arrowfree` is invariant at 1,546 as
it must be. So the information `ARROW_ROOTS` exposes is already expressible in
the existing `ArrowFact` vocabulary. **It does not need `ᾱ` at type-variable
positions. It needs the arrow IDENTITY to be right.**

Note also that `refIdentity` moves NONE of these: `sigfacts`, `carrying`,
`allflex` and `hasTop` are identical in the first two columns, which is the same
inference-side/translate-side split `Q-infer` showed. The signature channel is
untouched by GAP-A's fix.

**PHASE 0 VERDICT: NO-GO for promote as specified in this plan.** The GO
condition of §0.1 question 2 fails, and it fails in the direction the §0.1
caveat named: *"if it does not, the correct plan is to strengthen `sources`, not
to build `ᾱ`."* Building the co-walk and quantifying type-variable positions
would be the fifth entry in §0's refutation table.

**THE REDIRECT — and it is better founded than what this plan proposed.** The
measured problem is now stated exactly:

- Solver-root identity carries **1,078 more signature facts** and lifts the
  recoverable pool from 11.8 % to 42.3 %, because it uses the type checker's own
  proof that two arrows are one variable.
- It cannot ship, because sharing slots WITHOUT per-use freshening destroys the
  context sensitivity that manufactures usable singletons (−0.50 pp, §5.2 §10.9).
- The paper has both halves: one α per signature position, and `d⟨β̄⟩`
  freshening at every use (`τ[ᾱ↦β̄]`, Fig. 5 TIU-Def-Ref).
- **Eco has already built the freshening half** — `instantiateScheme`
  (`LssInfer.elm:239`) ties, carries and re-emits against slots that are fresh
  per call — and it is inert only because it is fed pre-solved facts derived
  from occurrence-identified signatures.

So the well-founded next plan is narrower than promote and reuses what exists:
**identify signatures by solver root, instantiate them per use.** Its gate is
already known and already measured — `arrowSolverRoots`-quality signature
content at `arrowIdentity`-quality dispatch coverage, i.e. `sigfacts` ≥ ~1,500
with no repeat of the −0.50 pp. That plan should be written before any code.

Q3 is not answered and is now moot for THIS plan; it becomes a Phase-0 question
for the redirect, where the `k1`/`kN` split of the recovered pool still decides
whether the work is dispatch-negative before sum lowering. Under `ARROW_ROOTS`
the split is visible in the ledger and is not encouraging on its own: `kN`
2,047 → 6,136 against `k1` 159,735 → 202,244, i.e. the pool skews toward
multi-member sets that today's singleton-only consumer declines.

**Q3 and the co-walk — NOT BUILT, and now not needed here.** Recorded for the
redirect. The revised batch, had Q2 passed, would have been:

1. **The §3.3 co-walk in census mode** at `applyFacts`: declared annotation
   against use-site type, counting positions where the instantiation has an
   arrow and the declaration has a `TVar`. This is Q2, and it is also Phase 1's
   deliverable, so building it now is not throw-away work.
2. **Per-arrow `var` rows** (`VARROW <arrowId> <readbacks> <knownElsewhere>`)
   so the intersection with the existing per-arrow `MSET` rows can be done
   offline. This is Q3: the `k1`/`kN` split of the recoverable pool, which
   decides whether promote is dispatch-negative before sum lowering.
3. **Declared-arrow vs type-variable split of the `knownElsewhere` pool**, which
   is what discriminates promote from a cheaper `sources` repair, and which the
   969-signature delta above says is genuinely in doubt.

Cost: one Stage-5 + Stage-6 rebuild (~15 min) plus one census leg (~7 min).

---

## §1 What promote is, in Eco's terms

The paper, 146:11 §4.2.2, verbatim:

> Lambda set variables appearing free in the *type signature* of the current
> definition are **promoted** to universally quantified lambda set parameters,
> and any inclusion constraints on these variables are added to the constraint
> set for the current definition. Variables *not* appearing in the type
> signature are **internalized**, meaning that they are replaced with concrete
> lambda sets sufficient to satisfy all their inclusion constraints.

Eco does the second half eagerly and correctly (measured: `internal=92,935`,
`diverge=0`). It does not do the first half at all. Today `zonkSigGo` reads the
scratch store and writes a *solved answer* per declared-arrow ordinal; a
position it cannot answer becomes `{rep=self, members=[], top=False}` — which is
indistinguishable from "nothing flows here" and from "ask the caller".

**Promote makes the third case representable and actionable**: the signature
says *"ordinal/position p is the quantified variable α_p, and here are the
constraints on α_p"*, and instantiation binds α_p to the caller's own slot at
the corresponding position of the instantiated type.

**What promote is NOT:**

- Not `S(Q,α)`. That is internalize, it is measured neutral, and it must not be
  rebuilt (§5.6.3).
- Not "make signatures non-trivial". Refuted (§5.7.1). A signature that says
  nothing because the *type* already says it is correct.
- Not a rank discipline. Reverted (§5.0b). `Engine.freshVar`'s "no
  generalization happens, so any fixed rank is safe" stays valid.

---

## §2 What already exists to build on

| piece | where | state |
|---|---|---|
| `LssSignature.quantified` (`ᾱ`, canonical ordinals) and `.residual` (`Q`) | `Engine.elm:108-130` | LANDED, derived from `members`, byte-neutral |
| `instantiateScheme` = `schemeTie` / `schemeFacts` / `schemeResidual` | `LssInfer.elm:239-330` | LANDED behind `lss.qSolve` |
| `Q` recording at every set write | `Store.noteQ`, `unifySlotWithSetC`, `addSlotSource` | LANDED, report-gated, inertness proven |
| inference-boundary solve + score | `Store.qInferenceCensus`, `LssInfer.elm:691` | LANDED, `REPRODUCES=yes`, `diverge=0` |
| reachability walk (which slots the signature reaches) | `Store.qSigClasses` | LANDED — this is the occurrence test §7 asked for |
| Σ provisional self-type | `LssInfer.elm:18-22, 758-786` | FAITHFUL per the mapping; preserve, do not rebuild |

**The occurrence test already exists and already runs.** `qSigClasses` walks a
def's root type Point collecting `FunL` set slots, and the partition it produces
(`reaching` / `internal`) is exactly the promote/internalize split. What is
missing is *acting* on it: today it feeds a counter.

---

## §3 The design

### §3.1 The boundary is `zonkSignatures`, and it is already the right place

Generalization happens in `LssInfer.inferUnitInScratch`, after `walkMembers` and
inside the scratch store: `zonkSignatures` turns each member's slots into an
`LssSignature`. That is the paper's generalization point, the reachability walk
is already invoked one line later (`qInferenceCensus`, `LssInfer.elm:691`), and
the store is still installed. Promote is a change to what `zonkSigGo`
(`LssInfer.elm:864`, `trivial` computed at 871, record built at 920) *emits*,
not a new phase.

*Citation drift, so the next reader does not chase it:* the parent register's
§0.2.1 cites `zonkSigGo` at `LssInfer.elm:731-737`. The file has grown since;
the numbers above are HEAD as of 2026-08-26.

### §3.2 The representation problem — ordinals cannot name a type-variable position

This is the whole difficulty, and §0.2.1 states it exactly:

> `facts` is indexed by ARROWS IN THE DECLARED TYPE. For
> `Task.succeed : a -> Task x a` the declared type has exactly ONE arrow […]
> The two `a` positions are bare type variables, not arrows, so they contribute
> no fact at all.

`ArrowFact.rep` can say "arrows *i* and *j* of the declared type share". It
cannot say "the arrow that `a` *becomes* is shared between the parameter and the
result", because at signature time `a` is not an arrow. The same mechanism
accounts for `List.cons` (hence **every list literal**), `Task.succeed` /
`andThen` / `attempt`, `List.map`, `Basics.composeL`, `idf : a -> a`.

**So promote needs a position key that survives instantiation.** Ordinals do
not: `applyFacts` pairs `Array.length sig.arrows` against
`Array.length slots` and poisons everything on mismatch
(`LssInfer.elm:215-216`).

### §3.3 The co-walk — declared type × instantiated type

Replace positional ordinal pairing with a **structural lockstep walk** of the
declared signature type against the use-site instantiated type, producing a map
from *declared position path* to the instantiated type's Point:

- declared `TLambda` vs instantiated `TLambda` → pair their set slots, as today;
- declared `TVar a` vs instantiated *anything* → record the binding
  `a ↦ <that subtree's root Point>`, and if the subtree contains arrows, their
  slots are the materialisation of any α that rode `a`;
- structural mismatch → the existing poison fallback, unchanged and still sound.

This generalizes the current pairing rather than replacing it: where the
declared type is arrow-for-arrow with the instantiation, the co-walk yields
exactly today's ordinals. Where the instantiation *grew* arrows under a type
variable, the co-walk yields positions the ordinal scheme could only poison.

A promoted variable is then keyed by **declared position path**, not by arrow
index — the one key that is stable across the two type objects and across the
memoization of the signature.

**Hazard, recorded loudly.** Signatures are GLOBAL and long-lived
(`S.lssSignatures`); Points are per-store. A promoted α must be a *symbolic
key*, never an `IO.Variable`. `Engine.ItemAux`'s comment on `arrowMemo` records
the identical trap and its consequence — "silent miscompile, not a crash" — and
`Translate.retranslateAt` records it verbatim a second time.

### §3.4 What a promoted α carries

Per promoted position: the constraints on it that are *not solvable at the def*
— i.e. `Q` restricted to that variable, which §5.2's `residual` already computes
— plus its tie class (which other promoted positions are the same variable). Both
are already in the record; only the KEY changes from ordinal to position path.

`schemeTie` / `schemeFacts` / `schemeResidual` then apply unchanged in shape:
tie, carry the non-set facts (⊤ and LSS_023 edges), re-emit `Q`. The slots are
already fresh per call, which is the freshening of `ᾱ`.

### §3.5 Internalize — DO NOT REBUILD

Measured neutral (§5.6.3). Promote changes what is *exported*; the internal half
keeps working exactly as it does. If a future restatement wants to touch the
eager path it must target **flex adoption** (`set-writes: flex=206,994`, 88.6 %)
and not the union (`union=24`, 0.01 %), or it optimises something that does not
happen.

### §3.6 What ⊤ becomes

Unchanged from the parent register §3.6: ⊤ survives for exactly one job, the
opaque kernel/FFI/port boundary, which is Eco's setting and not a representation
choice.

**CORRECTED 2026-08-26, before Phase 0 ran.** An earlier draft of this section
said promote would retire the arrow-count-mismatch poison (`censusLenGuard`).
**That population is ZERO on the self-compile** — `grep -ac lenGuard` over the
Run-AM census returns 0, matching §0.2.1's finding on the probes. The reason is
structural and worth stating, because it also corrects §0.1's question 2:
`sigSourceTypeFor` picks the stored **annotation** on the inference side AND on
the call side, so the two enumerations agree by construction and the mismatch
arm is unreachable. **The arrows a type variable becomes are therefore not
"mismatched" — they are never enumerated at all.** They are invisible to every
counter that exists today, which is precisely why measuring them requires the
co-walk of §3.3 rather than a classifier over `slots`.

So the only ⊤ producer promote can claim is ⊤-as-join-result at positions that
would be promoted instead of committed, and that claim must be measured, not
assumed.

---

## §4 Phases

**PHASE 0 — MEASURE (no code beyond instrumentation).** §0.1's three questions.
Deliverable: §0.2 of this file, with a GO/NO-GO. The `underTypeVar` classifier
at `zonkSigGo` is the only new instrument and is report-gated.

**PHASE 1 — the co-walk, census-only.** Build the declared × instantiated
lockstep walk and run it *beside* `applyFacts` without consuming its output.
Census: how many call sites have positions the ordinal scheme cannot name, and
how many of those carry a member the caller already knows (which promote would
not need) versus one only the callee's body knows (which it would).
**Gate: byte-identical `.mlir` with the census on and off**, as §5.1 proved for
`Q`. Inertness is proven, not asserted.

**PHASE 2 — promote at the boundary.** `zonkSigGo` emits promoted positions
keyed by path; `LssSignature` grows the promoted map beside `quantified`.
Flag-gated, default-off, hash token. **Gate: flag-off byte-identity** on the
two-binary/one-corpus rail.

**PHASE 3 — instantiate.** `applyFacts` consumes the co-walk: bind promoted
positions, then tie/carry/re-emit as today. **Gates: §5 in full.** Expect the
ledger's `kN` to rise and `var` to fall; expect `top` to fall by the
`censusLenGuard` population.

**PHASE 4 — retire what promote makes dead.** Only once Phase 3 is default-on:
the arrow-count-mismatch poison, and the transport hooks the parent register's
§5.5 lists. One piece per commit, each byte-neutral or individually measured.

---

## §5 Gates

Inherited from `lss-paper-inclusion-constraints.md` §6, unchanged, plus one:

1. §2.5 ledger `RECONCILES=yes`; headline is **`kN` rising and `var` falling**.
2. `MSET` / `multiSetSites` — `LssTaskSetProbe` is the named pin; `PMapPoly`
   (`List.map idf [ incr, decr ]`) is the pin for *this* plan, because it is the
   one §5.7.1 probe whose failure was attributed to a container literal of
   globals rather than to the polymorphic hop.
3. Dispatch census A/B with the `sat + fast` invariance rail (runtime-calls Run
   AE/AO protocol). **Coverage is expected to fall**: this plan ADDS sets, and a
   correct 2-set is worse than a singleton under a singleton-only consumer.
   Record it; do not gate on it. `plans/lss-sum-lowering.md` is the consumer.
4. elm-tests at the pre-existing failure set; E2E `--target full`.
5. **SELF-COMPILE LOWERING, every arm.** LSS_031's standing rule: E2E passed
   1,687/1,687 with a dangling `_fast_evaluator` because its corpus is small
   programs. `0 undefined fast evaluator` or the arm does not ship.
6. Wall/GC per `benchmarks/lss-opt.md`. The co-walk is new work on the mono
   critical path and must be costed, not assumed free.
7. **NEW — `Q-infer` must stay `REPRODUCES=yes` with `diverge=0`.** Promote
   changes what the signature exports; if it introduces a write path that is not
   a recorded constraint, this is the counter that says so. It is the standing
   guard on LSS_037 and it is currently clean.

---

## §6 Hard parts

- **The co-walk is where soundness lives.** Every mismatch arm must fall back to
  the existing poison, and the fallback must be counted. An unsound *widening*
  is a precision loss; an unsound *narrowing* is the miscompile direction and is
  exactly what LSS_026 and the `[42,42,42]` regression were about.
- **Elm has let-polymorphism; L^src does not.** The mapping rates let-bound
  function flow PARTIAL (GAP-9): *"Elm's polymorphic `let` has no L^src
  counterpart, so this axis is Eco's own to get right."* Promote must decide
  whether a let-bound function's set variables can be promoted at all, and argue
  it separately from the paper.
- **Currying.** LSS_013 spine injection is rated DIVERGENT with "no paper
  counterpart" — L^src has no currying. A promoted α at a residual-spine arrow
  must not silently drop the spine semantics.
- **Termination.** Σ guarantees no polymorphic recursion (Thm 4.1) in a system
  where α never escapes. Promote is exactly "α escapes". Re-verify the guarantee
  rather than inheriting it.
- **μ.** `plans/lss-set-variable.md` §3 concluded "µ is NOT re-imported" because
  members are flat `Int` ids and saturation reaches its least fixpoint. That
  argument holds only for the INTERNALIZED case; a variable that escapes into a
  signature can occur in its own constraints across a recursive def, where
  saturation has nothing to saturate. **Decide empirically in Phase 1** whether
  Elm programs produce escaping self-referential α; skip μ if they do not. Do
  not build μ on this paragraph alone.
- **`maxSetSize` interacts with a promoted variable.** Widening a set that is
  now a caller-supplied binding is a different act from widening an eagerly
  unioned one. Decide where the budget applies before Phase 3.
- **Store-scoping.** §3.3's hazard. Anything holding Points must be cleared in
  `Engine.clearedAux` and restored in `restoredAux`, or it leaks across a scratch
  swap — silent miscompile, not a crash.

---

## §7 Non-goals

- **Sum lowering.** `plans/lss-sum-lowering.md`. This plan produces sets; that
  plan consumes them. Promote without it is a reach improvement measured as a
  dispatch regression, and that trade is now an explicitly accepted one (§5.A2)
  rather than a blocker — but it is not this plan's job to fix.
- **Removing kernel/FFI ⊤.** Permanently out of scope. Eco's setting, not a
  representation choice.
- **Re-litigating internalization, `allflex`, or ranks.** All three are settled
  above; re-opening one requires new evidence, stated as such.
- **The post-mono architecture.** `plans/lss-post-mono-architecture.md` proposes
  taking sets out of the spec key and solving after monomorphization. It remains
  the road not taken; this plan follows the paper.

---

## §8 Relationship to the other plans

- **`lss-paper-inclusion-constraints.md`** — the parent. `Q`, `ᾱ` and the
  inference-boundary census are built there; this plan is its §3.3 promote half.
  Its §5.5 (retire the compensation layer) is downstream of Phase 4 here.
- **`lss-sum-lowering.md`** — the consumer, and the binding constraint on
  whether any of this shows up in a benchmark.
- **`lss-post-mono-architecture.md`** — its Phase 0 measurements are load-bearing
  evidence *for* this plan (the 43.6 % cross-item figure, and `keyed=False`
  destroying 12.4 singletons per multi-set), while its architecture is rejected.
  Its §3.3 per-site polymorphism census remains unbuilt and remains the right way
  to price the consumer.

---

## §9 Method notes carried forward

Four occurrences in the parent register, all avoidable:

- **Vary ONE thing per probe.** §0's own table was wrong because a probe
  contained both a list literal and an `if`, and the set came from the `if`.
- **Prefer an instrument that names the site** (census row, gdb frame) over
  inference from an A/B.
- **Put `-a` on EVERY grep in a census pipeline.** `grep` without it silently
  suppresses matches on binary-looking input and has twice produced a false
  reading in this arc.
- **Names do not join across arms.** Lambda symbols renumber whenever the spec
  population shifts; use ArrowIds (syntax-derived, flag-independent) or multiset
  differences of magnitudes.
