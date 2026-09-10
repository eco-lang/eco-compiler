# An inliner that runs BEFORE monomorphization

`MonoInlineSimplify` runs on fully-specialized code: a small polymorphic `map`
is monomorphized into N copies, and each copy is then inlined independently.
Inlining the polymorphic form ONCE, before specialization, is strictly less
work — and it is the only pass in the pipeline that destroys LSS identity,
because at the pre-mono IR that identity does not exist yet.

This plan adds `InlineSimplify` (pre-mono), flags both inliners independently,
and A/Bs the POSITION of the active inliner: exactly one runs in each arm, with
the same budget and config (§7).

**STATUS: PROPOSED. Nothing built.**

---

## 1. Why this is worth trying

**Work multiplication.** The self-compile performs **65,910 inlines**. Every
one operates on a monomorphic copy. If `map` has 40 specializations and is
inlined at 3 sites in each, that is 120 inlines of the same source definition;
pre-mono it is 3.

**It removes the only set-destroying pass.** `/work/direct-call-decline-census.md`
and `plans/lss-inline-member-propagation.md` establish that of every pass
between LSS derivation and codegen, `MonoInlineSimplify` is the ONLY one that
loses LSS identity — 863 members destroyed per self-compile, 100 % of its
reshapes. At the pre-mono IR there is no `ClosureInfo`, no `lssMember`, no
`CallInfo`: `TOpt.Function` carries `(Maybe SrcLambdaId, params, body, meta)`
and `TOpt.Call` carries no call info at all. **An early inliner cannot destroy
what has not been derived.**

**It may shrink monomorphization's input.** Inlining pre-mono deletes call
sites and may delete whole definitions, so fewer specializations are demanded.
Monomorphization is the pipeline's dominant phase.

This plan does NOT claim a runtime win. The hypothesis is compile-time work and
a cleaner phase order; runtime output may be identical, better, or worse, and
§7 measures which.

## 2. The two IRs, and what changes

| | pre-mono (`TOpt`) | post-mono (`Mono`) |
|---|---|---|
| function | `Function (Maybe SrcLambdaId) (List (Name, Can.Type id)) (Expr id) (Meta id)` | `MonoClosure ClosureInfo MonoExpr MonoType` |
| call | `Call Region (Expr id) (List (Expr id)) (Meta id)` | `MonoCall Region MonoExpr (List MonoExpr) MonoType CallInfo` |
| callee identity | `VarGlobal Region Global (Meta id)` | `MonoVarGlobal Region SpecId MonoType` |
| types | `Can.Type id` (polymorphic) | `MonoType` (ground) |
| node | `Define (Expr id) (EverySet String Global) (Meta id)` — **deps included** | `MonoDefine MonoNode MonoType` |
| identity fields | none | `lssMember`, `srcLambda`, `closureKind`, `captureAbi` |

Three consequences the implementer must internalise:

1. **No captures to recompute.** `MonoInlineSimplify` calls
   `Closure.computeClosureCaptures` on every rebuild; `TOpt.Function` has no
   capture list, so the pre-mono inliner simply does not have that problem.
2. **No identity to clear.** The four `lssMember = Nothing` sites have no
   analogue. This is the structural payoff.
3. **Recursion detection is free.** `Define` carries
   `EverySet String Global` deps, so an SCC over the node map gives the
   recursive set without a separate call-graph build.

## 3. Scope — functional parity, not a superset

`InlineSimplify` replicates `MonoInlineSimplify`'s documented list:

  - small-function inlining with a recursion guard;
  - beta-reduction of immediate lambdas;
  - let-callee forwarding (`ForwardClosure` / `ForwardPartialCall`);
  - let-sinking / let-elimination;
  - dead-code elimination incl. chain-aware dead closure bindings;
  - case simplifications.

**Explicitly OUT of scope for v1** (they are monomorphic-only by nature):

  - `loopify` — H5 recursive-HOF loopification keys on `SpecId`;
  - `arityRaise` — operates on staged SPECS;
  - `kernelCostClasses` cost vector — prices a call from its CONCRETE kernel
    instance; pre-mono the kernel is known (`VarKernel` carries home/name) but
    the instance is not. v1 uses the flat cost model (`kernelCostClasses` off
    semantics: every kernel call scores 6).

v1 is therefore WEAKER than `MonoInlineSimplify`, deliberately. The A/B in §7
runs both, so a weaker early pass plus the existing late pass is a valid
configuration and is the expected shipping shape.

## 4. Design

### 4.1 Module

`compiler/src/Compiler/GlobalOpt/InlineSimplify.elm`, exposing

```elm
optimize : Config.InlineConfig -> TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph Name, Metrics )
```

GlobalOpt rather than `LocalOpt/Typed/` because inlining needs the WHOLE graph:
`LocalOpt/Typed/*` passes are per-module (`normalizeLocalGraph` takes a
`LocalGraph`), and a cross-module inline needs the merged node map.

### 4.2 Insertion point

`Builder/Generate.elm:741`, `runMonoOptPipeline`, immediately before
`selectMonomorphizer`:

```elm
runMonoOptPipeline ecoConfig stats typedGraph globalTypeEnv =
    let
        ( inlinedGraph, preMetrics ) =
            if ecoConfig.inline.preMono then
                InlineSimplify.optimize ecoConfig.inline typedGraph

            else
                ( typedGraph, InlineSimplify.emptyMetrics )
    in
    FEStats.withPhase stats FEStats.PhaseMono
        (case selectMonomorphizer ecoConfig globalTypeEnv inlinedGraph of …)
```

### 4.3 Flags

| flag | env | default | meaning |
|---|---|---|---|
| `inline.preMono` | `ECO_INLINE_PRE_MONO=1` | **off** | run `InlineSimplify` before mono |
| `inline.postMono` | `ECO_INLINE_POST_MONO=0` | **on** | run `MonoInlineSimplify` after mono |

Both artifact-affecting; hash tokens `preInl=` / `postInl=`. `postMono` is a
NEW switch over existing behaviour, so its default-on value must be
byte-identical to today.

`InlineConfig` is at 17 fields after `partialHof`; two more is 19, clear of the
32-slot record cap (`memory: lssconfig-at-32-slot-cap` — that cap bit
`LssConfig`, not `InlineConfig`, but check before adding a third).

### 4.4 Adversarial review — findings applied above and below

Four claims were checked against the code; two held, one was refined, one is a
**blocking design gap** now folded into §5.

**R1 — "keyed by the Global's comparable form". HOLDS.**
`TOpt.toComparableGlobal` exists (`TypedOptimized.elm:313`).

**R2 — "SCC over the deps sets". HOLDS.** `Compiler.Graph` already provides
`SCC vertex = AcyclicSCC vertex | CyclicSCC (List vertex)` (`Graph.elm:21`),
which is what the mono pass's recursion guard uses.

**R3 — "v1 is weaker, so run both". SUPERSEDED by the two-arm design.** §7 is
now a POSITION test (one inliner per arm, same budget), so the EARLY arm being
weaker is a KNOWN asymmetry to report, not something to paper over by also
running the late pass. If EARLY wins compile time and loses runtime, the
both-on configuration is the follow-up, not part of the A/B.

**R4 — `SrcLambdaId` DUPLICATION. BLOCKING GAP — the plan was wrong.**

`TOpt.Function (Maybe SrcLambdaId) …` carries the id that BECOMES LSS member
identity downstream (`AbiCloning.instanceMember` rung 1 is `srcLambda = Just m`).
Inlining a function body at N sites duplicates every `Function` inside it —
and therefore duplicates its `SrcLambdaId`.

The mono inliner solves the analogous problem explicitly:
`remapClosureLambdaId` (`MonoInlineSimplify.elm:2550`) gives every closure in an
inlined body a **fresh `lambdaId`** while **deliberately preserving `srcLambda`
and `lssMember`** — physical identity fresh, logical identity kept, because
"inliner copies … all verbatim copies" genuinely ARE instances of the same
member.

Pre-mono there is no such split: `SrcLambdaId` is the only identity a
`Function` has. So duplicating it asserts that N copies — whose bodies differ
wherever a substituted argument reached them — are one interchangeable member.
Downstream that is the LSS_024 fingerprint-fence case: with the fence ON
(`layoutQualMembers`, default) it degrades to `bodyMismatch` declines; with the
fence OFF it is a miscompile.

**Consequence for the design:** the pre-mono inliner needs a SrcLambdaId
SUPPLY, and there is none to hand. The only supply is
`AssignMVarIds`'s `nextLam`, seeded at `TypeIds.firstSrcLambdaId` and internal
to that pass (`AssignMVarIds.elm:250,286`); `TOpt.GlobalGraph` carries no
`nextSrcLambdaId`. §5 gains **Step 0** to resolve this before any inlining is
written, and §9 gains the risk.

## 5. Implementation, lowered

Ordered so each step compiles and is separately testable.

### Step 0 — SrcLambdaId discipline: RESOLVED, NO WORK NEEDED (2026-09-09)

**Verified: option 1's escape clause applies — the ids are re-numbered
downstream, so duplication pre-mono is harmless.**

`AssignMVarIds.assignIds` runs INSIDE `MonoSolver.monomorphize`
(`MonoSolver/Monomorphize.elm:90`), i.e. strictly AFTER this plan's insertion
point, and its `Function` arm is

```elm
TOpt.Function _ args body meta ->
    let ( lamId, ctx0a ) = freshLamId ctx in
    ( TOpt.Function (Just lamId) newArgs newBody newMeta, ctx3 )
```

The incoming id is DISCARDED (`_`) and a fresh one minted from `nextLam`. Every
lambda is renumbered before any LSS member is interned, so N inlined copies
receive N distinct ids regardless of what the pre-mono inliner leaves behind.

**Consequence:** `InlineSimplify` may duplicate `Function` nodes verbatim,
`SrcLambdaId` included. No supply is needed and R4's miscompile window does not
exist on this path. The unit test below is kept as a REGRESSION pin, because the
guarantee depends on `AssignMVarIds` continuing to renumber — if that ever
changes to preserve incoming ids, R4 becomes live again.

**Pin:** a test asserting that two inlines of one body yield `Function` nodes
with distinct ids AFTER monomorphization (not after inlining).

### Step 0b — the original decision, retained for the record

Nothing else is safe until this is settled. Three options, in preference order:

1. **Freshen on duplication (RECOMMENDED).** Thread a `nextSrcLambdaId` supply
   through `InlineSimplify` and assign a fresh id to every `Function` in a
   duplicated body — the exact analogue of `remapClosureLambdaId`. Requires a
   supply the pass can own: seed it past the maximum id present in the graph
   (one fold over all `Function`/`TrackedFunction` nodes), so it cannot collide
   with ids `AssignMVarIds` later mints. **Verify that assumption** — read
   `AssignMVarIds`'s `nextLam` seeding and confirm it does not re-number
   existing ids; if it re-numbers, freshening here is free and this whole step
   collapses to "do nothing".
2. **Clear to `Nothing` on duplication.** Sound (no false member), but throws
   away identity the way the mono inliner does — and this plan's premise is
   that the early pass does NOT do that. Fallback only.
3. **Preserve verbatim.** Only defensible if it can be shown that every
   duplicate really is body-identical. It is not: substitution puts different
   arguments into different copies. **Do not choose this without a fingerprint
   argument.**

**Gate for Step 0:** a unit test that inlines a function containing a nested
lambda at two sites with different arguments, and asserts the two resulting
`Function` nodes do NOT share a `SrcLambdaId`.

### Step 1 — flags only (no new pass)

Add `preMono`/`postMono` to `Compiler/Eco/Config.elm` `InlineConfig`, defaults
`False`/`True`, decoder fields, hash tokens. Add the two env overrides in
`Builder/Eco/Config.elm` (copy `applyInlinePartialHofOverride` verbatim —
record UPDATE, never a literal). Gate the existing call at
`Generate.elm:858` on `ecoConfig.inline.postMono`.

**Gate: `.mlir` byte-identical at defaults.** This step must change nothing.

### Step 2 — the traversal skeleton

`InlineSimplify.optimize` that walks every `Node` and returns the graph
UNCHANGED, plus a `Metrics` record mirroring `MonoInlineSimplify.Metrics`
(`inlineCount`, `betaReductions`, `betaForwards`, `letEliminations`,
`deadLets`, `inlinedByCallee`). Model the recursion on
`LocalOpt/Typed/NormalizeLambdaBoundaries.elm`, which is the existing TOpt
structural rewrite and already solves alpha-renaming (`RenameCtx`/`RenameEnv`).

Nodes to walk: `Define`, `TrackedDefine`, `Cycle`, `PortIncoming`,
`PortOutgoing`. Leave `Ctor`/`Enum`/`Box`/`Link`/`Manager`/`Kernel` alone.

**Gate: with `preMono=1`, `.mlir` byte-identical** (identity transform).

### Step 3 — the candidate index

```elm
inlineCandidates :
    Config.InlineConfig
    -> TOpt.GlobalGraph Name
    -> Dict String ( List ( Name, Can.Type Name ), Expr Name, Bool )
```

keyed by `Global`'s comparable form (`TOpt.toComparableGlobal`). Mirrors
`MonoInlineSimplify.inlineCandidates`:

  - skip recursive globals — SCC over the `Define` deps sets
    (`Compiler.Graph` already provides the SCC utility the mono pass uses);
  - body from `Define expr _ _` where `expr` is `Function _ params body _`;
  - `cost = computeCost` — port the mono cost model with the kernel arm
    collapsed to the flat 6 (§3);
  - `exactOnly` uses the SAME rule as the mono pass —
    `cost > threshold && not whitelisted && not (partialHof && hofAdmitted)` —
    so both inliners agree on what is inlinable.

### Step 4 — substitution and the rewrite

`tryInlineCall` on `Call region (VarGlobal _ g _) args meta`:

  - exact arity → substitute params, alpha-rename bound names, splice;
  - partial → build a residual `Function`;
  - over-application → substitute then re-apply the remainder.

**Alpha-renaming is the correctness core.** `NormalizeLambdaBoundaries`'s
`RenameCtx` is the model; the mono pass's `freshenLetBoundNames` records the
trap that cost it a gate round: **`MonoDestruct` binders were passed through
verbatim while `MonoDef`/`MonoTailDef` binders were renamed**, so an inlined
`let (s1, a) = …` captured the caller's `a`
(`memory: eco-hof-elimination-plan`, "DESTRUCTURE-BINDER CAPTURE"). The TOpt
analogue is `Destruct (Destructor Name Path meta) body meta` — **rename that
binder too, inner-first.** A test for exactly this shape is mandatory (§6).

### Step 5 — beta, forwarding, DCE, case simplification

Port in that order, each with its own metric counter and its own unit test.
`ForwardPartialCall` needs `calleeArity`, which pre-mono is
`List.length params` of the target's `Function` — simpler than the mono pass's
`specArities` + `aliasArity` fuel chase.

### Step 6 — the fixpoint

`fixpointIterations` rounds, as the mono pass does. Reuse the config field.

## 6. Tests

Every step's gate, in one place, so the implementer can self-check:

| step | gate |
|---|---|
| 0 | two inlines of one body yield DISTINCT `SrcLambdaId`s |
| 1 | `.mlir` byte-identical at defaults (flags added, nothing else changes) |
| 2 | `.mlir` byte-identical with `preMono=1` (identity transform) |
| 3 | candidate set non-empty; recursive globals absent from it |
| 4 | `InlineSimplifyDestructCaptureTest` passes; E2E green |
| 5 | each transform's counter non-zero on a fixture that exercises it |
| 6 | fixpoint terminates; `elm-tests` at baseline |

| test | pins |
|---|---|
| `InlineSimplifyTest` (new, `compiler/tests/TestLogic/`) | one case per transform: exact inline, partial inline, beta, forward, DCE, case-simplify |
| **`InlineSimplifyDestructCaptureTest`** | Step 4's binder-capture trap: an inlined body containing `Destruct` whose binder shadows a caller name. **Write this before Step 4 passes.** |
| `test/elm/src/PreMonoInlineTest.elm` | runtime differential with CHECK lines; must print identically in all four flag arms |
| existing suites | `elm-tests` at the 13,455 / 12 baseline; E2E 1,720 / 1,720 |

## 7. A/B — POSITION test, two arms

**Exactly one inliner is active in each arm, with the SAME budget and config.**
This isolates the variable that matters — WHERE the inliner runs — rather than
confounding it with how much inlining happens.

| arm | `preMono` | `postMono` | meaning |
|---|---|---|---|
| **LATE** | off | on | today's default: inline after monomorphization |
| **EARLY** | on | off | inline before monomorphization |

Both arms share `threshold`, `hofThreshold`, `maxPerFunction`,
`fixpointIterations`, `whitelist`/`blacklist` and `partialHof`. Any difference
in those makes the comparison meaningless — the arms would differ in amount as
well as position.

Deliberately NOT run as headline arms:

  - **both on** — confounds position with amount; the sum of two passes is not a
    position measurement. Useful later as a SHIPPING candidate if EARLY wins on
    compile time but loses runtime, but it is not part of this A/B.
  - **neither on** — a no-inlining floor. Useful for attribution if a result is
    hard to read, not for the position question.

### 7.1 What to record per arm

  - **compile wall** — `benchmarks/lss-opt.md` protocol, one cold run per arm,
    census flags off, NO uprobe. (A probe roughly doubles wall; a probed number
    is not a wall figure.)
  - **mono input size** — nodes/specs entering monomorphization. EARLY should
    shrink this; it is the direct test of the work-multiplication hypothesis.
  - **inline count** — `InlineSimplify.inlineCount` (EARLY) against
    `MonoInlineSimplify.inlineCount` (LATE, 65,910 today). The ratio IS the
    redundancy §8 estimates, measured rather than inferred.
  - **`.mlir` size** and **generic dispatch** (uprobe, separate runs).
  - **LSS stamping**: `dispatchUpgraded`, `declinedNoInstance`, and the reshape
    census (`ECO_INLINE_REPORT=1`). EARLY should show `cleared = 0` — no pass
    left that destroys a member.

### 7.2 Reading it

Judge compile-time on **wall and mono input size**; judge runtime on
**dispatch and the protocol wall**. Do not mix them, and do not read a wall
measured under a probe.

EARLY is expected to be weaker on generated code (§3 — it lacks `loopify` and
the kernel cost classes) and stronger on compile time. If that is what the
numbers say, the follow-up is the both-on configuration, not a further position
experiment.

## 8. P0 census — informative, NOT a blocker

**How many of the 65,910 inlines are redundant per-specialization copies?**

Method: in `MonoInlineSimplify.recordInline`, the callee is already resolved to
a qualified name via `globalToQualifiedName` for `inlinedByCallee`. Add a second
Dict keyed `<qualifiedName>|<specId>` and report both sizes. Then

```
redundancy = inlines / distinct (qualifiedName, callSiteShape)
```

A cleaner proxy needing no new code: `inlinedByCallee` already gives inlines per
callee NAME. Report `Dict.size inlinedByCallee` against `inlineCount`: 65,910
inlines over K distinct callee names bounds the redundancy at `65910 / K`.

**Explicitly not a gate.** The user's decision: build and measure regardless.
The census sharpens the expectation; §7 decides.

### 8.1 P0 RESULT (2026-09-09)

Measured by keying each inline on `<callee qualified name>|<call-site region>`.
Two specializations of ONE source call site share a region, so the distinct
count is what a pre-mono inliner would visit ONCE.

| | |
|---|---:|
| inlines performed (post-mono) | **65,949** |
| distinct SOURCE call sites | **27,130** |
| distinct callee definitions | 769 |
| **redundancy factor** | **2.43x** |

**Reading it honestly.** A pre-mono inliner does not automatically collapse
65,949 into 27,130 — 2.43x is the CEILING on the work saved, not a prediction.
It says the average source call site is inlined 2.43 times because its enclosing
function was specialized 2.43 ways, on average.

That is a real but moderate multiplier. It is not the 10-40x that "inline `map`
once instead of once per specialization" might suggest, because the redundancy
is driven by how many ways the CALLER is specialized, not by how many
specializations the callee has. 769 distinct callees over 27,130 source sites
means the average definition is inlined at ~35 distinct sites — that breadth is
irreducible and a pre-mono inliner pays it too.

**Second-order effects the ratio does NOT capture**, and which the §7 A/B
measures directly: inlining before specialization may reduce the number of
specializations DEMANDED (deleting call sites deletes demand), which is a
compile-time saving on monomorphization itself rather than on the inliner. That
could be larger or smaller than 2.43x and is not inferable from this census.

**Not a gate** (user decision): build and measure regardless. The census sets
the expectation — a moderate compile-time win at best from work-avoidance alone
— and moves the burden onto §7's mono-input-size measurement.

## 9. Risks, and what makes them survivable

| risk | mitigation |
|---|---|
| **`SrcLambdaId` duplication** (R4) — asserts N differing copies are one LSS member; miscompile if the LSS_024 fence is ever off | Step 0, before any inlining is written; unit test that two inlines of one body yield distinct ids |
| **Binder capture** (Step 4) — a REAL bug the mono pass shipped | dedicated test written first; `Destruct` binders renamed inner-first |
| Pre-mono inlining changes which specializations are demanded, so `.mlir` legitimately differs | expected; the gate is E2E + the runtime differential, not byte-identity (except Steps 1–2) |
| Duplicated inliner logic drifts from `MonoInlineSimplify` | v1 shares the COST MODEL and the `exactOnly` rule by construction; both read `Config.InlineConfig` |
| Code growth pre-mono is then multiplied by specialization | arm C (early only) vs arm B (both) separates this; watch `.mlir` size |
| Type-directed decisions unavailable pre-mono | accepted: v1 is deliberately weaker (§3), and arm B keeps the late pass |

## 10. What NOT to do

- **Do not delete `MonoInlineSimplify`.** Even if arm C wins, the late pass
  reaches monomorphic-only optimizations (`loopify`, kernel cost classes) that
  v1 cannot. `postMono=0` is an experiment switch, not a deprecation.
- **Do not port `arityRaise`.** Measured 2026-09-08 at +76.6 % dispatch /
  +42.9 % wall, because raising clears the identity AbiCloning needs and
  collapses `singleton_fast` 13,045 → 1.
- **Do not expect an LSS win.** The reshape population it removes weighs
  0.245 % of generic dispatch (`plans/lss-inline-member-propagation.md` §7.3).
  The case for this plan is compile-time work and phase order.
- **Do not judge wall under a uprobe.**

## 11. IMPLEMENTATION RESULT (2026-09-09)

Built. `compiler/src/Compiler/GlobalOpt/InlineSimplify.elm`, wired into
`Builder/Generate.elm:runMonoOptPipeline` behind `inline.preMono`, with
`inline.postMono` gating the existing pass. Both default as planned
(`preMono=False`, `postMono=True`).

### 11.1 Gates

| gate | result |
|---|---|
| Step 1 — `.mlir` byte-identical at defaults | **GREEN**, verified twice (`s5`/`s6` and again `s9`/`s10` after the test-driven fixes): the post-change compiler reproduces its own input `.mlir` byte-for-byte. A bootstrap fixed point. |
| Step 3 — candidate set non-empty, recursives absent | GREEN — `InlineSimplifyTest`, including a `bodiesSeen` denominator (§11.4). |
| Step 4 — capture | GREEN, see §11.3; `InlineSimplifyDestructCaptureTest`. |
| Step 6 — fixpoint terminates | GREEN — both arms complete a full self-compile. |
| unit suite | 150/150 on the `InlineSimplify` filter; whole suite 13,458 passed against the 13,453 baseline, same 12 pre-existing `POST_010`/`TYPE_007`/golden failures. |
| E2E | **887 / 889** at defaults AND with `preMono=1, postMono=1`. `elm/FlagsRecordTest` (signal 6) and `elm/PortEchoTest` fail IDENTICALLY on the pre-change compiler — pre-existing, verified by swapping the binary. The EARLY arm (`postMono=0`) adds 7 segfaults, which are NOT this pass — see §11.6. |
| Steps 2 / 5 | Superseded / deferred — see §11.5. |

### 11.2 THE FINDING: a pre-mono inliner may only copy MONOMORPHIC bodies

This is the substantive result of the plan, and it was not in §4's adversarial
review.

`TOpt.Expr` carries a `Meta` on every node, and a `Meta` carries that node's
SOLVER VARIABLE. Copying a body copies the `Meta`s verbatim, so two copies of a
POLYMORPHIC body share one set of solver variables. `MonoSolver` then meets the
two call sites' instantiations at the same variable. Measured, on
`test/elm/src/PreMonoInlineTest.elm`, whose `twice : (a -> a) -> a -> a` is used
at `Int` and at `List Int`:

```
MonoSolver.unify-mismatch: ... unify-fail ({..} -> List<?a> -> List<?a>)
                                      /vs/ ({..} -> Int -> Int)
```

The two instantiations disagreed structurally, so this surfaced as a hard
error. **Two instantiations that happened to unify would have collapsed onto
one silently** — a wrong answer, not a crash.

`MonoInlineSimplify` has no such exposure: it runs on already-specialized code,
where every body is ground. **That is the reason the inliner is positioned
after monomorphization, and it is a reason of kind, not of degree.** §2's IR
comparison table treated the two positions as differing only in what
information is available; they also differ in what is SAFE to duplicate.

**v1's answer: refuse.** `isGround` walks the candidate's parameter types and
every `Meta` in its body and admits only fully-monomorphic candidates. The
walk is deliberately whole-body rather than signature-only, so let-polymorphism
inside a ground signature cannot slip a shared variable through.

**Cost of refusing**, measured on `PreMonoInlineTest.elm`:

| | |
|---|---:|
| admitted candidates | 4 |
| refused as polymorphic | **238** |
| refused over budget | 19 |

So the guard rejects ~98% of what the pass would otherwise admit. The EARLY arm
is therefore NOT the same amount of inlining moved earlier; it is a much
smaller amount of inlining, done earlier. §7's position A/B must be read with
that in mind — it is no longer a clean position-only comparison, and cannot be
made into one without the follow-on below.

**The follow-on, if the position is worth pursuing:** refresh the copied types
instead of refusing them — mint fresh solver variables per copy and substitute
them through every `Meta`. That is instantiation, i.e. re-implementing the part
of `MonoSolver` this pass runs before. It is a substantially larger piece of
work than the inliner itself, and it should not be started before §7's numbers
say the position is worth it.

### 11.3 Alpha-renaming: one uniform suffix per copy

`NormalizeLambdaBoundaries.renameExpr` was the intended vehicle (§Step 4) and
turned out to be unusable as-is: it renames `Def`, `Destructor` and `Case`
binders and all variable USES, but leaves `Function`/`TrackedFunction`
parameters and `TailDef` names and arguments alone. Handing it an environment
covering every binder renames the uses of a lambda parameter while leaving the
parameter itself — an unbound local, and a silent one.

`InlineSimplify` therefore does its own renaming: every local name in a copied
body — binder and use alike, `Destruct` and `TailDef` and lambda parameters and
`Case` label/root and `Path` roots included — gets ONE `_pi<n>` suffix unique to
that copy. A uniform suffix is injective on names, so it preserves shadowing
exactly and needs no scope tracking. The mono pass's destructure-binder capture
bug cannot recur because the walk has no per-binder-kind opt-out.

### 11.4 Two traversal defects found by building it

Both would have been invisible in a smoke test and are recorded because they
are easy to repeat:

  - **`cost` ignored the decider.** `Case`'s branch list holds only the SHARED
    jump targets; an unshared branch body lives in `Leaf (Inline expr)` inside
    the `Decider`. Costing only the branch list under-counts a `case`-heavy
    body by its entire weight, so a budget-respecting inliner copies something
    enormous while reporting that it stayed under budget.
  - **`buildCandidates` only matched `Define`/`Function`.** User code is
    overwhelmingly `TrackedDefine`/`TrackedFunction`. The first census run
    reported **`candidates=1` for a whole program** — a number small enough to
    look like a broken instrument, and it was.

`Metrics` therefore carries **`bodiesSeen`**, incremented for every node whose
body the pass even looks at. `candidates = 0` reads identically whether the
pass refused everything or never matched a node shape; `bodiesSeen` separates
those, and it is the counter that would have caught the defect above on the
first run instead of the third.

**Two representation facts worth keeping** (both cost a test round):

  - a self-recursive definition is emitted as a **`Cycle` node**, not as a
    `Define` that names itself, so it never reaches the recursion guard at all —
    `recursiveSkipped` stays 0 on that shape, and the honest assertion is that
    the recursive global is never inlined;
  - a **tail**-recursive function has no `VarGlobal` self-reference — the front
    end has already turned it into a local `Case`/`TailCall` loop. It is
    therefore SAFELY inlinable: the loop is copied along with the body and stays
    self-contained. The recursion guard exists for the non-tail case.

`recursiveGlobals` unions three independent sources — `Compiler.Graph`'s SCC
over the dependency sets (mutual recursion), `Cycle` membership, and a
structural scan of the body for a self-naming `VarGlobal`/`VarCycle`. The
structural scan is not redundant: the SCC saw the test harness's self-recursive
fixture as acyclic because its `deps` set did not contain itself.

### 11.5 Scope actually delivered

  - Steps 0, 1, 3, 4, 6 built. Step 2's "identity transform" gate is superseded:
    the skeleton was never landed on its own, and the pass at `preMono=1` is not
    an identity transform by construction. Step 1's byte-identity gate covers
    what mattered (defaults unchanged).
  - Step 5 (beta, forwarding, DCE, case-simplify) NOT built. The §7 arms
    therefore compare `MonoInlineSimplify` (all transforms) against
    `InlineSimplify` (direct-call inlining only) — a second respect in which the
    A/B is not position-only.

### 11.6 THE SECOND FINDING: `postMono=0` is not a legal configuration

The EARLY arm's E2E run failed 9 of 889 — the 2 pre-existing ones plus **7 new
segfaults**, clustered on Array/JsArray kernels:

```
elm-core/ArrayUnsafeGetFloatElementTest   ELF crashed (signal 11)
elm-core/ArrayUnsafeGetCharElementTest    ELF crashed (signal 11)
elm-core/ArrayUnsafeSetCharOverwriteTest  ELF crashed (signal 11)
elm-core/ArrayAppendRepeatedTest          ELF crashed (signal 11)
elm-core/JsArrayGetSetTest                ELF crashed (signal 11)
elm-core/JsArrayUnsafeGetIntTest          ELF crashed (signal 11)
elm-json/DecodeArrayShapeTest             ELF crashed (signal 11)
```

Attributed by running the same 38-test filter in three configurations:

| `preMono` | `postMono` | Array filter |
|---|---|---|
| 0 | 0 | **7 failed** |
| 1 | 0 | **7 failed** (the same 7) |
| 1 | 1 | **38 / 38** (and 887/889 on the full suite — the 2 pre-existing) |

**`MonoInlineSimplify` is load-bearing for CORRECTNESS, not only for speed.**
Turning it off segfaults the Array kernels whether or not the new pass runs, and
turning it back on fixes them whether or not the new pass runs. The new pass
introduces no miscompile; the plan's `postMono=0` arm does.

The most likely mechanism is that pass's kernel-specific arms —
`kernelLetDCE` / `deadDroppableKernelLets` / `deadBareKernelVar` — which delete
kernel lets whose surviving form the Array lowering depends on. That is an
unfixed latent defect in its own right and is recorded here, not fixed: nobody
had previously run the suite with the pass off, because until this plan there
was no flag to turn it off.

**Consequence for §7.** The two-arm position A/B cannot be run as designed. Its
EARLY arm requires `postMono=0`, and `postMono=0` does not produce a working
program — so the EARLY arm's 474.9 s wall is a wall for a program that
segfaults on Array operations, and comparing it to LATE's 477.9 s compares a
correct compile against a broken one. **Run AS's wall row should not be read as
a position measurement.** Combined with §11.2 (the EARLY arm does 1.5% of the
inlining), there are now two independent reasons the position question is not
answered by these numbers.

### 11.7 What is actually shippable, and what is not

**Shippable now, and shipped default-off:** the two flags and the new pass. The
compiler is at a bootstrap fixed point at defaults, so the default path is
provably unchanged.

**Not shippable:** `postMono=0` in any arm — it miscompiles. The flag stays as
an experiment knob and its danger is recorded above.

**The open question, and the one worth pursuing first:** §11.6's Array
segfaults are a real latent defect in `MonoInlineSimplify` that this plan
uncovered by accident. It deserves its own plan — a pass that is required for
correctness is a pass whose kernel arms are doing something other than
optimization, and that is worth knowing regardless of where any inliner runs.

**The position question itself** stays open and now needs §11.2's per-copy type
refreshing before it can even be asked. Given that both-on is the only correct
configuration, the realistic next experiment is `preMono=1, postMono=1` measured
against the default — inlining ADDED early, not moved early. That is a different
question from the one this plan set out to answer, and it is a cheap one: the
flags for it already exist.

---

# PART II — making the early inliner viable (2026-09-09)

§11 closed the v1 build with two blockers. Both are now root-caused, and neither
is a property of the inliner itself. This part is the work to remove them.

## 12. Polymorphic inlining — freshen the type variables per copy

### 12.1 The mechanism, exactly

`Compiler/Monomorphize/AssignMVarIds.elm` converts `GlobalGraph Name` to
`GlobalGraph MVarId`. Its per-definition environment is

```elm
{-| Per-scheme mapping from type variable names to their assigned MVarIds.
Reset for each top-level definition; grows lazily as new names are encountered.
-}
type alias SchemeEnv = Dict Name TypeIds.MVarId
```

**The identity of a type variable inside one top-level definition is its
NAME.** Two copies of a polymorphic body spliced into the same caller both say
`Can.TVar "a"`, so `ensureMVarId` hands both the same `MVarId`, and every later
demand meets at that one variable. That is the whole of §11.2's failure — not
the solver `Point` in `meta.tvar`, which monomorphization deliberately never
reads (`MonoSolver/Monomorphize.elm:15`: "works only from the total `meta.tipe`
(never `meta.tvar`)").

**Consequence: the fix is a pure `Name` rewrite, needing no solver state, no
fresh-variable supply and no access to the type checker.** It is available at
exactly the point `InlineSimplify` already runs.

### 12.2 What to rename

Give each inlined copy the SAME `_pi<n>` suffix the term-level rename already
uses, and apply it to every `Can.TVar` name reachable from the copied body:

  - every expression `Meta.tipe`;
  - the candidate's parameter types (they become `Let` declared types);
  - `Def`/`TailDef` declared types and `TailDef`'s `Maybe Vars.Variable`
    (left alone — unread by mono);
  - `Destructor`'s `Meta`;
  - `Can.TRecord`'s extension variable, `Can.TAlias`'s argument variables.

`groundExpr`/`children` from §11.2 already walk exactly this set, so the
rename is the same traversal with `Can.TVar name -> Can.TVar (name ++ sfx)`
substituted for the "is it ground?" test. **`isGround` then becomes dead and the
`polymorphic` counter becomes a census of what USED to be refused** — keep the
counter, retire the refusal.

### 12.3 Three things the rename must also do

These are not optional; each is a silent wrong answer if skipped.

**(a) Carry the supertype constraints across.** `ensureMVarId` reads a variable's
constraint from `ctx.varSupers`, the `Dict Name Vars.SuperType` that is the
GlobalGraph's fifth field — keyed by NAME. Renaming `number42` to
`number42_pi3` loses its `number` constraint, and an unconstrained variable
defaults differently. `InlineSimplify` already rebuilds the `GlobalGraph`, so it
must extend that dict with `<name><sfx> -> super` for every renamed name that
had an entry. Cheap, and the only reason the pass needs to touch the graph's
non-node fields at all.

**(b) Do NOT extend `schemeRoots`.** `ensureBinder` consults
`schemeRootsForDef` (`SchemeRootsByGlobal`, per-global, keyed by name) BEFORE
the plain path, and `ensureMVarIdForRoot` deliberately gives two names backed by
one solver root **the same MVarId** — which is precisely the merge we are trying
to avoid. Renamed names are absent from the caller's `schemeRoots`, so they fall
through to the plain per-name path automatically. **This is correct by
construction and must be left alone**; adding the renamed names to `schemeRoots`
would silently reinstate the bug.

**(c) Decide the arrow slots, and measure the decision.** `Can.TLambda` carries
an `ArrowSlot`; a `SolverRoot idx` makes `AssignMVarIds` mint ONE `ArrowId` for
every arrow sharing that root (`arrowRootEnv`, and it is GLOBAL state, not
per-definition). Two copies of a body keep the same roots, so their arrows —
and therefore their LSS members — merge, even though the copies now have
DIFFERENT types. A member that indexes copy A's body could then be stamped at a
call site in copy B, whose spec is a different instantiation.

  - **Conservative (recommended first):** rewrite the copied body's
    `TypeIds.SolverRoot _` slots to `NoArrow`. `AssignMVarIds` then falls back
    to per-occurrence `freshArrowId` — the same path every post-solve type
    already takes — so each copy gets its own arrow identity. Type-neutral:
    `ArrowSlot` feeds `ArrowId`/`rootKey` only, never `MVarId`.
  - **Cost:** LSS root identity is lost for inlined bodies, which is precision
    the `lss.arrowSolverRoots` / `sigRootIdentity` work exists to buy.
  - **Therefore measure both arms** (`stampedPapGlobal`, `dispatchUpgraded`,
    `declinedNoInstance`) before keeping the aggressive one. Do not ship
    root-preserving without that measurement — LSS_018's spiral is the
    precedent for what a wrong member identity costs.

### 12.4 Rename, not substitute — and why

The alternative is to MATCH the callee's parameter types against the actual
argument types at the call site, and substitute. It is tempting because it
produces a ground copy. Reject it for v1:

  - it needs a matcher, and a decision for every case the match is partial (a
    type variable that appears only in the body, under let-generalization);
  - it buys nothing correctness-wise — `MonoSolver` performs exactly that
    unification anyway, from the `Let` declared types the splice already
    creates;
  - the rename is total, is ~30 lines, and has no partial case.

**But state the cost honestly:** renaming gives every copy its own MVarIds, so
monomorphization solves MORE variables than before. That works AGAINST this
plan's premise (§8.1's 2.43x was about avoiding duplicated INLINING work, and
this adds duplicated SOLVING work). §12.6 is the measurement that decides
whether the trade is positive.

### 12.5 Steps

| # | work | gate |
|---|---|---|
| 12a | `suffixType : String -> Can.Type Name -> Can.Type Name`, and thread it through the existing `suffixExpr` walk so every `Meta.tipe` and declared type is renamed with the copy's suffix | unit: two copies of one polymorphic body share NO `TVar` name |
| 12b | extend `varSupers` with the renamed names (§12.3a) | unit: a `number`-constrained callee keeps its constraint after inlining |
| 12c | clear `SolverRoot` slots to `NoArrow` in copied bodies (§12.3c) | `.mlir` still byte-identical at defaults |
| 12d | retire the `isGround` refusal; keep `polymorphic` as a census counter | `PreMonoInlineTest` passes in the EARLY arm — it is the fixture that FAILED and is the direct gate |
| 12e | re-measure | §12.6 |

**`test/elm/src/PreMonoInlineTest.elm` is the gate for the whole of §12**: it
already exists, it already fails with the pre-mono inliner unrestricted, and it
uses four helpers at two types each precisely so a shared-variable collapse
cannot pass it.

### 12.6 What to measure after

`candidates` and `inlineCount` in the EARLY arm — the number to beat is **969**,
and the number it should approach is LATE's **65,949**. If it lands close, §7's
position A/B becomes runnable for the first time (subject to §13). Also record
mono input size and solver counters, because §12.4's cost lands there.

## 13. The `postMono=0` miscompile — ROOT-CAUSED, and it is not the inliner

### 13.1 Attribution

`ECO_INLINE_THRESHOLD=0` with `postMono=1` reproduces all 7 segfaults. So the
load-bearing thing is **inlining itself**, not `letDCE` / `kernelLetDCE` /
`closureDCE` / beta / forwarding, all of which still run at threshold 0.

Bisecting the threshold: **1 already fixes it.** At threshold 1 the census names
22 callees; blacklisting them via `eco-config.json` narrows to one:

```json
{ "inline": { "blacklist": ["Elm.JsArray.unsafeGet"] } }
```

`JsArrayGetSetTest` at DEFAULT settings, with that single name blacklisted,
segfaults. `gdb` puts the fault in `Array_get_$_2` — the mutator, not the GC.

### 13.2 The defect

Same source, same array, `Array.get`'s tail-lookup arm:

```mlir
; INLINED (correct) — the element kind is Int, so the slot read is unboxed
%12 = "eco.array.get"(%3, %11) : (!eco.value, i64) -> i64
%13 = "eco.construct.custom"(%12) {constructor = "Just", unboxed_bitmap = 1}

; CALLED (crashes) — the spec returns a BOXED value…
%12 = "eco.call"(%11, %3) {callee = @Elm_JsArray_unsafeGet_$_34} : (i64, !eco.value) -> !eco.value
%13 = "eco.unbox"(%12) : (!eco.value) -> i64      ; …and this unboxes a raw int
%14 = "eco.construct.custom"(%13) {constructor = "Just", unboxed_bitmap = 1}
```

and the spec itself:

```mlir
func.func private @Elm_JsArray_unsafeGet_$_34(%arg0: i64, %arg1: !eco.value) -> !eco.value
    attributes {eco.logical_result_types = ["value"]} {
  %0 = "eco.array.get"(%arg1, %arg0) : (!eco.value, i64) -> !eco.value
```

`_$_34` serves an array of UNBOXED `Int`s and reads its slot as `!eco.value`.
Note that `_$_21` — the specialization for the boxed `Node` array, called from
`Array_getHelp` — has a BYTE-IDENTICAL body. Two specializations exist, so the
specializer did distinguish the element types; the emitted body did not.

**Confirmed on a purpose-built probe.** A program holding both an `Array Int`
and an `Array Float`, compiled with `unsafeGet` blacklisted, emits **FOUR**
`Elm_JsArray_unsafeGet_$_*` specs — Int leaf, Float leaf and a `Node` tree spec
for each array. All four are byte-identical:

```mlir
func.func private @Elm_JsArray_unsafeGet_$_NN(%arg0: i64, %arg1: !eco.value) -> !eco.value
    attributes {eco.logical_param_types = ["i64", "custom:0:1:v"], eco.logical_result_types = ["value"]}
  %0 = "eco.array.get"(%arg1, %arg0) : (!eco.value, i64) -> !eco.value
```

So the specializer keys on the element type — four distinct `SpecKey`s could not
exist otherwise — while **the emitted body is element-kind-blind for all four**.
The information the fix needs is present; the emitter is not reading it.

### 13.3 The site, and the smoking gun

`Compiler/Generate/MLIR/Intrinsics.elm:915-931`, two arms of one `case`:

```elm
"unsafeGet" ->
    -- JsArray.unsafeGet : Int -> Array a -> a
    -- argTypes = [ MInt, MCustom _ "Array" [elt] ], resultType = elt
    case argTypes of
        [ Mono.MInt, _ ] ->                                   -- array type DISCARDED
            Just (ArrayGet { elementMlirType = Types.monoTypeToAbi resultType })

"unsafeSet" ->
    case argTypes of
        [ Mono.MInt, elt, _ ] ->                              -- element read from the ARG
            Just (ArraySet { elementMlirType = Types.monoTypeToAbi elt })
```

**`unsafeSet` takes the element kind from an argument; `unsafeGet` takes it from
`resultType` and throws the array type away.** `resultType` is the mono type of
the call expression being emitted (`Generate/MLIR/Expr.elm:4382`), which inside
a standalone spec is the spec's own declared result — boxed. Inlined into a
caller that wants an `i64`, the same code sees `MInt` and is right. That is
exactly the inlined/called split observed.

### 13.4 Fix

Make `unsafeGet` symmetric with `unsafeSet`: take the element kind from the
ARRAY ARGUMENT, which the probe above proves is distinct per specialization.

```elm
"unsafeGet" ->
    case argTypes of
        [ Mono.MInt, arrayTy ] ->
            case arrayElementType arrayTy of
                Just elt ->
                    Just (ArrayGet { elementMlirType = Types.monoTypeToAbi elt })

                Nothing ->
                    -- No concrete element: DECLINE the intrinsic and let the
                    -- ordinary kernel call be emitted, rather than guessing a
                    -- kind. Guessing is what produced this defect.
                    Nothing
```

**Two cautions for the implementer.**

  - **Do not trust the source comment's spelling.** It says
    `MCustom _ "Array" [elt]`, but the emitted `eco.logical_param_types` for
    that parameter is `custom:0:1:v` — a ONE-field custom, i.e. the `JsArray`
    wrapper, not the four-field `Array`. Find the real constructor by dumping
    the `MonoType`; write `arrayElementType` against what is actually there, and
    have it return `Nothing` for anything it does not recognise.
  - **Decline rather than default.** The whole defect is a boxed default
    standing in for an unknown element kind. A fallback to `resultType` would
    reintroduce it in exactly the cases that matter.

Then re-check `unsafeSet`'s arm with the same probe: it reads `elt` from the
argument list and so ought to be correct, but §13.5 records evidence it may not
be, and "ought to" is what put this bug in the tree.

### 13.5 Scope — this is bigger than the inliner

  - It is a **latent shipped miscompile**, reachable today by any program where
    `unsafeGet`'s cost exceeds the inline budget, or by any budget change. The
    default budget of 10 against a cost of 1 is the only thing hiding it.
  - `Elm.JsArray.unsafeSet` is also implicated: blacklisting both crashes, and
    blacklisting `unsafeSet` alone gave a nonzero exit with otherwise-correct
    output. **Confirm it separately** rather than assuming the `unsafeSet` arm
    is clean because it reads the argument.
  - The 7 failing tests are the regression suite for the fix:
    `ArrayUnsafeGetFloatElementTest`, `ArrayUnsafeGetCharElementTest`,
    `ArrayUnsafeSetCharOverwriteTest`, `ArrayAppendRepeatedTest`,
    `JsArrayGetSetTest`, `JsArrayUnsafeGetIntTest`,
    `DecodeArrayShapeTest` — Int, Float AND Char element kinds, which is good
    coverage of `monoTypeToAbi`'s unboxed cases.
  - **The right gate is `ECO_INLINE_THRESHOLD=0` on the whole E2E suite**, which
    is the first time this codebase has had one. It turns "the inliner is an
    optimization" from an assumption into something checked, and it should
    become a standing CI leg — every remaining crash under it is another latent
    miscompile of this class.

### 13.6 Sequencing

Do §13 FIRST. It is smaller, it is a real bug fix independent of this plan, and
until it is fixed no `postMono=0` arm means anything. §12 is only worth
finishing if §13 makes the EARLY arm a legal configuration at all.


## 14. §13 FIXED AND MEASURED (2026-09-09)

`Compiler/Generate/MLIR/Intrinsics.elm`. The fix is not the one-line change §13.4
proposed; getting there took three rebuilds and each one moved the diagnosis.

### 14.1 The real defect: a stale type NAME

```elm
arrayElementType ty =
    case ty of
        Mono.MCustom _ _ "Array" [ elt ] -> Just elt
        _ -> Nothing
```

**`Elm.JsArray` declares `type JsArray a`, so the constructor is `JsArray`, not
`Array`.** This helper therefore matched NOTHING, which is why `unsafeGet` was
reading its element kind out of `resultType` in the first place — and why
`singleton`, its only other caller, had been silently declining to a kernel call
for as long as it has existed.

Found by dumping the monomorphized type rather than reading the source comments,
which all say `MCustom _ "Array" [elt]`. `ECO_MONO_LSS_REPORT=1` prints it:

```
Xelm core Elm.JsArray JsArray(I)
Xelm core Elm.JsArray JsArray(Xelm core Array Node(I))
```

**Three separate comments in this file assert the wrong spelling.** They were
the reason the first attempt at the fix looked obviously right and was wrong.

### 14.2 The rule that shipped

Element kind from the ARRAY ARGUMENT, with two guards:

  - `Just (MVar _ _)` — the array is element-POLYMORPHIC. This is how
    `unsafeGet`'s own specialization arrives: its array parameter's element is
    a variable, so ONE spec body has to serve both boxed and unboxed elements,
    which an unboxed slot read cannot do. **Decline** and let the generic kernel
    call resolve the kind from the array at runtime.
  - `Nothing` (element unrecoverable) — use `resultType` only while it is a
    concrete UNBOXED primitive. A widened result is precisely the defect; an
    unboxed one cannot have been widened.

`unsafeSet` gets the same treatment, preferring the array and falling back to
its value argument, declining when neither is concrete.

**That the spec's element is a variable is the deeper finding.** The four
distinct `unsafeGet` specs do not differ by element kind at all; the emitted
body genuinely cannot know it. So the correct behaviour at a non-inlined site
is to decline, not to emit a better-kinded op — the information is not there to
emit one with.

### 14.3 Results

| configuration | before | after |
|---|---|---|
| Array filter, defaults | 38 / 38 | **38 / 38** |
| Array filter, `preMono=1 postMono=0` | 31 / 38 | **38 / 38** |
| Array filter, `preMono=0 postMono=0` | 31 / 38 | **38 / 38** |
| Array filter, `ECO_INLINE_THRESHOLD=0` | 31 / 38 | **38 / 38** |
| FULL E2E, defaults | 887 / 889 | **887 / 889** |
| FULL E2E, `preMono=1 postMono=0` | 880 / 889 | **887 / 889** |
| unit suite (`elm-tests`) | 13,453 / 12 baseline | **13,464 passed, same 12 pre-existing** |

The two residual failures are `elm/FlagsRecordTest` and `elm/PortEchoTest`,
which fail identically on the pre-change compiler.

**No default-path cost.** On `JsArrayGetSetTest` the LIVE `eco.array.get` sites
are 4 before and 4 after; what changed is that their result kinds are now
derived from the element (2 x `i64`, 2 x `!eco.value`) instead of guessed. The
two additional sites that now decline are inside the `unsafeGet` SPECS, which
have ZERO callers at default settings — dead code.

**Bootstrap fixed point re-established.** A codegen fix legitimately moves the
emitted `.mlir`, so the first iteration differs (15,626,963 -> 15,627,012 B,
+49); the second is byte-identical, which is the property that matters.

### 14.4 Consequences

  - **§13's blocker is gone.** `postMono=0` is now a legal configuration, and
    the EARLY arm passes the full E2E suite. §7's position A/B is unblocked on
    this axis — §12 (polymorphic inlining) remains.
  - **`ECO_INLINE_THRESHOLD=0` over the whole E2E suite should become a standing
    leg.** It is the check that the inliner is an optimization rather than a
    correctness dependency, this codebase has never had it, and the first time
    it was run it found a shipped miscompile.
  - The stale `"Array"` comments in `Intrinsics.elm` are corrected to
    `"JsArray"`, so the next reader is not sent down §14.1's dead end.


## 15. §12 BUILT AND MEASURED (2026-09-10)

Polymorphic bodies can now be copied. `PreMonoInlineTest` — the fixture that
failed §11.2 — passes in the EARLY arm, the EARLY self-compile succeeds, and the
full E2E suite is back to its 887/889 baseline with `preMono=1 postMono=0`.

### 15.1 What §12 got right, and the one thing it got wrong

Right: the clash is `AssignMVarIds`'s `SchemeEnv = Dict Name MVarId`, so it is a
`Name` rewrite needing no solver state (§12.1). `suffixType` does it, and
`varSupers` is extended for renamed names (§12.3a), and `SolverRoot` arrow slots
are cleared to `NoArrow` (§12.3c).

**Wrong: §12.4 rejected substitution and chose rename-only.** Renaming makes each
copy INDEPENDENTLY polymorphic — sound, but it leaves the copy's nodes
variable-typed with nothing to solve them, because the call that carried the
demand is exactly what inlining removed. Layout decisions then go wrong:

  - `swap : ( a, b ) -> ( b, a )` at two tuple types printed pointer-sized
    garbage (`swapA: [2241972932276, ...]`) — the spliced `Tuple`'s slot kinds
    were laid out from a type that was still a variable;
  - `Tuple.second` SIGSEGV'd all ten `RecordNarrow*` tests.

So substitution is not the optional refinement §12.4 called it; it is the
mechanism. `matchType` matches the callee's parameter types against the actual
argument types and its result type against the call's own, and `suffixType`
splices the bound type in verbatim, falling back to the rename only for
variables the call site leaves open.

### 15.2 The correction that actually made it work: decide per CALL

**Before monomorphization the CALL SITE frequently does not know its argument
types either** — an argument's `meta.tipe` is often still a variable that only
`MonoSolver` resolves. Where that happens the copy is variable-typed however
carefully it is renamed. So `determines` requires the call site to pin down
EVERY one of the callee's type variables to a GROUND type, and declines that
call otherwise. On the self-compile that is 1,506 declined calls — the guard is
doing most of the work, and it is a per-call decision, not a per-candidate one.

### 15.3 Four candidate-level guards, each found by a failing test

| guard | declines | found by |
|---|---:|---|
| `polyKernel` — a kernel call whose type is still variable | 15 | `Eco.Crash.crash : String -> a`, whose 134 copies registered `Eco_Kernel_Crash_crash` with conflicting ABIs (`eco.value -> eco.value` vs `eco.value -> i16`) |
| `hofParam` — a function-typed parameter | 40 | `List.foldr` inlined pre-mono made `LetNumberFoldrTest` print `0` for `105`; a lambda argument has no settled staging or PAP shape yet, which is what `MonoInlineSimplify`'s `hofThreshold`/`exactOnly`/`loopify` apparatus exists to handle on specialized code |
| `superVar` — a `number`/`comparable`/`appendable` variable | 22 | `LetNumber*`; freezing a constrained variable early changes its defaulting |
| `rowPoly` — an open `{ r \| … }` record | 0 | written for `RecordNarrow*`, which `determines` turned out to cover; kept because `matchType` genuinely cannot bind a row variable |

### 15.4 Numbers

| | v1 (refuse polymorphic) | §12 |
|---|---:|---:|
| candidates | 498 | **644** |
| inlines (self-compile) | 969 | **1,416** |
| declined: this CALL undetermined | — | 1,506 |
| full E2E, `preMono=1 postMono=0` | 887 / 889 | **887 / 889** |
| bootstrap fixed point at defaults | byte-identical | **byte-identical** |
| unit suite | 13,464 / 12 pre-existing | **13,464 / 12 pre-existing** |

1,416 against `MonoInlineSimplify`'s 65,949 is still 2.1%, so §7's position A/B
remains a comparison of two different AMOUNTS of inlining. The ceiling is now
visibly set by `undetermined` (1,506 declined calls, more than are performed),
and that is a pre-mono type-precision limit, not a budget one.

### 15.5 What would raise it

  - **`undetermined` is the whole game.** Every one of those 1,506 is a call
    whose argument types are still variables at this point in the pipeline.
    Nothing in this pass can improve that; it is a question about how much the
    type checker leaves for `MonoSolver`.
  - `hofParam` (40) is the one guard that is a deliberate scope choice rather
    than a hard limit, and it is where `MonoInlineSimplify` earns its keep.
  - A row-variable binding in `matchType` would retire `rowPoly`, which
    currently declines nothing but is load-bearing if `determines` is relaxed.


## 16. Follow-on investigation (2026-09-10) — see `/work/pre-mono-transformation.md`

Four questions (completeness of this pass; what post-mono can do without losing sets; other
pre-mono transforms; source shapes LSS resolves) are answered there. Two results land in this
plan's ledger:

  - **`determines` had a bug**: `typeVarsOfType` counted `Can.TAlias` parameter names as free
    variables, so every `Task`/`IO`-returning callee was refused as `undetermined`. Fixed (aliases
    contribute only their arguments' variables; same-name aliases match argument-wise). EARLY
    inlines 1,416 → **1,865**, `undetermined` 1,506 → 864. E2E 887/889 in the EARLY arm; defaults
    fixed point byte-identical.
  - **The denominator for §15.4 was wrong.** LATE's 65,949 is 27,130 source sites × 2.43
    per-spec multiplicity, and ≈35,100 of them are parameter-less alias forwards (`f = g`) that
    this pass skips at `List.isEmpty params`. A complete pre-mono pass tops out near the
    source-site count, not 66k. The ranked relaxations (R3 alias forwarding, R1 caller-binder
    bindings, R2 reference-node metas, R4 kernel cost classes) are in the report's §1.3.
