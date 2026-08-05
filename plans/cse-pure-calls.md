# CSE over pure calls — common subexpression elimination at the Mono level

**Status: NEW 2026-08-05, UNSIZED. Census (C1) before anything else.**

**Provenance:** `plans/opt-tier2-cons-fusion.md` §5 U-T2.5′, surfaced while
classifying the comparable-key work. That plan is now closed; this is one of
its two live descendants.

> **CATEGORY B — this adds a compiler pass, so it makes every program eco
> compiles faster, not just the compiler.** It is the only descendant of the
> tier-2 backlog whose win mechanism is *deleting executed work* rather than
> *reshaping allocation* — which, per `plans/live-heap-composition-census.md`
> §0, is the only mechanism this codebase has ever measured moving wall.

---

## 0. The claim, and the prior that makes it credible

Elm is pure and strict. Two evaluations of the same function applied to the
same arguments produce the same value, and neither can be observed to have
happened twice. Eliminating the second is therefore **unconditionally sound**
— modulo three carve-outs (§2) that are all statically decidable.

There is currently **no Elm-level CSE anywhere in the pipeline.**
`compiler/src/Compiler/GlobalOpt/` contains `AbiCloning`, `Borrow`,
`CafCensus`, `CafDedupe`, `CafHoist`, `ListCombinators`,
`MonoGlobalOptimize`, `MonoInlineSimplify`, `MonoReturnArity` and `Staging`
— none of them eliminate redundant computation. The only CSE in the pipeline
is LLVM's, which runs *downstream of every boxing, closure and layout
decision*, so by the time it can see two identical expressions they are two
identical **allocation sequences** it is not permitted to merge.

**The prior — and this series has not had one this good before.** K6
(`plans/mono-comparable-key-optimization.md` §14-15) is, structurally,
*dynamic CSE over type construction*: a hash-cons table that returns the
existing object instead of rebuilding it. It was hand-implemented at five
smart constructors and measured **solver −5.07% wall / −7.04% promotion /
−13.2% RSS / majors 13→10**, with subst −2.17%. Its motivating census (§13)
found **99.2% of type construction was duplicate work** — 14.8M
constructions for 116K distinct results.

A static CSE pass is the compile-time generalization of exactly that
insight, applied to every program rather than to five hand-picked
constructors. That is the case for building it. It is not proof that the
duplicate-work rate generalizes beyond `MonoType` construction — hence C1.

## 1. The motivating idiom

Probe-then-insert, pervasive and idiomatic:

```elm
if Set.member (f x) s then ... else Set.insert (f x) s
```

`f x` is built twice — the whole call tree, every allocation inside it, both
times. The same shape appears as `Dict.get k d` followed by `Dict.insert k
(g (Dict.get k d)) d`, as repeated `List.length xs` in a guard chain, and as
any accessor chain recomputed across branches of a `case`.

This compiler's own `Data.Map`/`Data.Set` API makes the idiom *worse* than
in stock Elm, because the key-derivation function is applied on every
operation (`compiler/src/Data/Map.elm:110`) — which is precisely the defect
K1 hand-fixed at two call sites with `memberKeyed`/`insertKeyed`. A CSE pass
would have subsumed that hand-fix; that it did not exist is why the hand-fix
was needed.

## 2. Soundness — the three carve-outs

Purity gives the transform for free. What it does not give:

1. **`Debug.log` / `Debug.crash` ordering.** Merging two calls that
   transitively log changes how many lines appear and in what order.
   `plans/opt-tier2-cons-fusion.md` U-T2.4′ already recorded that this
   policy is *owed* and never written. **Write it here, as an invariant note,
   before the first merge lands** — both fusion and CSE need the same
   statement, and CSE gets there first.
2. **⊥ selection.** If two occurrences would both diverge or crash, merging
   picks one of them as *the* ⊥. Under `--optimize` this is acceptable (the
   same latitude fusion would take), but the crash *message* can change, and
   the E2E suite asserts on crash text in places. Check before assuming.
3. **Effectful kernels.** Not every `MonoVarKernel` is pure —
   `Task`/`IO`/port/scheduler primitives are not. CSE needs an explicit
   **purity classification of kernel names**, defaulting to *impure* for
   anything unlisted. The `defaultWhitelist` machinery in
   `MonoInlineSimplify.elm:951` is the model for how such a list is
   maintained and where it lives.

`MonoCall` carries a `CallInfo` and a `Region`; equality for CSE purposes
must ignore `Region` (source position) and compare callee + args + result
type. Note `MonoVarGlobal Region SpecId MonoType` — the `SpecId` is the
identity that matters.

## 3. THE RISK THAT INVERTS THE NAIVE COST MODEL

**CSE extends live ranges by construction.** It converts two short-lived
computations into one value that must stay live from the first use to the
last. Under the retention finding (`live-heap-composition-census.md` §0),
that is the exact cost the collector *does* charge for — while the
allocation it saves is the cost the collector *does not* charge for.

So a naive whole-definition CSE can be **wall-negative while looking like a
clear win on every allocation counter**. This is not hypothetical: it is the
same trap that made chunked lists (−47.5% Cons) wall-neutral and made K6
(+0.02% objects) a −5% win, read from the other direction.

**Design consequence, load-bearing:**

> **Design rule C-R1: prefer near CSE to far CSE.** Bound the distance
> between the first and last use of a merged value. A merge inside one
> expression or one `case` branch is nearly free; a merge that spans a whole
> definition body creates a long live range and must justify itself against
> LH1's survival rate for the classes involved. Start with the tightest
> scope that captures the probe-then-insert idiom and widen only on measured
> evidence.

The corollary is that C1's census must count **redundancy at bounded
distance**, not redundancy in general. A census that reports "40% of calls
are textually repeated somewhere in their definition" would be measuring the
wrong thing and would over-promise, exactly as four previous static censuses
in this series did.

## 4. Units

### C1 — the census (do first; decides everything)

Count repeated pure-call subexpressions per definition on the self-compile
corpus **and at least one user workload** (the tier-2 lesson: self-compile
is simultaneously product and corpus, and a hot site in it is ambiguous —
see `mono-comparable-key-optimization.md` §0).

Report, bucketed by **syntactic distance** between occurrences (same
expression / same branch / same `let` chain / whole definition):

- count of duplicate pure-call subexpressions,
- estimated deleted work: sum over duplicates of the callee's body size
  (`MonoInlineSimplify` already has a size metric for its threshold),
- how many duplicates are `Set.member`/`Dict.get`-shaped probe-then-insert.

Implement as an `ECO_CSE_REPORT=1` output-only flag in
`compiler/src/Compiler/Eco/Config.elm` — **excluded from the artifact hash**,
following `mono.validate` / `borrowCensus0` (`Config.elm:110-111`).

### D-C — the gate

Proceed to C2 iff the census shows a duplicate-call population that is both
**≥2% of evaluated calls at bounded distance** and concentrated enough that
a bounded-scope pass captures most of it. Record the table either way.

**Set expectations honestly:** the tier pattern is ×4 — static censuses of
this shape have collapsed at the admissibility gate four consecutive times
(`eco-opt-tier-roadmap` memory; tier-1 T1.3.7/T1.3.8/T1.3.9). Expect that
outcome and let the data overturn it. The K6 prior is the one reason to
think this case differs, and K6's duplicate rate was measured on a single
data type, not on general expressions.

### C2 — bounded-scope CSE

A new GlobalOpt phase. `globalOptimizeWithStats`
(`MonoGlobalOptimize.elm:128`) currently runs six phases; CSE slots
**before** phase 5 (call-staging annotation) so the annotator sees the final
let structure, and **after** inlining, because inlining is what makes
duplicates syntactically visible in the first place.

Mechanics: bottom-up walk over `MonoExpr`, hashing pure subexpressions to a
canonical key (callee `SpecId` + arg keys + result `MonoType`), binding the
first occurrence to a fresh `MonoLet` at the tightest dominating scope, and
replacing later occurrences with `MonoVarLocal`.

### C3 — the `Debug.*` / ⊥ policy note

An entry in `design_docs/invariants.csv` stating the ordering and
⊥-selection latitude taken under `--optimize`. Owed by U-T2.4′ and now owed
by C2. Cheap; do it with C2, not after.

### C4 — widening (only on C2's measured result)

Candidates in decreasing confidence: across `case` branches with a common
prefix; record-accessor chains; partial redundancy (a value computed on some
paths only). Each needs its own measurement — do not batch them.

## 5. Gates

- **Output byte-identity HOLDS and is the primary gate.** Unlike K4 (which
  reordered keys and forfeited it), CSE is semantically transparent: the
  compiler computes the same thing faster, so the `.mlir` it *emits* for a
  fixed input must be byte-identical under both engines. The MLIR of the
  compiler *itself* changes — that is the point. Losing emitted-output
  identity means a soundness bug, not an intended reordering.
- Bootstrap `cmake --build build --target bootstrap`, **both** fixed points
  (Stage 4b JS, Stage 8c native).
- Full E2E once, teed, then grep — never re-run.
- elm-tests (12 known pre-existing typechecker-gate failures).
- **`elm-aws-codegen` canary, mandatory.** C2 adds `MonoLet` bindings, and
  GlobalOpt phase 5 `annotateCallStaging` is **O(2^let-in-bound-depth)**
  (`plans/annotate-call-staging-metadata.md`; the elm-aws-codegen "hang").
  A CSE pass that deepens let chains is the single most likely trigger this
  exponential has ever had. Measure it every run.
- Body-copying or rebinding rewrites need `freshenLetBoundNames` — duplicate
  internal let names on one SSA id produce "does not dominate" crashes.
- Wall always recorded with its major count; benchmark per
  `benchmarks/tier2-opt.md` methodology (cold-cache Stage 7a, constant
  config, `rm -rf eco-stuff` between legs, warmup leg first).
- If LH1 has landed, record the promotion delta too — per §3 it is the
  metric that can go the wrong way.

## 6. Explicitly out of scope

- Loop-invariant code motion (hoisting out of `MonoTailCall` loops) — same
  live-range risk, larger, separate.
- Memoizing across *definitions* — that is CAF territory, already shipped
  (`eco-caf-memoization-survey`), and its lesson was that construction is
  the fast path and hoisting lost.
- Anything that requires the borrow oracle at compile time (tier-1 design
  rule T1-R1: the analysis costs ~15% of Stage-7a wall).
