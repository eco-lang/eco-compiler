# Converting the IO monad's CALLERS to direct state-passing

Successor to `plans/io-monad-dispatch-reduction.md` (P1/P2/P3 shipped, −43.1 %
dispatch). That plan converted the union-find LEAVES; this one is about the
callers that sequence them, which is where the remaining cost lives.

Not to be confused with `plans/io-monad-refactoring.md` — that is the builder's
`System.IO` (HTTP/ports), SHELVED, unrelated.

**STATUS: PROPOSED. Nothing built. Step 0 is a census and must run first.**

---

## 1. The measured position

From `/work/direct-call-decline-census.md` (fully-optimized self-compile,
`eco-i35`, verified bootstrap fixed point; 933,032,776 generic dispatches):

| group | events | share |
|---|---:|---:|
| IO monad spine (`andThen`/`map`/`traverse`) | 370,949,194 | 39.8 % |
| Elm lambdas (mostly IO continuations) | 247,325,530 | 26.5 % |
| C++ kernel calling an Elm closure | 115,980,848 | 12.4 % |
| Runtime re-entry (over-application) | 111,208,149 | 11.9 % |
| Elm fold / collection callbacks | 61,403,717 | 6.6 % |
| Other Elm specs | 26,165,338 | 2.8 % |

`IO.andThen` alone is 234,751,320 (25.2 %); `IO.map` 99,010,065 (10.6 %).

## 2. Why the cost is in the callers, not the leaves

`IO a = State -> ( State, a )`, so every IO value is a function and binding one
means applying an unknown function to the state. Read out of the emitted MLIR
for `System_TypeCheck_IO_andThen_$_19506`:

```mlir
%0 = "eco.papExtend"(%arg1, %arg2) {_call_kind = "segmentation_unknown"}  ; ma s0     GENERIC
%3 = "eco.papExtend"(%arg0, %2)    {_call_kind = "singleton_fast", ...}   ; f a       STAMPED
%4 = "eco.papExtend"(%3, %1)       {_call_kind = "segmentation_unknown"}  ; (f a) s1  GENERIC
```

**The continuation `f` is already stamped.** What stays generic is `ma` — a
PARAMETER whose lambda set is the union of every IO action ever passed to that
spec, genuinely not a singleton — and the application of `f a`'s freshly minted
closure. Two generic dispatches per `andThen` EXECUTION, which is why the two
hot sites carry **26,361,474 each, identical to the digit**.

No increase in LSS precision reaches this. Only removing the bind does.

## 3. A correction to carry forward

An earlier note in this arc described `Solve.solveGo` as "half-converted". That
is wrong and the plan should not be built on it. Only its SIGNATURE is
eta-expanded:

```elm
solveGo : Env -> Int -> Pools -> State -> Constraint
       -> (IO State -> IO State) -> IO.State -> ( IO.State, State )
```

Its **body is still fully monadic** — `IO.andThen` chains throughout. So the
pattern is not yet proven anywhere on the hot path; what is proven is only that
the outer shape can be state-passing. The work is correspondingly larger.

## 4. The transformation

Every bind becomes a `let` destructuring:

```elm
-- from
typeToVariable rank pools tipe
    |> IO.andThen (\actual ->
        expectedToVariable rank pools expectation
            |> IO.andThen (\expected -> Unify.unify actual expected |> IO.andThen ...))

-- to
let
    ( s1, actual )   = typeToVariable rank pools tipe s0
    ( s2, expected ) = expectedToVariable rank pools expectation s1
    ( s3, answer )   = Unify.unify actual expected s2
in
```

### 4.1 The surface, measured

| module | `andThen` | `map` | `pure` | IO-returning sigs |
|---|---:|---:|---:|---:|
| `Compiler/Type/Solve` | 91 | 20 | 53 | 25 |
| `Compiler/Type/Constrain/Typed/Expression` | 83 | 42 | 27 | 46 |
| `Compiler/Type/Type` | 26 | 24 | 28 | 18 |
| `Compiler/Type/Constrain/Typed/Pattern` | 17 | 7 | 10 | 10 |
| `Compiler/Type/Constrain/Typed/Module` | 20 | 10 | 0 | 12 |
| `Compiler/Type/Occurs` | 6 | 0 | 9 | 2 |
| `Compiler/Type/Unify` | 8 | 5 | 5 | 4 |
| `Compiler/Type/Instantiate` | 1 | 4 | 7 | 2 |

After the 2026-09-08 module split (`Compiler.Type.Vars` + `Canonical` to
`ModuleName`), `System.TypeCheck.IO` has **20 importers, 12 of them monadic** —
down from 88. The surface above is now the whole of it.

## 5. Constraints, in order of how much they hurt if ignored

1. **Stack safety is load-bearing and non-obvious.**
   `plans/state-monad-stack-safety.md` exists because the JS build blows the
   stack; `Expression`/`Pattern`/`Module` were deliberately restructured onto a
   CPS DSL (`Constrain.Program`) for that reason, and `solveGo`'s `cont`
   parameter is the same defence. A `let`-chain is NOT automatically stack-safe
   where a CPS spine was required. **The conversion is therefore two different
   rewrites** — a flat one for non-recursive helpers, and a
   preserve-the-spine one for recursive drivers. Never apply the first to the
   second.
2. **The leaf work is done and adoption is near zero.** `freshS`/`reprS`/`getS`/
   `setS`/`modifyS`/`unionS`/`equivalentS`/`redundantQ` all exist;
   `UnionFind.get` and friends are four-line IO wrappers over them. Call sites
   still overwhelmingly use the wrappers (`UF.get` 48 vs `getS` 2). Convert the
   call site to the `S` form as you go, or you remove a bind and immediately pay
   a wrapper.
3. **The type alias is the escape hatch — use it.** `IO a` IS
   `State -> ( State, a )`, so a converted function still type-checks against
   unconverted callers. This can proceed function-by-function with the tree
   green throughout. No big-bang, no flag, no long-lived branch. (The
   2026-09-08 `Annotation.traverse` change is the worked example: three lines,
   no caller churn.)
4. **`State` is a 4-field record and every write copies it.** P4 of the
   predecessor — thread `Array PointCell` through the union-find core and
   rebuild `State` at the phase boundary — is ORTHOGONAL to bind removal and
   attacks allocation rather than dispatch. Do not mix the two in one change.

## 6. Sequencing

### Step 0 — attribute the 371 M to CALLING MODULES (MANDATORY GATE)

We know `IO.andThen` costs 234.8 M in total. We do **not** know how that splits
across the 12 monadic modules, because the census attributes to the `andThen`
SPEC, not to whoever called it. Without that, choosing `Solve` over
`Expression` is a guess — and this arc has mispredicted weight from static
counts four times (`foldrHelper` vs `Dict.foldl`, 700× apart and inverted;
`instanceQual`'s 10 sites carrying 81.7 M; the `p|` "upper bound" that the
result exceeded by 48 %).

Method: the `andThen` specs are monomorphized per call-site type, so a
caller-attributed uprobe census keyed by the RETURN ADDRESS inside each
`andThen_$_N` already distinguishes them; map each spec back to the module that
instantiated it via the registry's `reverseMapping`. One profiled run on a
fixed-point binary, plus a join. Cheap.

**Gate: proceed only if one or two modules carry the majority. If it is spread
evenly across 12, this plan is a large refactor for diffuse single-digit
millions each and should be closed unbuilt.**

### Step 1 — `Occurs`, `Instantiate`, `Unify` (15 binds total)

No CPS spine, small, and they sit under the hot path. Proves the pattern
end-to-end on real code and yields a MEASURED per-bind saving to price the rest.

### Step 2 — `Solve`'s non-recursive helpers

`typeToVariable`, `expectedToVariable`, `patternExpectationToVariable`,
`introduce`, `adjustRank`, `adjustRankContent`, `generalize`, `isGeneric`,
`poolToRankTable`. Leaves of the hot path; still no CPS involvement. Switch
their `UF.*` calls to the `S` forms in the same edit (constraint 2).

### Step 3 — `solveGo` itself

The largest single win and the CPS spine. Needs the stack-safety argument
re-made against the JS build, not assumed — the `cont` composition must survive
the rewrite. Do not start this until Steps 1–2 have a measured number.

### Excluded for now

`Expression` (83 binds), `Pattern` (17), `Module` (20) sit on the
`Constrain.Program` DSL that exists specifically to keep the JS build alive.
They are the largest static surface and the worst risk/reward until Step 0 says
otherwise.

## 7. Gates (every step)

| gate | requirement |
|---|---|
| unit | `elm-tests` at the 13,455 / 12 baseline |
| E2E | `--target full` 1,720 / 1,720 |
| bootstrap | the rebuilt compiler reproduces its own input (`cmp`) |
| artifact | canonical MLIR diff, renumbering-normalised (`memory: eco-artifact-canonical-diff`) — every hunk attributable to the converted functions |
| dispatch | caller-attributed uprobe A/B on identical input; report the DELTA, never a wall figure — the probe taxes every dispatch |
| wall | `benchmarks/lss-opt.md` protocol, one cold run per arm, census flags OFF; under 3 % is FLAT and is written "no regression detected" |

## 8. The honest go/no-go

**This plan is NOT my recommended next move, and it should not be built before
the alternative is priced.**

Against it: `/work/direct-call-decline-census.md` §4 ranks **over-application
re-entry at 92.0 M (9.9 %)** — 91,978,380 dispatches inside a single runtime
function (`RuntimeExports.cpp:2240`, where an over-applied call saturates then
re-enters with the remaining arguments). The static signal already exists
(`arityOver`, which LSS_039 already peels), and the fix is codegen: emit the
saturating call and the residual application as two ops instead of routing both
through the runtime. One function, no correctness-critical refactor.

By contrast this plan rewrites the typechecker's three largest modules — the
most correctness-critical code in the compiler — for a win the compiler could
instead obtain generically by inlining `andThen` at the call site or
devirtualizing the continuation, which would benefit every monadic user rather
than this one.

**Proceed only if Step 0 concentrates the weight AND the over-application work
is done or declined.**

## 9. What NOT to do

- **Do not split `State` into several monads.** Its four fields
  (`ioRefsPoint`, `ioRefsMVector`, `names`, `nodeIds`) have near-disjoint users,
  which looks like an invitation, but any function needing two would then need a
  product or a stack — more machinery for the same binds. `names` is the
  cautionary case: the module doc records it WAS a separate `StateT NameState`
  layer and was deliberately folded in. Splitting monads also removes no
  `andThen`: the same two dispatches per bind, in four monads instead of one.
- **Do not restructure the typechecker around a new DSL.** The predecessor's §5
  said this and it still holds: `Constrain.Program` was added for a real reason
  (JS stack) and this plan is about not paying monadic overhead for array
  indexing, nothing more.
- **Do not read the census's 39.8 % as an LSS opportunity.** The stamp is
  already firing on the half of `andThen` that can be resolved. The other two
  applications are what the representation costs.
