# Carrying LSS member identity through inliner reshapes

When `MonoInlineSimplify` rebuilds a closure — a partial inline, a beta of a
partial application, an arity raise — it CLEARS the lambda-set member. The
residual is then invisible to AbiCloning, so no site can ever stamp it. This
plan asks whether a NARROW class of those reshapes can carry identity forward
instead, and what it would take.

**STATUS: CLOSED UNBUILT (2026-09-09). Both mechanisms are refuted by
measurement: §6 has a population of ZERO (§6), and §5's population weighs
0.245 % of generic dispatch (§7.3). The census that decided it is kept, behind
`inline.report`. Nothing here should be built without new evidence.**

---

## 1. The mechanism, verified

Phase order (`Builder/Generate.elm:858`, then `globalOptimizeWithStats`):

```
monomorphization (LSS sets derived)  ->  MonoInlineSimplify  ->  AbiCloning (Phase 4, stamping)
```

`MonoGlobalOptimize`'s module doc states it: "Assumes MonoInlineSimplify.optimize
has already been applied." So every inliner reshape happens BEFORE any stamp is
placed.

Four sites clear identity, all of them closure REBUILDS:

| site | context |
|---|---|
| `MonoInlineSimplify.elm:3076` | `betaReduce`, partial-application branch |
| `:4710` | `tryInlineCall`, partial branch |
| `:721`, `:772` | `raiseStagedSpecs` (the `ECO_ARITY_RAISE` raiser) |

Each sets `srcLambda = Nothing, lssMember = Nothing, closureKind = Nothing,
captureAbi = Nothing`, with one justification:

> The residual is a NEW function, not a verbatim copy of the source lambda:
> params and capture layout differ. Claiming the source's `srcLambda` would let
> AbiCloning treat it as an interchangeable instance of the member (LSS_009
> impersonation).

A fully-SATURATED inline clears nothing — no closure is rebuilt. Only partial
reshapes lose identity, which is exactly the branch `inline.partialHof`
(`ECO_INLINE_PARTIAL_HOF=1`) forces.

## 2. Why the obvious fix does not work

"Just keep the member" fails, because membership is not a type-level claim. A
set asserts **ABI interchangeability**: `AbiCloning.joinGroup` (:574-576) admits
an instance to a group only under `sameSignatureLayout` AND
`sameCaptureLayout`, and the stamp license is `unanimous && fpUnanimous`. A
partially-inlined residual has a different parameter row and capture set by
construction — type-identical, ABI-different, which is precisely what a set may
not conflate.

Carrying the old id would therefore usually be CAUGHT, not catastrophic: the
reshaped instance fails `sameCaptureLayout`, starts a second group, the member
goes multi-group, and sites decline. Where the layout coincidentally matches but
the body differs, LSS_024's fingerprint fence catches it as `bodyMismatch`.

**The residual danger is narrow but real:** with the fence OFF
(`lss.layoutQualMembers=0`) a same-layout, different-body reshape WOULD be
stamped, and that is a miscompile. Any version of this work must therefore be
fence-dependent or must not reuse ids at all.

So naive propagation converts stamps into declines. It buys nothing.

## 3. The proposal — fresh identity for singleton reshapes

Do not reuse the id. **Mint a NEW member for the residual, and rewrite the sites
that named the old one** — but only when the old member is a TRUE SINGLETON: one
member, exactly one instance in the whole program, and that instance is the one
being reshaped.

```
before:  member m  ->  { one instance: closure C }      sites carry LSet [m]
reshape: C  ->  C' (different params/captures, same behaviour)
after:   member m' ->  { one instance: closure C' }     those sites carry LSet [m']
```

The set stays a singleton; the layout stays uniform because there is exactly one
inhabitant; the site can stamp on the new shape.

## 4. Why the singleton restriction is load-bearing

If the member had TWO instances and the inliner reshapes one, the set must
afterwards contain BOTH shapes to remain a sound over-approximation of what can
flow to the site — multi-layout, declines, no gain. Worse, rewriting the site to
name only the new one would be UNSOUND: the other instance still flows there.

Singleton-ness is what makes "rewrite every site naming m to name m' instead" a
faithful renaming rather than a narrowing. That is the whole soundness argument,
and it is checkable.

## 5. What would have to be built — CLOSED, see §7.3

| item | detail |
|---|---|
| **member-id supply in the graph** | `MonoGraph` carries `nextLambdaIndex` but NOT `nextMemberId` — that is a solver-side supply "seeded past `GlobalMVarState.nextLam` so member ids never collide (LSS_003)". The inliner has no collision-free way to mint a member today. Thread `nextMemberId` into `MonoGraph` (or a disjoint high range) BEFORE anything else; a fresh `lambdaId` from `nextLambdaIndex` is NOT safe to reuse as a member id. |
| **instance index, pre-inline** | Singleton-ness needs member → instance count. `AbiCloning.collectInstances` computes exactly this but runs AFTER the inliner. Either hoist a cheap counting pass, or have monomorphization export the count it already knows. |
| **site rewrite** | Sets live on arrow types as `LSet [Int]` inside `MFunction` (`Monomorphized.mFunction anno args ret`). Rewriting m → m' means a type-level walk over every annotated arrow that names m. `MonoTraverse.mapNodeTypes` is the existing vehicle. |
| **the reshape hook** | At :3076 / :4710 (and :721/:772 if the raiser is ever revived), replace `lssMember = Nothing` with `lssMember = Just m'` on the singleton path only; keep `Nothing` otherwise. |
| **`srcLambda` stays `Nothing`** | It names the SOURCE lambda for wrapper/home purposes; the residual is genuinely not that lambda. Only `lssMember` is being re-established. |

## 6. Cheaper alternative — MEASURED AND CLOSED (2026-09-09)

If the residual closure is immediately applied, no member is needed at all:
`rewriteExpr`'s `MonoCall (MonoClosure …) args` arm beta-reduces it, and a
let-bound residual used once in callee position is handled by `ForwardClosure`
in `rewriteLetChain`. A pass that sinks a residual to its unique application
site would remove the need for §5 on that subset.

**CLOSED: the population is ZERO.** §7's axis-2 census, over a full expression
tree walk, finds `appliedSameFn = 0` in BOTH arms (863 reshapes flag-off, 1,900
under `partialHof`). Not "small" — none. The prior was right for the right
reason: `beta` (1,722) and `betaForwards` (590) already take every
same-function case, so §6's incremental ground is empty by construction.

It is also structurally inapplicable to the motivating case: `andThen f ma` is
RETURNED as the enclosing function's value and the state is applied by the
CALLER. Sinking across that boundary is inlining the enclosing function, i.e.
arity raising — measured 2026-09-08 at **+76.6 % dispatch / +42.9 % wall** (§9).

**Do not revisit §6 without new evidence that `appliedSameFn` has become
non-zero.** It is a one-line read of the census.

## 7. P0 — the mandatory gate

**Measure how many declines are actually caused by a reshape having erased a
member.** The candidate population is already counted: `g1absentl = 1,439`
sites — an `l|` lambda member with NO instance in AbiCloning's index. Some
fraction of those are members whose sole instance the inliner reshaped or
inlined away.

Split `g1absentl` into:

  - **reshaped** — the member had exactly one instance at monomorphization and
    zero after inlining (this plan's population);
  - **pruned** — the instance was deleted entirely (DCE'd; nothing to stamp);
  - **other** — never had an instance.

Then weight the `reshaped` bucket dynamically, caller-attributed, on a
fixed-point binary.

### 7.1 The second axis — which mechanism, §5 or §6

The split above sizes the opportunity but does NOT choose between §5 and §6:
both target the same `reshaped` bucket. Add a second classification, over the
residual's USE SHAPE at the point the inliner rebuilds it:

  - **`appliedSameFn`** — the residual is applied inside the function that
    creates it. §6's population. Expect ~0: this is what `beta` (1,716) and
    `betaForwards` (590) already do, so anything here is a gap in those, not new
    ground.
  - **`returned`** — the residual IS the enclosing function's result, applied by
    a caller. **§6 cannot reach these**; only §5 (or a codegen fix) can. This is
    the IO-monad shape and is expected to dominate.
  - **`storedOrMulti`** — flows into a data structure, or has ≥2 application
    sites. Neither §5 nor §6 helps: §5's singleton rewrite is still sound but
    buys nothing if the value is not the callee of a stampable site, and ≥2 uses
    defeats sinking.

**Decision rule.** `appliedSameFn` large ⇒ fix the beta/forward gap instead;
this plan is unnecessary. `returned` large AND carrying dispatch ⇒ §5 is the
only candidate, proceed to §5's cost. Both small ⇒ close the plan; the residue
is noise and the weight is elsewhere (§8). **This arc has mispredicted weight from site counts five
times** (`foldrHelper` vs `Dict.foldl` inverted and 700x apart; `instanceQual`'s
10 sites carrying 81.7 M; the `p|` "upper bound" the result exceeded by 48 %;
`bodyMismatch` at 2x; the `partialHof` static counts that pointed the wrong way).
Do not open §5 on 1,439 as if it were a weight.

**Gate: proceed only if the `reshaped` bucket is both a majority of `g1absentl`
AND carries measurable dispatch.**

### 7.2 P0 RESULT (2026-09-09)

Instrumented at the clearing sites themselves, so `reshaped` is the set by
CONSTRUCTION (a DCE'd instance and a reshaped one are indistinguishable by
before/after counting). Census gated on `inline.report`.

| | flag-off | `ECO_INLINE_PARTIAL_HOF=1` |
|---|---:|---:|
| reshapes (all via `tryInlineCall`) | 863 | 1,900 |
| **`cleared` — reshape destroyed a member** | **863 (100 %)** | **1,900 (100 %)** |
| axis 2 — `returned` | **176** | **806** |
| axis 2 — `storedOrMulti` | 562 | 906 |
| axis 2 — `appliedSameFn` | **0** | **0** |
| located by the walk | 738 / 863 | 1,712 / 1,900 |

**Axis 1: every reshape destroys a member** — `cleared` equals `reshapesTotal`
exactly, in both arms. `betaReduce`'s partial branch never fires on this
workload; all reshapes come from `tryInlineCall`.

**Axis 2 decides both ways.** `appliedSameFn = 0` closes §6 (see there).
`returned` is §5's population and is the largest actionable bucket.
`storedOrMulti` is out of scope for both mechanisms.

**INSTRUMENT TRAP, paid twice.** (a) The first classifier inspected only tail
position and direct callee position; it reported `returned = 80` and
`storedOrMulti = 0`. The full tree walk gives 176 and 562 — the narrow version
missed the LARGEST bucket entirely and understated `returned` by 8.5x in the
flag-on arm. (b) Before that, two edits wiring the counters silently no-op'd (a
`replace` with no assert, and a script that died on a later assert after an
earlier successful replace), producing `reshapesTotal = 0` — which reads as "the
sites never fire" and would have closed this plan on a broken instrument. The
unconditional total counter is what caught it. **Assert every replace; add a
denominator counter whose zero is impossible if the instrument works.**

**Still UNWEIGHTED.** 176 sites is a site count, and this arc has inverted the
truth from site counts five times. §5 stays closed until the `returned` bucket
is weighted dynamically, caller-attributed, on a fixed-point binary.

### 7.3 DYNAMIC WEIGHT — §5 CLOSED (2026-09-09)

The `returned` bucket is the only population §5 could act on (§7.1). Weighted on
`eco-w8`, a verified bootstrap FIXED POINT — so the uid list from its own inline
report describes its own code — using `ECO_DISPATCH_STATS=1`, which attributes
by EVALUATOR POINTER. That is the right key: a stamp at the consuming site
converts exactly those indirect evaluator calls into direct ones.

| | |
|---|---:|
| total generic dispatch (`gen`) | 883,435,458 |
| **`returned` bucket** | **2,165,299** |
| **share** | **0.245 %** |
| residual uids matching a symbol | 97 / 176 |

One thin spike, then nothing: uid 39863 alone is 1,401,188 (65 % of the bucket),
the next four ~690 K, the rest trail into the hundreds. All the hot ones are
`System.TypeCheck.IO` residuals — but 2.2 M dispatches, not the hundreds of
millions the monad's own hosts carry.

**§5 IS CLOSED.** A mechanism needing a member-id supply threaded into
`MonoGraph`, a pre-inline instance index, and a type-level site rewrite (§5's
table) cannot be justified by 0.245 % — and that is an UPPER BOUND, since it
assumes every one of those dispatches would successfully stamp after the
rewrite.

**Caveat, stated rather than buried:** only 97 of 176 uids matched a symbol. The
other 79 either did not survive to codegen (inlined further, DCE'd) or are
emitted under a name the `_lambda_<uid>` pattern misses. Were they as hot as the
matched ones the bucket would still be under 0.5 %, so the verdict holds — but
2,165,299 is a floor with a known gap, not an exact figure.

Two facts about the instrument, for whoever reads this next: `fast = 0` across
the run (stamped fast dispatches need the `ECO_LSS_DISPATCH_SITE_COUNTERS`
lowering env), so `gen` is uncontaminated; and `sat == gen` exactly for every
residual in the bucket, meaning these closures are reached ONLY through the
generic funnel, never through the statically-known-arity path.

For proportion, from the same run:

| | dispatches | share |
|---|---:|---:|
| all generic (`gen`) | 883,435,458 | 100 % |
| over-application re-entry (census target #1) | ~92,000,000 | ~10 % |
| `partialHof` measured saving | 83,885,575 | 9.1 % |
| **§5's `returned` bucket** | **2,165,299** | **0.245 %** |

## 8. Honest go/no-go — the premise is partly refuted

The idea was prompted by the observation that inlined `System.TypeCheck.IO`
lambdas do not direct-dispatch. **Two measured facts cut against the premise:**

1. **Those lambdas' generic calls are not caused by lost identity.** The uprobe
   attributes to the ENCLOSING function; `System_TypeCheck_IO_lambda_40544` is
   the inlined `\s0 -> let (s1,a) = ma s0 in f a s1` body, and the generic calls
   are the same `ma s0` / `f a s1` that were inside `andThen` before. They are
   generic because `ma`/`f` are parameters whose sets are genuinely non-singleton
   unions — not because a member was cleared.
2. **Inlining currently INCREASES stamping.** With `ECO_INLINE_PARTIAL_HOF=1`
   (which forces the identity-clearing branch 515 times):

   | | off | on |
   |---|---:|---:|
   | `dispatchUpgraded` | 17,179 | **17,462** (+283) |
   | `stampedStaged` | 678 | 929 |
   | `stampedPapGlobal` | 2,133 | 2,295 |

   So at the aggregate the clearing is NOT costing stamps today. Whatever this
   plan can recover is a second-order residue, not the visible gap.

Against that, the honest positive: `partialHof` measured **−83,885,575 generic
dispatches (−9.14 %)**, and the single largest component was **−43.5 M (−40 %)
off `eco_apply_closure_eval`'s over-application re-entry**, NOT stamping. The
biggest available win in this neighbourhood is therefore the codegen fix for
over-application (`/work/direct-call-decline-census.md` §4 target #1), which
needs no set-flow work at all.

**Recommendation: do not build §5 until P0 shows a real `reshaped` population
with real weight, and until the over-application work is done or declined.**
Write the P0 census; it is one report line plus a join, and it either opens this
plan properly or closes it cheaply.

## 9. What NOT to do

- **Do not reuse the old member id on a reshaped closure.** §2 — it is caught by
  the layout guards in the common case and is a miscompile in the
  fence-off case. Fresh id or nothing.
- **Do not extend this to non-singleton members.** §4 — rewriting sites to name
  only the new instance narrows a set that still has other inhabitants.
- **Do not re-establish `srcLambda`.** Only `lssMember` is at issue; the
  residual really is not the source lambda, and wrapper-home logic depends on
  that being honest.
- **Do not revive `ECO_ARITY_RAISE` to carry this.** Measured 2026-09-08 on the
  current tree: +76.6 % dispatch, +42.9 % wall, because raising clears the same
  identity at 835 specs and collapses `singleton_fast` 13,045 -> 1. The raiser
  destroys far more stamping than this plan could restore.
