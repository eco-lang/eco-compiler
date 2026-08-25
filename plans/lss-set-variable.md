# Phase 3 — the lambda-set VARIABLE

**Status: IMPLEMENTED AND MEASURED, 2026-08-24 — see §8 for the numbers and the
verdict. `LambdaSetAnno` now carries `LVar Int`; multi-member sets still lower
to generic dispatch, deliberately (sum lowering is NOT part of this).**

**Result in one line: the variable's identity IS preserved across the annotation
round trip — `retranslations` fall 24–30 % in every arm, which is the mechanism
working — but resolution completeness is FLAT (±0.05 pp) and the
consumer-visible multi-set feedstock is UNCHANGED. The sharing Phase 3 preserves
was not the bottleneck on this workload.**

**§2 stands: the set variable does NOT remove the join on its own.** It removes
it only where nothing has to COMMIT a set to a concrete value — and
specialization keying is exactly such a commitment. Sum lowering is what removes
that commitment, and the join arms that survive in §8 (`LVar i ∪ LVar j`,
`LVar ∪ LSet`) are precisely the ones defunctionalization would delete.

---

## §0 Where this starts

`plans/lss-unknown-elimination.md` established, by measurement:

- **The representation is the defect.** Eco's `LambdaSetAnno = LTop | LUnknown |
  LSet [Int]` has a set and a top; the paper's `σ ::= {ℓ₁…ℓₙ} | α | µa.σ` has a
  set and a **variable**, and no top at all.
- **Identity alone is not enough, and alone it is a REGRESSION.** Phase 2a gave
  each arrow an identity and shared its slot; fast-dispatch coverage fell
  −0.50 pp, 99.0% of it one de-stamped site (§10.9). Mechanism: sharing a slot
  *without a quantifier* is unification, i.e. merging. Per-load slot minting is
  not only fragmentation — **it is the analysis's context sensitivity, and that
  is what manufactures the singletons the consumer can use.**
- **Eco has no set variable at all, and structurally cannot instantiate one.**
  `Engine.freshVar`: *"at the single fixed engine rank (`outermostRank`). **No
  generalization happens**"*. And when the analysis meets a generalized
  position, `LssInfer.joinArrowSets` answers `poisonBoth`. The set slot is a
  **λ-bound** monomorphic unification variable; the paper's α is **let-bound**,
  ∀-quantified in the def's scheme and freshly instantiated per use.

That single HM distinction is the gap. This plan is about closing it — and
about the two questions that decide whether closing it is worth anything yet.

---

## §1 Q1 — where does the deferral bottom out? ANSWERED

The paper terminates because the program is whole-program, topologically
ordered, and the entry point's type contains no arrows (AT-Entry). Eco's
monomorphizer is demand-driven and interleaved; the fidelity mapping calls this
"the deepest legitimate divergence". `main : Program flags model msg` carries
`init`/`update`/`view`, so **AT-Entry does not hold literally** — Eco has no
arrow-free root.

**It does not need one.** The resolution has three parts:

1. **Eco already instantiates per use — of TYPES.** A spec IS a def instantiated
   at a concrete demand type, and `Monomorphize.drain` walks the demand graph
   from `main`. The lambda-set variable should ride exactly that instantiation.
   The "topological order" the paper needs is Eco's worklist order, and the
   LSS_010 dirty-flush fixpoint is what makes it order-insensitive.

2. **Variables ground at SPEC EMISSION**, not at a program root. When a spec's
   `MonoType` is finalised for codegen, any variable still free in it takes its
   solution. Nothing is deferred past the point where code must exist.

3. **The grounding value is the LEAST solution (∅), but only where the
   constraint system is COMPLETE.** This is the real content of the answer. The
   paper may take the least solution because every actual inhabitant of an
   arrow contributes a constraint. Eco's system is *not* complete — the kernel
   and FFI boundary is opaque (LSS_004/021/022), ports and `Debug` cross it, and
   the interleaved order can observe a position before all its writers have run.
   Taking ∅ where completeness fails is exactly the LSS_001 error: an empty set
   claims a position has NO inhabitants, the one reading that is always wrong.

**Therefore ⊤ does not disappear — it narrows to exactly one job: the
INCOMPLETENESS MARKER.** That is a much smaller ⊤ than today's, and it is the
one the unknown-elimination plan already decided to keep (§0's scope decision:
"kernel poison and budget caps are KEPT. They are honest ⊤"). What dies is
⊤-as-unknown (done, Phase 1), ⊤-as-join-result, and ⊤-as-widening.

And completeness is already decidable with machinery that exists:
`Store.resolveSources`' `sawFlex` bit and LSS_026(a)'s honest-∅ rule are
precisely "did this resolution cross a source that may still be written".
**LSS_026(a) is not a wart to delete in Phase 3 — it is the completeness oracle
Phase 3 needs, and it should be promoted, not retired.**

---

## §2 Q2 — variables in spec keys. THE BLOCKER

`Engine.enqueueSpecKeyed` keys a specialization by its annotated `MonoType`.
Keying by annotated type IS lambda-set specialization. So: what does a
*variable* in a key mean?

Only two answers exist, and both defeat the purpose:

**(a) Erase variables in the key.** `toComparableFragments` renders every
`LVar _` as one fragment, exactly as Phase 1a's `annoKeyEq` makes `LTop` and
`LUnknown` one point. Two demands differing only in a variable then key
together — one spec, no fan-out. But that one spec must serve every caller, so
its variable's value is the JOIN over all callers that reached it. **The join
we set out to delete comes straight back**, now on variables instead of sets,
and with it ⊤ as the join's absorbing element.

**(b) Include variables in the key.** Each distinct variable assignment gets its
own spec. No join — this is the paper's precision. But it is per-call-site
specialization of every higher-order function, which is `maxSpecsPerGlobal`'s
problem raised by an order of magnitude. The 2026-08-22 budget sweep already
found the knee at 512 with four consumers above 64; per-variable keying moves
the whole distribution.

**The paper has neither problem because it does not specialize on lambda sets
at all.** `ℱ` is a defunctionalization: an arrow with set `{ℓ₁…ℓₙ}` becomes a
tagged union and ONE code path dispatches on the tag. There is nothing to key,
so nothing to join and nothing to fan out.

**So the honest statement of Q2 is: the question is malformed, and the thing
that dissolves it is sum lowering.** This is the same conclusion §10.9 of the
unknown-elimination plan reached from the runtime side, arriving here from the
analysis side:

> a correct 2-set is strictly worse than a singleton under a singleton-only
> consumer

Sum lowering is not "the payoff we get later". **It is a prerequisite for the
set variable to be implementable in its intended form.**

---

## §3 Q5 — does the variable re-import µ? NO

The paper needs a set-level `µ` for variables occurring free in their own
constraints — recursive and iterative control flow. Eco severs set-in-own-
identity by construction: members are flat `Int` ids (`widenSets`, LSS_003), so
a recursive def's constraint `α ⊇ {f} ∪ α` is a monotone equation over finite
flat sets and its least fixpoint is reached by ordinary saturation. No `µ`
constructor is needed in `LambdaSetAnno`.

Keep the id-only member representation. It is one of the places Eco's divergence
from the paper is a simplification rather than a debt.

---

## §4 Q4 — raw vs qualified member ids. UNCHANGED PREREQUISITE

The inference walk mints **raw** `injectLambdaMember`, not `…Qualified`, so
signature-transported `l|` ids arrive at AbiCloning with no closure instance
carrying that id and decline as `noInstance`. Measured as the cause of D1/D2's
`devirtDirect` staying flat. LSS_017-v2
(`plans/lss-fork-qualified-members.md` §8) must land before Phase 3, or every
variable-transported member repeats the same decline.

---

## §5 The two viable orders

**Order A — sum lowering first (RECOMMENDED).**

1. **Sum lowering**, proven on the smallest real shape. `multiSetSiteHist` is
   non-empty for the first time (`2->2` under `arrowIdentity`), so two genuine
   2-member dispatch sites exist to lower. This is a fraction of the analysis
   work and it is decisive: if a 2-set cannot be lowered profitably, §2 says the
   set variable has no implementable form, and the right move is to stop
   pursuing set precision entirely and take the `IO (\state -> …)` source
   rewrite instead (68.6% of generic dispatch, no plan file, cheaper than all of
   this).
2. **LSS_017-v2** (Q4).
3. **The variable + solver-root identity together** — Phase 2b and Phase 3 as
   ONE change, because §10.9 measured that identity without per-use
   instantiation is a regression, and 2b shares strictly more contexts than 2a.
   The artifact-format bump is then paid once.
4. **Delete what becomes dead**: the join lattice, ⊤-as-unknown and
   ⊤-as-widening, and the transport artifacts #1/#2/#4a/#5/#6/#8/#9/#10.
   **KEEP** the kernel/FFI ⊤ (§1's completeness marker), the budget, µ-tie,
   #3b, #4b, #11(d).

**Order B — variable first, accepting the join.** Land `LVar` with key-erasure
(§2a) and keep the join for now. This buys the *representation* (unknown
deferred UP rather than committed DOWN, signatures flexible) without the
precision, and it makes step 3 of Order A smaller later. It is defensible as
groundwork. **It should not be sold as "implementing the paper", because the
join is the thing the paper does not have.**

---

## §6 What is safe to build NOW, before that decision

Two pieces are prerequisites under either order and cannot regress anything:

- **The multi-set census** (`benchmarks/multiset-census.py` + the `MSET` block).
  Landed 2026-08-24. It is what tells us whether Phase 3 raises HONEST
  multi-sets or merge-induced ones — the distinction §10.9 showed is the whole
  ballgame. **Its per-arrow join across arms is only valid because ArrowIds are
  flag-independent**, which is itself a Phase-2 deliverable.
- **The completeness oracle** (§1.3): promote `resolveSources`' `sawFlex` bit
  and LSS_026(a) from "a widening rule" to "the predicate that decides whether a
  variable may ground to ∅". Pure refactor of something that already exists, and
  it is the piece §1 shows Phase 3 depends on.

---

## §7 Risks

1. **Sum lowering proves infeasible.** Then §2 has no resolution and this plan
   should be abandoned rather than worked around — the workaround IS the
   compensation layer we are trying to delete.
2. **Order B gets mistaken for Order A.** The variable without sum lowering
   still joins; shipping it and calling the arc finished would leave the
   register in exactly the state that produced fourteen months of +0.02 pp.
3. **The completeness oracle is wrong somewhere.** Grounding to ∅ where the
   system is incomplete is the LSS_001 miscompile, not an imprecision. Every
   ∅-grounding site needs the same honesty treatment LSS_026(a) got, and the
   runtime witness (`test/elm/src/LssMixedSigHonestyTest.elm`) must stay green.
4. **`maxSpecsPerGlobal` under §2b.** If key-inclusion is chosen after all, the
   budget stops being fan-out policy and becomes load-bearing again — reversing
   LSS_018's demotion of it.

---

## §8 IMPLEMENTED AND MEASURED (2026-08-24)

**What was built.** `LambdaSetAnno` gains `LVar Int`; Phase 1's anonymous
`LUnknown` retires into it. Three pieces make it the paper's α rather than a
rename:

1. **`Store.varNumberFor`** — at zonk, an unwritten set slot gets a CANONICAL
   number keyed by its union-find REPRESENTATIVE, allocated in walk order and
   reset per zonked type (`ZonkCtx.varOf`/`nextVar`). Two arrows the store
   unified therefore read back the SAME `n`.
2. **`Store.mintVarSlots`** — a pre-pass over a demand `MonoType` mints ONE
   store slot per distinct `LVar n`, and `monoTypeToVarC` resolves every
   occurrence to it. **This is the whole point:** Phase 1 minted a fresh slot
   per arrow, so a store unification was DESTROYED by the annotation round trip;
   now it survives. Done as a pre-pass so the map is read-only and the encoder
   keeps threading `IO.State` alone.
3. **The key law changed.** `LVar n` hashes by `n`, emits its own
   `toComparableFragments` fragment `Av<n>(`, and `annoKeyEq` is now plain
   structural equality. So `(α → α)` and `(α → β)` key DIFFERENTLY — the
   sharing PATTERN is part of the key — while two call sites with the same
   pattern still key together. `LVar` is never the same key point as `LTop`,
   because they encode differently (flex slot vs poison) and merging them would
   let a stored ⊤ poison a variable demand.

`unionAnno` keeps a join, and §2 is why: `LVar i ∪ LVar i = LVar i` (the arm
Phase 3 exists to create — Phase 1 could not tell "the same unknown" from
"another unknown"), but `LVar i ∪ LVar j` and `LVar ∪ LSet` still go to `LTop`,
because a lattice join has no store to write a substitution into. Multi-member
sets still lower to generic dispatch: **sum lowering is deliberately not part of
this.**

### §8.1 The numbers — same frozen corpus, same three flag arms

| | k=1 | k≥2 | top | var | total | completeness | arrows | retrans |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| pre-Phase-3, `arrowIdentity=0` | 144,875 | 545 | 29,379 | 249,087 | 423,893 | 34.31 % | 13 | 439 |
| **Phase 3, `arrowIdentity=0`** | 147,708 | 557 | 30,095 | 254,211 | 432,578 | 34.28 % | 13 | **310** |
| pre-Phase-3, `arrowIdentity=1` | 155,729 | 2,005 | 30,919 | 237,057 | 425,717 | 37.05 % | 100 | 443 |
| **Phase 3, `arrowIdentity=1`** | 158,502 | 2,043 | 31,640 | 241,758 | 433,950 | 37.03 % | 100 | **312** |
| pre-Phase-3, `+ arrowSolverRoots` | 165,854 | 4,302 | 29,644 | 243,922 | 443,729 | 38.35 % | 1,009 | 436 |
| **Phase 3, `+ arrowSolverRoots`** | 167,966 | 4,377 | 30,517 | 247,266 | 450,133 | 38.30 % | 1,009 | **331** |

### §8.2 Verdict — honest, and it is not the win the plan hoped for

**What Phase 3 demonstrably buys: `retranslations` −24 % to −30 % in every
arm** (439→310, 443→312, 436→331). That is exactly the `LVar i ∪ LVar i = LVar i`
arm doing its job: joins that used to report `changed` — because two anonymous
`LUnknown`s could not be recognised as one variable — now report no-change, and
`Engine.enqueueSpecKeyed` stops forcing a re-translation. A real compile-time
win, and direct evidence that the variable's IDENTITY is being preserved across
the annotation round trip, which is the mechanism the phase is about.

**What it does not buy: resolution completeness is FLAT** (34.31→34.28,
37.05→37.03, 38.35→38.30 — all within ±0.05 pp). Concrete answers rise in
absolute terms (+2,833 / +2,773 / +2,112 at k=1, and +12 / +38 / +75 at k≥2),
but total readbacks rise proportionally more.

**And the consumer-visible feedstock is UNCHANGED**: `multiSetSites` is
identical in every arm — `(none)` / `2->2` / `2->20 3->4 4->4 5->1 6->1 7->1`.
Distinct multi-set ARROWS are identical too (13 / 100 / 1,009).

**Reading.** The sharing Phase 3 preserves was not the bottleneck on this
workload. That is consistent with everything else the arc measured — the
producer side is the ceiling, not the transport — and it is a third independent
confirmation of the same thing: Phase 1b's de-laundering moved concrete +43 %
and dispatch 0.00 pp; Phase 2a/2b moved analysis a lot and dispatch negatively;
Phase 3 moves re-translation cost and completeness not at all.

**What it does NOT tell us**, and this is the honest limit: Phase 3 is measured
here against a consumer that declines every multi-member set. Its value is
supposed to be realised BY sum lowering, and that has not been built. §2's
conclusion stands unchanged — the join arms that remain (`LVar i ∪ LVar j`,
`LVar ∪ LSet`) are exactly the ones defunctionalization would remove.

### §8.3 Gates

Phase 3 is UNCONDITIONAL (no flag), so there is no byte-identity rail — it is
an analysis change and the artifact moves by design, as Phase 1b's did.

| gate | result |
|---|---|
| §2.5 ledger + `RECONCILES` | yes in all three arms |
| elm-tests | **13,355 / 12** — the pre-existing failure set exactly. The golden constraint fingerprints did NOT move this time, which is the right sanity signal: `LambdaSetAnno` is a `MonoType` concern and cannot touch constraint generation. |
| `LambdaSetIntegrity` (LSS_002) under BOTH `arrowIdentity` arms | green — no member lost to variable-mediated slot sharing |
| `LssSigFlowTest` miscompile pins (cases 3 and 4) | green, untouched |
| E2E `--target full` | **1,687 / 1,687** |
| `honestSources: topMixedFlex` | 0/0, 1/0, 2/0 — unchanged from pre-Phase-3 |

`ComparableKeyEncodingTest` was extended in the same commit as the key-law
change (the §6-risk-2 discipline): `annoAt` draws `LVar`, the goldens pin the
literal `Av0(`/`Av1(` fragments, and `handwritten` now contains the
`(α → α)`-versus-`(α → β)` pair so both K4 differential tests actually exercise
variable-vs-variable, variable-vs-⊤ and variable-vs-set.

---

## §9 A DEFECT in `arrowSolverRoots`, found while measuring sum lowering's feedstock

Lowering the self-compile MLIR of the `arrowSolverRoots=1` arm **fails**:

```
error: 'eco.papExtend' op references undefined fast evaluator 'Terminal_Main_lambda_532'
Error: Failed to parse MLIR file
```

A call site is stamped with a `fastEvaluator` naming a lambda instance that is
never emitted. Isolation, three lowerings:

| arm | lowers? |
|---|---|
| Phase 3, shipping defaults (`arrowIdentity=0`) | **yes**, EXIT=0 |
| Phase 2b arm, PRE-Phase-3 (`arrowSolverRoots=1`) | **NO** — `…lambda_514` |
| Phase 3 + `arrowSolverRoots=1` | **NO** — `…lambda_532` |

**So the defect belongs to Phase 2b, and Phase 3 merely inherits it.** The
flag being DEFAULT-OFF is therefore load-bearing, not merely cautious.

**And it exposes a gate gap worth more than the bug.** `--target full` passed
**1,687/1,687 with `arrowSolverRoots=1`** — because the E2E corpus is small
programs, and only the self-compile is large enough to produce the bad stamp.
**A flag that changes lambda-set IDENTITY must be gated on a self-compile
LOWERING, not on E2E alone.** Every arm in Runs AH/AI/AJ was gated on ledger +
elm-tests + E2E; none of them lowered the flag-on self-compile MLIR, which is
why this sat undetected through three run records.

First place to look: slot sharing maps two distinct lambdas onto one member id
and `AbiCloning` picks a representative whose instance does not survive pruning
— `multiInstanceGroups` and `declinedBodyMismatch` both grow under sharing
(3,385 → 3,442 and 39 → 72). Not fixed here.
