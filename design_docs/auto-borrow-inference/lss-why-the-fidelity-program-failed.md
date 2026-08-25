# Why the LSS fidelity program netted +0.02 pp, and what the paper does that we don't

**Date:** 2026-08-23. **Status:** diagnosis, evidence-backed. Written after
`plans/lss-gap2-callarg-transport.md` finished as a NO-GO, at which point the
question stopped being "which gap next" and became "why does closing gaps not
move the number".

Three independent lines of evidence — the paper's algorithm, Eco's
representation, and fourteen months of measured plan outcomes — converge on
one answer. This document states it, with the numbers that force it.

---

## 1. The scoreboard

Dispatch coverage = `fast / (sat + fast)`, statically-stamped direct `$cap`
calls over total closure dispatches.

| what | Δ coverage |
|---|---|
| The entire GAP-1…GAP-9 fidelity program (≈10 plans, 14 months) | **+0.02 pp** |
| Changing `maxSpecsPerGlobal` from 64 to 512 (one integer) | **+13.4 pp**, and −3.6% production wall |

Of the eight register items executed, seven produced no measurable dispatch or
wall movement. Three landed with a real gain in the whole record: E2.7 staged
stamping (+3.62 pp, a *consumer* change), Fix B / LSS_017 (+6.4 pp, an
*identity* change), and the budget integer (+13.4 pp, a *policy* change).
**Not one of the three was a flow/transport repair.** Every flow repair —
sigFlow symmetric (−26.7% rel), LSS_023 directed (−12.6% rel), LSS_026
callArgFlow (−0.51 pp) — regressed the metric it was built to improve.

## 2. The deficit is at the two ENDS of the pipeline; every plan worked on the middle

**Producer end — the pipe is empty.** Of 11,538 signature zonk events at HEAD
with every flag on:

| class | count | share |
|---|---:|---:|
| `allflex` — has arrow slots, body contributed **nothing** | 7,218 | **62.6%** |
| `bodyless` | 2,388 | 20.7% |
| `arrowfree` | 1,538 | 13.3% |
| **`carrying`** | **321** | **2.8%** |
| `hasTop` — explicitly widened | 73 | **0.6%** |

96.6% of definitions state nothing about their own lambda sets. The
`allflex : hasTop` ratio is **100 : 1** — for every set we knew and gave up
on, there are a hundred we never learned. The founding census (2026-07-16) put
it at 99 : 1. **Fourteen months moved that ratio by nothing.**

Readback side, same picture: of 422,403 classified set readbacks, `flex`
(never written) 39.8%, `poison` 36.2%, `set` 24.0% — and much of that poison
is unconstrained-⊤ laundered into an explicit write one hop later (the plan's
own HOP-3). **52.3% of everything that reads ⊤ was never written at all.**
78.5% of all minted arrow slots are never written by anything, ever.

**Consumer end — the pipe is capped at width one.** `maxSetSize` 8 / 16 / 32
produce a **byte-identical compiler**. Multi-member sets are 0.29% of the
population and have no default-on consumer: every exploitation path
(AbiCloning's stamp arms, E9/E9.1/E9.2/E9.5 devirt) requires `|set| = 1`.

Put those together and you get the signature that repeats in every failure:
**adding true set information to a singleton-only consumer is net-destructive.**
An honest union at a hub turns an honest singleton into an honest 2-set, which
the consumer declines. That is why three correctly-implemented precision
improvements all regressed.

## 3. What the paper does that we do not

The paper (Brandon et al., PLDI 2023) has **no ⊤, no widening, no unknown, and
no unresolved case** — not as an optimization, but as a structural consequence
of three choices:

1. **The lambda set is a type-level variable inside the arrow constructor**
   (`τ₁ --σ--> τ₂`, Fig. 2, 146:6). It moves only by unification. TIU-App
   (Fig. 5, 146:10) emits a *whole-arrow equality*
   `(τ₁ --α₁--> τ₂) ∼ (τ₃ --α₂--> τ₂)`; the sets get tied as a byproduct of
   unifying the types. There is no separate transport mechanism because
   transport is not a separate thing.

2. **Stored signatures are FULLY FLEXIBLE — every set position is a
   ∀-quantified variable, never a concrete set** (146:10, the inductive
   invariant). This makes "concrete ∼ concrete" — the only case that would
   force a join — *unreachable by construction*. No join operator exists
   anywhere in the algorithm.

3. **"Not yet known" is exported as a PARAMETER, not committed as a value.**
   Unresolved variables are promoted to `∀ᾱ. Q ⇒ τ` and deferred *up* to
   callers; only variables that provably cannot escape are internalized, to
   the **minimal** solution (default ∅ — bottom, not top; Fig. 7, 146:11).
   The deferral terminates because the entry point's type contains no arrows
   (AT-Entry, 146:7), so every deferred variable is eventually paid off by a
   caller.

**Eco inverted all three.** Sets are ground `List Int` committed at the
definition; unknown-ness is committed *downward* as ⊤ rather than exported
*upward* as a parameter; and the entire LsTop / widening / `maxSetSize` /
budget lattice exists only to cope with having to guess early.

`ArrowFact.sources` (LSS_023) is a partial re-invention of the ∀-parameter —
but as an inclusion edge between *ordinals*, resolved by a pull-at-read
fixpoint, and only at loader-enumerated arrow positions. It is the right idea
in a representation that cannot carry it.

## 4. The mechanical root cause: sets do not travel with the type

Eco actually gets the hard part right. The set slot **is** a real union-find
node (`FunL arg result slot`, `IO.elm:654-662`), and unifying two arrows
**does** unify their slots (`Unify.elm:732-736`). If types were shared, sets
would propagate for free, exactly as in the paper.

They are not shared. `Store.loadTypeC` **mints fresh arrow structure on every
load**; the per-item memo is consulted in exactly one place — `loadVarC`, for
`Can.TVar` leaves only (`Store.elm:294-317`). That is invariant LSS_006. So:

- two loads of the same canonical type share their leaf vars and **nothing
  else** — their `FunL` nodes and set slots are disjoint UF classes;
- two loads of a **ground** type share *literally nothing*.

**Why it cannot be fixed by memoising harder: `Can.TLambda` has no identity.**
Canonical types carry ids only at `TVar` leaves. An arrow is a structural node
with nothing to key a memo on. The paper's arrows each carry their own σ
variable — the arrow *is* identified, by its set variable, once per type
rather than once per load.

Everything downstream follows from that one fact:

- ≥10 hand-written "reconnect" sites exist solely to re-tie slots that a
  shared representation would never have split (`injectArgLambdaMember`,
  `demandUnifyRoot`+`lssRootAnn`, `joinLetUse`, `unifyCallShape`,
  `connectArgFlow`, `connectTypes`, the TailDef branch, …). Each is a place a
  leak can hide, and the GAP register is largely a catalogue of them.
- The self-id filter (B.1.f) *removes* each def's own identity from its
  signature, because identity is instead injected translate-side at syntactic
  argument positions. Identity delivery is syntactic, not type-directed.
- The 62.6% `allflex` mass is dominated by positions the ordinal/slot scheme
  **structurally cannot express** — chiefly type-variable positions.
  `always : a -> b -> a` builds no closure; its honest statement is
  "result ⊇ param 0"; `loadTypeC` mints slots only at syntactic `TLambda`
  nodes, so **there is no slot to link**. The register named this twice and
  skipped it twice as "a deep change, not a counter-sized one".

## 5. The measurement that makes this concrete

The unresolved dispatch is not a diffuse long tail. It is a handful of
closures, and **they are trivially resolvable in principle**:

| | share of all generic dispatch |
|---|---|
| top 10 function pointers | **33.7%** |
| top 50 | 66.0% |
| top 200 | 91.8% |

| gen dispatches | `papCreate` sites | closure |
|---:|---:|---|
| 179,693,407 | **1** | `Terminal_Main_lambda_14760` — created in `System_TypeCheck_IO_andThen` |
| 72,733,782 | **1** | `Terminal_Main_lambda_14756` |
| 63,559,710 | **1** | `Terminal_Main_lambda_38219` |
| 59,115,789 | **1** | `Terminal_Main_lambda_14772` |
| … | | (all of the top 12 have exactly one, bar one with two) |

**620 M generic dispatches — 27% of all dispatch — on twelve closures, each
constructed at exactly ONE site in the entire program.** There is no aliasing
ambiguity to resolve. Under the paper's algorithm these are settled by pure
unification along the path from creation to call.

And the analysis already *knows* the answer in at least one case:
`IO.andThen`'s signature carries `ordinal 3: m=1,l` — one lambda member, no
sources, no ⊤. That **is** `lambda_14760`. The fact is computed, and 179.7 M
dispatches still go out generically, because the path from that signature to
the dispatch site crosses `loadType` boundaries that mint disjoint slots.

A corroborating detail from the same run: when LSS_026's transport *did*
deliver information, it arrived and was **discarded at the last step** —
`declinedNoInstance` rose 1,091 → 1,203, exactly +112, the transported
singletons landing at AbiCloning with no instance to stamp.

## 6. The second failure mode: static counters have never predicted runtime effect

| static claim | runtime reality |
|---|---|
| `declinedNoInstance +133`, "NOT material" | one of them was the artifact-decode loop → **44 M events** |
| `byKernel` 4,065 → 1,575 (−61%) | singletons and devirt identical **to the digit** |
| `grounded = 4,955`, GAP-1 closed | every downstream counter unmoved, `out.mlir` +213 B |
| singletons **+10.7%**, `edges` 177 → 16,896 | `devirtDirect` FLAT, coverage **down** |
| `declinedBlocked` 156 → **0** | **0.000 pp** |

The register names the unit error itself — *"site counts and event counts are
different units"* — and then keeps deciding in site counts. Relatedly, three
causal attributions for the callArgFlow regression have now been proposed and
**all three refuted by measurement**; the mechanism is still unknown, and
per-site *dynamic* attribution (`plans/lss-gap2-callarg-transport.md` §11.6)
has never been built.

## 7. What to keep from the GAP-2 plan

**Keep:**
- **LSS_026(a), honest ∅-as-source, unconditional.** It fixes a *real
  miscompile* (`test/elm/src/LssMixedSigHonestyTest.elm` printed
  `[42,42,42]` for `[41,42,82]` at the shipping default). This alone
  justifies the plan.
- The three pin files and the runtime fixture.
- The census instrumentation (`ARGF` rows, zonk-cause split, `blockedMembers`
  probe). Every real finding in this document came out of it.
- The written record, **especially the refutations**.

**Deleted (2026-08-24):** D1/D2 — `connectArgFlow`, `flowArgWp`, the
`ArgStash` carrier, the `itemAux` pending slot, the four behaviour counters,
and the `lss.callArgFlow` flag with its env override and hash token. They were
scaffolding around LSS_006 — hand-reconnection of slots that should never have
been split. Under the representation fix in §8 the problem they solve *ceases
to exist*, and meanwhile they cost +2.68% wall and −0.51 pp for no consumer.
Keeping them dormant would have implied the approach is merely awaiting a
consumer; it is not. `LSS_026` in the register is now clause (a) only, with
the transport's measurements preserved as a history clause; `LssCallArgFlowTest`
was reduced to its D0 content and renamed `LssHonestSourcesPipelineTest`.

## 8. What to do instead, ranked by measured mass

**Step 0 — cheap validation, do this first (hours, not days).** Take
`lambda_14760`: one creation site in `IO.andThen`, 179.7 M generic dispatches,
and a signature fact that already names it. Trace by hand why the set does not
reach the dispatch site. If the answer is "it crosses N `loadType` boundaries
that mint disjoint slots", §4 is confirmed on the hottest object in the
program and the fix in step 1 is justified by direct evidence rather than by
inference. **This session refuted two confident attributions built on
aggregate counters; do not add a third.** Trace the object.

**Step 1 — give arrows identity in the canonical type.** The paper's
`ℱ(t₁ → t₂) = ℱ(t₁) --α--> ℱ(t₂)` assigns α **once per type**, not once per
load. The Eco analogue is to extend `Can.TLambda` with a set-variable id
assigned where the annotation is created, so `loadTypeC` can memoise arrows
the way it already memoises `TVar` leaves. Consequences: the ≥10 reconnect
sites become redundant; A.1 / GAP-2 / GAP-9 close *by construction* rather
than by hand; and slots become available at positions the ordinal scheme
cannot currently reach. This is the change the register twice called "deep"
and twice skipped, and it is the one that owns the 62.6%.

**Step 2 — make "unknown" a parameter rather than ⊤.** Once arrows have
identity, `ArrowFact.members : List Int` can become a genuine set *variable*
with the paper's fully-flexible-signature invariant, and the ⊤/widening
lattice can start to retire. This is the substantive fidelity item and it
depends on step 1.

**Step 3 — sum lowering (GAP-6).** The only consumer that makes multi-member
precision worth an instruction. Currently declared NO-GO on evidence that was
itself a *producer* measurement ("multi-member sets don't form") — a circular
argument the register flagged and never resolved.

**These three steps are now a plan: `plans/lss-unknown-elimination.md`**
(2026-08-24), sequenced LUnknown → arrow identity → set variable, with the
11 retirable transport artifacts enumerated, the 10 decision points and 8
hazards of the AST change recorded, and Phase 3 explicitly marked as an
outline rather than a work order.

**Also on the table, and cheaper than all of the above:** the `IO (\state ->
…)` idiom is **68.6%** of all generic dispatch, and one function
(`readPointCell`) is ~8% by itself. A direct state-passing rewrite at the
*source* level would delete the hottest object in the program without any
analysis improvement at all. No plan file exists for it. Given the record —
one integer beat fourteen months of analysis work — this deserves to be costed
before another analysis plan is written.

---

## Sources

Measurements: `/work/lss-unresolved-dispatch-attribution.txt`,
`/work/lss-gap2-d2-argflow-{on,off}.census`,
`/work/lss-gap2-dispatch-{on,off}.tsv`, `/work/lss-gap2-phase0-census.txt`,
`benchmarks/lss-opt.md` (Runs X, AB–AG), `benchmarks/runtime-calls.md`,
`/work/lss-knob-sweeps-report.md`.
Paper: Brandon et al., *Better Defunctionalization through Lambda Set
Specialization*, PLDI 2023 —
`design_docs/auto-borrow-inference/lambda-set-specialization.pdf`.
Register: `design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md`.
