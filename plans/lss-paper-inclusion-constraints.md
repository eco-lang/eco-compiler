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

### §5.6 `Q` IS AN INFERENCE ARTIFACT — it is currently scoped to the wrong phase

**ADDED 2026-08-25, and it supersedes the repair §5.3 was heading for.** Two
earlier proposals in this register are WITHDRAWN by the finding below: (a)
"record a seed constraint at `monoTypeToVar` and `unifyStep`", and (b) "make the
signature channel the only channel by flexing demand annotations". Both were
aimed at a defect that is not there.

#### §5.6.1 The finding

`LssInfer.resolveSignature` runs the whole inference unit inside a scratch
store:

```elm
case Engine.withScratchStore (inferUnitInScratch members) s3 of
```

`Engine.clearedAux` empties `qLog` on entry and `restoredAux` drops the inner
log on exit. **So every constraint the INFERENCE phase records is discarded, and
the census at `finishNode` is scoring the SPECIALIZATION phase instead.** That
is what `scratchDropped = 106,023` — 45.9 % of all recorded constraints — has
been measuring all along: not incidental loss, but the entire population the
paper's `Q` is about.

**This reverses the reading of every divergence.** The members `Q` "under-records"
arrive when a spec's stored demand type re-enters the store
(`Translate.demandUnifyVar` → `Store.monoTypeToVar`, `Translate.elm:85`). That is
not a leak in an inference channel — it is the paper's own `σ̄`, the concrete set
a specialization is keyed by (Fig. 9 Mono-Used, 146:13). The paper has ground
sets at specialization too; what it does NOT have is constraints there, because
`Q` is discharged when inference ends. **Eco was recording `Q` across a phase
boundary the paper does not cross.**

So the ground-demand channel is NOT to be retired. Retiring it would mean
ceasing to specialize on lambda sets, since the demand's `LSet` IS the spec key
— the opposite of what LSS exists to do, and measured at 64 % of fast dispatch
by Run AK's `keyed=False` arm.

#### §5.6.2 The work — implementation-ready

**Move the census inside the inference scratch store, and keep the existing one
as a separate line.** They measure different phases and both are worth having.

1. `Engine.LssStats.sigStats` gains `qInfer : QShadowStats` beside `qShadow`.
   Same record, no new type.
2. `Store.qInferenceCensus : List IO.Variable -> Engine.S -> Engine.S` — the
   existing `qShadowCensus` body, with two changes: the signature-reachability
   set is built from the UNIT'S ROOTS (a list, unioned) rather than from the
   single `itemAux.qSigRoot`, and the counters land in `qInfer`.
3. Call it at the end of `LssInfer.inferUnitInScratch`, after `zonkSignatures`
   and BEFORE returning — the scratch store must still be installed. The roots
   are already in hand: `loadMemberSlots` returns
   `List ( String, IO.Variable, Array IO.Variable )`, whose second component is
   each member's signature root and whose third is its arrow-slot array.
4. Clear `itemAux.qLog` immediately after consuming it there, so the same
   constraints are not then counted again as `scratchDropped` on scratch exit.
   The two censuses must partition the constraints, not overlap.
5. `Store.qSigClasses` already does the reachability walk and needs only to be
   folded over several roots instead of one.

#### §5.6.2b MEASURED 2026-08-25 — the gate PASSES

```
Q-infer:  constraints=106314 (members=105784 tops=353 edges=177) units=5844
          classes=106300 agree=106261 diverge=0(super=0 sub=0 top=0 other=0)
          partition reaching=13404 internal=92896(agree=92889 diverge=0)
          REPRODUCES=yes

Q-shadow: ... diverge=66(sub=56[merged=12 unseen=44] top=10) scratchDropped=0
          REPRODUCES=NO      <- specialization phase, NOT gated
```

**Zero divergences over 106,300 classes.** Three independent corroborations that
the census is now on the right phase, none of which could be arranged by
accident:

1. **`edges=177` matches `sigflow: edges=177` exactly.** Under the old scoping
   the census read `edges=0` against the same 177. The LSS_023 edges are
   installed during inference and were being discarded with the scratch store.
2. **`scratchDropped` fell to 0.** The constraints are consumed at the inference
   boundary instead of dying on the way out, so the two censuses now PARTITION
   the constraints rather than one silently eating the other's.
3. **`constraints=106314` against the old `scratchDropped=106023`.** The
   population that was being thrown away IS the population the paper's `Q` is
   about; the small delta is corpus drift between runs (the corpus is the
   compiler, and the compiler changed).

The partition also moves, and the new figure is the honest one: **reaching
13,404 (12.6 %) / internal 92,896 (87.4 %)**, against 46.5/53.5 under the
wrong-phase scoping. Inference has far more body-internal variables than the
specialization phase does, which is what one would expect and what the earlier
number was obscuring.

**The gate stays `REPRODUCES=yes`, but now it means something:** `Q` recorded
over inference, solved at the inference boundary, must reproduce what inference
left in the scratch store. A divergence THERE is a genuine defect in `Q`. The
`finishNode` line becomes a specialization-phase observation and is not gated.

#### §5.6.3 §5.3, re-decided against `Q-infer` — SAFE, and NEUTRAL

**The soundness blocker is CLEARED.** `internal=92896(agree=92889 diverge=0)`:
over the whole self-compile, the minimal solution `S(Q,α)` never disagrees with
what inference left in the store for a single internalizable class. The 7
remainder are `unresolved` — no eager answer to compare — not divergences.
Substituting `S(Q,α)` cannot drop a member, so it cannot manufacture the false
singleton that LSS_025's devirt hijacks. The `[42,42,42]` risk recorded under
the old scoping was an artifact of measuring the specialization phase.

**But the two constraints on the payoff survive the rescoping, and together they
settle it:**

- `divergeSuper = 0`. The shadow solution NEVER exceeds the eager answer.
  `S(Q,α)` is at best equal, so it cannot buy precision — it can only relocate
  when the same set is computed.
- `set-writes: union=24` of 233,751 — **0.01 %**. There is no eager union to
  retire. The eager COMMITMENT is `flex=206,994` (88.6 %), adopting a concrete
  set into an unconstrained slot.

**Verdict: building §5.3 as written is a provably-neutral refactor.** Both of
its stated gates pass trivially — `k1 + kN` cannot fall when the answers are
identical, and `union` is already not a write-path phenomenon. Recorded as the
phase's result rather than built. If §5.3 is ever restated it must target the
FLEX ADOPTION, not the union, or it optimises something that does not happen.

#### §5.6.4 GATED 2026-08-25 — §5.1, §5.2 and §5.6 together

| gate | result |
|---|---|
| E2E `--target full` | **1691 / 1691**, `EXIT=0` |
| elm-tests | **13,355 passed / 12 failed** — the pre-existing baseline, the same 12 (if-chain + 11 POST_010/TYPE_007 node-type-scoping) |
| self-compile LOWERS | `emit EXIT=0` (14,959,837 B), `lower EXIT=0` (70,298,448 B), **0** `undefined fast evaluator` |

The lowering gate is LSS_031's standing rule and is not optional for anything
touching the signature path: E2E passed 1,687/1,687 with the bad `_fast_evaluator`
stamp because its corpus is small programs. Byte-identity rails were already in
place for §5.2 (flag-off vs flag-on across eight probes) and §5.1 (report-on vs
report-off), so these three close the suites rather than the rails.

### §5.7 Make signatures non-trivial — the population, measured

Independently of §5.6, the signature channel says almost nothing. Self-compile,
9,216 signatures with a body:

| class | count | share | meaning |
|---|---|---|---|
| `allflex` | **7,259** | **78.8 %** | HAS arrows, every fact is `{rep=self, members=[], top=False}` |
| `arrowfree` | 1,546 | 16.8 % | declared type has no arrows — nothing to say, no loss |
| `carrying` | 333 | 3.6 % | carries members |
| `hasTop` | 78 | 0.8 % | carries ⊤ |

**The trivial population is NOT dominated by arrow-free defs** — that was worth
checking before designing around it, and it survived. 78.8 % of signatures have
arrows and state nothing, which is GAP-2's recorded loss item 1: tyvar positions
mint no slot, so `always : a -> b -> a` cannot state "result ⊇ param 0".

**ORDER IS LOAD-BEARING.** Any move that reduces what the ground-demand channel
carries must come AFTER the signature channel demonstrably carries it, or the
information is deleted rather than relocated. `applyFacts` short-circuits on
`sig.trivial`, so today 78.8 % of defs would replace a real set with nothing.

#### §5.7.1 TESTED 2026-08-25 — **`allflex` is a NON-LOSS. Do not build this.**

The population is real; the LOSS is not. Six probes, all at shipping defaults:

| probe | shape | own 2-set? |
|---|---|---|
| `PAlways` | GAP-2's literal case: `always : a -> b -> a` | **YES** |
| `PWrap` | through a record field: `wrap : a -> { v : a }` | **YES** |
| `PAlwaysCross` | `always` used at TWO types, one memoized signature serving both | **YES** |
| `PThread` | two polymorphic hops: `always (idf incr) True` | **YES** |
| `PMapPolyLam` | `List.map idf [ \x -> x+1, \x -> x-1 ]` | **YES** |
| `PMapPoly` | `List.map idf [ incr, decr ]` | no — **but see below** |

`PAlways`'s signature is confirmed `allflex`: `sigfacts` dumps every NON-DEFAULT
fact and `always` produces no row at all. **The set transports anyway.**

`PMapPoly` is the only failure and it is NOT this phase's. Swapping the bare
globals for lambdas over the SAME `idf` hop (`PMapPolyLam`) transports, and
dropping the hop entirely while keeping the bare globals (`PBareGlobals`,
`[ incr, decr ]`) still fails. The failing ingredient is the container literal
of GLOBALS — §5.4's GAP-A — not the polymorphic hop.

**Why there is nothing to fix, and it is the paper's own reason.** The two
occurrences of `a` in `a -> b -> a` are the SAME type variable. Instantiating it
makes both the same arrow carrying the same set slot, so "result ⊇ param 0"
holds by ordinary unification and the signature never has to state it — exactly
*"unification only ever equates set variables"* (§1, 146:6–11). What makes the
slot shared is `lss.arrowIdentity`, default-on since §5.A3.

**So GAP-2's loss item 1 is CLOSED by §5.A3, not outstanding.** The 78.8 %
`allflex` figure measures signatures that have nothing to say because the TYPE
already says it — which is the paper's design, not a shortfall against it.
Recorded here so the count is not mistaken for a defect a third time.

### §5.4 GAP-A — references instantiate, they do not inject

Delete `standaloneMemberWith`'s inject-into-a-freshly-loaded-slot in favour of
the label arriving with the instantiated signature. Gate: `[ incr, decr ]`
reaches `kN = 2`; `LssTaskSetProbe` reaches `multiSetSites ≥ 1`.

Decide μ here, on evidence (§3.4).

#### §5.4.1 TRIED, MEASURED, REVERTED — the self-id filter is NOT GAP-A's cause

**HYPOTHESIS.** LSS_020's B.1.f filter drops the def's own member at signature
readback, and its recorded rationale says the identity reaches callers *"via the
`g|` standalone spine injection"* instead — i.e. by the very INJECTION §0.1
blames. So: keep the identity in the signature (the paper's TIU-Lam,
`ℓ_d ⋸ α` on the def's own arrow), and a reference INSTANTIATES it rather than
injecting into a freshly-loaded, disjoint slot.

Built behind `lss.selfIdInSig` (`ECO_MONO_LSS_SELFID`, `lssSI=`), in two
variants: keeping the raw `l|` body-lambda id, and — since the paper's element
denotes THE DEF, which in Eco's vocabulary is the `g|` member — substituting the
`g|` id for it.

**RESULT: NO-GO. Both variants leave GAP-A exactly where it was.**

| probe | off | on (either variant) |
|---|---|---|
| `PBareGlobals` `[ incr, decr ]` | no `{incr,decr}` set | **still no `{incr,decr}` set** |
| `PGlobalsTuple` `( incr, decr )` | nothing | **unchanged** |
| `LssTaskSetProbe` | set present | set present |

The flag is not inert — `PBareGlobals` gains 10 multi-set arrows and `var` falls
172 → 153 — but every one of those is some OTHER def's identity now riding its
signature (`Basics.composeL`, `List.foldrHelper`). **The position GAP-A is about
gains nothing.** So the identity riding the signature does not reach that
position either, and the filter is not the blocker.

REVERTED, on §5.0b's precedent: a measured NO-GO flag is neither byte-neutral
nor carrying its weight. **Do not rebuild it.**

**What this rules out, which is the value here.** GAP-A is NOT "the label is
missing from the signature channel". The label is available; it still does not
land. That points back at §0.1's literal claim — `Store.loadType` inside
`standaloneMemberWith` mints a slot disjoint from the position, and the
returned `WpHonest funcVar` is not unified with the element's slot. The next
step is to TRACE one `[ incr, decr ]` element from `standaloneMemberWith`'s
`funcVar` to the cons argument's Point and find where they fail to meet — not
another signature-side hypothesis.

#### §5.4.2 TRACED 2026-08-26 — **GAP-A is not in `LssInfer` at all**

The trace was run to the point where it contradicted the plan, and it does.

**Step 1 — the discard.** `walkExpr`'s wildcard arm covers `TOpt.List` and
`TOpt.Tuple`, and `walkChildren : ... -> Step ()` returns UNIT: every child's
`WalkPoint` is thrown away. So a child's injected identity can only reach the
container's element position by landing in a slot the position already shares.
That looked like the answer.

**Step 2 — it is not, because the arm never runs on the failing program.** A
census of every member body `walkMembers` walks, on `PBareGlobals`, lists
`elm/core:*` and `elm/json:*` and **nothing from the module under compilation**.
No `fns`, no `incr`, no `decr`. LSS inference walks a def's body only when its
signature is DEMANDED by a caller (`preResolveCallees`); a top-level `fns` in
the program being compiled never is.

So `LssInfer.standaloneMemberWith` — which §0.1 names as GAP-A's cause — is
never reached for `[ incr, decr ]`. **§0.1's attribution is wrong for this
shape.** The `zc|…PBareGlobals.incr|…` rows that made it look otherwise are
ZONK causes, emitted from translation, not inference.

**Consequence: the sets that DO form here come from TRANSLATION.** `PLambdas`
succeeds because `Translate` injects lambda-instance members as it walks the
body (`injectArgLambdaMember`, `lambdaInstanceMemberId`, LSS_013 spine
injection). GAP-A is the absence of the equivalent for a `g|` standalone
reference in a container literal, **in `Translate.elm`**.

**Everything ruled out so far, so the next attempt does not repeat one:**

| candidate | verdict |
|---|---|
| the self id filtered out of signatures (§5.4.1) | NO-GO, reverted |
| solver-root arrow identity sharing the slot | no effect — all three probes byte-identical off/roots |
| `walkChildren` discarding element points | real, but the arm never runs here |
| `unifyParamsBestEffort`'s second load of the arg type | not the path — 3 events, none with a global arg |

#### §5.4.3 TRACED FURTHER — the missing injection is real, and it is not enough

Translation was instrumented next, and the trace produced a REAL missing
mechanism plus a second wall behind it.

**The missing mechanism.** `Translate.translateVarRef` handles every bare
`VarGlobal`/`VarEnum`/`VarBox`/`VarCycle` reference and does exactly two things:
`classify canType` and `Engine.enqueueSpec`. **It injects no member.** The
identity is injected only at ARGUMENT positions, by
`injectArgLambdaMember` → `standaloneArgMember "g|…"`. That is the whole
asymmetry:

| shape | why it behaves as it does |
|---|---|
| `[ \x -> x+1, … ]` | `specializeLambda` → `classify` → `classifyLambdaHead` injects the lambda's member |
| `[ Just incr, … ]`, `[ idf incr, … ]`, `[ Task.succeed incr, … ]` | `incr` is a call ARGUMENT → `injectArgLambdaMember` fires |
| `if b then incr else decr` | `pick` is CALLED, so its signature is demanded, so inference walks it and `joinCfHub` joins the branches |
| **`[ incr, decr ]`, `( incr, decr )`** | bare reference, not an argument, inside a value nobody calls → **neither path fires** |

**Adding the injection works — and still does not fix it.** Injecting the
reference's member in `translateVarRef` (reusing `injectArgLambdaMember`, so the
kernel-alias fold stays identical) demonstrably puts members in the store:
`refId|ok|members1` ×2 and `refId|ok|members2` ×1 on `PBareGlobals`. The set
FORMS. But `kN` stays 0, and combining it with `arrowSolverRoots` changes
nothing either. Reordering the `TOpt.List` arm so the list type is classified
AFTER its elements are translated — the annotation was being snapshotted before
the members existed — also changes nothing.

**The second wall, measured.** The zonk-cause census is decisive:

```
PLambdas       zc|…PLambdas fns|k2    1     <- fns's type IS zonked, yields a 2-set
PBareGlobals   (no zc|…fns rows at all)     <- no set readback during fns's translation
```

`PBareGlobals`'s rows are for `incr` and `decr`, which are their OWN SPECS with
their own item stores. `Engine.resetItem` installs a fresh store per spec, so
the members injected while translating `fns` live in `fns`'s store, and the
readback that would publish them happens in a different one.

**So GAP-A is a per-item-store boundary problem, not a missing-label problem.**
The label can be minted, injected, and present in the store, and still not be
readable where it is needed, because the reader is a different work item. That
is the same architectural fact §5.6 found from the other side — inference
constraints dying with a scratch store — and it is why `[ incr, decr ]` resists
every local repair.

BOTH EXPERIMENTS REVERTED (the injection and the reordering): each was measured
as no-effect on the target, and a default-off flag that moves nothing is dead
weight. **Do not rebuild either without first solving the store boundary.**

**NEXT — and it is no longer a `Translate` question:** establish where a set for
`fns`'s element position could be READ at all, given `fns`, `incr` and `decr`
are three separate items with three separate stores. Compare against `PLambdas`,
where the members are minted INSIDE `fns`'s own item because the lambdas are
part of `fns`'s body. That asymmetry — members owned by the item that reads them
vs members owned by another item — is the thing to fix, and it is the same
question `plans/lss-post-mono-architecture.md` was written to answer.

#### §5.4.4 ROOT CAUSE — `translateVarRef` classifies STORELESSLY, and the storeless classifier stamps `⊤`

`Store.classifyGo`'s `Can.TLambda` arm, in the compiler's own words:

```elm
-- One arrow per MFunction, mirroring zonkFlat's Fun1 arm
-- (GlobalOpt flattens later per GOPT_016). Storeless
-- classification stamps LTop (sound-but-imprecise;
-- fast paths gate on signature triviality in M2).
Ok (Engine.consS (Mono.mFunction Mono.LTop [ mFrom ] mTo) s2)
```

`Translate.classify` IS `Store.classifyDirect` — "read-only classification: no
store minting" — so **every arrow it returns is `⊤` by construction**. And
`translateVarRef`, the path for every bare `VarGlobal`/`VarEnum`/`VarBox`/
`VarCycle`, calls exactly that.

**So the element position is POISONED before any label could reach it.** That
is why all three repairs measured inert: they worked hard to get a member into a
SLOT, and on this path the annotation never comes from a slot at all.

**The evidence, and it is unambiguous.** Censusing what each spec is registered
with (`annoSketch` over the `MonoType` at `enqueueSpecKeyed`):

```
PBareGlobals   specType|…incr|T      specType|…decr|T      specType|…fns|[T]
PLambdas                                                    specType|…fns|[T]
PNoKernel      specType|…applyAll|V[T][]   and  V[V][]
```

`V` (an `LVar`) appears elsewhere in the same run, so `T` here is genuine
poison, not "unwritten". And `fns` registers `[T]` in the WORKING case too —
which kills the write-back theory: `PLambdas`'s 2-set does not live on the
registry entry at all, it lives on the lambda closure types inside `fns`'s body
(`zc|…fns|k2`).

**Why the two working shapes work, stated exactly:**

- a LAMBDA goes through `classifyLambdaHead`, not storeless `classify`;
- a call ARGUMENT goes through `translateGlobalCallSlow`, and
  `translateGlobalCall` **gates** its storeless fast path on `lssFastOk` —
  *"the cached/storeless fast classifications stamp LTop, which is exact only
  when the callee's signature is trivial AND no argument type mentions an
  arrow"*.

**THE DEFECT IN ONE LINE: `translateGlobalCall` gates the storeless classifier;
`translateVarRef` does not.** A bare reference takes the imprecise path
unconditionally, including when its own type is an arrow that a set could
inhabit.

**THE FIX.** Give `translateVarRef` the same gate: when lss is on and the
reference's type mentions an arrow, classify STORE-AWARE — load the type, inject
the referent's identity (`injectArgLambdaMember`, so the kernel-alias fold stays
identical to the argument path), and zonk the result from the store — instead of
stamping `⊤`. That is §5.4's own title, "references instantiate, they do not
inject", read the right way round: the injection was never the missing half; the
storeless classification was.

#### §5.4.5 FIXED 2026-08-26 — `classifyRef`, and it is the largest single move in this arc

`Translate.classifyRef` gates the storeless classifier exactly as
`translateGlobalCall` already gated it. When lss is on and the reference's type
mentions an arrow, a bare global reference is classified STORE-AWARE: load the
type, inject the referent's identity via `injectArgLambdaMember` (so the
`g|`/`c|`/`k|` dispatch and the kernel-alias fold stay identical to the argument
path — LSS_016), then zonk the answer back out of the store. Arrow-free
references keep the cheap path and are byte-identical.

Flag `lss.refIdentity` (`ECO_MONO_LSS_REF_IDENTITY`, hash token `lssRI=`),
DEFAULT-OFF pending the suites.

**GAP-A's headline case is CLOSED.** `PBareGlobals` (`[ incr, decr ]`) now emits
`MSET 4649 2 g|…incr | g|…decr` — the exact set §5.4's gate names — where it
previously emitted nothing.

| probe | `kN` | `top` | `{incr,decr}` |
|---|---|---|---|
| `PBareGlobals` `[ incr, decr ]` | 0 → **3** | 9 → **7** | 0 → **2** |
| `PGlobalsTuple` `( incr, decr )` | 0 → **2** | 9 → **7** | — |
| `PLambdas` (control) | 1 → 1 | 7 → 7 | unchanged |
| `LssTaskSetProbe` | 4 → **8** | 17 → **7** | 1 → **2** |

**Self-compile, both arms, and BOTH LOWER:**

| | off | on | delta |
|---|---|---|---|
| `k1` | 159,735 | 195,033 | +35,298 |
| **`kN`** | 2,047 | **3,386** | **+65.4 %** |
| **`top`** | 28,304 | **20,816** | **−26.5 %** |
| `var` | 250,624 | 273,390 | +22,766 |
| multi-set ARROWS | 100 | **728** | +628 % |
| lower | `EXIT=0`, 0 undefined-fast-evaluator | `EXIT=0`, 0 | ✓ |

`.mlir` 14,965,780 → 15,247,547 B (+1.9 %); md5 `fe1eeffb…` → `360e4655…`.

**`top` falling by a quarter is the fix's signature, not a side effect** — those
28,304 were substantially storeless ⊤ stamps on positions that had never been
consulted. `var` rising alongside is the correct direction: a position moved
from ⊤ (a false claim of "poisoned/unknown") to an honest unconstrained
variable, and `k1 + kN` rose by 36,637 on top of that.

**GATES MET AND FLIPPED DEFAULT-ON, 2026-08-26 (same day).** E2E
`--target full` flag-on: **1,691 / 1,691**, with the harness cache forced cold
(`touch test/elm/src/*.elm` — the recorded env-blind-cache trap) so every test
program compiled fresh under the flag (`0 cached` on every sub-suite).
elm-tests flag-on: **13,355 / 12** — the pre-existing failure set exactly
(if-chain + 11 node-type-scoping). Dispatch: runtime-calls Run AO, NEUTRAL
(−274 fast of 560 M, one spec split, events conserved). Analysis coverage
(gate 0): **+7.14 pp at artifact positions** (16.59 % → 23.73 %) — the largest
single completeness gain measured in this arc, double the readback delta,
because the position metric exposes the storeless-⊤ stamps the ledger flattered
(⊤ = 54.3 % of positions at old defaults). Escape hatch
`ECO_MONO_LSS_REF_IDENTITY=0`; `lssRI=0` now rides the OFF arm.

**NO NEW CARRY-FORWARD IS NEEDED.** The registry demand type and
`Engine.lssSignatures` already carry information across items. Nothing needs to
travel; the reference site needs to READ the store instead of stamping `⊤`. Find where a list
literal's elements are translated and whether a `g|` member is injected into
the element's slot; compare against the lambda path that works. All four
eliminations above were inference-side, which is why none of them moved the
number.

**METHOD NOTE, fourth occurrence in this register.** Two intermediate readings
of this experiment were WRONG and both were tooling, not reasoning: `grep`
without `-a` in later stages of a pipe silently suppresses matches on
binary-looking input, which produced a false "the flag destroyed
`LssTaskSetProbe`'s set" and a false "no set is formed". Put `-a` on EVERY grep
in a census pipeline.

### §5.5 Retire the compensation layer

Only once `Q` is the solver: the ~11 transport hooks, ⊤-as-join-result,
⊤-as-widening. One piece per commit, each byte-neutral or individually measured.

---

## §6 Gates

0. **THE PROGRESS GATE (SUPERSEDES GATE 3's OLD CLAUSE — user-directed,
   2026-08-26): ANALYSIS COVERAGE MUST RISE.** *Completeness first,
   exploitation later.* `coverage = (k1 + kN) / positions` over arrow positions
   in the emitted artifact; `LVar` and `LTop` are both UNCOVERED. Emitted as the
   `coverage:` census line (`Mono.annoCoverage`, added 2026-08-26). **A `kN` set
   counts exactly as much as a `k1` set** — which inverts this register's
   long-standing tension, where every precision gain that converted a singleton
   into a 2-set scored as a regression. Baseline at HEAD, ARTIFACT POSITIONS
   (the gate metric, measured 2026-08-26): defaults **16.59 %**
   (127,957 positions, ⊤ 54.3 % / var 29.1 %), `+refIdentity` **23.73 %**
   (+7.14 pp). Per-readback ledger for continuity with older entries only:
   36.71 % / 40.28 % / 41.37 %. Note the metrics DISAGREE on the diagnosis —
   at positions ⊤ dominates, at readbacks var does; the position figure is the
   gate. Full statement: `plans/lss-solver-root-signature-identity.md` §4
   gate 0.
1. §2.5 ledger `RECONCILES=yes`; **headline is `kN` RISING and `var` falling**.
2. `MSET`/`multiSetSites` — `LssTaskSetProbe` is the named pin.
3. Fast-dispatch census A/B with the `sat + fast` invariance rail
   (`benchmarks/runtime-calls.md` Run AE protocol). ~~Coverage must not
   regress~~ — **RECORDED, NOT GATED, as of 2026-08-26.** A fall in
   fast-dispatch coverage that buys a rise in ANALYSIS coverage (gate 0) is an
   accepted trade; `plans/lss-sum-lowering.md` is the consumer that reaps it
   later. **Terminology:** "coverage" is now ambiguous in this register — say
   **analysis coverage** (gate 0) or **fast-dispatch coverage** (this gate),
   never bare "coverage".
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
