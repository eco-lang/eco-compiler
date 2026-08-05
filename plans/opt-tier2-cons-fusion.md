# Eco optimization roadmap — Tier 2: residual list-traversal deletion (CLOSED)

**Status: CLOSED 2026-08-05. This tier is a record, not a backlog.** Every
unit has been shipped, killed by measurement, or split out to its own plan.
Nothing here is schedulable; the four successor plans in §2 are.

**Why it closed:** the tier's original program (pairwise combinator fusion)
was measured dead by the chunked-list L5 adjacency census on 2026-08-03
(§1). Its *replacement* program — the census-ranked residual cons units —
then lost its ranking metric on 2026-08-05, when the comparable-key track
demonstrated for the third time that **wall follows retention, not
allocation volume** (§3). Every remaining unit here was ranked by an
`ECO_CONS_SITES` allocation census. They have been re-scoped and moved to
plans that gate on the right number.

**Series:** `plans/opt-tier{1..4}-*.md` — see `opt-tier1-aggregate-promotion.md`
for the series header and ordering rationale.

---

## 0. Scope note (kept — it was the useful part of this file)

This tier contained only transforms that change the code eco **emits**, i.e.
things that make every compiled program faster, the compiler included. Hand
optimizations of the compiler's *own Elm source* are a different category:
they improve self-compile wall and nothing else.

Why the distinction is easy to lose: the `ECO_CONS_SITES` census that ranked
everything here measures **the compiler compiling itself**, a workload that
is simultaneously the product (axis 1) and the benchmark corpus (axis 3). A
hot site in that census does not by itself say whether eco *generates* bad
code for a pattern or whether one compiler function is written badly.
Classify before scheduling. The former U-T2.2′ was exactly that confusion,
and became `plans/mono-comparable-key-optimization.md` — which went on to be
the most productive track in the series.

## 1. The fusion verdict (chunk plan §6 L5, 2026-08-03 — do not re-run on self-compile)

As scoped pre-Aug-2 this tier was "list/Cons deforestation" on the premise
that *"not allocating the intermediate list at all is the only lever."* The
chunked-list plan executed the recognition-and-loop-template half under its
own phasing and measured the fusion half dead:

- **The infrastructure this tier planned to build already exists** (chunk
  plan §6 L1 as-builts): `GlobalOpt/ListCombinators.elm` whole-combinator
  recognition; combinator shunts to chunk-building kernels
  (`Functions.elm listChunksShunt`); the GC-rooted scratch stack
  (`eco_scratch_mark/push_*/finish/finish_fwd/abandon`); backend passes
  `EcoListTemplate` and `EcoListCursor` (3,191 of 4,626 whiles walk mixed
  spines allocation-free); chunk chaining for over-cap batches. This was
  U-T2.2's option (b) — "List-LoopIR at emission, BytesFusion precedent" —
  shipped under another name.
- **The target mass collapsed via a different lever than fusion.** Final
  flag-on trade, now the default baseline: **−4.28% objects, −47.5% Cons
  (737.5M → 387.9M), −24% list bytes, −1.7% RSS, lower minor-GC time in
  every pair, zero measurable wall cost.**
- **Gate D-T2 (≥10% of allocation projected) became unreachable by
  arithmetic:** residual Cons is 388M of 6.21B objects ≈ **6.2%** — perfect
  deforestation of every remaining cons could not clear the gate this plan
  set for itself.
- **Adjacency census, per-function-scoped** (an earlier global-scope scan
  was invalidated by cross-function SSA-name collisions: 6,638 apparent
  pairs → **1,162 real**): `foldl∘reverse` 815 (70% — `foldrHelper`'s
  internal >500-element fallback, one site per spec, dynamically rare,
  already chunk-chain-cheap), `append∘append` 120, `map∘map` 44, everything
  else ≤40. **No high-value fusible pool exists on the self-compile
  workload.** A speculative `reverse∘reverse→id` peephole was implemented,
  measured against the corrected census (0 real occurrences), and removed.

| killed | by | revive iff |
|---|---|---|
| Pairwise fusion laws / deforestation on self-compile (the original U-T2.1–U-T2.3) | L5 adjacency census (1,162 real pairs, top pool cold) + D-T2 denominator arithmetic (6.2% < 10%) | a workload whose adjacency census shows a hot `map∘map`/`fold∘map`/`concatMap` pool — i.e. user programs. Capture point is mono-level closure composition + re-specialization over `ListCombinators` recognition, NOT MLIR (lambdas are opaque `papExtend`s by then). Owed before the first law lands: the `Debug.log`/`Debug.crash` ordering + ⊥-selection policy as an invariant note — now inherited by `plans/cse-pure-calls.md` C3. |

## 2. Disposition of every remaining unit

| unit | disposition |
|---|---|
| **U-T2.1′** function-level accumulator templates | → **`plans/accumulator-templates.md`**, re-justified on retention + traversal deletion rather than cons count |
| **U-T2.2′** the `toComparable` site | → `plans/mono-comparable-key-optimization.md` (moved 2026-08-04, category A). **SHIPPED K1–K7**; the track's own outcome is §3 below |
| **U-T2.3′** measurement discipline | → absorbed into all four successors' gate sections; `benchmarks/tier2-opt.md` remains the bench log |
| **U-T2.4′** user-workload fusion activation | → **`plans/opt-tier4-parked.md`** as a reactivation trigger; the activation criterion and capture point are recorded in §1 above |
| **U-T2.5′** CSE over pure calls | → **`plans/cse-pure-calls.md`** |
| **U-T2.6′** sum-type wrapper unboxing | → **`plans/sum-type-wrapper-unboxing.md`** |
| *(new)* the measurement everything needed | → **`plans/live-heap-composition-census.md`** — gates the other three |
| **TRMC** | still out of scope. Chunk templates + chaining consumed most of its spine-building value; it reduces recursion overhead but does not remove allocation. Revisit only on user-workload evidence |

## 3. Why the ranking metric was retired (2026-08-05)

Three controlled experiments, two of which post-date this plan's last
revision:

| change | allocation | promotion | wall |
|---|---|---|---|
| chunked lists (§1) | **−349.6M Cons (−47.5%)** | not measured | **0** |
| K4 hash-consing-lite (Run C) | −21.3% apparent / −1.31% true | **identical (375.9M)** | **flat** |
| K6 construction-time hash-consing, solver (Run F) | **+0.02% (allocates MORE)** | **−7.04% (−29.2M)** | **−5.07%** |

Run F: *"this change allocates nothing and keeps 29M fewer objects alive"* —
GC time covered 91% of the wall delta, majors 13→10, max RSS −13.2%. K7 then
took subst a further −2.0% at −2.5% promotion.

The explanation is the collector's cost model: a copying nursery pays for
**survivors**, not allocation volume. Dead-on-arrival objects cost one
inlined bump-pointer increment (HEAP_034) and are never touched again.

**Consequence for this file:** §4's residual-cons composition — the table
that ranked U-T2.1′ first — measures a quantity the collector does not
charge for. It is retained below as a record of *where cons cells come
from*, which is still true, and not as a priority ordering, which it never
validly was.

## 4. Residual Cons composition (record only — chunks-on census, post-K2)

`ECO_CONS_SITES` return-address tally on the flag-on census run:

- **`toComparableFragments` 158.3M** — still the #1 cons site, ~10× the next.
  Superseded as a *target*: K4 removed 143.2M Cons here and **objects
  promoted were identical**, wall flat. Measured nursery garbage.
- **Sub-4-element lists ≈61M** (kernel `reverse` n<4 cells fallback,
  LTO-inlined into the specs) — below any chunk threshold by design;
  irreducible.
- **Lambda/tail-inline long tail ≈150M** — the tail-inline share is
  capturable by function-level templates; the closure-mediated foldr-family
  share (λ≈7.7 papExtend traffic) is uncapturable without defunctionalization
  (U2b/H7 NO-GO precedents apply). Parked.
- Thin kernel tail: `append` cells 5.8M, `String.split` 5.5M, `map2` 4.8M.

**Stale citation warning, carried forward:** the old borrow-oracle figure
"`List.cons` is the #1 owned kernel site (4,175 defaulting call sites)"
predates chunks — much of that traffic now routes through chunk builders.
Re-run the borrow census flag-on before quoting kernel-site numbers.

## 5. Lessons carried into the successors

Each successor plan restates the ones it is exposed to; collected here
because they were learned in this tier's territory:

- **Inliner interactions are real, twice over.** `MonoInlineSimplify`
  threshold-inlining silently defeated the L1 shunts until the blacklist was
  upgraded to full non-candidacy — any new template/shunt symbol must join
  the Generate blacklist when `list.chunks` is on. Body-copying rewrites need
  `freshenLetBoundNames` (duplicate-let SSA-redefinition lesson).
- **`annotateCallStaging` is O(2^let-in-bound-depth)** (GlobalOpt phase 5) —
  any pass that wraps bodies in lets needs the `elm-aws-codegen` canary.
  `plans/cse-pure-calls.md` is the most exposed of the four.
- **Census legs are mandatory when a change moves allocation**
  (`ECO_INLINE_ALLOC=0`) — the standard counter misread the same class of
  change twice. Retention metrics do **not** have this problem, because
  promotion is counted inside the collector; see
  `plans/live-heap-composition-census.md` §1.
- **Never report a wall without its major count** (GC-trigger lottery).
- **Static censuses of "how many sites have shape X" have collapsed at the
  admissibility gate four consecutive times.** The upside has always come
  from dynamic heat evidence. Every successor plan gates on a dynamic join.
- E2E/elm-tests cache race: serialize; run E2E once, teed, and grep the file.
