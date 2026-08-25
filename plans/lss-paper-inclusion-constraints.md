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

**ROOT CAUSE — the hypothesis was WRONG. Nothing is pruned; the symbol was
never spelled the way the emitter spells it.**

A monomorphized node whose whole expression IS a `MonoClosure` — an ordinary
top-level `f a b = …` — is emitted by `Functions.generateNode` under
`specIdToFuncName ctx.registry specId`, the SPEC's name. Its own
`closureInfo.lambdaId` never becomes an MLIR symbol; only `Lambdas.elm`, which
emits NESTED closures, names anything `lambda_NNN`.

`AbiCloning.collectGo` did not draw that distinction. It walked every
`MonoClosure` it met, top-level ones included, and indexed each under
`closureInfo.lambdaId`. When such an instance became a `LayoutGroup`'s `rep`,
`StampPap` wrote `fastEvaluator = Just inst.lambdaId` and `Expr.elm` rendered
it as `lambdaIdToString` — naming a symbol that was never emitted. The verifier
`PapExtendOp::verifySymbolUses` (`runtime/src/codegen/EcoOps.cpp:64`) is what
catches it.

So it is not a pruning race and not identity sharing per se. Solver roots merely
change WHICH instance wins the `rep` election, and under roots-on a top-level
one starts winning.

MEASURED (self-compile): 17 stamps are both top-level and stamped with
`arrowSolverRoots=1`; **0 at shipping defaults**, which is exactly why the flag
being default-off hid it. 25,486 top-level closures carry 25,486 DISTINCT uids,
so there is no lambdaId collision to blame either.

**FIX (Option B — fix the stamp, not the naming).** Renaming top-level specs to
their lambdaIds would churn every consumer of the spec name for no gain. Instead
the stamp now records WHICH symbol the instance was emitted under:

- `Mono.CallInfo` gains `fastEvaluatorSpec : Maybe SpecId`.
- `AbiCloning.collectInstances` threads the node's `SpecId` through the fold and
  `collectNode` hands it to the node's top-level closure — for EXACTLY the three
  node kinds that route through `Functions.generateDefine` (`MonoDefine` and the
  two port kinds), which hand their whole expression to
  `generateClosureFunc funcName`. `MonoTailFunc` is deliberately EXCLUDED: its
  params are already split out and its expr is the BODY, so a closure there is an
  ordinary nested lambda that `Lambdas.elm` names — attributing the spec to it
  would swap one wrong symbol for another. Nested closures get `Nothing`,
  unchanged.
- `Instance` gains `topLevelSpec`, set only when `closureInfo.captures` is EMPTY
  — `generateNode` emits the spec un-suffixed, so the spec name is usable only
  where the emitter takes the bare branch rather than `…$cap`. A top-level
  definition is closed over globals, so this is expected to hold universally; the
  guard means a violation degrades to the old behaviour (a loud lowering error)
  rather than inventing a wrong `$cap` symbol.
- `Expr.elm`'s fast-dispatch stamp carries `FastRef = ( LambdaId, Maybe SpecId )`
  and `fastRefBaseName` resolves it via `specIdToFuncName` when the spec is
  present.
- `MonoGlobalOptimize`'s stamp-preserving record update carries the new field, or
  a later rewrite would silently drop it back to the lambdaId spelling.

BYTE-NEUTRAL AT DEFAULTS BY CONSTRUCTION: with roots off nothing sets
`topLevelSpec`, so `fastEvaluatorSpec` is always `Nothing` and every emitted
symbol is character-for-character what it was.

**GATED 2026-08-25 — the flag now lowers.** Self-compile with
`ECO_MONO_LSS_ARROW_ID=1 ECO_MONO_LSS_ARROW_ROOTS=1`: emit `EXIT=0`
(15,054,203 B of MLIR), lower `EXIT=0` (70,450,536 B binary), and
`grep -c 'undefined fast evaluator'` = **0**. The only `ld` output is the
pre-existing stackmap-relocation / DT_TEXTREL warning pair. This is the gate
LSS_031 itself demanded — a self-compile LOWERING, not E2E — and §5.A3 is no
longer blocked on it.

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

**DONE 2026-08-25 — FLIPPED. All required gates met; full numbers in
`benchmarks/runtime-calls.md` Run AL.**

| gate | class | result |
|---|---|---|
| self-compile LOWERS | REQUIRED | ✅ both arms `EXIT=0`, **0** `undefined fast evaluator` |
| E2E `--target full` | REQUIRED | ✅ 1691/1691 |
| elm-tests at the pre-existing failure set | REQUIRED | ✅ 13,355 / **12** — the same 12 as LSS_035's baseline |
| ledger/MSET moves right | REQUIRED | ✅ `kN` 557 → **2,043** (+266.8%), multi-set arrows 13 → **100** |
| dispatch A/B | RECORDED | −0.306 pp (12.407% → 12.101%) — milder than AE's −0.50 pp |
| corpus md5 | RECORDED | on `03ae16a4a743a66e8b7ef74e3e8aa07f`, off `25730f3128b26ab45edebcdc87b55d04` |

The headline the phase was actually after: **`var` 260,280 → 247,813, −12,467
positions that were unresolved and now are not.**

**Three unit tests had to be RESTATED, and the reason generalises to anything
else this arc touches.** `LssSigFlowTest` test 9 and `LssHonestSourcesPipelineTest`
tests 1–3 asserted that certain positions were UNWRITTEN (`LVar`) or resolved
`⊤`. Both were PROXIES that only discriminated while LSS_006 per-load slot
minting left the position dangling — which is precisely the leak this flip
closes. Each was VERIFIED before being changed, not assumed:

- The contravariance pin's two HOF inner arrows read `LSet[6]`, where hof1's own
  set is `LSet[4]`, hof2's is `LSet[5]` and `k`'s own is `LSet[6]` — they carry
  EXACTLY `k`'s member, which is the forward flow the test's own title demands
  ("*or carries k*"). A backwards flip would have pushed 4/5 in.
- For `mixedSigModule` the complete inhabitant set of `d`'s result genuinely is
  `{incr, the one caller's lambda}` — the 2-set now reported.
- `test/elm/src/LssMixedSigHonestyTest.elm`, the runtime fixture that printed
  `[42,42,42]` for `[41,42,82]` when this miscompile class last regressed,
  PASSES.

The restated assertions pin each title's real claim instead of the proxy:
carries-k AND never-carries-the-hof-params'-own-members; and
never-a-singleton rather than always-`⊤`.

**WATCH ITEM.** `honestSources: topMixedFlex` reads `0/0` flag-off and `1/0`
flag-ON at CORPUS scale — the REVERSE of the small fixtures, where sharing the
slot removes their crossing entirely. Arrow identity RELOCATES where the
honest-∅ rule fires; it does not retire it. **§5.5 must re-measure this counter
rather than reason from the fixtures.**

#### §5.A4 — re-measure the gaps

With arrow identity shipped, re-run §0's probe table and the frozen-corpus
ledger. **This decides whether Phase B is needed at all**, and in what scope.
Specifically: does anything still fail to transport that is not the
`Platform.sendToApp` cross-call boundary (which no set variable can cross)?

**DONE 2026-08-25. Answer: exactly ONE shape still fails, and it is §5.4's,
not §5.2's.**

§0's table re-run at the shipping default against the escape hatch
(`ECO_MONO_LSS_ARROW_ID=0`). "members" is what the `MSET` line actually names:

| probe | shape | off | on | members formed |
|---|---|---|---|---|
| `PGlobals` | `[ incr, decr ]` — globals as bare list elements | `(none)` | **`(none)`** | ✗ **still nothing** |
| `PContainers` | `[ Just incr, Just decr ]` | `(none)` | 2-set | `g\|incr`, `g\|decr` |
| `PLambdas` | `[ \x->x+1, \x->x-1 ]` | `(none)` | 2-set | `l\|102`, `l\|103` |
| `PIdf` | `[ idf λ, idf λ ]` through `idf : a -> a` | `(none)` | 2-set | `l\|102`, `l\|103` |
| `PPick` | `if b then λ else λ` — cf join | 2 sets, both `?106\|?107` | 3 sets, one CONCRETE | `l\|106`, `l\|107` |
| `PTaskLambdas` | `[ Task.succeed λ, Task.succeed λ ]` | `(none)` | 2-set | Task-wrapped `l\|104`, `l\|105` |
| `LssTaskSetProbe` | `[ Task.succeed incr, Task.succeed decr ]` | `(none)` | 2-set | `g\|incr`, `g\|decr` |

Six of seven rows go from NOTHING to the correct concrete 2-set. `PPick` also
resolves its previously-unresolved member refs (`?106|?107` → named lambdas).

**Three extra probes narrow the survivor to a precise shape:**

| probe | shape | result |
|---|---|---|
| `PGlobalsIf` | `if b then incr else decr` — globals, cf join, no literal | **2-set** ✓ |
| `PGlobalsArg` | `[ idf incr, idf decr ]` — globals as ARGUMENTS | **2-set** ✓ |
| `PGlobalsTuple` | `( incr, decr )` — globals in a TUPLE literal | `(none)` ✗ |
| `PGlobals` | `[ incr, decr ]` — globals in a LIST literal | `(none)` ✗ |

**THE SURVIVING GAP, stated exactly:** a GLOBAL reference sitting DIRECTLY in a
container LITERAL — list or tuple — where no argument-injection hook and no
control-flow hub also writes the position. Wrap the same global in ANY call
(`Just incr`, `idf incr`, `Task.succeed incr`) and it transports; put a LAMBDA
in the same slot and it transports. That is §0.1's diagnosis unchanged:
`standaloneMemberWith` injects into a freshly-loaded, disjoint slot, and arrow
identity repairs it only where something else writes the position too.

**VERIFIED it is a failure and not a better outcome** — the trap this register
has fallen into twice. `PGlobals` and `PLambdas` are the SAME program shape
differing only in member class, and their ledgers agree everywhere except the
position at issue:

| | total | k1 | kN | top | var |
|---|---|---|---|---|---|
| `PLambdas` | 241 | 61 | **1** | **7** | 172 |
| `PGlobals` | 241 | 60 | **0** | **9** | 172 |

Same total, same `var`. What `PLambdas` resolves to an honest 2-set,
`PGlobals` **widens to ⊤**. It is not resolving to singletons.

##### The Phase B decision

- **§5.4 (GAP-A) — PROCEED, and it is now narrowly scoped.** It is the only
  shape still failing, and the failing predicate is precise enough to target:
  a standalone global member whose position is a container-literal element.
- **§5.2 (`ᾱ` in signatures) — its EMPIRICAL motivation is gone.** §0.2.2
  attributed every failing row to "any set living inside a TYPE VARIABLE has no
  fact… `List.cons`, `Task.succeed`/`andThen`/`attempt`, `List.map`,
  `Basics.composeL`, `idf : a -> a`". Every one of those now transports at the
  shipping default without a set variable existing anywhere. §0.3 consequence 1
  called this correctly: the operative mechanism was LSS_006 slot
  disjointness. **This does not settle the FIDELITY argument** — the paper has
  `α` and Eco does not, and that is a separate and legitimate reason to build
  it. What is settled is that §0's measured gaps no longer justify it.
- **§5.1 (`Q` shadow mode) and §5.3 (`S(Q,α)`) exist to SERVE §5.2** and inherit
  its status.
- **§5.5 (retire the compensation layer) — DO NOT retire blind.**
  `honestSources: topMixedFlex` reads `1/0` at corpus scale WITH the flip
  (0/0 without). The layer is still firing; only the small fixtures stopped
  reaching it.

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

#### BUILT AND MEASURED 2026-08-25

Recording sites: `Store.unifySlotWithSetC` (the single point every eager member
and ⊤ write passes through) and `Store.addSlotSource` (LSS_023 edges, recorded as
`σ_dst ⊇ σ_src`). Each entry captures the target slot's content BEFORE the write,
because the eager answer is `seed ⊔ Q` and without the seed an annotation-minted
slot reads as a spurious divergence. Solved at `finishNode` by grouping on
`UF.repr` — two slots the solver unified are ONE σ, exactly as they are one
variable in the paper — and scored against the store, read-only, exactly as
`rezonkSettled` is. Report-gated throughout.

**INERTNESS PROVEN, not asserted:** the emitted `.mlir` is BYTE-IDENTICAL with
the census on and off (`PGlobals` `8538a779…`, `LssTaskSetProbe` `5ee6246b…`,
`PIdf` `ceba0887…`). "Consume nothing" holds.

Self-compile, `ECO_MONO_LSS_REPORT=1`:

```
Q-shadow: constraints=125289 (members=124512 tops=777 edges=0) items=23579
          classes=109910 defined=109910 agree=109844
          diverge=66(super=0 sub=56[merged=12 unseen=44] top=10 other=0)
          unresolved=0 edgeOnly=0 scratchDropped=106023
          | partition sigRoots=22808 reaching=51102 internal=58808
          REPRODUCES=NO
```

**1. `Q` reproduces the eager answer to 99.94 % — and the 0.06 % residual is
ONE structural fact, not noise.** Every divergence is `shadow ⊊ eager`: `Q`
under-records, never over-records (`super=0`, `other=0`). Split by cause:

- `unseen=44` — a slot minted WITH content by `Store.monoTypeToVarC` from an
  `LSet` annotation and never constrained, so it never entered `Q`'s domain at
  all; it later unified into a constrained class, whose eager answer then holds
  members `Q` never saw.
- `merged=12` — two set slots unified through `Unify.merge`, which joins their
  contents WITHOUT passing `unifySlotWithSetC`.
- `top=10` — the same two causes, ⊤-valued.

**So the store has TWO ways to put members in a slot — the eager union and
ordinary type unification — and only the first is a "constraint" today.** That
is the finding §5.3 has to act on: making `Q` the solver means the UNIFY path
must emit constraints too. It is not a disagreement about solving, which is why
the gate reads `NO` on a recording gap rather than on a semantic one.

**2. 45.9 % of all constraint activity is thrown away inside scratch stores.**
`scratchDropped=106023` against `125289` that survive — of 231,312 constraints
recorded, 106,023 die with an `Engine.withScratchStore` Point. Every one of the
177 LSS_023 edges `sigflow` reports installing is in one, which is exactly why
the census reads `edges=0`; the two counters agree once the drop is visible, and
on the probe programs (where `sigflow` independently reports `edges=0`) the
census reads `edges=0` too. This is the sharpest number the phase produced and
it is a direct measurement of §3.1's *"REAL deferral, WRONG SCOPE"* row.

**3. The paper's partition is REAL and close to even: 46.5 % / 53.5 %.** Over
22,808 def roots, 51,102 constrained classes are reached by the def's own
signature — they would be quantified into `ᾱ` — and 58,808 are not, so they
would be internalized to `S(Q,α)`. Computed the paper's way: a REACHABILITY walk
from the def's root type Point (`Translate.demandUnifyRoot`'s `annVar`),
collecting `FunL` set slots.

**This is the number §5.0b went looking for and could not find.** Ranks measured
`escaped = 0` over 27 defs and 1,064 variables and concluded the def-level
partition was empty. It is not empty — ranks asked a SCOPE question, and scope is
genuinely degenerate here because `withScratchStore` gives every unit a fresh
store. The paper asks an OCCURRENCE question, and that one has a 46.5 % answer.
§3.1's correction is now measured rather than argued.

**4. `unresolved=0` is VACUOUS and the metric is withdrawn.** A class that
received a constraint has by definition been written, so it always has an eager
answer; the counter can only ever read 0. §5.1's third census item — "deferred
past a signature boundary" — is answered by the partition in (3) instead, which
is what the phrase actually means once there is a boundary to measure against.

### §5.2 Quantified `ᾱ` in signatures

`LssSignature` becomes `d⟨ᾱ⟩ : (Q ⇒ τ)`; instantiation freshens `ᾱ`. Gate: the
§0 probe's row 4 (lambdas through `Task.succeed`) reaches `kN ≥ 2`.

#### BUILT 2026-08-25 — LANDED, BYTE-NEUTRAL

`LssSignature` now carries the scheme half beside the facts:

- **`quantified`** — `ᾱ`, the CANONICAL ordinals (those that are their own
  `rep`). Ordinals sharing a `rep` are one set variable, so the canonical ones
  are exactly the variables the signature abstracts over. `rep` was always that
  statement in ordinal form; naming it lets instantiation say what it does.
- **`residual`** — `Q`, as `ℓ… ⋸ α` keyed by CANONICAL ordinal. Same information
  `ArrowFact.members` carries, in the paper's direction: a constraint the USE
  re-emits against a freshly instantiated α, not a solved set the use copies.

`LssInfer.instantiateScheme` (gated by `lss.qSolve`, env `ECO_MONO_LSS_QSOLVE`,
hash token `lssQS=`) applies a signature the paper's way round, in three steps:
`schemeTie` unifies the ordinals that share a `rep` into one variable,
`schemeFacts` carries the two things that are NOT solved sets (⊤, which is
Eco's incompleteness marker per §3.6, and the LSS_023 edges), and
`schemeResidual` re-emits `Q`. The slots are already fresh per call — that IS
the freshening of `ᾱ`.

**MEASURED byte-identical flag-off vs flag-on** across all eight probes,
including the gate probe. `residual` is derived from the same `members` at
generalization and keyed by the `rep` `schemeTie` has already unified, so the
two paths agree by construction; the A/B is the check that the REORDERING
(all ties, then all facts, then all constraints — rather than interleaved per
ordinal) is also neutral, which is not obvious and is now measured.

**The stated gate is met but NOT by this phase.** `PTaskLambdas`
(`[ Task.succeed (\x -> x+1), Task.succeed (\x -> x-1) ]`) reads `kN=5` with the
2-set `l|104 | l|105` in BOTH arms — §5.A3's arrow-identity flip is what
delivered it, as §5.A4 recorded. §5.2's value here is structural: the
application path stops reading a pre-solved answer, which is the precondition
§5.3 needs. It buys no precision on its own and is not claimed to.

### §5.3 `S(Q,α)` at generalization; retire the eager union

Move the union from every write to one solve at the boundary. Gate: the §2.5
ledger's `k1 + kN` does not fall, and `union` becomes a solver statistic rather
than a write-path one.

#### MEASURED 2026-08-25 — **BLOCKED, and the blocker is a SOUNDNESS condition**

The census was extended to score the partition's two halves separately, because
`S(Q,α)` is substituted for exactly one of them and overall agreement does not
decide the question. Self-compile:

```
partition sigRoots=22824 reaching=51142 internal=58860(agree=58794 diverge=66)
diverge=66(super=0 sub=56[merged=12 unseen=44] top=10 other=0)
```

**Every one of the 66 divergences is in the INTERNAL population — the reaching
half agrees 51,142 / 51,142.** And every divergence is `shadow ⊊ eager`
(`super=0`, `other=0`). So replacing the internal classes with `S(Q,α)` today
would DROP members at 66 classes: an under-approximation, which is the
miscompile direction — a set claiming fewer inhabitants than it has is exactly
what licenses a wrong devirtualization (LSS_026's whole subject).

**The blocker is §5.1's finding, now priced.** Members reach a slot by two
routes and only one is a constraint: `Store.monoTypeToVarC` seeds a slot from an
`LSet` annotation (44 classes), and `Unify.merge` joins two set slots without
passing `unifySlotWithSetC` (12; the 10 ⊤ cases are the same two causes).
**§5.3 cannot land until `Q` records both.**

CORRECTED — an earlier draft of this paragraph said neither was a small edit,
reasoning that `monoTypeToVarC` threads only `IO.State` and that `Unify.merge`
is shared with the typechecker and cannot see `S`. Both are true of the DEEP
functions and both are beside the point: each route has a `Step`-level wrapper
that holds everything needed.

- `Store.monoTypeToVar` (`Store.elm:689`) has the `Mono.MonoType`, the root
  Point it produced, and `Step`. Walking the type alongside the Points and
  emitting `ℓ ⋸ α` for every `MFunction` carrying an `LSet` records the seed
  without touching the recursive encoder at all. The walk already exists —
  `Store.qSigGo`, written for §5.1's partition.
- `Store.unifyStep` (`Store.elm:1016`) has both Points and `Step`. Recording
  each side's set-slot contents as seeds BEFORE unifying covers the merge
  whichever way it joins them.

So the work is two `Step`-level walks against an existing helper, not surgery on
the encoder or the shared unifier. **The census says when it is done:
`internDiverge` must reach 0.**

**Do it for fidelity, not for precision.** `divergeSuper = 0` says `S(Q,α)`
never exceeds the eager answer, so closing the gap makes `Q` TRUSTWORTHY — which
§5.4 and §5.5 both need — but it does not make it more informative.

**The gate's second clause is already vacuous, and that is worth knowing.**
`set-writes: skip=26732 flex=206994 topJoin=1 union=24 slow=0`. The write-path
union is **24 operations out of 233,751** — 0.01 %. There is no eager union to
retire. The eager COMMITMENT is `flex=206,994` (88.6 %): adopting a concrete set
into an unconstrained slot. Any future restatement of §5.3 should target the
flex adoption, not the union, or it is optimising something that does not
happen.

**What `S(Q,α)` would buy if the recording gap were closed: nothing.**
`divergeSuper = 0` over 110,002 classes means the shadow solution NEVER exceeds
the eager answer, and it equals it 99.94 % of the time. The paper needs
`S(Q,α)` because it defers everything and has no store to read; Eco computes the
same sets eagerly and §5.1 proved the two agree. Retiring the eager path would
relocate WHEN the union happens, not WHAT it computes — and would newly expose
the 45.9 % of constraints that die inside `withScratchStore`.

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
