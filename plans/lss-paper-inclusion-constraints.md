# LSS §4 the paper's way: inclusion constraints `Q`, quantified set variables `ᾱ`

**Status: PROPOSED, 2026-08-25. §0 is a measured reproducer that already exists;
§1 is what the paper says; §2 is where we diverge, quoted from our own fidelity
audit. §5 is the build.**

**Directive this plan serves: follow the paper.** Every design choice below is
justified by a citation into `design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md`
(itself keyed to Fig./page:line of the paper), not by what is locally convenient.
Where Eco must diverge because Elm is not L^src, the divergence is named as a
divergence and its soundness argued separately.

---

## §0 The two gaps, MEASURED

Reproducer in the tree: `test/elm/src/LssTaskSetProbe.elm` (runs green,
`r: [42, 40]`; it is a *correctness* pin today and becomes the *precision* pin
when this plan lands). Census under `ECO_MONO_LSS_REPORT=1`:

| probe | shape | `kN` | multi-set arrows |
|---|---|---|---|
| `[ incr, decr ]` | two top-level GLOBALS in a list | **0** | 0 |
| `[ Just incr, Just decr ]`, `[ Ok incr, Ok decr ]` | globals inside containers | **0** | 0 |
| **`[ \x -> x+1, \x -> x-1 ]`** | two LAMBDAS in a list | **2** | **2** (`MSET 5 2 ?6\|?7`) |
| `[ Task.succeed (\x -> x+1), Task.succeed (\x -> x-1) ]` | the same lambdas through Task | **0** | 0 |
| `[ Task.succeed incr, Task.succeed decr ]` | the original | **0** | 0 |

`set-writes: union = 0` in EVERY arm — no slot ever receives a second member.
And it is not kernel poison: the same runs report `widened byKernel = 2`,
`kernelLicensed = 22`, `kernel licenses REFUSED at the occurrence: (none)`.

### §0.1 GAP-A — a global reference's label never reaches the position

`LssInfer.standaloneMemberWith` (`LssInfer.elm:2099`) is the whole mechanism:

```elm
standaloneMemberWith depthOf mint meta s0 =
    if canTypeIsArrow meta.tipe then
        … Store.loadType meta.tipe … injectSpineMemberId (depthOf s2) mid funcVar …
    else
        Ok ( WpNone, s0 )
```

It mints the member and injects it into a slot obtained from a **fresh
`Store.loadType`** — and LSS_006 is precisely that `loadType` mints DISJOINT
slots per load. So `ℓ_incr` lands in a slot that is not the slot of the position
`incr` flows into, and reconnection depends on whichever of the ~11 hand-written
transport hooks happens to fire. A lambda has no such problem: its member is
injected into the arrow of its own expression node, which IS the position.

**In the paper this step does not exist.** A reference to `g` instantiates `g`'s
signature, and the label is already in the instantiated type. There is nothing to
inject and nothing to reconnect.

### §0.2 GAP-B — a set does not survive instantiation of a type variable

Row 4 of the table is the sharp one: the SAME two lambdas form `{ℓ₁,ℓ₂}` in a
bare list and form NOTHING once routed through `Task.succeed`. Its signature is
`a -> Task x a`; computed over the POLYMORPHIC type, `a` has no arrow structure,
so the signature has no arrow fact to carry (`signatures: 30 memoized (17
trivial)`). The caller instantiates `a := Int -> Int` and the arrow exists only
at the call site, after the signature has already said nothing.

#### §0.2.1 LOCALIZED (§5.0 discharged) — the site, with census evidence

The probe's own census names it. **Every callee on the path has a TRIVIAL
signature:**

```
ARGF  pop|calleeTrivial=1                     5      <- 5 of 5 populated sites
ARGF  popt|elm/core:Task.andThen|triv=1       1
ARGF  popt|elm/core:Task.onError|triv=1       1
ARGF  popt|elm/core:List.map|triv=1           1
ARGF  popt|elm/core:Basics.composeL|triv=1    2
ARGF  calleeTriv|g:elm/core:Task.attempt|triv=1
```

and `applyFacts` (`LssInfer.elm:210-212`) short-circuits on exactly that:

```elm
applyFacts global sig slots funcVar s0 =
    if sig.trivial then
        Ok ( (), s0 )          -- the caller's instantiation is linked to NOTHING
```

Triviality is decided in `zonkSigGo` (`LssInfer.elm:731-737`):

```elm
trivial =
    List.all identity
        (List.indexedMap
            (\j f -> f.rep == j && not f.top && List.isEmpty f.members && List.isEmpty f.sources)
            facts)
```

**`facts` is indexed by ARROWS IN THE DECLARED TYPE.** For
`Task.succeed : a -> Task x a` the declared type has exactly ONE arrow — the
outer one. The two `a` positions are bare type variables, not arrows, so they
contribute no fact at all. One arrow, `rep == 0`, no top, no members, no
sources ⇒ **trivial** ⇒ `applyFacts` does nothing ⇒ the lambda's member has
nowhere to go.

**This is the paper's α, stated as an absence.** `ArrowFact.rep` can say
"arrows *i* and *j* of the declared type share". It cannot say "the arrow that
type variable `a` *becomes* is shared between the parameter and the result",
because at signature time `a` is not an arrow. The paper writes that as
`succeed⟨α⟩`, where α rides the type variable and materialises when `a` is
instantiated to `τ₁ --α--> τ₂`.

**Ruled OUT by the same census**, so §5.2 need not chase them: the
arrow-count-mismatch poison never fires (`poison|lenGuard` rows absent), and
kernel poison is not involved (`widened byKernel = 2`, `kernelLicensed = 22`,
`REFUSED: (none)`).

#### §0.2.2 The general statement — and a CORRECTION to §0's table

Two further probes isolate it, and they correct a mis-attribution in §0's own
table. §0 read "lambdas form a 2-set, globals do not". **That was wrong** — the
probe that produced `kN=2` contained BOTH a list literal and an `if`, and the
set came from the `if`. Split apart:

| construct | `kN` |
|---|---|
| `pick b = if b then (\x -> x+2) else (\x -> x-2)` — control-flow join | **2** |
| `[ \x -> x+1, \x -> x-1 ]` — list literal, same lambdas | **0** |
| `[ idf (\x -> x+1), idf (\x -> x-1) ]` — through `idf : a -> a` | **0** |

The census explains both outcomes in one line each:

```
SplitB  sigfacts|author/project:SplitB.pick|0|m=2,l     <- arrow 0 carries TWO members
SplitA  sigfacts|elm/core:List.cons|1|m=1,k             <- facts for the SPINE only
```

`pick : Bool -> (Int -> Int)` transports because its set lives on a **real arrow
in the declared type**. `cons : a -> List a -> List a` does not, because its
facts describe its own arrow SPINE and the element `a` — where the set lives —
is not an arrow in the declared type at all.

**So there is ONE root cause, and it is pervasive.** Any set living inside a
TYPE VARIABLE has no fact, the signature is trivial or all-flex at that
position, and `applyFacts` transports nothing. That single mechanism accounts
for every failing row: `List.cons` (hence **every list literal**),
`Task.succeed`/`andThen`/`attempt`, `List.map`, `Basics.composeL`, and
`idf : a -> a`.

Control-flow joins are the exception ONLY because `TOpt.If`/`Case` bypass
signatures entirely via an explicit `joinCfHub` (`LssInfer.elm:1324-1340`).

**METHOD NOTE, third occurrence this register.** §0's table, the `Task.perform`
bisect (`plans/task-perform-value-msg-segfault.md`), and this correction all came
from a probe that moved two variables at once. Vary ONE thing per probe; prefer
an instrument that names the site (census row, gdb frame) over inference from an
A/B.

---

### §0.3 THE RESCOPING MEASUREMENT (task #40, 2026-08-25) — arrow identity ALONE closes both gaps on the probes

Before building `ᾱ`, the cheaper hypothesis had to be tested: is the sharing
already available, and merely switched off? It is.

| arm | `[ \x->x+1, \x->x-1 ]` (list literal) | `LssTaskSetProbe` (globals through Task) |
|---|---|---|
| shipping defaults | `kN=0`, arrows=0 | `kN=0`, arrows=0 |
| **`ECO_MONO_LSS_ARROW_ID=1`** | **`kN=1`, arrows=1, `byK=2->1`** | **`kN=4`, arrows=1, `byK=2->1`** |
| `+ ECO_MONO_LSS_ARROW_ROOTS=1` | identical to arrowid | identical to arrowid |

And the members are exactly the ones in question:

```
SplitA  MSET 1592 2  l|0|L(A(I->I)) | l|1|L(A(I->I))
Task    MSET 1649 2  g|...LssTaskSetProbe.incr|A(I->I) | g|...LssTaskSetProbe.decr|A(I->I)
```

**Three consequences, and they rescope §5.2 substantially.**

1. **The mechanism is LSS_006 slot-disjointness, NOT a missing set variable.**
   `loadType` mints a fresh slot per load; `arrowIdentity` makes a repeated load
   of the same stamped type object reuse the slot the first load minted
   (`Store.elm`, `Can.TLambda` arm). `loadVarC` ALREADY memoizes `TVar` by
   MVarId — the hole is only at `TLambda`, which is exactly where the set lives.
2. **GAP-A is fixed by the same switch.** The Task probe's 2-set is over
   `incr`/`decr`, top-level GLOBALS. So §5.4's "references instantiate, they do
   not inject" may reduce to the same cause rather than a separate repair.
   RE-MEASURE before building it.
3. **`ARROW_ROOTS` adds nothing on these programs** — solver-root identity is
   about cross-item stability, which two lambdas in one module do not exercise.
   It stays required for `Q`'s keyspace (§4), not for this.

**What is NOT fixed, and it is the honest limit of this result.**
`multiSetSites` remains `(none)` in every arm: the set forms at an ARROW but
never reaches a DISPATCH SITE. In the Task probe the applied call site
(`case msg of Got (Ok f) -> f 41`) sits downstream of `Platform.sendToApp` —
genuine CROSS-CALL, correctly poisoned, and not something a set variable can
carry across.

**So the critical path is not `alpha-bar` — it is the two things keeping
`arrowIdentity` default-off:** the measured -0.50 pp fast-dispatch regression
(Run AE: 99% of it at ONE de-stamped site) and LSS_031's self-compile lowering
defect. Both are prerequisites to shipping what this measurement shows already
works.

---

## §1 What the paper actually requires

From the fidelity mapping §1 (paper Fig. 2, 146:6–12):

1. Every function type carries a set: `τ₁ --σ--> τ₂`, with
   **`σ ::= {ℓ₁,…,ℓₙ} | α | μa.σ | a`**. Concrete sets of lambda terms, set
   **variables**, μ-recursive sets. **There is no ⊤.**
2. Defs get polymorphic signatures **`d⟨ᾱ⟩ : (Q ⇒ τ)`**, where `Q` is a set of
   **inclusion constraints `ℓ ⋸ σ`**.
3. **Unification only ever equates set variables.** It does not union.
4. Variables not reaching the signature are **internalized** to the minimal
   solution **`S(Q,α) = {ℓ | (ℓ ⋸ α) ∈ Q}`**, with **μ** introduced when α
   occurs in its own constraints (146:11).
5. A provisional-type rule **(Σ)** forces recursive self-references to the
   current def's own type, so inference **never emits polymorphic recursion**
   (Thm 4.1, 146:12).
6. Specialization (§5) makes one fresh `d_spec` per distinct `σ̄ ∈ uses(d,π)`
   (Mono-Used, Fig. 9).

Points 2–4 are one mechanism: **defer the facts into `Q`, quantify the
variables, solve minimally at the boundary.** Both gaps in §0 are consequences of
not having it.

---

## §2 Where Eco diverges — quoted from our own audit

`lss-paper-fidelity-mapping.md`, verbatim ratings:

| paper element | Eco today | rating |
|---|---|---|
| inclusion constraints `ℓ ⋸ σ`, constraint set `Q` | "none accumulated — `unifySlotWithSet` **eagerly unions** members into slots"; "eager solving computes the paper's minimal solution `S(Q,α)`, but only because signatures are ground (GAP-2); **nothing is deferrable**" | **PARTIAL** |
| set variable `α` | "`FlexVar` slot Points **during solving only**; zonked to ground facts, **never in signatures or annotations**" | **PARTIAL** — "transient, item-local" |
| "same α at two positions" in a signature | `ArrowFact.rep`, an ordinal | **PARTIAL** — "the *sharing structure* of a polymorphic signature **without symbolic elements**" |
| TIU unification of set variables | `Unify.elm` FunL×FunL subUnifies slots; LambdaSet1×LambdaSet1 **total join** | FAITHFUL *for the ground fragment* |

Read together these say one thing: **Eco solves eagerly because it has nowhere to
defer to.** Eager solving is only equivalent to `S(Q,α)` when every fact is
present at the moment two slots meet. GAP-A is a fact that arrives in the wrong
slot; GAP-B is a fact that arrives after the signature was computed. Both are
"too late" for a system with no `Q`.

---

## §3 The design

### §3.1 The deferral target is a SCHEME, not a list — and its boundary is REACHABILITY

**CORRECTED 2026-08-25.** An earlier draft of this section said "add a per-def
constraint store `Q : List (Member, SetVar)`". That is not a place to defer to.
For a constraint to be DEFERRED rather than merely LOGGED, three things must
hold: it can be recorded without knowing the answer; it **survives to a boundary**
where the answer becomes knowable; and that boundary is a defined moment with a
defined action. A list gives only the first. Solved at the same instant the eager
union would have fired, `Q` is a log.

**What is missing is the boundary. The paper's boundary is REACHABILITY, and
it is NOT ranks.**

CORRECTED 2026-08-25, after building ranks and reverting them (§5.0b below).
An earlier draft of this section argued the boundary "needs ranks", reasoning
from `Engine.freshVar`'s *"single fixed engine rank… No generalization happens,
so any fixed rank is safe"*. That reasoning was about HM implementation
technique, not about the paper. The paper states its criterion directly:

> *"variables **not reaching the signature** are internalized to minimal
> concrete solutions `S(Q,α) = {ℓ | (ℓ ⋸ α) ∈ Q}`"* — §1, 146:11

That is an OCCURRENCE TEST on τ. Ranks (Rémy's levels) are one efficient way to
compute such a test when generalization scopes NEST and share a store — and the
paper has **no nested generalization scopes**: it generalizes at the def and
nowhere else, because L^src has no let-generalization at all (GAP-9: *"the
paper has no let-generalization"*). So a faithful implementation never needs
ranks, and `freshVar`'s fixed rank is not a precondition this plan has to
invalidate.

**The partition to build is therefore:** walk the signature's own slots,
collect the set variables they reach, and split the def's minted variables into
reaching (quantify into `ᾱ`) and not-reaching (internalize via `S(Q,α)`).

**What already defers, and to where:**

| candidate | lifetime | verdict |
|---|---|---|
| `LsFrom` / slot `sources` (LSS_023) | per-item store; `resetItem` installs `freshStore` | REAL deferral, WRONG SCOPE — defers to *read time*, dies at item end |
| `LssSignature.ArrowFact.sources` | `lssSignatures` is GLOBAL, "survives the whole run" (`Engine.elm:1062`) | **the closest existing thing to `Q ⇒ τ`** — start here |
| ranks / pools in the mono engine | — | absent — and NOT needed; see the correction above |

**Why the in-tree precedent MISLEADS here.** `Compiler/Type/Solve.elm` is
*"Algorithm W with rank-based let-polymorphism, using pools to track variable
scopes"*, and `Unify.merge` already does `min desc1.rank desc2.rank`. It is
tempting to read that as "the discipline already exists, apply it to set
variables" — and §5.0b did, and it was wrong. The typechecker needs ranks
because Elm's TYPE system has let-polymorphism and therefore nested
generalization scopes. The paper's SET system has neither. Reuse the pools idea
if it is convenient for enumerating a def's variables; do not reuse the rank
criterion.

With the boundary in place, `Q` is then the payload: `unifySlotWithSet`'s eager
union is replaced at the *recording* sites by a `Q` entry, and the union survives
only as the SOLVER's action on `Q` at generalization.

Note what this buys GAP-A directly: `ℓ_incr ⋸ σ_elem` is a fact about a
POSITION, so it no longer matters which slot `loadType` minted — the constraint
names σ, and σ is unified with the element's set variable by ordinary type
unification.

### §3.2 `α` — symbolic, quantified, instantiated

`LambdaSetAnno` already has `LVar Int` from Phase 3 and `Store.varNumberFor`
numbers unwritten slots canonically by union-find repr. That is the
representation half. What is missing is the SCHEME half: `Engine.LssSignature`
must become `d⟨ᾱ⟩ : (Q ⇒ τ)` — quantifying the set variables that reach the
signature and carrying the residual `Q` — and instantiation must freshen `ᾱ`
per use, exactly as type instantiation freshens type variables.

`ArrowFact.rep`'s ordinal is the degenerate case of this and is subsumed: an
ordinal says "positions i and j share"; a symbolic α says the same thing AND
survives being instantiated to an arrow that did not exist when the signature was
computed. **That is GAP-B's fix**, and it is why Phase 3 measured flat on its
own — `LVar` gave the annotation a symbol with nowhere to live.

### §3.3 `S(Q,α)` — internalize at the boundary

At generalization, partition the variables: those reaching the signature are
quantified; the rest are internalized to `S(Q,α) = {ℓ | (ℓ ⋸ α) ∈ Q}`. This is
the paper's minimal solution and is where today's eager union legitimately
survives — as the *solver*, applied once at a defined point, rather than as an
invariant of every write.

### §3.4 `μ` — only where the paper needs it

Introduce `μa.σ` when α occurs in its own constraints (146:11).

**This reverses `plans/lss-set-variable.md` §3's finding**, and the reversal must
be argued rather than assumed. That §3 concluded "µ is NOT re-imported" because
members are flat `Int` ids, so `α ⊇ {f} ∪ α` is monotone over finite flat sets
and ordinary saturation reaches its least fixpoint. **That argument holds only
for the internalized case.** A variable that ESCAPES into a signature can occur
in its own constraints across a recursive def, and there saturation has nothing
to saturate — the constraint is symbolic. §5.4 must decide empirically whether
Elm programs actually produce escaping self-referential α, and skip μ if they do
not. Do not build μ on this paragraph alone.

### §3.5 `Σ` — provisional self-type

Recursive self-references unify against the def's own provisional type. Already
FAITHFUL per the mapping (`LssInfer.elm:18-22, 758-786`, "explicitly labelled
the paper's Σ/TIU-Self-Ref rule"). Preserve it; do not rebuild it.

### §3.6 What ⊤ becomes

The paper has no ⊤. Eco keeps it for exactly one job — the **incompleteness
marker** at the opaque kernel/FFI/port boundary (LSS_004/021/022), which is
Eco's setting and not a representation choice. Every other ⊤ producer
(⊤-as-join-result, ⊤-as-widening, ⊤-as-unknown) is a consequence of eager
solving and should not survive `Q`. `maxSetSize` widening is the honest
exception and stays, as a budget.

---

## §4 What already exists to build on

Do not start from scratch; the substrate is unusually complete.

| piece | where | what it gives |
|---|---|---|
| `ArrowFact.sources` / LSS_023 `LsFrom` | `Engine.elm:80-84`, `Store.elm` | **a proto-`Q`**: deferred inclusion edges resolved at read by `resolveSlotMembers`. This is the closest existing thing to the paper's constraint set and is where §3.1 should start. |
| `LambdaSetAnno.LVar` + `Store.varNumberFor` | Phase 3 | symbolic α that survives the annotation round trip, numbered canonically by UF repr |
| `Engine.LssSignature` / `ArrowFact` | `Engine.elm` | the per-def scheme shape (`rep`, `members`, `top`, `sources`) |
| Σ / TIU-Self-Ref | `LssInfer.elm:18-22, 758-786` | already FAITHFUL |
| solver-root arrow identity | Phase 2b, LSS_031 | stable arrow ids across items — needed to name positions in `Q` |
| the §2.5 ledger + `MSET` census | `Monomorphize.renderLssReport` | the acceptance instrument |
| `LssTaskSetProbe` | `test/elm/src/` | the end-to-end pin for both gaps |

**LSS_031 is on the critical path.** Solver-root arrow identity is what gives a
position a name stable enough to appear in `Q`, and its self-compile still fails
to lower. Fix it first or `Q` has no keyspace.

---

## §5 Phases

**RE-CUT 2026-08-25 after §0.3.** The original §5 treated `Q`/`ᾱ` as the main
line and arrow identity as background. §0.3 measured the opposite: arrow
identity ALONE closes both gaps on the probes, so the main line is making it
SHIPPABLE, and `Q`/`ᾱ` become follow-on work gated on what remains afterwards.
The old phases are preserved below as Phase B, unchanged in content.

Each phase is separately gated and separately revertible.

---

### PHASE A — make `arrowIdentity` shippable (THE MAIN LINE)

§0.3 showed the analysis already works behind the flag. Two measured things
keep it off, and they are the whole of Phase A.

#### §5.A1 — LSS_031: the self-compile lowering defect

`lss.arrowSolverRoots=1` emits MLIR that FAILS TO LOWER on the self-compile:
`'eco.papExtend' op references undefined fast evaluator
'Terminal_Main_lambda_NNN'`. Reproduced on both the 2b arm and the 2b+Phase-3
arm; shipping defaults lower clean.

**Gate gap this exposes, and the reason it cannot be skipped:** E2E
`--target full` passed 1,687/1,687 with the flag ON, because E2E is small
programs. Only the self-compile is large enough to produce the bad stamp. Any
change to lambda-set identity must be gated on a self-compile LOWERING, not on
E2E.

First hypothesis per LSS_031: solver-root sharing maps two distinct lambdas
onto one member id, and AbiCloning picks a representative whose instance does
not survive pruning (`multiInstanceGroups` and `declinedBodyMismatch` both grow
under sharing).

#### §5.A2 — the −0.50 pp dispatch regression is ACCEPTED, not fixed here

**STANDING DIRECTIVE, restated because this register keeps re-deriving it as a
blocker and it is not one:** a regression from a SINGLETON to a MULTI-SET is
fine. The goal of this arc is to get the LSS ANALYSIS correct. The benefit is
reaped later by multi-set lowering
(`plans/lss-sum-lowering.md`). Do not gate analysis work on dispatch
coverage in between those two points.

Run AE attributes the regression completely and the attribution CONFIRMS it is
the benign kind:

> *"the shared slot unions what per-load minting kept apart, the singleton
> becomes a multi-member set, and every devirt arm declines it"* —
> `multiSetSites` 0 → `2->2`

99.0% of the loss is ONE site (`lambda_15169$cap`, 11,515,632 dispatches,
`sat=0 fast=11.5M` flag-off — a closure reached ONLY by static stamp), and
flag-on that exact magnitude reappears as `gen`. The singleton was an artifact
of per-load slot minting keeping apart two things that are genuinely the same
arrow; the 2-set is the HONEST answer. Losing a false singleton is not a
precision loss.

So: **record the delta, do not fix it, do not let it block the flip.**

**THE ONE DISTINCTION THAT DOES BLOCK.** A lowering FAILURE is a blocker
(LSS_031 — the compiler emits MLIR that will not lower, i.e. it does not
work). A dispatch REGRESSION is not (the compiler works and is temporarily
slower on a metric another plan owns). Keep those apart.

#### §5.A3 — flip `arrowIdentity` default-on

Gates — note what is and is NOT required:

- **REQUIRED: the self-compile LOWERS.** This is the blocker class (§5.A2).
- **REQUIRED:** elm-tests at the pre-existing failure set; E2E `--target full`.
- **RECORDED, NOT GATED: the dispatch A/B.** Run it with the `sat + fast`
  invariance rail and write the delta into `benchmarks/runtime-calls.md`. A
  regression is EXPECTED (§5.A2) and does NOT block the flip.
- **RECORDED, NOT GATED: the corpus md5.** It is expected to move —
  `c9ae525e2601518c50696d2929ab40b8` was the analysis-neutral baseline, and
  this is deliberately an analysis change. Record the new one.
- **REQUIRED: the ledger/MSET census moves the right way** — `kN` UP,
  `multiSetSites` non-trivial. That is the actual acceptance signal for this
  phase.

#### §5.A4 — re-measure the gaps

With arrow identity shipped, re-run §0's probe table and the frozen-corpus
ledger. **This decides whether Phase B is needed at all**, and in what scope.
Specifically: does anything still fail to transport that is not the
`Platform.sendToApp` cross-call boundary (which no set variable can cross)?

---

### PHASE B — `Q` and `ᾱ` (FOLLOW-ON, gated on §5.A4)

Preserved unchanged. Two of these may shrink or dissolve once §5.A4 reports —
§5.2's scope depends on whether any set-carrying position remains untransported
after arrow identity, and §5.4 (GAP-A) may already be closed by it (§0.3
consequence 2). RE-MEASURE BEFORE BUILDING EITHER.

### §5.0 Localize GAP-B — MEASUREMENT, NO CODE

Trace one readback through `Task.succeed (\x -> x+1)` and name the exact site
where the lambda's member stops. Options: the wrapper's signature application
(`applyFactsGo`), the annotation round trip, or the store's per-call
instantiation. **Do not proceed to §5.2 on the §0.2 hypothesis alone.**

Deliverable: the site, quoted, as §0.2 quotes GAP-A's.

**DISCHARGED — see §0.2.1 and §0.2.2.** The site is
`LssInfer.zonkSigGo:731-737` (facts indexed by declared-type SPINE arrows) plus
`LssInfer.applyFacts:210-212` (short-circuits on `sig.trivial`). One root cause,
covering list literals as well as the Task path.

### §5.0b Ranks and pools — TRIED, MEASURED, REVERTED (do not rebuild)

**BUILT 2026-08-25, gated byte-identical, then REVERTED. The revert is
correct; do not rebuild.** §3.1 says why: ranks are Rémy's technique for NESTED
generalization scopes, and the paper has none — one boundary, the def, because
L^src has no let-generalization. The partition `S(Q,α)` needs is an occurrence
test, and §5.1/§5.3 do it directly.

**The findings survive the revert, and they are the phase's actual output:**

1. **The def-level partition is EMPTY, by any mechanism.** Measured
   `escaped = 0` over 27 defs and 1,064 set variables:
   `Engine.withScratchStore` gives each unit a FRESH store, so no variable can
   unify across a def boundary in the first place. §5.3 must not expect a
   def-level partition to separate anything by scope; the separation it needs
   is occurrence in τ.
2. **The candidate set does not need pools either.** "Which variables might be
   internalized" is answered by `Q` itself — every σ a constraint mentions.
   No side bookkeeping, no `LssGen`.
3. **The rails are proven, ~90 min.** Four-arm frozen-corpus byte-identity via
   a temporary one-source switch; `eco-boot.js`, NOT guida (guida OOMs at a
   12 GB node heap — proven independent of the change under test, because the
   OFF arm failed identically); build arm binaries under
   `ECO_MONO_ENGINE=subst`, since both engines self-host byte-exact.
4. **`c9ae525e2601518c50696d2929ab40b8` is the standing corpus baseline** —
   `ph0-Ap.mlir`, spanning the 35 kernel licences and everything since. Any
   analysis-only change must still produce it.

### §5.1 `Q` in shadow mode

Accumulate `ℓ ⋸ σ` alongside the existing eager union, consume nothing, and dump
a census: how many constraints, how many would resolve differently from the eager
answer, how many are deferred past a signature boundary. **Gate: `Q` must
reproduce the eager answer everywhere the eager answer is defined.** A divergence
here is a bug in `Q`, not a finding.

### §5.2 Quantified `ᾱ` in signatures

`LssSignature` becomes `d⟨ᾱ⟩ : (Q ⇒ τ)`; instantiation freshens `ᾱ`. Gate: the
§0 probe's row 4 (lambdas through `Task.succeed`) reaches `kN ≥ 2`.

### §5.3 `S(Q,α)` at generalization; retire the eager union

Move the union from every write to one solve at the boundary. Gate: the §2.5
ledger's `k1 + kN` does not fall, and `union` becomes a solver statistic rather
than a write-path one.

### §5.4 GAP-A — references instantiate, they do not inject

Delete `standaloneMemberWith`'s inject-into-a-freshly-loaded-slot in favour of
the label arriving with the instantiated signature. Gate: `[ incr, decr ]`
reaches `kN = 2`; `LssTaskSetProbe` reaches `multiSetSites ≥ 1`.

Decide μ here, on evidence (§3.4).

### §5.5 Retire the compensation layer

Only once `Q` is the solver: the ~11 transport hooks, ⊤-as-join-result,
⊤-as-widening. One piece per commit, each byte-neutral or individually measured.

---

## §6 Gates

1. §2.5 ledger `RECONCILES=yes`; **headline is `kN` RISING and `var` falling**.
2. `MSET`/`multiSetSites` — `LssTaskSetProbe` is the named pin.
3. Dispatch census A/B with the `sat + fast` invariance rail
   (`benchmarks/runtime-calls.md` Run AE protocol). Coverage must not regress:
   this plan ADDS sets, and a correct 2-set is worse than a singleton under a
   singleton-only consumer (`plans/lss-sum-lowering.md` is the consumer).
4. elm-tests at the pre-existing failure set; E2E `--target full`.
5. **SELF-COMPILE LOWERING, every arm** — LSS_031's lesson: E2E passed
   1,687/1,687 with `arrowSolverRoots=1` while its self-compile did not lower,
   because E2E is small programs.
6. Wall/GC per `benchmarks/lss-opt.md`; `Q` is new work on the mono critical
   path and must be costed, not assumed free.

---

## §7 Hard parts

- **Generalization at the def boundary must be built, but NOT as ranks.**
  `Engine.freshVar`'s *"No generalization happens, so any fixed rank is safe"*
  is a precondition this plan does NOT need to invalidate (§3.1, corrected
  after §5.0b was tried and reverted). What must be built is the occurrence
  test — walk the signature's slots, collect the set variables they reach,
  quantify those and internalize the rest. Smaller than a rank discipline, and
  it is the paper's own criterion rather than an HM implementation technique
  imported by analogy.
- **Elm has let-polymorphism; L^src does not.** The mapping rates let-bound
  function flow PARTIAL (GAP-9) and says plainly: *"Elm's polymorphic `let` has
  no L^src counterpart, so this axis is Eco's own to get right."* The paper
  cannot be followed here because there is nothing to follow; argue it
  separately.
- **Currying.** LSS_013 spine injection is already rated DIVERGENT with *"no
  paper counterpart"* — L^src has no currying. `Q` must not silently drop it.
- **Termination.** Σ guarantees no polymorphic recursion (Thm 4.1) — verify that
  guarantee still holds once α is genuinely quantified, since Σ is currently
  faithful in a system where α never escapes.
- **`maxSetSize` interacts with `S(Q,α)`.** Widening a set that is now a solved
  minimal solution is a different act from widening an eagerly-unioned one;
  decide where the budget applies.

---

## §8 Relationship to `plans/lss-post-mono-architecture.md`

That plan proposes the OPPOSITE architecture: take sets out of the spec key and
solve AFTER monomorphization, where no polymorphism remains and α is
unnecessary. **It is hereby the road not taken** — the paper solves the
polymorphic program, and this register follows the paper.

Its Phase 0 measurements stand and are load-bearing evidence FOR this plan:

- **43.6%** of the attributed `var` population sits at arrows that resolve
  elsewhere in the run (Run AK) — information that exists and is lost. `Q` is
  what stops losing it.
- **`keyed = False` destroys 12.4 singletons per multi-set it creates.** Taking
  sets out of the key is not a way to get multi-sets; a real solver is.
- Intra-item settling recovers exactly zero, and is non-zero ONLY under arrow
  identity — reinforcing §4's claim that LSS_031 is on the critical path.

Its §3.3 per-site polymorphism census remains unbuilt and remains the right way
to price the consumer.

---

## §9 Non-goals

- **GENERAL defunctionalization (`ℱ`, paper §5).** `plans/lss-sum-lowering.md`.
  NARROWED 2026-08-25: the `|set| = 2` case is now IN scope, as §5.A2, because
  Run AE shows the arrow-identity dispatch regression is a 2-member set at two
  sites and a 2-way tag switch is what unblocks the flip. Everything beyond
  that minimal consumer stays out of scope here.
- **Removing kernel/FFI ⊤.** Permanently out of scope — Eco's setting, not a
  representation choice (§3.6).
- **Re-litigating the kernel licences.** `KernelSetFacts` is settled for this
  register; §0 proves poison is not what blocks the probe.
