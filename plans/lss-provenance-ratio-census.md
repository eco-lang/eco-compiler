# Provenance-ratio census — measuring the layer Q is blind to

**Status:** proposed 2026-08-27. Small: two `Env` fields, one census line, no
new traversal and no new counters in any hot path.

## §1 Why this exists

Analysis fidelity to the LSS paper decomposes into three layers. We instrument
one of them well and the other two not at all:

| layer | question | instrument today |
|---|---|---|
| 1. constraint GENERATION (ζ) | do we emit every equality the paper does? | **NOTHING** |
| 2. SOLVING | given our constraints, do we extract all that follows? | `Q` — `REPRODUCES=yes diverge=0`, clean |
| 3. DENOMINATOR | are we counting positions the paper would count? | nothing (needs the liveness census) |

**`Q` is structurally blind to layer 1.** `Q` records the constraints the solver
emits and re-solves them independently, so it verifies that we extract
everything OUR constraint system implies. A constraint we never emit is not in
`Q`'s input and cannot appear in its output. `diverge=0` is therefore evidence
about solving, and says nothing whatever about generation.

Layer 1 is exactly where Eco is known to be incomplete. The paper's step (3) is
`ζ = 𝓔(ξ)` — the lambda-set equalities implied by the type equalities
(146:10) — and Eco reads them off the checker's union-find rather than
re-deriving them. `Compile.elm` stamps `TypeIds.SolverRoot idx` onto each arrow
while the solver state is live, and its own comment records the leak: the walk
*"leaves any subtree it cannot follow in lockstep as `NoArrow`"*. Module scoping
is the second leak (a raw root index is meaningless across modules, so
cross-module equalities are never formed).

`plans/lss-solver-root-signature-identity.md` §2.4a states the consequence
exactly: Eco's ζ ⊆ the paper's ζ, and **"a missed equality means a variable
stays a variable — an analysis-coverage loss, never a false union."**

That sentence is the whole motivation. It means part of the `var` bucket is NOT
"information never had" but "an equality we failed to generate", and it is the
part `Q` can never see. Today we cannot say how big it is.

## §2 What to measure

An arrow reaching `AssignMVarIds.rewriteCanType`'s `TLambda` arm goes down one
of two paths, and they are exactly the two populations we need:

- `TypeIds.SolverRoot rootIdx` — provenance SURVIVED. `recordRootKey` records
  `occId -> rootKey`.
- `_` (`NoArrow`) — provenance was LOST upstream. A fresh occurrence id is
  minted and nothing is recorded.

So:

```
arrows       = Id.toComparable nextArrow - Id.toComparable firstArrowId
withRoot     = Dict.size arrowRootOf
rootClasses  = -nextRootKey - 1          (keys are -1, -2, … by construction)
```

**provenance = withRoot / arrows.** The layer-1 fidelity number. 1.0 means every
arrow in the program carried the checker's identity into LSS and no 𝓔 equality
was lost to a stamping failure. Below 1.0, the shortfall is arrows for which we
CANNOT have generated the paper's equality, because we no longer know which
class they belong to.

**tie = (withRoot - rootClasses) / withRoot.** How much recovered provenance
actually MERGES anything. Necessary because provenance alone is not information:
if every arrow sat in its own root class, 𝓔 would be the identity relation and a
provenance ratio of 1.0 would be worth nothing. `tie` is the share of
provenance-carrying arrows that share their class with at least one other arrow.

Report `arrows`, `withRoot`, `rootClasses` raw beside both ratios, so the line
is re-derivable and joinable and neither ratio has to be trusted on its own.

## §3 What the number does and does not license

**It is an UPPER BOUND on layer-1 loss, not a measurement of lost sets.** A
missed equality only costs coverage if the two arrows it would have tied
actually differ in what reaches them — tying two already-empty slots changes
nothing. So `1 - provenance` bounds the damage from above; it does not predict a
coverage gain.

**The denominator is program arrows, not artifact positions.** `arrows` counts
occurrences in the whole `GlobalGraph` at `AssignMVarIds` time; the `coverage:`
gate counts arrow positions per specialization in the emitted registry
(133,652). They are different populations and MUST NOT be divided into one
another. This is the same never-say-bare-"coverage" discipline the arc already
carries.

**It cannot see the paper's equalities we never had the chance to lose** — any
place the CHECKER itself does not unify what the paper's ξ would. That is a
deeper question about our type inference, out of scope here.

## §4 Implementation

Everything needed already exists in `GlobalMVarState`; the `sigRootIdentity`
side table made this free. Four edits:

1. `Engine.Env` gains `arrowTotal : Int` and `arrowRootClasses : Int`
   (`arrowRootOf` is already there, so `withRoot` needs no field).
2. `Monomorphize.initState` sets both from `mvarState`, next to the existing
   `arrowRootOf = mvarState.arrowRootOf`.
3. `Monomorphize.renderLssReport` emits one line beside `coverage:`:
   `provenance: arrows=N withRoot=N rootClasses=N provBp=NNNN tieBp=NNNN`
   Basis points, matching `coveredBp`, so no float formatting.
4. `Store.testLoadCtx*` untouched — this reads nothing during loading.

**Report-gated only.** The counters are already-computed state, so there is no
hot-path cost, and `report` is excluded from the config hash — the artifact
cannot move. Byte-identity at defaults is the gate.

## §5 Gates

1. Flag-off/on is not applicable — this is a census line, always computed,
   printed under `lss.report`.
2. **Analysis-invariance at defaults**, NOT byte-identity. This edits compiler
   source and the workload is the compiler compiling itself, so the artifact
   necessarily moves (`lss-solver-root-signature-identity.md` §3.2a — the same
   trap, which cost a gate cycle there). The correct assertion is that the
   analysis is untouched: `coverage:`, `ledger:`, `sigfacts` and `signatures:`
   must be IDENTICAL to the pre-change run, since this change adds counters and
   reads no new state during solving. Reference (clean bootstrap, new
   defaults): `positions=133652 k1=32600 kN=5794 var=37104 top=58154
   coveredBp=2872`, `sigfacts` 1,825, `signatures: 9955 memoized (8386
   trivial)`.
3. `arrows >= withRoot >= rootClasses >= 0`, and `withRoot == 0` iff
   `rootClasses == 0` — a self-check in the same spirit as `RECONCILES`.
4. elm-tests at the pre-existing failure set.

## §5.1 MEASURED 2026-08-27 (self-compile, new defaults, report on)

```
provenance: arrows=254625 withRoot=230955 rootClasses=119127 provBp=9070 tieBp=4841 SANE=yes
```

| quantity | value | reading |
|---|---:|---|
| `arrows` | 254,625 | arrow occurrences stamped by `AssignMVarIds` |
| `withRoot` | 230,955 | carry the checker's identity — CAN participate in an 𝓔 equality |
| **lost provenance** | **23,670** | **9.30 % — CANNOT, whatever the solver does** |
| `rootClasses` | 119,127 | distinct solver-root classes |
| **`provBp`** | **90.70 %** | layer-1 fidelity |
| **`tieBp`** | **48.41 %** | share of provenance-carrying arrows that share a class |

**Layer 1 is a real but BOUNDED gap: 9.30 %.** Nearly one arrow in eleven
reaches monomorphization with no solver provenance, so the paper's `𝓔` equality
for it cannot be generated at any price — this is upstream of the solver, which
`Q` separately certifies clean.

**`tieBp` = 48.41 % says the recovered provenance is genuinely informative.**
230,955 arrows collapse into 119,127 classes (≈1.94 arrows per class), and
almost half of provenance-carrying arrows share their class with at least one
other. `𝓔` is nowhere near the identity relation, so a `provBp` point is worth
having rather than being a bookkeeping artefact.

**Analysis invariance held where it must.** `coverage:` identical to the field
(`positions=133652 … coveredBp=2872`), `signatures: 9955 memoized (8386
trivial)` identical, `sigfacts` 1,825 identical. The readback `ledger:` moved
by +58 of 507,310 (k1 +30, var +28; `kN`/`overcap`/`top` unchanged) — that is
the WORKLOAD growing, not the analysis shifting: this change edits the
compiler, the compiler compiles itself, and the new `bp` helper and record
fields are themselves arrows to read. Perturbation is structurally impossible
in the other direction: `renderLssReport` runs on `sFinal` AFTER solving and
reads only already-computed state, and the two `Env` counters are set once at
`initState` and never read while solving.

## §6 What the answer changes

The measured 90.70 % lands between the two anticipated outcomes, so both
readings apply in part:

- **There IS a concrete, paper-grounded layer-1 target: 23,670 arrows.** It sits
  in `Compile.elm`'s lockstep stamping walk (the `NoArrow` fallback) and module
  scoping — NOT in the solver, which `Q` certifies clean. Anyone tempted to
  attack `var` by improving propagation should read this line first: 9.30 % of
  arrows are beyond propagation's reach by construction.
- **But it is almost certainly NOT the whole `var` story.** Do not divide 9.30 %
  into `var`'s 27.8 %: the denominators are different populations (254,625
  program arrows vs 133,652 artifact positions) and §3 forbids the division.
  What can be said is qualitative and weak — a 9.30 % shortfall on one
  population does not look big enough to account for a 27.8 % bucket on
  another, so the liveness census (dead vs live `var` positions) remains
  necessary to interpret `var` and is the natural next measurement.

**The bound is an upper one and must be quoted as such.** Recovering a lost
equality only buys coverage if the two arrows it would tie actually differ in
what reaches them. 23,670 is the ceiling on the damage, not a forecast of the
gain.

---

# §7 The liveness census — is a `var` position one the paper would even have?

## §7.1 Why, and what is already known

Layer 3 asks whether we are counting positions the paper would count. The paper
specializes demand-driven from a monomorphic entry point, so every position it
EMITS has a concrete set; a position no producer reaches is one it never
creates. Eco keys specs on type and layout instead, so it can emit an arrow
position nothing inhabits — and the gate counts that as uncovered.

**A partial split already exists** and must be read first, because it reframes
the question. `settled-var-arrows`, measured 2026-08-27 at the new defaults:

```
varArrows=20798 setArrows=14403 attributed=224233 ofVar=267877
knownElsewhere=33437/749arr  unknownEverywhere=190796/20049arr
```

So of 20,798 arrows with a still-`var` readback, only **749 (3.6 %)** have a
concrete readback in ANOTHER item's store — the per-item-teardown prize a
post-mono solve would collect. **20,049 (96.4 %) are `unknownEverywhere`:
nothing, anywhere, ever writes them.**

`Engine.elm` explains that population as *"kernel/FFI/port boundary — no
reordering helps"*. **That explanation is untested and looks wrong.** The
`zc|<global>|flex` attribution puts the mass in `List.foldrHelper` (22,776),
`Json.Decode.apply` (14,964), `Dict.balance` (10,890), `Result.map` (10,166),
`List.foldl` (8,985) — ordinary polymorphic combinators, not boundaries. Either
the comment is wrong or the attribution means something other than it appears
to, and either way it is a claim in the code that no measurement supports.

## §7.2 The measurement

**Definition.** An arrow is APPLIED if it is ever peeled by an argument at a
call site. That is not a proxy for application — in
`LssInfer.unifyParamsBestEffort` it IS application: the function's arrow is
destructured into (param, rest) precisely because an argument is being passed
to it.

Mark, per `ArrowId`, that it was applied; then intersect with the existing
`settled.varArrows` / `settled.setArrows` keyspaces:

- **`var` ∩ applied — LIVE-UNKNOWN.** A real call site whose target we cannot
  name. The paper would have a set here. This is genuine incompleteness and the
  honest numerator of any "how incomplete are we" claim.
- **`var` \ applied — NEVER CALLED.** A function-typed position that is never
  invoked in the emitted program. `var` is a defensible answer; the paper would
  not have needed a set. These should arguably leave the gate's denominator.

**MANDATORY CONTROL: `set` ∩ applied must be HIGH.** Concrete arrows are
overwhelmingly ones we resolved because they are called; if they do not show up
as applied, the instrument is not seeing applications and the `var` split is
meaningless. A low control invalidates the finding — it does not become the
finding. This is the differential discipline this arc has now paid for twice
(`TestPipeline`'s inert stamping, `LssSigFlowTest`'s collapsed arms).

**Coverage limit, stated up front.** The hook sits on the argument-unification
path. Call shapes that never peel an arrow there — kernel calls, and
letEnv-bound local callees with their own arms — may be undercounted. The
control ratio QUANTIFIES that limit rather than leaving it as a caveat: it is
an empirical lower bound on how much of application the hook sees.

## §7.3 Implementation

Mirrors `multiSetsByArrow`, which is already a global `ArrowId`-keyed dict that
survives `resetItem`:

1. `Engine.SigStats` gains `appliedArrows : CoreDict.Dict Int Int`.
2. `Engine.bumpAppliedArrow` — report-gated, resolves set-slot pointKey →
   `ArrowId` through `itemAux.arrowOfSlot` (the same join key the multi-set
   census uses, so the three keyspaces intersect exactly).
3. `LssInfer.unifyParamsBestEffort` calls it on the `Just ( pParam, pRest )`
   arm, using `Store.arrowSetSlot desc.content`.
4. One report line:
   `liveness: varArrows=N varApplied=N setArrows=N setApplied=N liveBp=NNNN controlBp=NNNN`

Report-gated throughout: `arrowOfSlot` is only populated under `lss.report`, so
the census reads 0/0 with the flag off and CANNOT move the artifact.

## §7.5 MEASURED 2026-08-27 — THE INSTRUMENT DOES NOT WORK. NO SPLIT IS REPORTED.

Two attempts, both failing the control. Per §7.4 gate 2 the `var` split is NOT
reported from either.

| attempt | hooks | `appliedArrows` | `setApplied/setArrows` | **`controlBp`** |
|---|---|---:|---|---:|
| 1 | `LssInfer.unifyParamsBestEffort` | 15,981 | 1,550 / 14,403 | **10.76 %** |
| 2 | + `Translate.unifyParamsCollect`, `Translate.resultVarAfter` | 17,446 | 1,601 / 14,405 | **11.11 %** |

Attempt 1's hook was a mistake worth recording: `LssInfer.unifyParamsBestEffort`
has exactly ONE caller, `localCalleeJoin` — "a call whose callee is a
letEnv-bound LOCAL". A narrow special case mistaken for the general path.

**But attempt 2 is the informative one: fixing that barely moved the control
(+0.35 pp), which REFUTES "the hooks are incomplete" as the explanation.** The
keyspaces are near-DISJOINT, not nested:

```
appliedArrows = 17,446
  ∩ setArrows =  1,601   (of 14,405 set arrows)
  ∩ varArrows =  8,239   (of 20,805 var arrows)
  in neither  =  7,606
```

Applied arrows overlap VAR arrows 5× more than SET arrows. Incomplete coverage
produces a subset; it does not invert a correlation.

**First hypothesis — devirtualization — TESTED AND INSUFFICIENT.** The idea was
that a resolved singleton call is rewritten to a direct call and so never peels
generically, biasing the instrument against exactly the arrows the control
counts. The counters refute it as a complete explanation:

```
devirtDirect 4,529 + devirtKernel 991      =  5,520 devirtualised sites
concrete arrows NOT marked applied         = 12,804  (14,405 - 1,601)
```

Even granting one arrow per devirt site, devirt accounts for at most ~43 % of
the gap. Something else dominates.

**What the evidence actually supports is weaker and more awkward: THE CONTROL'S
PREMISE IS FALSE.** The control assumed concrete arrows are overwhelmingly ones
we resolved BECAUSE they are called. But an arrow reads back concrete whenever
members reach its slot — including arrows in stored demand types that are never
call sites at all: a function held in a record field, a returned closure, a
value passed through and never invoked. Those are legitimately concrete AND
legitimately never applied. If they are numerous, a low `controlBp` is the
CORRECT reading of a WORKING instrument.

**So the honest status is "unvalidated", not "broken".** The liveness numbers
may be right; the control chosen cannot tell us, because it presupposed a
correlation that the analysis does not guarantee. Reporting `liveBp` would mean
reporting a number whose only check has been withdrawn — so it stays unreported,
but on the ground that it is UNWARRANTED, not that it is wrong.

**What a working validation would need:** a control that does not assume any
relationship between resolution and application. The obvious candidate is a
POSITIVE control from ground truth — take arrows at positions known by
construction to be called (a spec's own top-level arrow for a function that the
emitted graph contains a call to) and confirm those register as applied. That
tests the hook directly instead of via a correlation, and it is the piece
missing here.

**The control earned its place.** Without it this pass would have reported
`liveBp` 33.41 % and then 39.60 % as "a third of `var` positions are live",
twice, from an instrument measuring something else. Two prior instruments in
this arc failed the same way (`TestPipeline`'s inert stamping,
`LssSigFlowTest`'s collapsed differentials); a census without a control is a
number without a warrant.

## §7.6 POSITIVE CONTROL — PASSES 100 %, and it changes the verdict

The correlation-based control was withdrawn (§7.5). Its replacement assumes
nothing: every call of `noteApplied` IS an application, so `apply|attempt` is a
ground-truth denominator, and the split says exactly where an application is
lost — `noSlot` (content was not a `FunL`), `noArrowId` (`arrowOfSlot` cannot
name the slot), or `hit`.

```
liveness: attempts=512757 hit=512757 noSlot=0 noArrowId=0 hitBp=10000
```

**512,757 applications, 512,757 named, zero lost.** The hook sees applications
and resolves every one to an `ArrowId`, so `appliedArrows` is a SOUND set of
"arrows applied on the hooked paths".

**Consequence: the low `controlBp` (11.11 %) is a REAL PROPERTY, not an
artefact.** §7.5's revised reading is confirmed — concrete arrows are largely
NOT applied, so "concrete because called" was simply false, and the original
control was measuring a correlation that does not exist.

**What is now warranted:** `varApplied` is a valid LOWER BOUND, because
unhooked paths could only ADD applications, never remove them. So **at least
39.62 % of `var` arrows (8,248 of 20,815) are applied somewhere** — they are
live positions with no nameable target, which is genuine incompleteness and not
denominator inflation.

**What is still NOT warranted: the COMPLEMENT.** "60 % of `var` is never
applied" does not follow, because of one unexplained number:

```
appliedArrows 17,454 — of which  1,602 in setArrows
                                 8,248 in varArrows
                                 7,604 in NEITHER   (43.6 %)
```

`varArrows ∪ setArrows` is supposed to cover every arrow that was ever zonked,
so an applied arrow in neither was applied but never read back. Until that is
explained — a discarded item, a spec never recorded, or a keyspace mismatch
between the marking point and the settle-time replay — the complement cannot be
trusted, and the liveness census must be quoted ONLY as the lower bound.

## §7.7 FLAG-GATING — `lss.arrowCensus`, DEFAULT-OFF

The liveness marking is NOT free: `noteApplied` runs a union-find `repr`, two
dict lookups and two counter bumps **per application**. Left under `lss.report`
it would be paid by every benchmark run, because the benchmark protocol MANDATES
`ECO_MONO_LSS_REPORT=1`.

**This is the `qCensus` situation exactly, and it has already been paid for
once.** `lss.qCensus` was SPLIT OUT of `lss.report` on 2026-08-26 for the same
reason — every timed run was recording ~106k constraints plus a solve and a
reachability walk inside the measured wall/RSS/GC. Do not repeat it.

- **`lss.arrowCensus`** (`ECO_MONO_LSS_ARROW_CENSUS`, token `lssAC=`,
  DEFAULT-OFF) gates the per-application marking AND the `liveness:` line.
- **It REQUIRES `lss.report`**, because the `ArrowId` lookup goes through
  `itemAux.arrowOfSlot`, which `Store` populates only under `report`. With
  `report` off the census cannot name anything, so the flag is documented as
  needing both.
- **The line prints ONLY when the flag is on** — the `qCensus` rule. Printing
  all-zero counters under `report` alone would render as a measurement that
  found nothing, when in fact nothing ran. That is the failure mode the
  `qCensus` comment calls out by name.

**`provenance:` stays under `report` and is NOT flag-gated.** It is genuinely
free per compile: `arrowTotal` and `arrowRootClasses` are two integers copied
once at `initState`, and the line reads them plus one `Dict.size` at render.
There is no per-call, per-arrow or per-item cost to gate.

**VERIFIED 2026-08-27, and the A/B is stronger than the gate asked for.** Same
binary, same source, only `ECO_MONO_LSS_ARROW_CENSUS` differing:

| | flag-off | flag-on |
|---|---|---|
| `liveness:` line | absent | present |
| `apply\|` rows | 0 | 2 |
| `coverage:` | `positions=133971 … coveredBp=2867` | **identical** |
| `provenance:` | `arrows=254922 withRoot=231226 … provBp=9070 tieBp=4844` | **identical** |
| positive control | — | `512861/512861`, `hitBp=10000` |

Coverage and provenance being IDENTICAL across arms proves the census is
read-only. Note this is a genuinely better inertness check than the
"analysis-invariance across builds" of §5 gate 2: that one drifts every time,
because each build edits the compiler that compiles itself (this pass's own
flag plumbing moved `coveredBp` 2872 → 2867 by adding ~60 lines of config code
whose own positions are mostly unresolved). **A same-binary env-var A/B has no
such confound and should be the gate for any future census.**

## §7.4 Gates (liveness)

1. Analysis invariance at defaults — `coverage:`, `sigfacts`, `signatures:`
   identical (see §5 gate 2 for why byte-identity is the wrong assertion).
2. `controlBp` must be high. If it is not, report the instrument as broken and
   do NOT report a `var` split from it.
3. `varApplied <= varArrows`, `setApplied <= setArrows`.
4. elm-tests at the pre-existing failure set.

---

# §8 The stamping-walk census — WHERE the 9.30 % is lost

## §8.1 Why this must precede any fix

§5.1 measured 23,670 arrows reaching monomorphization with no solver
provenance. That number is not yet actionable, because of how the walk fails.

`SolverRoots.stampArrowRoots` descends the canonical type and the solver's type
in LOCKSTEP: `TLambda` expects `Fun1`, `TType` expects `App1`, `TRecord` expects
`Record1`, `TTuple` expects `Tuple1`, `TAlias Holey` expects `Alias`. Every
mismatch arm does the same thing — `_ -> canType` — which returns the node
**unstamped AND unrecursed**. `stampArrowRootsList` matches it on a length
mismatch: *"the lockstep is lost, leave the rest alone."*

**So one mismatch does not lose one arrow; it abandons the whole subtree.**
23,670 is therefore consistent with two opposite worlds:

- ~20,000 small independent failures spread across all arms — the walk is
  broadly fragile and there is no single fix;
- a few hundred failures high in large types, each shedding a big subtree — a
  handful of cases account for nearly everything, and one arm might recover most
  of the 9.30 %.

Nothing currently distinguishes them, and they call for opposite work.

**A second split matters at least as much.** `Compile.elm` names TWO sources of
lost provenance: the walk failing, and arrows built AFTER the solve, which never
enter the walk at all. No repair to `stampArrowRoots` can touch the second. If
its share is large, fixing the walk is mostly wasted effort and the real target
is wherever post-solve types are constructed.

## §8.2 Measurement — read the STAMPED OUTPUT, not the walk

The obvious instrument (counters at each `_ ->` arm) needs the census to escape
a pure function in the TYPE-CHECK phase and reach a report rendered in the MONO
phase. That is real cross-phase plumbing (`Compile` → `Build` → `Generate`, or a
new `FEStats` channel) for a diagnostic.

**`AssignMVarIds` already walks every stamped type in the mono phase, and the
stamped output distinguishes the two populations by itself:**

- a type with SOME arrows stamped and some not ⇒ the walk RAN and DESCENDED
  (something got stamped) and then broke. **Unambiguous mid-walk abandonment.**
- a type with NO arrows stamped ⇒ the walk never ran on it, or failed at the
  root. **The never-walked-or-root-failed population.**
- a type with ALL arrows stamped ⇒ clean.

That is exactly the §8.1 reconciliation, and it needs no solver state and no
plumbing. It deliberately does NOT report which arm mismatched or what the
solver held instead — that needs the in-walk instrument, and is only worth
building if this census shows the walk is where the loss actually is.

Per-type classification comes from snapshotting two counters the provenance
census already maintains, around each TOP-LEVEL `rewriteCanType` call (the ten
external call sites; the recursive ones inside must NOT be wrapped):

```
arrowsInType   = nextArrow    after - before
stampedInType  = arrowsStamped after - before      (new counter, bumped in the SolverRoot arm)
```

`Dict.size arrowRootOf` must NOT be used for this — it is O(n) in Elm and would
make the pass quadratic.

Report:

```
stampwalk: types=N all=N none=N partial=N | arrowsNone=N arrowsPartialUnstamped=N
           lostTotal=N RECONCILES=yes|NO
```

## §8.3 Gates

1. **`RECONCILES`**: `arrowsNone + arrowsPartialUnstamped` must equal
   `arrows - withRoot` from the `provenance:` line (23,670-ish). A mismatch means
   the wrapper missed a top-level call site — the census is then wrong, and the
   line says so rather than being quietly believed.
2. Same-binary env-var A/B for inertness where applicable (§7.7's lesson);
   these counters are pure bookkeeping in a pass that always runs, so the
   `coverage:` line must be identical to the previous build's.
3. elm-tests at the pre-existing failure set.

## §8.3.1 MEASURED 2026-08-27

```
stampwalk: types=112141 all=104860 none=6438 partial=843
           | arrowsNone=15584 arrowsPartialUnstamped=8145
             lostTotal=23729 expected=23729 RECONCILES=yes
```

`RECONCILES=yes` — the two lost populations sum EXACTLY to `arrows - withRoot`,
so the wrapper caught all ten top-level call sites and the split is over the
whole population, not a sample.

| bucket | types | arrows lost | share of loss | arrows per type |
|---|---:|---:|---:|---:|
| all stamped | 104,860 (93.5 %) | 0 | — | — |
| **partial** (provable mid-walk abandonment) | **843 (0.8 %)** | **8,145** | **34.3 %** | **9.7** |
| **none** (never walked OR root failure) | **6,438 (5.7 %)** | **15,584** | **65.7 %** | **2.4** |

**Subtree amplification is REAL and now quantified.** Each of the 843 partial
types sheds ~9.7 arrows — one mismatch, ten arrows gone. That is the mechanism
§8.1 predicted, and it is why counting arrows rather than failures mattered.

**But it is NOT the dominant population.** Two thirds of the loss sits in types
where NOTHING was stamped, and those are small (~2.4 arrows each) and numerous.
So the answer to §8.1's "few big failures or many small ones" is: BOTH, in a
roughly 1:2 split, with the many-small side larger.

## §8.3.2 THE REMAINING AMBIGUITY, and why it decides the fix

**`none` conflates two populations that need opposite work**, exactly as §8.2
warned:

- **root failure** — the walk RAN and mismatched at the very first node. This IS
  a walk failure and the same repair reaches it.
- **never walked** — the type never entered `stampArrowRoots` at all. No repair
  to the walk touches it.

`AssignMVarIds` cannot tell them apart: both produce a wholly-unstamped type.
So the honest bound today is:

> Repairing `stampArrowRoots`'s mismatch arms recovers **at least 8,145** of the
> 23,729 lost arrows (34.3 %), and **at most 23,729** (100 %) — the upper end
> only if every one of the 6,438 unstamped types was actually walked.

**The measurement that closes this is cheap and specific.** `Compile.elm`
already discriminates the two cases in its stamping guard:

```elm
case ( maybeType, Maybe.withDefault Nothing (Array.get i rootedNodeVars) ) of
    ( Just t, Just v ) -> Just (SolverRoots.stampArrowRoots solverState t v)   -- WALKED
    _                  -> maybeType                                            -- NEVER WALKED
```

Two counters on those arms — nodes walked vs nodes skipped for want of a solver
variable — split the 6,438. It needs the cross-phase plumbing §8.2 avoided
(`Compile` has no stderr channel and the report renders in the mono phase), so
it is a bigger change than this census; but it is now the ONE number standing
between us and knowing whether the walk is worth repairing.

## §8.3.3 MEASURED 2026-08-27 — BOTH GUARDS ZERO SKIPS; THE AMBIGUITY IS CLOSED

`ECO_STAMP_GUARD_CENSUS=1`, one line per module, summed externally:

```
modules=267
nodes:       walked=356693 skipped=0 total=356693 skipped%=0.00
annotations: walked=6383   skipped=0 total=6383   skipped%=0.00
```

**Nothing is skipped. Every node type and every annotation ENTERS the walk.**
So the `none` bucket contains NO "never walked" types at all — those 6,438 types
are ROOT FAILURES: the walk ran and mismatched at the very first node.

**This INVERTS §8.4's decision rule, which was written before the measurement
and was wrong.** The rule said a dominant `none` bucket meant the walk never saw
those types and repairing it would be wasted. The truth is the opposite:

> **ALL 23,729 lost arrows are WALK FAILURES.** Repairing `stampArrowRoots`
> addresses **100 %** of the 9.30 % provenance gap, not the 34.3 % lower bound
> §8.3.2 could justify.

**CORRECTED 2026-08-27 by §9.6 — the sentence above is WRONG.** The guard
census proves nothing is skipped among types that EXIST when the guard runs. It
says nothing about types created AFTERWARDS, and there are such types: the
typed optimizer SYNTHESIZES constructor function types in `addCtorNode`, after
`Compile.elm` has stamped. Those never reach the guard at all, so they are
neither "walked" nor "skipped" — a third case the census could not see. `none`
is therefore root failures PLUS post-stamping synthesis, and repairing
`stampArrowRoots` does NOT reach the latter. See §9.6.

And it re-ranks the two targets — **root failures are the bigger prize**:

| failure | types | arrows | share |
|---|---:|---:|---:|
| **root** (first node mismatches) | 6,438 | **15,584** | **65.7 %** |
| mid-walk abandonment | 843 | 8,145 | 34.3 % |

A root failure is also the more tractable of the two: the top of a def's type
failed to line up with what the solver held for it, which is a far easier thing
to diagnose than a mismatch buried in a nested subtree.

## §8.3.4 HYPOTHESIS (UNTESTED) — the root failures may BE the annotations

`annotations walked = 6,383` against `none types = 6,438`. A gap of 55 out of
6,438 is close enough to be worth testing and far too close to ignore.

A mechanism fits. `stampArrowRootsInAnnotation` walks
`Can.Forall freeVars tipe` against the def's `annotVar`. For a POLYMORPHIC
annotation the solver variable is generalized/quantified and may carry no
`Fun1` structure at all, so `lookupFlatType` returns `Nothing` at the very first
node and the ENTIRE annotation goes unstamped — every arrow in it lost at once.
That would make "annotated polymorphic defs lose all arrow provenance" the
single dominant cause of the 9.30 % gap.

**Do NOT act on this without testing it** — the two counts come from different
populations (`Compile` stamps 356,693 expression node types; `AssignMVarIds`
rewrites 112,186 types), so the near-equality could be coincidence. The test is
cheap: tag the §8.2 wrapper's counters by CALL SITE, so `none` splits into
annotation-path versus node-path. That is one extra argument threaded through
`rewriteCanTypeTop` and its ten call sites.

## §8.4 What each outcome directs

- **`partial` dominates** ⇒ the walk is the target, and the in-walk arm census
  (§8.2's deferred half) becomes worth building to say WHICH arm.
- **`none` dominates** ⇒ MEASURED: it does, 65.7 % — **and this rule as written
  was WRONG.** §8.3.3 shows nothing is ever skipped, so `none` is entirely ROOT
  FAILURES, which the walk repair DOES reach. The rule assumed unstamped implied
  unvisited; measuring the guard refuted it. Repairing the walk addresses 100 %
  of the gap.
- **both large** ⇒ two independent problems, and the ratio sizes each.

---

# §9 GAP EXAMPLES — probing §8.3.4, which is REFUTED; the real cause is CONSTRUCTOR ARROWS

## §9.1 Method

Small single-purpose programs in `test/elm/src`, each compiled standalone with
`ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_ARROW_CENSUS=1 ECO_STAMP_GUARD_CENSUS=1`.
A tiny program takes seconds, so iteration is cheap — unlike the ~20-minute
self-compile the rest of this plan measures on.

**What licenses the comparison:** `stampwalk none=122 arrowsNone=218` is
IDENTICAL across eight structurally different probes, and `LssGapNoDecls` (a
negative control declaring nothing) sits exactly on it. So 122/218 is fixed
background from `elm/core` + `Html`, and any deviation is attributable to the
probe's own declarations. Without that control the deltas below would be
uninterpretable.

## §9.2 §8.3.4 IS REFUTED

| probe | `applyTwice` signature | none | arrowsNone |
|---|---|---:|---:|
| `LssGapMonoAnnotated` | `(Int -> Int) -> Int -> Int` | 122 | 218 |
| `LssGapPolyAnnotated` | `(a -> a) -> a -> a` | 122 | 218 |
| (deleted) inferred | none | 122 | 218 |

**A polymorphic annotation loses NO provenance.** All three are identical, so
"annotated polymorphic defs lose all their arrow provenance" is false. The
near-equality of `annotations walked = 6,383` and `none types = 6,438` that
suggested it was coincidence — exactly the risk §8.3.4 flagged, now realised.

## §9.3 THE REAL CAUSE — synthesized CONSTRUCTOR arrow types

| probe | declares | none | arrowsNone | Δ |
|---|---|---:|---:|---|
| `LssGapNoDecls` | nothing | 122 | 218 | — |
| `LssGapRecordFnNoAlias` | nothing (inline record, fn field) | 122 | 218 | — |
| `LssGapTupleFn` | nothing (fn in a tuple) | 122 | 218 | — |
| **`LssGapEnumNoArrows`** | **`type Colour = Red \| Green \| Blue`** | **122** | **218** | **—** |
| `LssGapCustomTypeFn` | `type Box = Box (Int -> Int)` | 124 | 222 | +2 / +4 |
| `LssGapRecordNoFn` | `type alias Nums = { a : Int, b : Int }` | 125 | 224 | +3 / +6 |
| `LssGapRecordField` | `type alias Ops = { transform : Int -> Int }` | 128 | 230 | +6 / +12 |
| **`LssGapCtorScale`** | **4 types, ctor arities 1+2+3+4** | **130** | **238** | **+8 / +20** |

Three facts pin the cause:

1. **Containers are innocent.** A function in a tuple, or in an INLINE record
   type, loses nothing. So it is not `TTuple`/`TRecord` lockstep failure.
2. **Declaring a type is innocent.** `LssGapEnumNoArrows` declares a custom type
   with three constructors and sits exactly on background — because zero-arity
   constructors have NO ARROWS in their types.
3. **It scales with constructor ARROWS.** 4 constructors of arity 1+2+3+4 = 10
   constructor arrows lose 20; one arity-1 constructor loses 4; one arity-2
   loses 6. Consistently ≈2 arrows lost per constructor arrow.

**Conclusion: the synthesized constructor function of every declared type whose
constructors take arguments loses ALL its arrow provenance.** Record-alias
constructors (`Nums : Int -> Int -> Nums`) and custom-type constructors
(`Box : (Int -> Int) -> Box`) are built outside the solve, so they carry
`NoArrow` and the paper's 𝓔 equality can never be formed for them.

This is a concrete, reproducible, arity-scaling target — a far better one than
§8.3.4's refuted guess, and it is the first named mechanism behind the 9.30 %.

## §9.4 Two further gaps the probes surfaced

**Exploitation, not analysis.** `LssGapBranchSelect` RESOLVES its set —
`sigfacts|LssGapBranchSelect.chosen|0|m=2,gc`, i.e. exactly
`{double, triple}` — and still emits `fastEval=0` with 4 `papCreate`. The
analysis is right and the consumer ignores it. This is the standing kN
exploitation gap, now with a two-line witness.

**Containers leave `var`, not ⊤.** `LssGapListOfFns` (functions in a `List`,
applied through a fold) reads `positions=19 k1=3 kN=2 var=8 top=6` — **42 % of
its positions are `var`**, the worst of any probe.

## §9.5 The examples, and what each is for

All in `test/elm/src`, auto-discovered by the E2E harness. Their `CHECK` lines
assert RUNTIME CORRECTNESS only — deliberately not the gap measurements, so
they do not fail the day someone closes a gap; the measurements live here.

| file | role |
|---|---|
| `LssGapNoDecls` | background control — must sit on 122/218 |
| `LssGapEnumNoArrows` | control — declaring a type is not the cause |
| `LssGapRecordFnNoAlias`, `LssGapTupleFn` | controls — containers are not the cause |
| `LssGapCustomTypeFn`, `LssGapRecordNoFn`, `LssGapRecordField` | witnesses — constructor arrows lost |
| `LssGapCtorScale` | the scaling witness (+8/+20) |
| `LssGapMonoAnnotated`, `LssGapPolyAnnotated` | the §8.3.4 refutation pair |
| `LssGapBranchSelect` | positive control: a 2-set IS resolved; exploitation gap |
| `LssGapListOfFns`, `LssGapPolyTwoTypes` | `var`/⊤-heavy container and polymorphic shapes |

## §9.6 MECHANISM, TRACED IN CODE — constructor types are synthesized AFTER stamping

The §9.3 correlation now has a code path, and it corrects §8.3.3.

**`Compiler/LocalOpt/Typed/Module.elm:147` `addCtorNode`** builds each
constructor's function type from the union DECLARATION:

```elm
resultType = Can.TType home typeName (List.map Can.TVar unionData.vars)
ctorType   = List.foldr Can.tLambda resultType c.args     -- one arrow per argument
```

**`Compiler/AST/Canonical.elm:358`**: `tLambda = TLambda TypeIds.NoArrow`. Its
own docstring states the invariant — only `Compile.elm` (while the solver is
live) and `AssignMVarIds` may name an arrow slot. So `ctorType`'s arrows are
born WITHOUT identity, by design.

**Why stamping can never reach them.** `Compile.elm` stamps exactly two things
while the solver state is live: the checker's expression `nodeTypes` and its
`annotations`. `ctorType` is neither. It does not exist yet — the typed
optimizer runs AFTER type checking and synthesizes it from the declaration, and
there is no solver variable for it because the checker never inferred it as an
expression. This is not a walk failure; it is a type the walk could not have
seen.

**Why the loss is ~2× the constructor arrows.** `addCtorNode` materialises
`ctorType` TWICE — once as the graph node (`TOpt.Ctor c.index c.numArgs
ctorType`, line 162) and once as its annotation (`Can.Forall freeVars ctorType`,
line 175). Both reach `AssignMVarIds` (the node via the `TOpt.Ctor` arm at
`AssignMVarIds.elm:548`, the annotation via the annotation arm) and both are
unstamped, so a k-argument constructor loses 2k arrows. Measured: arity 1 → 4,
arity 2 → 6 (2×2 plus the alias's own), 1+2+3+4 → 20.

**Why enums are exempt, predicted and observed.** `Can.Enum` builds
`TOpt.Enum c.index ctorType` (line 168), and for a zero-argument constructor
`List.foldr Can.tLambda resultType []` is just `resultType` — NO ARROWS. So an
enum loses nothing, which is exactly what `LssGapEnumNoArrows` measured.

**Consequence for the fix.** Repairing `stampArrowRoots`'s mismatch arms does
NOT address constructor arrows; nothing is mismatching. The fix is to give
these types identity where they are BORN — either stamp them in `addCtorNode`
(no solver state there, so it would need a different identity source) or let
`AssignMVarIds` treat a constructor's arrows as a known, canonical family, since
a constructor's arrow structure is fully determined by its declaration and needs
no inference at all.

**Method note.** §8.3.3's error was assuming the guard census enumerated the
whole population. It enumerated everything that existed AT THAT MOMENT. A
later phase creating new arrow types was outside its frame entirely, and only
tracing the code — not more counting — surfaced it.
