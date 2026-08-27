# LSS: solver-root signature identity, with per-use instantiation

**Status: UNBLOCKED (2026-08-26 late) — the P0 exit criterion is MET.** The
`+arrowSolverRoots +papMembers` arm emits, lowers (0 undefined fast
evaluators) and **RUNS** — 29/29 dependencies, `Compiling (162)`, stopped only
by the deliberate timeout. Two rounds were needed
(`plans/lss-injection-completeness.md` carries both post-mortems): (1) PAP
injection with the corrected `p|<global>|<supplied>` identity — the drafted
`g|`-reuse itself miscompiled via a stampable-class devirt; (2) the
`declaredArityGo` kernel-alias arm — `(::)`'s `Define (VarKernel …)` node
floored at arity 1, so `(::) x` classified saturated and the injection never
fired on the motivating shape (the SECOND missing-arm defect in that walk).
The false singleton now reads `{g|identity, p|List.cons|1}` and the
identity-map devirt cannot form. **P1–P4 of §3 are open**, gated on this plan's
own batteries; note `lss.papMembers` is still DEFAULT-OFF, so root-sharing
work must carry it (or its flip) explicitly.

Prior statuses, for the record: STILL BLOCKED after R1's first round (the
kernel-alias arity gap); before that BLOCKED on §0.6 — `arrowSolverRoots`
produces a MISCOMPILED compiler at HEAD. The arm lowers cleanly (`Exit status: 0`, zero
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

**RESOLVED 2026-08-26** — the answer was neither branch as posed. The defect was
INJECTION INCOMPLETENESS, not root identity: partial applications injected no
member, so root sharing merged a producer set that was missing an inhabitant
and published a false singleton. Root identity was the AMPLIFIER, not the
cause. `lss.papMembers` closes it (`plans/lss-injection-completeness.md`), the
roots arm now runs, and §2 proceeds with `papMembers` as a hard co-requirement
rather than a recommendation.

### §0.7 MEASURED — P1 and P2 as built (2026-08-27)

Self-compile, `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_MONO_LSS_REPORT=1`,
both arms carrying `ECO_MONO_LSS_PAP_MEMBERS=1` so only `SIG_ROOT_ID` moves.

| | flag-off | flag-on | delta |
|---|---:|---:|---:|
| **analysis coverage** | **27.85 %** | **28.72 %** | **+0.87 pp** |
| positions | 133,913 | 133,652 | −261 |
| k1 | 32,457 | 32,600 | +143 |
| kN | 4,841 | 5,794 | **+953** |
| var | 37,016 | 37,104 | +88 |
| top | 59,599 | 58,154 | **−1,445** |
| `sigfacts` rows | 751 | 1,825 | **×2.43** |
| defs carrying facts | 712 | 1,569 | +857 |
| non-trivial signatures | 712 | 1,569 | +857 |
| `out.mlir` bytes | 15,320,374 | 15,091,684 | −228,690 |

Gate 1 (`sigfacts` ≥ 1,400) MET at 1,825. Gate 2 met in the intended
direction — the movement is ⊤ → `kN`, which is exactly the predicted mechanism
(a def's body members reach its annotation ordinals, so positions the storeless
classifier had stamped ⊤ acquire named inhabitants). `var` is flat-to-slightly-up
(+88, +0.2 %): root identity does not manufacture information where the checker
had none, and was never predicted to.

**Read `kN` +953 against `k1` +143 deliberately.** Under gate 0 both count, and
the gain is dominated by MULTI-member sets. On the retired dispatch criterion
this same change would have scored as a regression — which is the inversion
gate 0 was adopted to correct, showing up here in its first measurement.

Byte-identity: flag-off reproduces the frozen-corpus reference `.mlir`
(`2d51917dbc9f6c6a33432e5111a9ea58`) both at P1 (side table built, never read)
and at P2 (key split in place, `arrowKeyRoots=False`). The occurrence-id supply
is untouched by construction — root keys are negative — so this is structural,
not luck.

Remaining P2 gates: lowering clean (`0 undefined fast evaluator`, 164.95 s);
gate 5b PASSES — the flag-on binary ran a real self-compile for the full 200 s
probe and died only to the timeout, having allocated 819 MB across 758,310
objects and completed CAF promotion (the recorded miscompile died at 0.92 s).
E2E at defaults 1,691/1,691.

**Gate 8 — Q, both arms (the QCENSUS lines live inside `renderLssReport`, so
`ECO_MONO_LSS_QCENSUS=1` needs `ECO_MONO_LSS_REPORT=1` beside it; without it
the verifier RUNS and prints nothing, which is silence, not a pass — the first
attempt at this leg made exactly that mistake):**

| | flag-off | flag-on |
|---|---:|---:|
| `Q-infer` classes | 110,031 | 98,686 |
| `Q-infer` agree | 109,993 | 98,649 |
| `Q-infer` diverge | **0** | **0** |
| `Q-infer` REPRODUCES | **yes** | **yes** |
| partition reaching / internal | 13,655 / 96,376 | 13,812 / 84,874 |
| `Q-shadow` diverge | 79 (sub=79, merged=16, unseen=63) | 79 (sub=79, merged=16, unseen=63) |

`Q-infer` reproduces exactly in both arms, which is the gate. The `Q-shadow`
79 is **identical in both arms down to its breakdown**, so it is PRE-EXISTING
and this change neither causes nor worsens it — the A/B is what establishes
that, and a flag-on-only reading would have looked like a new defect.

The `Q-infer` class count falling 110,031 → 98,686 (−11,345, −10.3 %) is the
mechanism measured directly: root identity merges arrow classes, and internal
classes absorb the whole drop (96,376 → 84,874) while reaching classes hold
(13,655 → 13,812). §2.4b predicted no structural update to `Q` would be needed
and none was; the re-run was mandatory anyway because slot CONTENTS change even
though the write paths do not.

### §0.9 P3 — FAST-DISPATCH A/B: EXACTLY NEUTRAL (Run AO rail, recorded not gated)

Two counters-lowered binaries (`ECO_LSS_DISPATCH_SITE_COUNTERS=1` applied to the
P2 `.mlir`s), both run on the SAME cold self-compile with shipping-default env
and no `ECO_MONO_LSS_REPORT` — the arms differ in how the compiler was BUILT,
not in what it is asked to do.

| arm | distinct | sat | gen | typed | fast | sat+fast | **fast %** | wall |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| flag-off | 7,303 | 2,122,654,764 | 2,088,223,890 | 34,430,874 | 571,069,994 | 2,693,724,758 | **21.200** | 7:24.09 |
| flag-on | 7,216 | 2,122,654,695 | 2,088,223,826 | 34,430,869 | 571,069,987 | 2,693,724,682 | **21.200** | 7:23.48 |
| Δ | −87 | −69 | −64 | −5 | **−7** | −76 | **−0.000 pp** |

**The trade gate 0 was written to accept did not have to be made.** Analysis
coverage rises +0.87 pp for −7 fast events out of 571 million, `fast %` equal to
three decimals, and wall flat (−0.6 s of 7 min). Both arms emit a byte-identical
`.mlir` for the workload, which is the invariance check that makes the counter
comparison admissible. `distinct` −87 (fewer distinct evaluator fps reached)
lines up with the −228,690 B artifact: slightly less spec duplication, same
dispatch behaviour.

Measurement trap recorded: the runtime prints its OWN totals line before the
per-fp rows (read that, never re-sum the rows), and mawk's `printf "%d"`
TRUNCATES TO 32 BITS — `sat+fast` first printed as exactly 2147483647. Use
`%.0f` for every counter.

**P4 is NOT triggered, and the reason is the interesting part.** The mechanism
counters moved as §4 gate 4 asked to have reported beside the dispatch numbers:

| counter | flag-off | flag-on | Δ |
|---|---:|---:|---:|
| `declinedNoInstance` | 16,372 | 21,051 | **+4,679 (+28.6 %)** |
| `declinedBlocked` | 5,638 | 5,494 | −144 |
| `dispatchUpgraded` | 4,803 | 4,797 | −6 |
| `stampedStaged` | 680 | 680 | 0 |

P4's condition was "the `declinedNoInstance` rise DOMINATING", meaning the
coverage gain being paid for in dispatch. It is not: dispatch is flat to the
unit and `stampedStaged` did not move at all. So the +4,679 are positions that
**now NAME a member but have no INSTANCE available to exploit it** — they were
not converting to fast dispatch before either. That is precisely the shape the
user's "completeness first, reap the 2-set benefit later" directive predicted:
the analysis now knows more than the consumer can currently use, and the
+4,679 is a measure of the UNEXPLOITED surface (LSS_017/LSS_024 member-instance
territory), not of a regression. Do not respond to it by reverting transport.

### §0.8 HARNESS GAP FOUND — pipeline tests could not see solver roots AT ALL

`TestLogic.TestPipeline.runToTypedOpt` passed `Dict.empty` for scheme roots and
never performed the arrow-root stamping that `Compiler.Compile` does while the
solver state is live. Every type reaching monomorphization in a test therefore
carried `NoArrow` on every arrow, so `arrowRootOf` was necessarily EMPTY and
**every root-identity feature was structurally inert in every pipeline test** —
`lss.sigRootIdentity`, `lss.arrowSolverRoots`, and Phase 2b alike. A test could
turn any of them on, pass, and have verified nothing at all.

Found by writing §3.1's pins: the store-level pins (which drive `loadTypeC`
directly) passed, and the two pipeline-level pins failed with "root identity
changed nothing at the consumer" — the flag reading as a no-op in a harness
that could not supply its input.

Fixed in `runToTypedOpt` by mirroring `Compile.elm`'s block: normalize node and
annotation vars to their union-find roots, stamp both, and thread the stamped
values onward. **Behaviour-neutral at default flags** — `AssignMVarIds` mints a
fresh occurrence id and stamps `Arrow` for `SolverRoot` and `NoArrow` alike
unless a root-identity flag is on — so it cannot move any existing expectation,
which is what makes it safe to land inside this plan rather than as its own
change.

The general lesson, for the register: **a flag-gated test proves nothing until
one arm is shown to differ from the other.** Both pipeline pins here were
written as off-vs-on differential assertions, which is the only reason the gap
surfaced instead of being papered over by three green tests.

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

### §2.1 Mint both identities; stamp the occurrence one — IMPLEMENTATION (all anchors verified 2026-08-27)

**Flag first** (`lss.sigRootIdentity`, env `ECO_MONO_LSS_SIG_ROOT_ID`, hash
token `lssSR=` — verified free): the exact five-site checklist proven by
`lss.papMembers` yesterday — `Config.elm` `LssConfig` field + doc (cite this
plan; DEFAULT-OFF; artifact-affecting) → `defaultLss` `= False` → `lssDecoder`
**append at the very END** (the chain is positional; the file's own "APPEND
ONLY, and LAST" warning) → the hash-token block emitting `lssSR=1|0` on
`/= default` → `Builder/Eco/Config.elm` `applyLssSigRootIdentityOverride`
(copy `applyLssPapMembersOverride` with the field swapped) + one
`Utils.envLookupEnv "ECO_MONO_LSS_SIG_ROOT_ID"` row in the Task chain.

**State** — `AssignMVarIds.GlobalMVarState` (`AssignMVarIds.elm:29-37`) gains
three fields; only the last is consumed downstream:

```elm
    , rootKeyEnv : Dict ( String, Int ) Int -- (moduleKey, solver root idx) -> NEGATIVE root key. Pass-internal; mirrors arrowRootEnv's module scoping ("unrelated arrows in different modules collide on a raw index — a FALSE union").
    , nextRootKey : Int                     -- next negative key; starts at -1, decrements. Pass-internal.
    , arrowRootOf : Dict Int Int            -- Id.toComparable occId -> root key (NEGATIVE). The side table the memo consults.
```

Seed all three in BOTH `state0` initializers (`:176-184` and the second at
`:206`): `Dict.empty / -1 / Dict.empty`.

**The build** — in `rewriteCanType`'s `Can.TLambda` arm
(`AssignMVarIds.elm:1119-1152`), the `TypeIds.SolverRoot rootIdx` branch's
NON-`useSolverRoots` path currently just calls `freshArrowId ctx`. It becomes:

```elm
TypeIds.SolverRoot rootIdx ->
    if ctx.useSolverRoots then
        ensureArrowIdForRoot rootIdx ctx

    else
        -- Side table for `lss.sigRootIdentity`
        -- (plans/lss-solver-root-signature-identity.md §2.1): stamp the
        -- OCCURRENCE id exactly as before — the graph is byte-identical —
        -- and additionally record occId -> rootKey, where root keys come
        -- from their OWN NEGATIVE supply. Drawing them from `nextArrow`
        -- would shift every later occId's number; occurrence ids feed an
        -- `==` fast path (`Translate.sameCanTypeIgnoringArrows`), so
        -- numbering stays byte-stable by construction instead of by test.
        let
            ( arrowId, ctx1 ) =
                freshArrowId ctx

            key =
                ( ctx1.moduleKey, rootIdx )

            st1 =
                ctx1.state

            ( rootKey, st2 ) =
                case Dict.get key st1.rootKeyEnv of
                    Just rk ->
                        ( rk, st1 )

                    Nothing ->
                        ( st1.nextRootKey
                        , { st1
                            | rootKeyEnv = Dict.insert key st1.nextRootKey st1.rootKeyEnv
                            , nextRootKey = st1.nextRootKey - 1
                          }
                        )
        in
        ( arrowId
        , { ctx1
            | state =
                { st2 | arrowRootOf = Dict.insert (Id.toComparable arrowId) rootKey st2.arrowRootOf }
          }
        )
```

The table is partial by construction — `NoArrow` slots (types built after the
solve) take the plain `freshArrowId` path and get no entry, so the tie degrades
to today's behaviour there ("degrades rather than breaks", §0.1). Under
`useSolverRoots` (2b) the stamped id is already shared and the table is not
built — 2b's semantics are untouched.

**Threading** — `Engine.Env` (`Engine.elm:1059-1069`) gains
`arrowRootOf : CoreDict.Dict Int Int` beside `lamLabels` (the established
side-table slot); `Monomorphize.initState` (`:787`, env built `:805-822`)
copies `mvarState.arrowRootOf` in. `rootKeyEnv`/`nextRootKey` are deliberately
NOT lifted — they are pass-internal.

### §2.2 Key the arrow memo by root — ONLY in the inference scratch store — IMPLEMENTATION

**The scratch flag.** Add `scratchRootKeys : Bool` to `Engine.S` (default
`False` in the initial state). It rides `withScratchStore`
(`Engine.elm:1737-1803`), whose entry/exit are the ONLY places it changes —
verified single call site: `LssInfer.elm:457`. Carry it on `S`, not `itemAux`:
`clearedAux` resets aux fields to their DEFAULTS on scratch entry, the wrong
polarity for a flag that must be ON inside.

```elm
-- entry (the sFresh record update, :1746):
{ s0 | store = freshStore, memo = CoreDict.empty, revMemo = Array.empty
     , itemAux = clearedAux s0.itemAux
     , scratchRootKeys = s0.env.lss.sigRootIdentity }

-- exit (the final Ok, :1803):
Ok ( a, { s3 | store = s0.store, memo = s0.memo, revMemo = s0.revMemo
             , itemAux = restoredAux s0.itemAux s3.itemAux
             , scratchRootKeys = s0.scratchRootKeys } )
```

(The `Err e` arm aborts the whole monomorphization — no restore needed.)

**`Store.LoadCtx`** gains two fields:

```elm
    , arrowKeyRoots : Bool                    -- sigRootIdentity, inside the inference scratch only
    , arrowRootOf : Dict.Dict Int Int         -- Id.toComparable occId -> NEGATIVE root key (env side table)
```

Constructors:

- `sharedLoadCtx` (`Store.elm:114-127`):
  `arrowKeyRoots = s.scratchRootKeys, arrowRootOf = s.env.arrowRootOf`.
  (`scratchRootKeys` is only ever True when the flag is on, so no second
  conjunct is needed.)
- `isolatedLoadCtx` (`:140-158`): `False, Dict.empty` — **untouched
  semantics.** Its own doc records the H1 collapse hazard (*"threading the
  item's arrow memo into an isolated load would make every call site of an
  annotated `f` unify into ONE lambda set — monomorphic set analysis, maximal
  imprecision"*); the per-use freshening this plan's title depends on IS that
  emptiness.
- `testLoadCtx` (`:96-112`): keep its signature (one caller,
  `ArrowIdentityTest.elm:122`) and default the fields `False, Dict.empty`; add
  `testLoadCtxRoots : Dict.Dict Int Int -> Bool -> Bool -> Dict.Dict Int IO.Variable -> IO.State -> LoadCtx`
  for the §4 store-level pin.

**The key split in the `TLambda` arm** (`Store.elm:327-390`). Today one `akey`
serves both the memo and the census (`noteArrow`). §2.4b requires them to
DIVERGE — the census must keep the occurrence id or the MSET cross-arm join
silently breaks. Replace the `akey` binding with:

```elm
-- The census key: ALWAYS the occurrence id (0 = unstamped sentinel).
-- `noteArrow` and the MSET census key on corpus-stable occurrence ArrowIds
-- (the Run-AE lesson); root keying must not leak into them.
occKey =
    case arrowSlot of
        TypeIds.Arrow aid ->
            Id.toComparable aid + 1

        _ ->
            0

-- The memo key: root-translated ONLY inside the inference scratch under
-- `lss.sigRootIdentity`. Root keys are NEGATIVE by construction, so they
-- can never collide with occurrence keys (>= 1) or the 0 sentinel.
memoKey =
    if c2.arrowKeyRoots && occKey /= 0 then
        case Dict.get (occKey - 1) c2.arrowRootOf of
            Just rootKey ->
                rootKey

            Nothing ->
                occKey

    else
        occKey
```

Then, mechanically: `noteArrow` keeps `occKey`; the guard
`if not c2.arrowIdOn || akey == 0` becomes `memoKey == 0` (equivalent — a zero
memoKey occurs iff occKey is 0); `Dict.get`/`Dict.insert` on `c2.arrowMemo`
use `memoKey`. **The hit/miss contract is untouched** — a HIT still pushes to
`arrowSlots` and leaves `slotsMinted` alone (`Store.elm:306-326`, "all four
rows load-bearing"), which is what makes root keying ordinal-safe by existing
design, including the same-Point-twice case (`repOrdinal` copes; `trivial`
goes false more often — a compile-time cost, not a precision change).

**Nothing else changes**: the translate/specialization path keeps
per-occurrence keying (the demand channel and spec keys are unaffected), and
`itemAux.arrowMemo`'s store-scoping lifecycle (`clearedAux`/`restoredAux`/
`resetItem`) is untouched — only the KEY computation changed, and the memo is
cleared at both scratch boundaries, so occurrence-keyed and root-keyed entries
never coexist in one dict.

### §2.3 The hazard that DOES apply — REWRITTEN 2026-08-26/27, because the original claim was REFUTED by a miscompile

The original text called unit-internal merging "a precision question, not a
soundness one", on the argument that sharing only ever ADDS members. **The
`arrowSolverRoots` crash refuted that**: sharing is over-approximation only
when every producer flowing into the merged class INJECTED a member. With a
non-injecting producer in the class, sharing delivers an
UNDER-approximated set (a false singleton) to consumers that per-occurrence
fragmentation used to quarantine — devirt then acts on it, and `Task.map f`
compiled to the identity map. The full invariant, argument and repair are in
§3 P0 and `plans/lss-injection-completeness.md`.

Consequences for THIS plan, both binding:

1. **`lss.sigRootIdentity` REQUIRES `lss.papMembers`.** Root-keyed inference
   exports the merged classes' sets through signatures (`applyFacts` writes
   them into caller slots), so an injection-incomplete class reproduces the
   false singleton at every caller — §0.6's outcome (b), measured. Every
   flag-on battery in §3 carries `ECO_MONO_LSS_PAP_MEMBERS=1`, and
   `sigRootIdentity` may not flip default-on before (or without)
   `papMembers`. Enforce in review, not in code — the flags stay orthogonal
   so the A/B arms remain expressible.
2. **The residue of injection totality is this plan's residual risk**, sized
   by the census: `callUnknownCallee` ≤533 (unknown-callee partials,
   deferred), `papInject|deep` 600 (depth ≥2 residual arrows, head-only
   today), `callResult|trivial` 137. A merged class touching one of these can
   still under-approximate. The backstops are gate 5b (the lowered binary
   must RUN) and the P3 probe; if either trips, the repair is extending
   injection (per the totality programme), not weakening the sharing.

What remains true from the original: merged classes also gain members they
did not need (use A's member reaching use B's ordinal) — THAT part is genuine
over-approximation, is sound, and is the likely source of part of the
measured `kN` 3,386 → 6,136 and the `declinedNoInstance` rise. Measured, not
argued away, via the §3 batteries.

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

**P1 — the side table, inert.** Edits: the §2.1 checklist EXCEPT the flag
consumers — `GlobalMVarState` three fields + both `state0` seeds, the
`SolverRoot` branch build, `Env.arrowRootOf`, `initState` threading, and the
`Config`/`Builder` flag plumbing (dead until P2). Nothing reads the table.

Battery (one build + two cold legs, ~35 min; the P0-census recipe verbatim):

```bash
BK=build/compiler/build-kernel
rm -f "$BK/bin/eco-compiler.mlir" "$BK/bin/eco-compiler"; rm -rf "$BK/eco-stuff"
ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_BORROW=1 ECO_AGG_PROMOTE=1 \
    cmake --build build --target eco-compiler
# cold leg at defaults → out.mlir must be BYTE-IDENTICAL to the pre-change
# leg on the same corpus (two-binary rail: keep the pre-change binary's leg
# output; env vars are not ninja inputs — the rm above is load-bearing).
```

**Gate: byte-identical `out.mlir` at defaults.** This is exactly what the
negative-key-space amendment buys: occId numbering is untouched, so the gate
tests the THREADING alone. A diff here means the build accidentally consumed
the table (or the supply) — stop and bisect the P1 edit, nothing else is in
play.

**P2 — root keying in the inference scratch store, flag-gated default-off.**
Edits: the §2.2 set — `S.scratchRootKeys` + the two `withScratchStore` record
updates, the two `LoadCtx` fields + three constructors + `testLoadCtxRoots`,
and the `occKey`/`memoKey` split in the `TLambda` arm (census keeps `occKey`).

Battery, in order (every flag-on leg carries `ECO_MONO_LSS_PAP_MEMBERS=1` —
§2.3 consequence 1, non-negotiable):

1. **Flag-off byte-identity** vs the P1 leg (same corpus, same binary rules).
2. **Flag-on census leg** (`ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_PAP_MEMBERS=1
   ECO_MONO_LSS_SIG_ROOT_ID=1`): `sigfacts` row count is the H-MAIN decider —
   **≥ 1,400 expected** (424 baseline; 1,502 under full roots); `coverage:`
   and the ledger recorded beside it; `RECONCILES=yes`.
3. **Gate 5b**: lower the flag-on `out.mlir`
   (`/work/build/runtime/src/codegen/eco-boot-native <mlir> -o <bin>`), assert
   0 `undefined fast evaluator`, then **RUN the binary on a `make`** (the
   `timeout 200` probe; 124 = pass). This is the gate the miscompile class
   taught us; it is cheap and non-negotiable.
4. **Q verifier leg** (`ECO_MONO_LSS_QCENSUS=1`, flag-on): `Q-infer`
   `REPRODUCES=yes`, `diverge=0` (§2.4b: no structural update needed, the
   re-run is the proof), plus the `qSolve` A/B re-run (byte-equivalence of
   `instantiateScheme` vs `applyFactsGo` under coarser rep classes).
5. elm-tests at the pre-existing set; E2E `--target full` flag-off
   (**rebuild after** — `--target full` deletes `bin/eco-compiler`).

**P3 — the reach/coverage battery and the flip decision.** Fast-dispatch A/B
on the Run-AO rail (counters-lowered arms, `sat + fast` invariance) —
RECORDED, NOT GATED per §4 gate 0; report `stampedStaged` /
`declinedNoInstance` beside it (the trade's mechanism). Analysis-coverage A/B
at positions is the decision number. Wall/GC row per `benchmarks/lss-opt.md`
(analysis change: `out.mlir` moves, say so, no cross-corpus wall claims). The
§0.3 prediction is on record — `sigfacts` ≈ 1,400–1,500, `kN` up, `var` down,
dispatch flat-to-−0.3 pp — so the flip argument is settled by numbers. Flip
ordering constraint: **not before `papMembers`** (§2.3).

**P4 — only if P3 shows the `declinedNoInstance` rise dominating:** the repair
is member INSTANCE availability (LSS_017/LSS_024 territory), not less
transport. Do not respond by reverting the transport.

### §3.2a GATE DESIGN TRAP — byte-identity is UNSATISFIABLE for a default flip

The first flip gate written here was "compiling at the new defaults must
reproduce the measured flag-on `.mlir` byte-for-byte". It reported DIFFER (79
bytes larger, 11,089 diff lines), and **the gate was wrong, not the flip.**

The workload is the compiler compiling ITSELF. Flipping a default edits
`defaultLss` in the compiler's own source, so the two `Bool` literals appear in
the emitted artifact — the first textual difference is literally
`"arith.constant"() {value = false}` becoming `{value = true}` twice. The
`Engine.elm` co-requirement guard shows up too: `&& s0.env.lss.papMembers`
makes `withScratchStore` project one more field from the config record, which
changes its codegen and renumbers everything downstream.

**A source change to the compiler cannot be gated on byte-identity of a
self-compile.** The right equivalence for a default flip is the ANALYSIS, and
it held exactly: `coverage: positions=133652 k1=32600 kN=5794 var=37104
top=58154 coveredBp=2872`, `sigfacts` 1,825, `signatures: 9955 memoized (8386
trivial)` — every field identical to the flag-on P2 leg. The exactness is
meaningful rather than lucky, because two `Bool` literals and one `&&`
introduce no arrow positions, so the 133,652-position population is genuinely
unchanged.

### §3.2 THE FLIP DECISION — measured 2026-08-27, TAKEN 2026-08-27

**FLIPPED 2026-08-27, both together, at the user's direction.** `defaultLss`
now carries `papMembers = True, sigRootIdentity = True`.

Three changes rode with the flip, and the last two are the ones a reviewer
should look at hardest:

1. Doc comments on both flags and both env overrides now record DEFAULT-ON and
   that the hash tokens `lssPM=0` / `lssSR=0` ride the OFF arm (the
   `arrowIdentity` / `refIdentity` precedent).
2. **The co-requirement is now ENFORCED, not documented.**
   `Engine.withScratchStore` sets `scratchRootKeys = sigRootIdentity &&
   papMembers`. Before the flip the unsound pairing needed two deliberate env
   vars; after it, `ECO_MONO_LSS_PAP_MEMBERS=0` ALONE would have reached it —
   one env var away from the recorded identity-map miscompile. The guard sits
   at the single place the flag is read, so it covers every config path (env,
   JSON, future call sites) rather than each path that can produce the pairing.
3. **Two test suites had to be repaired by the flip, for two DIFFERENT
   reasons.** This is the part that generalises, and it cost a full
   elm-tests cycle to learn the second half.

   *`LssPapMembersTest` — a SOUNDNESS pairing.* It set `papMembers` explicitly
   and INHERITED `sigRootIdentity`, so after the flip its flag-off arm would
   have run root identity without injection completeness — the test isolating
   `papMembers` would itself have been running the miscompile configuration.
   Its `lssConfig` now moves `sigRootIdentity` with `papMembers`.

   *`LssSigFlowTest` — an OVERLAPPING CHANNEL.* Its harness toggles `sigFlow`
   and inherited both new flags into BOTH arms. `sigRootIdentity` opens a
   second channel to the same place `sigFlow` does (signatures conducting
   members), so the differentials collapsed and three tests failed at the new
   defaults: 1b's "the channel is empty" ABSENCE stopped holding, 2's 2-member
   set appeared in the flag-OFF arm as well, and 3's negative control stopped
   being identical because root identity makes signatures non-trivial
   (9,243 → 8,386) and that control's premise is a trivial signature. Fixed by
   pinning both flags OFF in the harness — the remedy the file already used
   for `layoutQualMembers` when LSS_024 went default-on in Aug 2021's flip.

   **The rule, now paid for twice: a DIFFERENTIAL test must pin EVERY flag
   that overlaps the one it toggles, and a test pinning one flag of a
   CO-REQUIRED pair must pin both.** Absolute tests (asserting a counter under
   one config, like this file's tests 6 and 8) do not need pinning and were
   deliberately left alone. The failure mode is silent in the dangerous
   direction: a collapsed differential still COMPILES and can still PASS if
   the assertion happens to be satisfied by the second channel.

The ordering constraint was honoured by flipping them together, which is the
only ordering that is safe at every intermediate state: §2.3 makes injection
completeness a SOUNDNESS pre-condition of root sharing, so `sigRootIdentity`
must never be on while `papMembers` is off — and flipping them in two separate
commits would leave exactly that window open between them.

Expected effect on shipped defaults: analysis coverage **≈ 23.7 % → ≈ 28.7 %
(+5.0 pp)** — `papMembers` +4.2 pp, `sigRootIdentity` +0.87 pp on top of it —
at flat dispatch, flat wall, and a smaller artifact.

The evidence supporting the flip, gathered before it was taken:

| evidence | status |
|---|---|
| analysis coverage rises | +0.87 pp (28.72 % vs 27.85 %), beats the 27.90 % bar |
| flag-off byte-identity | reproduces `2d51917d…` at P1 and P2 |
| lowering + RUN (gate 5b) | clean lower, binary survives a real 200 s compile |
| `Q` fidelity | `REPRODUCES=yes`, `diverge=0`, both arms |
| elm-tests | pre-existing failure set only |
| E2E at defaults | 1,691/1,691 |
| **E2E with BOTH flags on** | **1,691/1,691** (596 sources touched — the harness cache is env-blind) |
| fast dispatch | 21.200 % both arms, −7 events of 571 M |

Re-verified AT the new defaults (§3.2a explains why the equivalence is the
analysis and not the bytes): `coverage: positions=133652 k1=32600 kN=5794
var=37104 top=58154 coveredBp=2872`, `sigfacts` 1,825, `signatures: 9955
memoized (8386 trivial)` — every field identical to the flag-on leg. Gate 5
clean, gate 5b passes, `Q-infer` `REPRODUCES=yes diverge=0` with
`classes=98686` (identical to the flag-on leg), E2E 1,691/1,691.

**FULL CLEAN BOOTSTRAP, 2026-08-27.** `build/` deleted and `~/.eco` moved
aside (SHA-pinned toolchain download cache preserved), reconfigured from
scratch, whole `eco-compiler-boot → eco-compiler-boot-2 → eco-compiler` chain
rebuilt in 17m47s to a 70,325,136-byte binary, and a fresh 8.7 MB `~/.eco`
resolved from nothing. Self-compiled with **no LSS env overrides at all** —
so the flags come from `defaultLss` alone — and reproduced the expected
configuration to the field: `coveredBp=2872`, `sigfacts` 1,825, `signatures:
9955 memoized (8386 trivial)`, ledger `RECONCILES=yes`. elm-tests
13,367/12 = the pre-existing set exactly; E2E `--target full` 1,691/1,691.

**Build-command trap found doing it.** `cmake --build build` with NO target
builds only the JS bootstrap (`guida.js`, 280 modules) — it does NOT build the
native compiler, despite CLAUDE.md calling it "Build all targets". The first
bootstrap attempt therefore reported `build exit=0` and then died at the
self-compile with exit 127. **An exit-0 build that produced no binary is a
green that means nothing**; the script survives it only because it checks for
the artefact and RUNS it rather than trusting the build's status. Use
`--target eco-compiler`, which drives the whole boot chain.

The injection-totality census re-run at the new defaults also confirms the gap
is closed from BOTH sides: `inj|papKnown` = 3,624 and `papInject|pap` = 3,624,
matching per depth (d1 3,038 / d2 536 / d3 44 / d4 1 / d5 5). Note the depth
SPLIT moved from the P0 table (d1 was 3,020, d2 552, d3 46) because the
kernel-alias arity fix pulled `(::) x`-shaped sites into d1 — the identical
3,624 total is coincidence, not invariance. `callResult|trivial`, the
"totality unproven" bucket, fell 137 → 31, which is `sigfacts` 751 → 1,825
seen from the other end. The standing caveat still applies: census and
mechanism share `declaredArityOf`, so this agreement proves totality GIVEN the
classifier — what changed is that the classifier is now correct.

One prediction in §0.3 MISSED and is corrected here: `var` was predicted to
fall and instead was flat-to-slightly-up (+88, +0.2 %). Root identity moves ⊤
into named sets; it does not manufacture information the checker never had.
The `kN`/⊤ movement carried the whole gain.

### §3.1 Unit pins (write in P1/P2, run with every battery)

1. **Store-level (the mechanism guarantee; `ArrowIdentityTest` precedent —
   drive `Store.loadTypeC` with `testLoadCtxRoots`):** two `Can.TLambda`s with
   DISTINCT occurrence ids whose `arrowRootOf` maps both to one negative key
   → `arrowKeyRoots=True` yields ONE slot Point (pointKey equality),
   `False` yields two; a pair with NO table entry yields two under both; the
   hit still pushes `arrowSlots` (ordinal count 2) and leaves `slotsMinted`
   at 1 for the shared case — the `Store.elm:306-326` contract, pinned.
2. **AssignMVarIds-level:** a module whose annotation and body arrows the
   solver unified produces `arrowRootOf` entries mapping two distinct occIds
   to ONE negative key; `nextArrow` after the pass equals the pre-change
   value for the same module (numbering stability, unit-level — the corpus
   gate is P1's byte-identity).
3. **Pipeline-level (goal-shaped):** flag-on, a fixture def's signature
   carries a body member at an annotation ordinal that flag-off reads
   `allflex`. **WRITTEN, and the instrument had to be corrected twice —
   record both, they generalise.**

   *First instrument, WRONG:* assert at a consumer's parameter annotation
   (the `LssPapMembersTest` reading). It does not discriminate — the
   call-argument transport already carries a member to a consumer's parameter
   within one module, so BOTH arms name one and the signature change is
   invisible. Measured: `[LTop, LSet 1 1]` off and on for the
   returned-lambda fixture, `[LTop, LSet 2 1 2]` for the branch fixture.

   *Second instrument, and the right one:* assert on `sigfacts` itself, via
   `runSolverMonoWithReport` (which forces `report = True`) and the `ARGF`
   block in the returned census string. Count rows that NAME a member
   (`m=` non-zero); flag-on must exceed flag-off. This is the unit-scale form
   of gate 1 on the same counter, so a unit regression and a corpus
   regression read identically — and it asserts where the claim lives (the
   SIGNATURE), rather than somewhere the claim happens to be visible.

   The lesson: **pick the instrument the claim is stated in.** The claim was
   always about signatures; reading a consumer's annotation was reading a
   downstream consequence that another mechanism also produces.

   *Then the FIXTURE had to be corrected too — and this pin is NOT LANDED.*
   Three instruments were built and all three measured NEGATIVE:

   | attempt | reading | what it establishes |
   |---|---|---|
   | consumer's parameter annotation | `[LTop, LSet 1 1]` off AND on | wrong instrument: call-argument transport already names a member there |
   | `sigfacts`, producer RETURNS a lambda | `Test.mkStep\|0\|m=1,l` off AND on | a def whose body IS a lambda already names itself at ordinal 0 |
   | `sigfacts`, producer IS the value (`applyTo double 3`) | ZERO rows off AND on | at fixture scale every signature is TRIVIAL and `censusSigFacts` skips those |

   Together they BOUND where the effect lives: it needs a def whose signature
   is non-trivial AND whose identity arrives from outside its own item — a
   cross-item property a synthetic single-module fixture does not reproduce.
   That is what §3.1 predicted ("resist minimization from first principles"),
   so the sanctioned fallback stands: **the CORPUS `sigfacts` gate is the
   transport gate**, 751 → 1,825 rows over 857 newly-carrying defs.

   `LssSigRootIdentityTest` therefore lands with SEVEN passing pins — five at
   the store, one at the side table, one co-gate — and a comment block carrying
   the three negative results so the next person does not re-derive them. The
   negatives are not failures to hide; they are the measured boundary of the
   mechanism.
4. **The co-gate pin:** the `LssPapMembersTest` `joinModule` shape run with
   `sigRootIdentity = True, papMembers = True` still yields no singleton at
   the consumer (the §2.3 co-requirement, pinned where the crash lived).

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
   `+refId +arrowSolverRoots` 41.37 %.

   **UPDATED 2026-08-26/27:** `refIdentity` has since FLIPPED default-on, and
   `+papMembers` measures **27.90 %** at positions (`+4.2 pp` over the new
   defaults — `plans/lss-injection-completeness.md` P1). So THIS plan's gate-0
   comparison runs against the `papMembers`-on arm (its §2.3 co-requirement
   anyway): the flag-on leg must beat **27.90 %**. The roots artifact now RUNS
   (§3 P0 exit criterion met), so position figures for root-shared arms are
   measurable again.

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
9. **Every flag-on arm carries `ECO_MONO_LSS_PAP_MEMBERS=1`, and the flip is
   ordered after `papMembers`'s** (§2.3 consequence 1). A `sigRootIdentity`-on
   / `papMembers`-off arm is the measured recipe for the identity-map
   miscompile through the signature channel; it may be run ONLY as a
   deliberate negative probe, never as a battery arm.

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
