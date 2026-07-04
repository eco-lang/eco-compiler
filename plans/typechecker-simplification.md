# Typechecker Simplification Plan

Reduce the complexity and improve the readability of the eco constraint-based typechecker
**without touching the two properties that justify its current shape**: the mutable
`Array`-backed union-find speed and the `IO.loop` constant-stack safety.

Scope is the typechecker proper: constraint generation (`Constrain/**`), solving (`Solve`),
unification (`Unify`), and the `IO`/`State`/name-generation plumbing. **PostSolve, SolverRoots,
and SolverSnapshot are out of scope** for this pass.

## Guiding principle: essential vs. incidental complexity

Almost none of the readability cost is the speed/safety machinery. The two are barely coupled,
so the wins below are achievable with the hot path (union-find `Array` IO + `IO.loop`
trampoline) left untouched.

**Essential — keep untouched:** mutable `Array` union-find `IO`/`IORef`; the `IO.loop`/`Step`
trampoline (the *real* stack-safety driver); the freer-monad "continuation-in-leaf" encoding
(forced by Elm having no existentials/GADTs); the `Unify` `Result`-in-IO monad; the super-type
lattice, occurs check, extensible-record row unification; rank + `vars`-accumulator threading;
`Data.Map` where keys are genuinely non-comparable (`PostSolve` located fields — out of scope).

**Incidental — remove:** the dead reified `Frame` continuation stack; the `StateT NameState`
layer (one client); `Data.Map` on the union-find `Record1` where key==comparable==`String`;
five `Unify` sites that drop out of the monad into hand-threaded `Result`; the duplicate `Prog`
vs `ProgS` DSLs; and the whole second copy of the constraint generator (`Erased/**` vs
`Typed/**`).

## Related plans (avoid conflict / reuse context)

- `state-monad-stack-safety.md` — introduced the `Prog`/`ProgS` DSL this plan cleans up.
- `typecheck-io-stack-safety.md` — the `IO.loop`/`Step` conversions this plan relies on.
- `eliminate-unnecessary-data-map-dict.md` — broader `Data.Map`→`Dict` sweep; **Step 3 here is
  the typechecker-`Record1` subset** of that plan.
- `type-all-exprs-group-ab.md`, `fix-constrainWithIds-structural-differences.md` — the Group A/B
  split and Erased/Typed constraint parity that **Step 6** consolidates into one generator.

---

## Execution order (low risk → med risk)

Implement one step at a time. After **each** step: rebuild + run `elm-tests`, then run the E2E
suite (`--target full`). A step is complete only when both are green. See **Test protocol**.

| Order | Step | Risk | Touches hot path? | Prereq |
|------:|------|------|-------------------|--------|
| 1 | **S1** Delete the dead `Frame` continuation stack | ~none | no | — |
| 2 | **S2** Fold `NameState` into `IO.State`; delete `Strict.elm` | low | no | — |
| 3 | **S3** `Record1` → elm/core `Dict Name`; delete 6 conversions | low | no | — |
| 4 | **S4** Add `forEach_`/`zipWithM_`/`try`; route 5 raw `Unify` sites | low | no | — |
| 5 | **S5** Unify `Prog` into `ProgS ()`; delete `Erased/Program.elm` | low | no | — |
| 6 | **S7** Close the Erased `let`-chain construction-time overflow | low | no | — |
| 7 | **S6** Merge Erased+Typed generators via an `Observer` | med | no | S5, S7 |

Note the deliberate re-ordering: **S6 (the big merge) runs last** because it is the only
medium-risk step; **S7 runs just before it** so the deferred-`let` structure is already in place
when the generators merge (S6 preserves it), and **S5 runs before both** because the unified
generator is built on `ProgS s`.

---

## S1 — Delete the dead `Frame` continuation stack

**Finding.** In both `Erased/Program.elm` and `Typed/Program.elm`, the `List Frame` "explicit
continuation stack" in `run`/`step`/`stepInstr` is **never pushed to** — it is seeded `[]`
(`Erased/Program.elm:182`), threaded unchanged in every `stepInstr` branch
(`:220,224,228`), and only ever *popped* in the unreachable `Done value -> k :: rest` branch
(`:206-207`). It is provably always `[]`. Real stack-safety comes from `IO.loop` + deferred
leaf continuations, not this stack. The `Typed` twin is identical (`Typed/Program.elm:207-257`).

**Change.**
- `Erased/Program.elm`: collapse `run prog0 = IO.loop step ( prog0, [] )` to `IO.loop step prog0`;
  `step` loses the tuple and the `stack` param — `Done v -> IO.pure (IO.Done v)`,
  `Step i -> stepInstr i`; `stepInstr` loses its `stack` param and returns
  `IO.Loop nextProg`. Delete `type alias Frame` (`:188-189`).
- `Typed/Program.elm`: same for `runS`/`stepS`/`stepInstrS`, keeping the `s` state thread.
  Delete `FrameS`.
- Fix the module docstrings that claim an "explicit continuation stack" — it is `IO.loop` that
  provides safety.

**Risk:** ~none — deleting provably-dead code; no behavior change. **Verify:** `elm-tests`
green (esp. the deep-nesting cases), E2E green.

---

## S2 — Fold `NameState` into `IO.State`; delete `Control/Monad/State/TypeCheck/Strict.elm`

**Finding.** `Strict.elm` is a generic `StateT` instantiated at exactly one type (`NameState`)
and imported by exactly one client (`Type.elm`). The first naming pass (`getVarNames`) already
runs in plain `IO`; only the second pass is lifted into `StateT`, so the transformer buys
nothing structural — ~90 `State.*`/`liftIO` sites are pure noise on every union-find touch.

**Change.**
- Add a `names : NameState` field to `IO.State` (`System/TypeCheck/IO.elm:133-138`); move
  `NameState`/`NameStateData` into `IO.elm` (it already owns `Descriptor`/`Content`/etc.).
- Add `IO.getNames`, `IO.withFreshNames : NameState -> IO a -> IO a` (save current `names`,
  seed, run, **restore** — this makes re-entrancy safe, e.g. `Unify.unify` calling
  `Type.toErrorType` mid-solve).
- In `Type.elm`: `getFreshVarName : IO Name`; `variableToCanType`/`variableToErrorType`/
  `termToCanType`/`termToErrorType` become plain `IO`; delete every `liftIO`, and rewrite
  `State.andThen/map/pure/apply/traverseList/traverseTuple/traverseMap` to the `IO.` forms.
- Replace `runStateT`/`evalStateT` at the entry points (`Type.elm:432,464,636`) with
  `IO.withFreshNames`. `toCanTypeBatch` keeps its "unique across the batch" guarantee by seeding
  once and never resetting mid-batch (identical to today).
- Delete `Strict.elm` and its import.

**Risk:** low — the one hazard is name-uniqueness scoping, mitigated by save/restore
`withFreshNames`. **Verify:** `elm-tests` (annotation/error-message rendering exercises naming);
E2E. Watch for any `Debug.log`/error output whose type-variable names changed.

**Bonus:** this deletes the duplicated `traverseListSTHelp`/`traverseMapSTHelp` trampolines in
`Strict.elm` for free.

---

## S3 — `Record1` on elm/core `Dict Name`; delete the 6 conversion sites

**Finding.** The union-find `FlatType.Record1` stores fields as
`Data.Map.Dict String String Variable` (`IO.elm:487`) where key==comparable==`String`, so the
3-param wrapper is `Dict` + a tuple alloc + a discarded `compare`. It only forces conversion glue
at the boundary with the Canonical AST (`Can.TRecord (Dict Name …)`).

**Change.**
- `System/TypeCheck/IO.elm:487`: `Record1 (Dict Name Variable) Variable` using elm/core `Dict`.
- Update the `Record1` readers/writers: `Unify.elm` (record unification, `~825-912`, incl. the
  hand-rolled `traverseMaybe`), `Solve.elm:839,964,1174`, `Occurs.elm` (record field iteration),
  `Type.elm:585,769,991`.
- Delete the conversions: `Type.elm:585` (`Data.Map.toList compare >> Dict.fromList`),
  `Type.elm:769`, `Type.elm:991` (`Data.Map.values compare` → `Dict.values`),
  `Solve.elm:839,964` (`Data.Map.fromList identity (Dict.toList …)` → pass through),
  `Solve.elm:1174`.

**Risk:** low but **broad** (touches Unify/Solve/Occurs/Type/IO). Mechanical. **Verify:**
record-heavy `elm-tests` (records, extensible records, updates, accessors) + E2E.

**Note:** typechecker-scoped subset of `eliminate-unnecessary-data-map-dict.md`. Do **not** touch
`PostSolve`'s `A.Located Name`-keyed `Data.Map` (out of scope; genuinely non-comparable key).

---

## S4 — Add `forEach_`/`zipWithM_`/`try` to `Unify`; route the 5 raw sites

**Finding.** `Unify` recurses on *type-structure* depth (low tens) → needs no trampoline. The
`Result`-in-IO monad already short-circuits and reads fine *when used*; the verbosity is 5 sites
that bypass it into raw `Unify (\vars -> … case result of Ok…|Err…)` with hand-threaded `vars`:
`unifyArgs` (`Unify.elm:784-818`), the near-duplicate `unifyAliasArgs` (`:635-672`), `unifyField`
(`:915-931`), and the App1/Alias/Record drop-downs (`:708-722, 609-623, 750-763`). The
comparable-tuple bug (already fixed at `:541`) was a symptom of hand-sequencing inside a fold.

**Change.** Add three combinators once (built on the existing monad; optionally on `IO.loop`
for width safety):
- `forEach_ : List a -> (a -> Unify ()) -> Unify ()` — element-wise, short-circuit.
- `zipWithM_ : (a -> b -> Unify ()) -> List a -> List b -> Unify ()` — pairwise, `mismatch` on
  length difference.
- `try : Unify () -> Unify Bool` — run-and-recover, **preserving the `vars` accumulator on the
  error path** (the "run-all-then-report" discipline used by args + record fields).

Rewrite the comparable-tuple case, `subUnifyTuple`, App1/Alias args (deleting `unifyArgs` +
`unifyAliasArgs`), and `unifyField` through these. **Preserve the two existing error disciplines
exactly** (short-circuit for tuples; run-all-then-report for args/records — the latter must keep
returning collected `vars` on `Err`). Pin the discipline with a test before refactoring.

**Risk:** low, but the `vars`-on-error semantics are subtle — cover with tests first. **Verify:**
`elm-tests` (unification-error cases incl. the tuple-comparable tests added earlier) + E2E.

---

## S5 — Unify `Prog` into `ProgS ()`; delete `Erased/Program.elm`

**Finding.** `Prog a` is exactly `ProgS () a` minus `GetStateS`/`ModifyStateS`. The two DSL
modules are near-identical.

**Change.** Keep only `ProgS s a` (rename to a single `Prog s a` module, or reuse
`Typed/Program.elm`). Point `Erased/Expression.elm`/`Pattern.elm`/`Module.elm` at it, running in
`ProgS ()` — they simply never call `opGetS`/`opModifyS`. Delete `Erased/Program.elm` (~228
lines). `andThen`/`map`/`run`/smart constructors specialize to `s = ()` for free.

**Risk:** low — mechanical monad substitution. **Verify:** `elm-tests` + E2E. Groundwork for S6.

---

## S7 — Close the Erased `let`-chain construction-time overflow (latent bug)

**Finding (latent bug).** In the Erased generator, `Can.Let`/`LetRec`/`LetDestruct` do
`constrainProg rtv body expected |> Prog.andThen (constrainDefProg rtv def)`
(`Erased/Expression.elm:151-161`). The subject `constrainProg rtv body` is evaluated eagerly in
`andThen`'s subject position (not a tail call), so **building the `Prog` recurses one JS frame
per `let` nesting level** and a deep right-nested `let`-chain (or wide `let` block →
nested `Can.Let`) overflows *at construction time*, before the trampoline runs. The Typed path is
already safe (its Group-A handler defers `body` inside a `\() -> …` continuation,
`Typed/Expression.elm:749-775`).

**Change.** Restructure the Erased `Let`/`LetRec`/`LetDestruct` arms to place the `body`
recursion **inside a continuation** (mirror the Typed Group-A shape), so descent is deferred and
driven one level per `IO.loop` iteration. Add a **regression test**: a synthetically deep
`let a = … in let b = … in … leaf` chain (e.g. depth 5–10k via `SourceBuilder`) that overflows
the current Erased path and passes after the fix (assert type-checks with no error/crash).

**Risk:** low, targeted. **Verify:** the new deep-`let` test + full `elm-tests` + E2E. S6 later
preserves the deferred structure in the merged generator.

---

## S6 — Merge the Erased + Typed generators via an `Observer` (the big one)

**Finding.** `Typed/*` = `Erased/*` + "record this node's var alongside." The extra Typed vars
are fresh, existential, and unified straight to `expected`, so they are **semantically inert** —
which is exactly why both paths type-check identically. `Typed/Expression.elm` also carries a
*second, largely dead* copy of the arms (`constrainNodeWithIdsProg` + the four
`…NodeWithIdsProg` + `constrainGenericWithIdsProg`, `~859-969, 1066, 1243, 1413, 1604`). Total
merge-able surface ≈ 5,400 lines; the two paths have **already drifted** (record-update errors
report at the outer `region` in Erased, `Erased/Expression.elm:745,754`, vs `fieldRegion` in
Typed, `Typed/Expression.elm:1812,1823` — different error span per backend).

**Change.** One generator over `ProgS s`, parameterized by a 5-field `Observer s`:
```
type alias Observer s =
    { recordNatural : Int -> IO.Variable -> ProgS s ()
    , observeSynthetic :
        Int -> A.Region -> E.Category -> E.Expected Type
        -> (E.Expected Type -> ProgS s Constraint) -> ProgS s Constraint
    , observePatternVar : Int -> A.Region -> E.PCategory -> E.PExpected Type -> State -> ProgS s State
    , recordPatternFromExpectation : Int -> E.PExpected Type -> ProgS s ()
    , recordSchemeBinders : Name -> Dict Name IO.Variable -> ProgS s ()
    }
```
- `erasedObserver : Observer ()` — **pass-through**: `observeSynthetic _ _ _ exp body = body exp`,
  everything else `pureS ()` / no-op. No synthetic var, no extra `CEqual`/`CPattern`, no `Array`.
- `typedObserver : Observer NodeIdState` — the recording behavior from today's Typed path
  (Group A `recordNatural`; Group B `observeSynthetic` = allocate synthetic var + record + reroute
  `body` through it + wrap in `∃v. CAnd [con, CEqual region cat (VarN v) expected]`).
- Entry points: Erased runs `runS () (…generatorG erasedObserver…) |> IO.map Tuple.first`; Typed
  runs `runS nodeIdState (…generatorG typedObserver…)`. Delete `Erased/{Expression,Pattern,Module}.elm`.
- Same treatment for `Pattern` (observer wraps each step; pass-through ⇒ single `CPattern`,
  exactly the Erased `addProg`) and `Module`.

**Reject** "always run Typed, ignore the table" — it changes every JS-backend constraint tree
(extra inert vars, shifted numbering) and adds solver work; violates byte-identity + the
no-slow-the-JS-path constraint. **Reject** deleting the Typed Group A/B logic — it is essential,
not duplication; only the *tree-walk* deduplicates.

**Correctness gate — byte-identical Erased output.** Because `erasedObserver` allocates nothing
and reorders nothing, `Type.mkFlexVar` is called in the same order/count ⇒ identical variable ids
⇒ identical constraint bytes. **Add a golden-constraint diff test** comparing merged-Erased
against a captured snapshot of current-Erased constraints over a corpus, and keep the existing
`TypedErasedCheckingParity` suite green.

**Migration.** Arm-by-arm behind the golden diff: natural-var arms first (trivially identical),
then synthetic wrappers, then patterns, then delete the dead `…NodeWithIdsProg` layer and the
Erased modules last. This also **fixes the record-update region drift** (pick one region).

**Impact.** ~6,282 → ~3,100 constraint-gen lines (~50%), 9 files → 6, ~4 dead functions gone.

**Risk:** med — broad and correctness-sensitive. Mitigated by the golden-constraint diff + parity
suite + arm-by-arm landing with `elm-tests`/E2E after each sub-arm if needed. **Verify:** golden
diff + `TypedErasedCheckingParity` + full `elm-tests` + E2E.

---

## Test protocol (after every step)

Per `CLAUDE.md`, run each suite **once**, tee to a temp file, and inspect with grep/head/tail —
do not re-run to see different output.

1. Unit / integration: `cmake --build build --target elm-tests 2>&1 | tee /tmp/s<N>_elmtests.txt`
   → require `Failed: 0`.
2. E2E: `cmake --build build --target full 2>&1 | tee /tmp/s<N>_e2e.txt` → require
   `Result: PASSED`. Use `full` (not `check`): these are Elm/front-end changes that regenerate
   MLIR, so `check` risks stale `.mlir`.

A step is **done** only when both are green. If a step regresses, fix within that step before
proceeding (do not stack steps on a red tree).

Stress (`--target stress`) and the full bootstrap (`bootstrap` + gates) are **not** required
per-step; run them once at the end as a final gate.

## Success criteria (the /goal)

1. S1–S7 all implemented (in the order above).
2. `elm-tests`: `Failed: 0` after each step and at the end.
3. E2E `--target full`: `Result: PASSED` after each step and at the end.
4. No change to the union-find `Array` IO or the `IO.loop` trampoline (the speed/safety core).
5. Net effect: ~3,000+ lines and one whole monad module removed; the dead `Frame` stack gone;
   the Erased `let` construction overflow and the record-update region drift both closed.

## Out of scope (this pass)

Step 8 "optional bets" from the review: replacing the DSL with plain direct recursion + spine
loops (Design B), the explicit-worklist rewrite (Design C), collapsing record-wrappers to bare
aliases, and adding `traverseArray` combinators. Revisit after S1–S7 land green.
