# LSS: solver-root signature identity, with per-use instantiation

**Status: BLOCKED (2026-08-26) on §0.6 — `arrowSolverRoots` produces a
MISCOMPILED compiler at HEAD.** The arm lowers cleanly (`Exit status: 0`, zero
`undefined fast evaluator`) and the resulting binary then crashes 0.92 s into
any `make`, reproducibly, 3/3. Diagnose that before building anything here;
§2 reuses the same root identity and may inherit the defect. Design and evidence
below are complete and stand — this is a sequencing block, not a refutation.

The redirect out of `plans/lss-promote-quantified-set-variables.md` §0.2, which
measured that the recoverable set information sits at DECLARED-ARROW positions
and needs correct arrow IDENTITY rather than quantified `ᾱ`.

**One sentence.** Tie a def's annotation arrows to its body arrows using the
type checker's own union-find identity — but ONLY inside the inference scratch
store, so the specialization phase keeps per-occurrence identity and per-call-site
instantiation.

---

## §0 Evidence ledger — what is VERIFIED, what is MEASURED, what is HYPOTHESIS

Everything below was established 2026-08-26. Nothing in this plan rests on an
unmarked assumption.

### §0.1 VERIFIED IN CODE

| claim | evidence |
|---|---|
| The tie mechanism is real and is the documented purpose of `arrowSolverRoots` | `AssignMVarIds.elm:117-121`: *"Two arrows the type checker UNIFIED share a union-find root and therefore get the same `ArrowId` — which is the whole point: a def's annotation arrow and its body node's arrow are structurally-equal DISTINCT objects (measured: 97.5% of the time)"* |
| ArrowIds are minted ONCE, globally, and stamped INTO the type | `AssignMVarIds.elm:1119-1152` — the `Can.TLambda` arm returns `Can.TLambda (TypeIds.Arrow arrowId) …`. **There is no downstream phase choice; the flag decides at mint time.** This is why §3 must mint a side table rather than "turn roots on in inference". |
| Root resolution is best-effort | same arm: only `TypeIds.SolverRoot rootIdx` slots resolve; everything else takes `freshArrowId`, *"the reason 2b degrades rather than breaks where the lockstep stamp walk lost the solver var"* |
| Root ids are module-scoped | `ensureArrowIdForRoot` keys `( moduleKey, rootIdx )`; without it, *"unrelated arrows in different modules collide on a raw index — which would be a FALSE union of two lambda sets"* |
| The inference unit loads through the SHARED arrow memo | `LssInfer.loadMemberSlots` → `Store.loadTypeWithArrows` (`LssInfer.elm:708`), and the body walk uses `Store.loadType` at 16 sites (1436, 1459, 1496, 1566, 1657, 1697, 1726, 1775, 1940, 1997, 2013, 2067, 2088, 2291, 2405, 2880) — all shared, all inside `withScratchStore` |
| **Per-use freshening ALREADY EXISTS at the signature application site** | `LssInfer.instantiateWithSignature` (`LssInfer.elm:127`) → `Store.loadTypeIsolatedWithArrows`, documented *"fresh per-call-site instantiation"*; `isolatedLoadCtx` sets `arrowMemo = Dict.empty` and is never written back |
| Facts transport by ORDINAL, so the caller needs no arrow identity to receive them | `applyFacts` pairs `sig.arrows` against `slots` positionally; Q2 measured every new fact landing at a declared-arrow ordinal |
| `GlobalMVarState` is already the vehicle for a side table | `assignIds : Bool -> … -> ( graph, GlobalMVarState )`; `initState` already lifts `superVars`, `nextId`, `nextLam`, `lamLabels` into `S`/`env` |
| **The ordinal contract SURVIVES within-type slot sharing — by existing design** | `Store.elm:306-326`: the memo hit/miss table is documented with "all four rows load-bearing" — a HIT still **pushes** to `arrowSlots` (so `applyFacts`' length pairing cannot break) and the comment pre-answers the duplicate case: *"NEW AND EXPECTED: the ordinal array can now hold the SAME Point twice. `applyFactsGo`/`repOrdinal` cope (repOrdinal already reports the smallest UF-equivalent ordinal)"* — plus the cost warning that `trivial` goes false more often |
| **The rep tie IS re-applied per use, on the DEFAULT path** | `applyFactsGo` (`LssInfer.elm`): when `fact.rep /= i` it runs `Store.unifyStep slots[rep] slots[i]` against the caller's freshly isolated slots — the paper's `τ[ᾱ↦β̄]` freshening, verified in code, not only in the `qSolve` `schemeTie` variant |
| Arrow-id VALUES touch an equality fast path (cost only, not semantics) | `Translate.elm:2668`: `(a == b) \|\| (stripArrowIds a == stripArrowIds b)` — a `==` fast path that ids can defeat, with an id-blind fallback. Argues for keeping occId numbering byte-stable (§2.1 amendment) |

### §0.2 MEASURED (self-compile, HEAD, `ECO_MONO_LSS_REPORT=1`)

Three arms on one tree: defaults, `+refIdentity`, `+refIdentity +ARROW_ROOTS`.

| counter | defaults | +refId | +refId +ROOTS |
|---|---:|---:|---:|
| `sigfacts` rows | 424 | 424 | **1,502** |
| defs with facts | 411 | 411 | **1,381** |
| `sig\|carrying` | 333 | 333 | **1,297** |
| `sig\|allflex` | 7,264 | 7,264 | **6,295** |
| `k1` | 159,735 | 195,033 | 202,244 |
| `kN` | 2,047 | 3,386 | **6,136** |
| `top` | 28,304 | 20,816 | 18,912 |
| `var` | 250,624 | 273,390 | 276,356 |
| `knownElsewhere` share | 9.9 % | 11.8 % | **42.32 %** |
| `slotsMinted` | 836,761 | 854,948 | **732,344** |
| `sigflow edges` | 177 | 177 | 64 |
| `union` / `topJoin` | 24 / 1 | 1,342 / 1 | 3,567 / 74 |
| `stampedStaged` | — | 682 | **669** |
| `declinedNoInstance` | — | 14,037 | **19,416** |
| `declinedBlocked` | — | 4,641 | 4,738 |
| `declinedAbiMismatch` | — | 8 | 28 |

**Who gains.** 970 defs, of which **965 are `eco/compiler`**. The
dispatch-hot families gain almost nothing: `System.TypeCheck.IO` **1**,
`Compiler.Type.UnionFind` **0**, `Data.IORef`/MVar **0**, `elm/core:List.*` /
`Dict.*` **0**. The bulk is `Compiler.GlobalOpt` (158), `Compiler.MonoSolver`
(80), `Compiler.Type.*` (67) and a long Builder/Details/Outline tail.

**Heat exposure, bounded.** 24.9 % of `gen+typed` dispatch is at NAMED closures
(the rest is anonymous `Terminal_Main_lambda_N$cap`, unattributable by name —
the recorded discipline). Of that named heat, **9.43 % sits at defs that gain
facts** ⇒ roughly **2.4 % of total dispatch heat** is exposed to this change.
The hottest named closures — `System_TypeCheck_IO_map` 41.7 M,
`Compiler_Type_UnionFind_fresh` 35.3 M — are NOT gainers.

### §0.3 HYPOTHESIS — stated as such, and what would refute it

**H-MAIN: the WIN is inference-side and the COST is (mostly) translate-side, so
confining root identity to the inference scratch store keeps the 1,078 facts
without the full `ARROW_ROOTS` penalty.**

- Supporting: the win is produced entirely inside `inferUnitInScratch`
  (annotation↔body tie), and Q2 measured its output landing in the existing
  ordinal vocabulary, which transports without any caller-side identity.
- Supporting: `arrowIdentity`'s own cost was re-measured smaller after LSS_024
  and LSS_025 landed (−0.50 pp → −0.306 pp), i.e. the cost class is
  "stamps lost to slot union at translate" and is partially recoverable by
  better member identity, not intrinsic to having more facts.
- **Against, and it is the honest counterweight:** `declinedNoInstance` rises
  14,037 → 19,416 (**+38 %**) and `stampedStaged` falls 682 → 669 in the ROOTS
  arm. That is the Run-AE/Run-AG signature, and its mechanism is *signature-
  driven*: transported mass is raw `l|`, which declines at AbiCloning per
  LSS_017. **An inference-only arm inherits part of this**, because it exports
  the same raw members through the same channel.
- **Refuted if:** the inference-only arm's `sigfacts` lands well short of ~1,500
  (then the win needed translate-side roots too), or its `declinedNoInstance`
  rise matches the full ROOTS arm's (then nothing was avoided).

**Expected outcome, stated before building:** `sigfacts` ≈ 1,400–1,500, `kN`
up, `var` down, `stampedStaged` down slightly, dispatch coverage **flat to
−0.3 pp**. This is a REACH change in the same class as `callArgFlow` (Run AG:
"reach was the deliverable") and `postSettleDevirt`. It must be sold and gated
as reach, not as performance.

### §0.4 THE LOWERING HAZARD — RE-TESTED AT HEAD, AND IT PASSES

The parent register's gate 5 records the specific failure that makes this
direction risky: *"E2E passed 1,687/1,687 with `arrowSolverRoots=1` while its
self-compile did not lower, because E2E is small programs."* That was LSS_031,
fixed 2026-08-25 (LSS_036), but never re-tested against ROOTS.

Re-tested 2026-08-26 on the artifact the Phase-0 leg already produced:

```
ECO_LSS_DISPATCH_SITE_COUNTERS=1 eco-boot-native p0-roots-out.mlir -o eco-p0roots
  input  15,173,807 B   (self-compile output, +refIdentity +ARROW_ROOTS)
  wall   5:06.75        Exit status: 0        RSS 4,695,576 kB
  output 70,916,688 B
  "undefined fast evaluator" occurrences: 0
```

The lowering PASSES. **But lowering is not the gate it was thought to be — see
§0.5, which is the finding that now blocks this plan.**

### §0.5 BLOCKER — the `arrowSolverRoots` arm LOWERS CLEANLY AND THE BINARY IS MISCOMPILED

Attempting to take the dispatch upper bound produced a much more important
result: **`eco-p0roots` — the compiler self-compiled under `+refIdentity
+ARROW_ROOTS` — crashes 0.92 s into any `make`.**

```
Registry: POST .../all-packages/since/16846 completed in 408ms
Verifying dependencies (17/29) … (25/29)
Eco crash: Error from `Terminal.Main` should have been reported already.
Backtrace (21 frames)                                     Exit status: 1
```

**Controlled, and the control is decisive.** Same command, same
`rm -rf eco-stuff` reset, back to back, same session:

| binary | built from | result |
|---|---|---|
| `eco-disp-def` | defaults | ran the full workload (Run AO) |
| `eco-disp-ri` | `+refIdentity` | **passes 29/29, reaches `Compiling (142)`** |
| `eco-p0roots` | `+refIdentity +ARROW_ROOTS` | **dies at 25/29, 3/3 reproductions** |

`--version` exits 0, so the binary is not wholly broken; the third reproduction
carried no `ECO_MONO_*` workload env at all, so it is not workload-flag
dependent. `refIdentity` alone is exonerated by the `eco-disp-ri` control.
**The variable is `arrowSolverRoots`.**

**Why this matters more than the LSS_031 precedent.** LSS_031 was a LOWERING
failure — loud, and caught by the gate. This arm passes that gate with
`Exit status: 0` and **zero** `undefined fast evaluator`, and the binary it
produces is still wrong. **A clean lower does not imply a correct binary**, and
the standing gate list does not currently catch this class. The cheapest
addition that would: run the freshly-lowered binary on any `make` at all — one
second, and it separates the two failure modes completely.

**What this does to §0.2's numbers.** The census counters (`sigfacts` 1,502 etc.)
were computed by a GOOD binary (`eco-lss-post`) running `ARROW_ROOTS` as a
WORKLOAD flag — so they faithfully report what that analysis computed. But the
same analysis, on the same run, emitted the artifact that miscompiles.
**Until the crash is diagnosed, the 1,078 extra facts cannot be assumed sound**,
and this plan must not treat "reach 1,502 sigfacts" as a win to chase.

**What survives untouched.** The promote NO-GO does not depend on soundness:
Q2's finding is about WHERE facts appear (declared-arrow ordinals, not
type-variable positions), which is a structural property of the enumeration.
`plans/lss-promote-quantified-set-variables.md` §0.2 stands.

### §0.6 BLOCKING ITEM — diagnose the `arrowSolverRoots` miscompile FIRST

No part of §2 may be built until this is understood, because §2 reuses the same
root identity and may inherit the same defect. The diagnosis is cheap to start:
the failure is deterministic, early, and in `Builder`'s dependency-verification
path, so it should bisect quickly — and the recorded method note applies (use
`gdb`, vary ONE thing; the first bisect in a comparable arc blamed the wrong
component). Two outcomes and their consequences:

- **The defect is at TRANSLATE-time slot merging** ⇒ §2's inference-only scoping
  likely avoids it, and this plan proceeds with the crash as its regression pin.
- **The defect is in the FACTS themselves** ⇒ §2 inherits it, and the plan is
  dead until the fact-level soundness bug is fixed.

Either way the artifact is a gift: a small, deterministic, reproducible
miscompile in a flag that is default-off, which is the easiest conditions this
kind of bug is ever found under.

---

## §1 Why not simply flip `arrowSolverRoots`

Three measured reasons, in order of severity:

1. **It coarsens everywhere.** `slotsMinted` −14.3 % (854,948 → 732,344): arrows
   the solver unified share one slot at EVERY load site, including translate.
   §5.2 of the parent register measured that slot sharing without per-use
   freshening *"trades the context sensitivity that manufactures usable
   singletons"* (−0.50 pp, 99 % at one site), and that 2b shares strictly more
   contexts than 2a.
2. ~~**It has a recorded lowering failure.**~~ **CLEARED 2026-08-26 — re-tested
   at HEAD and it PASSES.** The parent register's gate 5 exists because *"E2E
   passed 1,687/1,687 with `arrowSolverRoots=1` while its self-compile did not
   lower"*. That was LSS_031, fixed 2026-08-25 (LSS_036). Re-test: the
   `+refId +ROOTS` self-compile output (`p0-roots-out.mlir`, 15,173,807 B) was
   lowered with `ECO_LSS_DISPATCH_SITE_COUNTERS=1` — **wall 5:06.75, `Exit
   status: 0`, binary 70,916,688 B, ZERO `undefined fast evaluator`**. Since
   this plan's design is a strict SUBSET of full `arrowSolverRoots`' blast
   radius, clearing the superset clears the subset. **This was the one hazard
   that could have blocked the whole direction upstream of any measurement, and
   it is now retired.**
3. **It is a bigger change than the win requires.** The win is one tie
   (annotation↔body) inside one phase. Flipping the flag buys that tie and pays
   for merging every other solver-unified pair in the program.

---

## §2 The design

### §2.1 Mint both identities; stamp the occurrence one

In `AssignMVarIds.rewriteCanType`'s `Can.TLambda` arm, unconditionally:

- take `freshArrowId` as today → `occId`, and stamp `Can.TLambda (Arrow occId)`
  exactly as the current default does (so the stamped graph is unchanged, and
  every flag-off rail still holds byte-for-byte);
- **additionally**, when the slot is `TypeIds.SolverRoot rootIdx`, resolve
  `ensureArrowIdForRoot rootIdx` → `rootId` and record `occId ↦ rootId` in a new
  `GlobalMVarState.arrowRootOf : Dict Int Int`.

`ensureArrowIdForRoot` already exists; the table is partial by construction —
arrows that lost solver provenance simply have no entry, and the tie degrades to
today's behaviour there, exactly as §0.1's "degrades rather than breaks" row
describes.

**AMENDED after the adversarial pass (2026-08-26): allocate root keys from a
SEPARATE key space, NOT the shared ArrowId supply.** If `ensureArrowIdForRoot`
draws from `nextArrow`, every table miss shifts the numbering of all later
occurrence ids versus today's defaults. Occurrence ids are compared for
equality in at least one artifact-relevant fast path
(`Translate.elm:2668`'s `==`-then-`stripArrowIds` fallback), so renumbering is
at best a cost perturbation and at worst a P1 byte-identity failure to debug
for no reason. The memo key is just an `Int`: derive the root key as a value
disjoint from all occurrence keys (e.g. negated, offset by the supply bound, or
a second counter). Then P1's byte-identity gate tests the threading alone, and
occId numbering is byte-stable by construction.

`initState` lifts `arrowRootOf` into `env` beside `lamLabels`, which is the
established pattern for exactly this kind of pre-pass side table.

### §2.2 Key the arrow memo by root — ONLY in the inference scratch store

`LoadCtx` gains one field, `arrowKeyRoots : Bool` (or, equivalently, the table
plus a flag). `Store.loadTypeC`'s `TLambda` arm computes its memo key as
`rootOf arrowId` when the flag is set and the table has an entry, and
`arrowId` otherwise.

Set it **True in `sharedLoadCtx` only while the inference scratch store is
installed**, and False everywhere else.

**The scoping predicate is exact, not approximate — VERIFIED.**
`Engine.withScratchStore` has exactly **one call site in the entire compiler**:
`LssInfer.elm:457`, `Engine.withScratchStore (inferUnitInScratch members) s3`.
So "inside the scratch store" and "computing a signature" are the same
condition, and the flag can simply ride `withScratchStore`'s entry/exit — which
already swaps `store`, `memo`, `revMemo` and `itemAux` and restores them, so the
restore path is written and tested. Carry the flag on `S` rather than on
`itemAux`: `clearedAux` sets aux fields to their *defaults* on entry, which is
the wrong polarity for a flag that must be ON inside.

**Nothing else changes.** In particular:

- `isolatedLoadCtx` keeps `arrowMemo = Dict.empty`. This is not incidental — its
  own doc records the **H1 collapse hazard**: *"`LssInfer.sigSourceTypeFor` and
  the call path read the SAME annotation value out of `s.env.annotations`, so
  threading the item's arrow memo into an isolated load would make every call
  site of an annotated `f` unify into ONE lambda set — monomorphic set analysis,
  maximal imprecision."* The per-use freshening this plan's title depends on IS
  that emptiness. Do not touch it.
- The translate/specialization path keeps per-occurrence keying, so the demand
  channel and the spec keys are unaffected.

### §2.3 The hazard that DOES apply, and why it is a precision question not a soundness one

Root keying inside the unit merges not only annotation↔body but also any two
*body* arrows the solver unified — e.g. two uses of a local whose results were
unified. Members from use A can then reach the annotation ordinal via use B.

That is an **over-approximation**: the set gains members it might not need. Over
-approximating a lambda set is sound (more members ⇒ more dispatch, never wrong
dispatch); it is exactly how `LTop` is sound. It is also the likely source of
part of the measured `kN` 3,386 → 6,136, and therefore of the
`declinedNoInstance` rise. It must be measured, not argued away.

### §2.4a Paper fidelity — this IS the paper's step (3), scoped to inference

Brandon et al. 146:10 gives the inference algorithm as five steps: **(1)**
annotate every arrow with a fresh lambda-set variable; **(2)** accumulate the
type-equality constraints ξ; **(3)** compute the lambda-set-variable equalities
`ζ = 𝓔(ξ)` implied by them — *"we require that each implied lambda set equality
take the form α₁ ∼ α₂ where α₁, α₂ are lambda set variables"*; **(4)** compute
the most general unifier φ of ζ; **(5)** apply it. The mapping is exact:

| paper | Eco under this plan |
|---|---|
| (1) fresh α per arrow | `arrowIdentity` occurrence ids + one fresh `FlexVar` slot per arrow (`loadTypeC`) |
| (2) ξ | the HM typechecker's unification — already run; Eco READS its union-find instead of re-deriving it |
| (3) `ζ = 𝓔(ξ)` | **root identity**: two arrows in one solver root class ⇒ one memo key. `ensureArrowIdForRoot` is 𝓔 computed by the checker's solve |
| (4)+(5) φ applied | same memo key ⇒ same slot Point — the variables ARE unified |
| TIU-Def-Ref `τ[ᾱ↦β̄]` | `loadTypeIsolatedWithArrows` (fresh slots per use) + `applyFactsGo`'s rep unification re-establishing the ties (verified — §0.1) |
| Σ provisional self-type | the scratch-unit shared memo (already rated FAITHFUL) |

**The degradation direction is the sound one.** Eco's ζ ⊆ the paper's ζ: the
`NoArrow` fallback (arrows built after the solve lose provenance) and module
scoping can only MISS an equality, never invent one. A missed equality means a
variable stays a variable — an analysis-coverage loss, never a false union.
And μ stays N/A: members are flat ints, so no constraint can mention a set,
shared slot or not.

**Where this plan deliberately deviates from full 𝓔 — and why that is still
equivalent AT THE SIGNATURE.** The paper applies φ everywhere; this plan applies
it only inside inference. At a call site, a signature whose ordinals i, j are
one variable reaches the caller as `fact.rep`, and `applyFactsGo` unifies the
caller's fresh slots i, j — so the USE sees the same variable structure the
paper's φ would have given it, re-derived per use instead of substituted
globally. Same fixpoint, different evaluation order. The translate-side loads
that full `arrowSolverRoots` would additionally merge are exactly the
context-sensitivity §1 preserves.

**One thing the paper cannot say anything about: type-variable positions.**
L^src is SIMPLY TYPED — its only polymorphism is over lambda sets, so "a set
under a type variable" (GAP-B) has no paper counterpart at all. Eco's answer to
it is the natural lift of 𝓔 to a polymorphic host: `loadVarC`'s `TVar` memo
ties the variable's occurrences, and when instantiation creates the arrow, the
arrow is minted at the use site where occurrence/root identity governs it.

### §2.4b The Q verifier under root identity — NO structural update; ONE mandatory re-run

Asked directly (2026-08-26): does the shadow-`Q` machinery still validate under
root identity, or does it need updating? **It validates unchanged**, for three
code-level reasons:

1. **The recording surface is untouched.** Root keying changes WHICH Point
   receives a write, never the write path: every member/⊤ write still passes
   `unifySlotWithSetC` (→ `noteQ`), every edge still passes `addSlotSource`.
2. **The solve is identity-agnostic.** `qStep` groups constraints by `UF.repr`
   at solve time; two occurrences now sharing a Point collapse to one class
   trivially. Seeds (`QPre`) are captured before the first constraint per
   Point, and `seed ⊔ constraints` remains exactly the eager store's content
   for the shared slot.
3. **The known unrecorded path SHRINKS.** The residual divergences Q has ever
   shown (`merged=12`) come from `Unify.merge` joining two content-carrying
   slots. Sharing at mint replaces post-hoc merging, so that population can
   only fall.

**But it must be RE-RUN as a gate** (§4 gate 8): LSS_037's standing rule is
"turn the verifier on when a write path changes", and while the path is
unchanged, the effective slot contents are not. `REPRODUCES=yes` with
`diverge=0` flag-on is the cheap proof; a divergence there is a genuine defect
in this plan's §2.2.

**One census subtlety that IS an update, small and mandatory:** `noteArrow`
(`Store.elm:347-352`) records `slot → akey` for the MSET census using the SAME
key the memo uses. Under §2.2 the memo key becomes the translated root key —
but the census key must stay the ORIGINAL occurrence id, or the MSET cross-arm
join (which depends on flag-independent occurrence ArrowIds — the Run-AE
lesson) silently breaks. **Memo key ≠ census key; implement them as two
values.** With sharing, `Dict.insert` attributes a shared slot to its
last-loaded occurrence — an attribution smear the census reader must know
about, not a defect.

### §2.4 Soundness of exporting the tied fact

The tie is the type checker's own unification: the annotation arrow and the body
arrow ARE one type. A member written into the body arrow genuinely flows through
the arrow the annotation names, so publishing it at that ordinal is sound.

The LSS_017 representative-hijack class does not re-open here: signatures are
computed pre-spec and use the RAW `injectLambdaMember`
(`LssInfer.elm:160-163` — *"signatures are per-unit and pre-spec by design"*),
so the exported ids are raw `l|`, which AbiCloning declines rather than stamps.
That is simultaneously why this is safe and why it costs `declinedNoInstance`.

---

## §3 Phases

**P0 — BLOCKER: fix the `arrowSolverRoots` miscompile. NOTHING ELSE IN THIS
PLAN MAY START UNTIL THIS IS DONE.** §0.5/§0.6 have the evidence and the
controls. Three reasons it is a hard blocker rather than a parallel task:

1. **§2 reuses the same root identity**, so the defect may be inherited
   wholesale. Building on top of a known-miscompiling mechanism would mean
   debugging two things at once.
2. **It is on the critical path for the programme goal now.** Under §4 gate 0,
   `arrowSolverRoots` is worth **+1.09 pp of analysis coverage** on top of
   `refIdentity`. Before the gate change its dispatch cost kept it default-off
   and the crash was a curiosity; now the crash is the only thing between us and
   the coverage.
3. **Every measurement taken under the flag is provisional until it is fixed**
   (§0.5): the analysis that produced `sigfacts` 1,502 and the 42.32 %
   recoverable pool is the same analysis that emitted the broken artifact.

**Reproducer (deterministic, 3/3):** lower any `+arrowSolverRoots` self-compile
output and run `make` with the resulting binary — it dies in 0.92 s at
`Verifying dependencies (25/29)` with
`Eco crash: Error from `Terminal.Main` should have been reported already.`
`--version` exits 0. The control (`+refIdentity`, no roots) passes 29/29 and
reaches `Compiling (142)` on identical arguments.

**CONTROL-MATRIX HOLE, found by the adversarial pass (2026-08-26): the crash
arm differed from its passing control in TWO variables, not one.** The crashing
artifact (`p0-roots-out.mlir`) was emitted with `ECO_MONO_LSS_REPORT=1` AND
`ARROW_ROOTS=1`; the passing control (`AN-on-out.mlir` → `eco-disp-ri`) had
NEITHER. `report` is documented output-only, but that is not currently PROVEN
on this tree (the AM-vs-AN `out.mlir` sizes differ, and the binaries differed
too — inconclusive). The missing control exists on disk: `AM-on-out.mlir` =
`+refIdentity +report`, no roots.

**CONTROL RUN 2026-08-26 15:44 — `report` EXONERATED; the attribution is now
SINGLE-VARIABLE.** `AM-on-out.mlir` lowered clean (`exit 0`, 0
`undefined fast evaluator`) and its binary ran PAST the crash point on the
identical command — `Verifying dependencies (29/29)`, reached
`Compiling (142)`, stopped only by the deliberate 150 s timeout (`exit 124` =
the pass signal). Full matrix, all four arms now run:

| artifact | refId | report | roots | verdict |
|---|---|---|---|---|
| `AN-off-out` (`eco-disp-def`) | – | – | – | runs (Run AO) |
| `AN-on-out` (`eco-disp-ri`) | ✓ | – | – | runs, 29/29 → Compiling(142) |
| `AM-on-out` (`eco-amon-ctl`) | ✓ | ✓ | – | **runs, 29/29 → Compiling(142)** |
| `p0-roots-out` (`eco-p0roots`) | ✓ | ✓ | ✓ | **crashes at 25/29, 3/3** |

**The crash variable is `arrowSolverRoots`, full stop.** Status: attributed,
NOT diagnosed, NOT fixed.

**First step, and it is small:** `badInside` (`Builder/Build.elm:2522`) fires on
`RNotFound | RProblem | RBlocked`, so the roots-built compiler is failing to
compile **one of the 29 dependency packages** and losing the error on the way
out. Identify that package and compile it alone — that turns the whole-compiler
reproducer into a single-package one. Then the recorded method note applies:
**use gdb, vary ONE thing** — a comparable arc's first bisect blamed the wrong
component and was wrong.

**LEAD SHARPENED 2026-08-26 (offline `addr2line` over the crash's own printed
frames — the binary is RelWithDebInfo, no run needed):**

```
Eco::Kernel::Crash::crash
  ← Builder_Build_addInside_$_26126        <- the badInside crash arm
  ← Dict_foldr_$_26129
  ← Builder_Build_toArtifacts_$_26123
  ← Builder_Build_toArtifactsFromResults_$_26069
  ← Scheduler::stepProcess … System_IO_run ← Terminal_Main_main
```

So the shape is confirmed: one module's compile RESULT is
`RProblem`/`RBlocked` at artifact collection — **the miscompiled binary
mis-compiles (or mis-reports) a VALID dependency module at the front end**, and
the error is swallowed. Two consequences for the bisect: (a) the defect
manifests in the FRONT-END/typecheck path of the roots-built binary, not in
codegen of the program being compiled — look for roots-affected analysis state
feeding the front end (the solver-root memo is mono-side, so suspicion falls on
what the flag changed in the BINARY'S OWN code, i.e. a genuine miscompile of
one of the compiler's functions); (b) instrumenting `badInside` to NAME the
module is a one-line change worth making in the reproducer build.

**Isolation recipe (verified: `Stuff.elm:407-411` honours `ECO_HOME`):** copy
`~/.eco` to a scratch dir, run the reproducer with `ECO_HOME=<copy>` and a
scratch cwd — zero contention with suites or benchmarks on the shared cache.

**ROOT CAUSE ESTABLISHED 2026-08-26 (same day, full runtime + artifact trace).**
The miscompiled function is `Task.map` (Utils task flavour) at the spec serving
`Utils.Task.Extra.apply`'s chain: its wrapper `\a -> succeed (f a)` compiled to
**`\a -> succeed a`** — `num_captured = 0`, the application of `f` β-reduced
away (bad artifact: `Task_map_$_24853` → `Terminal_Main_lambda_21835`; good
artifact captures `f` and chains it). `Task.map f` therefore IS the identity
map; in `Build.findModulePaths` the `(::) x` cons never runs, every source-dir
scan returns `[]`, every inside module is `RNotFound` (which `addErrors` does
not collect — a root nobody imports has no importer to report it), the root
goes `RBlocked`, and `toArtifacts` crashes with `badInside`. Verified at every
step: OS `stat`=0 ✓, kernel returns True ✓ (instrumented `fileExistsBody`),
scheduler delivers the Bool to the right wrapper ✓ (instrumented
`callClosure1`, ordered traces IDENTICAL across arms through the whole scan),
`\flg` builds the cons-pap ✓ — then the map wrapper ignores `f` ✗.

**Mechanism — §2.3's malignant direction, via a THREE-FLAG interaction:**

1. At `apply`'s instantiation, map's `f` is a VARIABLE (runtime: the `(::) x`
   pap or `identity`). At defaults its slot gets NO member → `LVar` → generic
   call → correct.
2. `refIdentity` injects `g|Basics.identity` at the `else`-branch's bare
   reference — the member supply.
3. The `(::) x` PARTIAL APPLICATION injects nothing — the recorded PAP gap
   (`plans/lss-pap-argument-members.md`), the one-sidedness.
4. `arrowSolverRoots` merges the callback-result arrow's slot with map's `f`
   arrow's slot (the solver genuinely unified them) — the over-sharing. The
   shared slot zonks to the FALSE SINGLETON `{Basics.identity}`; devirt
   inlines it, β-reduces `succeed (f a)` → `succeed a`, elides the capture.

**The violated invariant, stated once: a lambda-set slot is devirtable only if
EVERY value that can flow into its unified class injected a member.**
Per-occurrence slots guarantee this structurally (an occurrence receives only
its own writes). A root-shared class receives from every unified occurrence —
including non-injecting producers (PAPs, kernel returns). Sharing without
injection-completeness manufactures false singletons. LSS_026(a)'s honest-∅
rule is this principle for flex INFLOWS; root sharing needs its class-level
analogue.

**Consequence for THIS plan — §0.6's outcome (b), the bad one:** the defect is
IN THE FACTS, not in translate-side merging alone. §2's inference-scoped
design exports members through signatures whose ordinals root-sharing has
tied; a signature carrying `{identity}` as a COMPLETE set for a position that
non-injecting producers also reach reproduces the same false singleton at
every caller. **P1–P4 stay closed until one of the two repairs lands:**

- **(R1) close the injection gap** — PAP/branch-returned partial applications
  inject their `k|`/`g|` member (the pap-argument-members plan), so the class
  is injection-complete and the singleton is honest; and/or
- **(R2) the class-level honest-∅ guard** — a slot whose class includes any
  occurrence written by a non-injecting producer position zonks to ⊤ (or
  stays `LVar`), never to a publishable set.

**R1/R2 ORDERING CORRECTED 2026-08-26 (user fidelity challenge: "widening to ⊤
is not part of LSS — what are we missing?"). The answer: INJECTION TOTALITY,
and it is the paper's own rule, finitely enumerable.** L^src has no currying —
what Elm writes `(::) x` the paper can only write as an explicit λ, and EVERY
abstraction self-injects (`𝒬` adds `λ[…] ⋸ α` per Fig. 6, no exceptions), so
the false singleton cannot form there and no widening is ever needed. The
"structurally incompletable" claim earlier in this section is RETRACTED: it
conflated "no sound `g|` member" with "no sound member" — the paper's element
for an inner-lambda return is THE INNER LAMBDA ITSELF, and Eco already
implements that (`l|` members; `selfIdOf` keeps inner-lambda ids; GAP-2 row 11
measured `readPointCell … ord0: m=1,l`). A declining `l|` member still serves
soundness: any honest second member kills the false singleton.

The producer enumeration and its status: lambda literals ✓ (`l|`), bare
refs ✓ (`g|`/`c|`, position-independent since `refIdentity`), **partial
applications ✗ (R1 — the ONLY known missing form)**, full-call results ✓ via
signature facts at the residual ordinal (totality unproven), branch joins ✓
(honest iff branches injected), container/field reads ✓ (sets ride the element
type), kernel/FFI-produced closures = the one conceded ⊤ boundary (§3.6,
Eco's setting, not the paper's problem).

**So: R1-as-totality IS the paper implementation and IS the sound-by-
construction path. R2 is DEMOTED from semantics to (a) a verifier-era
tripwire** — while totality is unproven, refuse to publish a class containing
a producer position that injected nothing; the same epistemic role shadow-Q
plays for LSS_037, retired by proving the census clean, not permanent
semantics — **and (b) the permanent kernel/FFI boundary. The missing
INSTRUMENT is an injection-totality census**: count arrow-typed producer
sites whose translation contributed no member, by producer form, kernel
excluded. Zero is the condition under which root sharing needs no guard at
all — and every hole it finds is a `var`/⊤ position serving the coverage
gate too.

**Exit criteria:** the roots-built binary self-compiles to completion, and
`--target full` + elm-tests are at the pre-existing failure set with the flag
on. Only then do P1–P4 open.

**P1 — the side table, inert.** `arrowRootOf` built and threaded, nothing reads
it. **Gate: byte-identical `.mlir`.** Proves the minting change is neutral.

**P2 — root keying in the inference scratch store, flag-gated default-off.**
Flag `lss.sigRootIdentity`, env `ECO_MONO_LSS_SIG_ROOT_ID`, hash token `lssSR=`.
**Gates: flag-off byte-identity; flag-on `sigfacts` ≥ 1,400.** That single
number decides H-MAIN.

**P3 — the full battery** (§4), and the flip decision. Expect to be arguing
reach against a small dispatch cost; the §0.3 prediction is on record so the
argument is settled by the numbers rather than re-litigated.

**P4 — only if P3 shows the `declinedNoInstance` rise dominating:** the repair is
member INSTANCE availability (LSS_017/LSS_024 territory), not less transport.
Do not respond by reverting the transport.

---

## §4 Gates

0. **THE PROGRESS GATE — ANALYSIS COVERAGE MUST RISE.** This supersedes the
   dispatch-based acceptance criteria this arc has used until now
   (user-directed, 2026-08-26): *completeness first, exploitation later.*

   **`coverage = (k1 + kN) / positions`**, over ARROW POSITIONS in the emitted
   artifact — one tally per arrow per specialization, taken from the registry's
   stored types. `LVar` and `LTop` are BOTH uncovered; they differ for
   diagnosis (⊤ = information destroyed, `LVar` = information never had) but
   not for the metric, and every non-analysis consumer treats them identically.
   Emitted as the `coverage:` census line (`positions= k1= kN= var= top=
   coveredBp=`), implemented 2026-08-26 in `Mono.annoCoverage` +
   `renderLssReport`.

   **A `kN` set counts exactly as much as a `k1` set.** That is the point of
   the change, and it inverts this arc's long-standing tension: every prior
   precision gain that turned a singleton into a 2-set was scored as a
   regression against a singleton-only consumer. Under this gate it is a win,
   and the consumer becomes unfinished exploitation rather than an acceptance
   criterion.

   **BASELINE — ARTIFACT POSITIONS (the gate metric), measured 2026-08-26 with
   the new counter (`cov-def`/`cov-ri` legs, cold, census on):**

   | arm | positions | k1 | kN | var | top | **analysis coverage** |
   |---|---:|---:|---:|---:|---:|---:|
   | defaults | 127,957 | 20,558 | 682 | 37,237 | 69,480 | **16.59 %** |
   | `+refIdentity` | 132,113 | 29,087 | 2,276 | 39,024 | 61,726 | **23.73 %** |

   **`refIdentity` = +7.14 pp on the gate metric** — double its readback delta.
   And the position metric INVERTS the readback diagnosis: at the artifact
   level **⊤ dominates (54.3 % of positions at defaults), not `var` (29.1 %)**
   — hot concrete slots are read many times, which made the readback ledger
   flatter ⊤'s true footprint. The registry's stored demand types carry the
   storeless-classify ⊤ stamps, which is why `refIdentity` (whose mechanism is
   exactly the removal of those stamps) is worth so much more here.

   Per-readback ledger, same arms, kept for cross-arm continuity with older
   entries (NOT the gate): defaults 36.71 % / `+refIdentity` 40.28 % /
   `+refId +arrowSolverRoots` 41.37 % (roots arm has no position figure — its
   artifact miscompiles, §0.5).

   **NAME COLLISION — resolve it in every future entry.** "Coverage" already
   meant *fast-dispatch coverage* (`fast / (sat + fast)`) in
   `benchmarks/runtime-calls.md`. They are different numbers on different axes
   and this plan needs both words: say **analysis coverage** for this gate and
   **fast-dispatch coverage** for the runtime one. Never bare "coverage".

1. **`sigfacts` ≥ 1,400** flag-on (against 424 today, 1,502 under full
   `arrowSolverRoots`). This is the MECHANISM behind gate 0 for this particular
   plan — it is how the analysis coverage is expected to rise here.
2. §2.5 ledger `RECONCILES=yes`; `kN` rising, `var` falling.
3. Flag-off byte-identity on the two-binary/one-corpus rail; P1 byte-identity
   unconditionally.
4. Fast-dispatch census A/B on the Run AE/AO protocol with the `sat + fast`
   invariance rail. **RECORDED, NOT GATED** — and under gate 0 this is now the
   settled policy for the whole arc, not a per-plan concession: a fall in
   fast-dispatch coverage that buys a rise in analysis coverage is an ACCEPTED
   trade. Report `stampedStaged` and `declinedNoInstance` beside it, because
   they are the mechanism by which the trade happens.
5. **SELF-COMPILE LOWERING, every arm** — `0 undefined fast evaluator`. This
   plan touches the signature path, which is exactly LSS_031's blast radius, and
   `arrowSolverRoots` is the flag with the recorded lowering failure.
   **See §0.4 for the HEAD re-test of that failure.**
5b. **NEW GATE, and §0.5 is why it exists: RUN the freshly-lowered binary.** A
   clean lower does NOT imply a correct binary — `eco-p0roots` lowers with
   `Exit status: 0` and zero `undefined fast evaluator`, and then dies 0.92 s
   into any `make`. One `make` invocation against any project catches it, costs
   about a second, and separates "did not lower" from "lowered wrong". This gate
   is cheap enough that it should be added to the parent register's list too,
   not just this plan's.
6. elm-tests at the pre-existing failure set; E2E `--target full`.
7. Wall/GC per `benchmarks/lss-opt.md`.
8. **Q verifier flag-on: `ECO_MONO_LSS_QCENSUS=1`, `Q-infer` must read
   `REPRODUCES=yes` with `diverge=0`.** No structural update to Q is needed
   (§2.4b has the argument); the re-run is mandatory because the effective slot
   contents change even though the write paths do not. Re-run the
   `qSolve`-equivalence A/B (`instantiateScheme` vs `applyFactsGo`
   byte-identity) at the same time — `residual`/`quantified` derivation now
   sees coarser rep classes and the reordering-neutrality argument must be
   re-measured, not carried over.

---

## §5 Non-goals

- **Flipping `arrowSolverRoots` itself.** §1. This plan exists to get its win
  without its blast radius.
- **`ᾱ` / promote.** Ruled out by measurement —
  `plans/lss-promote-quantified-set-variables.md` §0.2.
- **`S(Q,α)` / internalization.** Measured neutral, parent register §5.6.3.
- **Fixing `declinedNoInstance`.** Real, adjacent, and its own plan (§3 P4).
- **Sum lowering.** `plans/lss-sum-lowering.md` remains the consumer that turns
  any of this into dispatch.
