# Plan: Short-Circuit `&&` / `||` by Lowering to `If` in TypedOptimized

## Problem Summary

The infix operators `&&` and `||` in Elm source are currently lowered by
`Compiler.LocalOpt.Typed.Expression` to a strict `Call` on `Basics.and` /
`Basics.or`. After monomorphization, MLIR codegen selects the strict boolean
intrinsics `eco.bool.and` / `eco.bool.or` (see
`Compiler/Generate/MLIR/Intrinsics.elm:408-412`), which evaluate *both*
operands unconditionally.

Reproducers in `/work/test/elm/src/`:

- `BoolShortCircuitTest.elm` — `False && shouldNotRun ()` / `True || shouldNotRun ()`
  where `shouldNotRun` overflows the stack via non-tail recursion.
- `BoolShortCircuitParserIdiomTest.elm` — `idx < length && unsafeIndex src idx /= '\u{0000}'`
  where `unsafeIndex` segfaults when out of bounds.

Both tests SIGSEGV / overflow on the native backend because the RHS is always
evaluated. The JS backend already passes (JS `&&` / `||` short-circuit).

## Goal

Encode short-circuit semantics for `&&` / `||` *once*, in the shared
TypedOptimized IR, by rewriting the source `Binop` form to a
`TOpt.If` expression. Every downstream backend (MLIR, JS, any future
backend) inherits correct evaluation order from the existing `If` codegen
path.

Strict `Basics.and` / `Basics.or` calls (from first-class uses like
`List.foldl (&&) True xs`) retain their current strict lowering — the
intrinsics remain valid for those callers.

## Invariants to Preserve

- **TOPT_001** — every `TOpt.Expr` carries a `Meta` (`{ tipe, tvar }`).
  New `If` nodes and their injected `Bool` literals must attach consistent
  Bool `tipe` and a sensible `tvar`.
- **TOPT_004** — type preservation. The rewritten `If` must be typed
  identically to the original `Binop` (always `Bool`).
- **CGEN_*** / **HEAP_*** — unchanged; no runtime or codegen layout change.
- No change to the strict boolean intrinsics (`eco.bool.and` / `eco.bool.or`)
  or their `[Pure, Commutative]` traits.

## Where the Fix Lives

File: `compiler/src/Compiler/LocalOpt/Typed/Expression.elm`

Current Binop arm (`optimizeExpr`, lines 418-436):

```elm
Can.Binop _ binopHome name (Can.Forall _ funcType) left right ->
    let
        optimizeArg =
            optimize kernelEnv annotations exprTypes exprVars home cycle
                << TCanBuild.toTypedExpr exprTypes exprVars
    in
    Names.registerGlobal region binopHome name funcType Nothing
        |> Names.andThen
            (\optFunc ->
                optimizeArg left
                    |> Names.andThen
                        (\optLeft ->
                            optimizeArg right
                                |> Names.map
                                    (\optRight ->
                                        TOpt.Call region optFunc
                                            [ optLeft, optRight ]
                                            { tipe = tipe, tvar = tvar }
                                    )
                        )
            )
```

The enclosing function already has `region`, `tipe`, and `tvar` in scope
(from `optimizeExpr` at line 338). The `Binop` constructor carries
`binopHome : IO.Canonical` and `name : Name`.

`optimizeTailExpr` (line 770) has no `Can.Binop` arm and falls through its
final `_ ->` catchall (line 943) into `optimizeExpr`, so the new rewrite
applies in tail position as well — see the "Open Questions" section for the
TCO trade-off this implies.

## Implementation Checklist

### Step 1 — Add small helpers in `Compiler.LocalOpt.Typed.Expression`

Near the other type-constructor helpers (e.g. the pattern that constructs
`Can.TType ModuleName.basics "String" []` at line 393), introduce two private
helpers:

```elm
boolType : Can.Type Name
boolType =
    Can.TType ModuleName.basics "Bool" []


boolLit : A.Region -> Bool -> Maybe IO.Variable -> TOpt.Expr Name
boolLit region value tv =
    TOpt.Bool region value { tipe = boolType, tvar = tv }
```

Rationale: centralizes `Bool` type construction and ensures TOPT_001 holds
for the injected literals. Follow the existing synthesized-literal pattern
in `Chr` / `Str` (lines 390/393): thread the outer `tvar` into `boolLit`
so that the `True` / `False` node carries the same type var the original
`Binop` node did. This preserves the XSNAP_001 / XSNAP_002 invariants
(every TypedOptimized expression has a stable mapping back to a solver
type var) and keeps debugger / monomorphizer type views consistent.

### Step 2 — Rewrite `&&` / `||` to `If` in `optimizeExpr`

Replace the current `Binop` arm (lines 418-436) with:

```elm
Can.Binop _ binopHome name (Can.Forall _ funcType) left right ->
    let
        optimizeArg =
            optimize kernelEnv annotations exprTypes exprVars home cycle
                << TCanBuild.toTypedExpr exprTypes exprVars

        lowerShortCircuit buildBranch =
            optimizeArg left
                |> Names.andThen
                    (\optLeft ->
                        optimizeArg right
                            |> Names.map
                                (\optRight ->
                                    let
                                        ( cond, thenE, elseE ) =
                                            buildBranch optLeft optRight
                                    in
                                    TOpt.If [ ( cond, thenE ) ] elseE
                                        { tipe = tipe, tvar = tvar }
                                )
                    )
    in
    if binopHome == ModuleName.basics && name == "and" then
        -- a && b  ==>  if a then b else False
        lowerShortCircuit
            (\l r -> ( l, r, boolLit region False tvar ))

    else if binopHome == ModuleName.basics && name == "or" then
        -- a || b  ==>  if a then True else b
        lowerShortCircuit
            (\l r -> ( l, boolLit region True tvar, r ))

    else
        -- Existing strict-call lowering for every other binop
        Names.registerGlobal region binopHome name funcType Nothing
            |> Names.andThen
                (\optFunc ->
                    optimizeArg left
                        |> Names.andThen
                            (\optLeft ->
                                optimizeArg right
                                    |> Names.map
                                        (\optRight ->
                                            TOpt.Call region optFunc
                                                [ optLeft, optRight ]
                                                { tipe = tipe, tvar = tvar }
                                        )
                            )
                )
```

Notes:

- `TOpt.If` takes `List ( Expr, Expr )` branches + final else + `Meta`; it
  does **not** carry its own region (confirmed from `AST/TypedOptimized.elm:156`).
- The outer `tipe` is already `Bool` for `&&`/`||` (the Binop is typed from
  the operator's annotation), so threading `{ tipe = tipe, tvar = tvar }`
  preserves TOPT_004.
- We keep `binopHome`/`name` matching rather than string-matching on a
  string module home — this is symmetrical with code elsewhere (e.g.
  `Expression.elm:343` uses `ModuleName.dict`).

### Step 3 — Documentary comments (no behavior change)

**`compiler/src/Compiler/Generate/MLIR/Intrinsics.elm`** — above the
`and`/`or` arms at lines 408-412, add:

```elm
-- These intrinsics are strict in both arguments; they are used only for
-- first-class references to Basics.and / Basics.or (e.g. `(&&)` passed as
-- a value). Short-circuit semantics for the (&&) / (||) operators are
-- implemented earlier in TypedOptimized by rewriting Binop to If, and do
-- not flow through this path.
```

**`compiler/src/Compiler/Generate/JavaScript/Expression.elm`** — above the
`"or"` / `"and"` arms at lines 725-729, add a matching note:

```elm
-- Reached only for strict function-call uses of Basics.and / Basics.or.
-- Operator uses of (&&) / (||) are lowered to TOpt.If in TypedOptimized.
```

No functional JS change. (See Open Question 4 for whether to simplify
further.)

### Step 4 — Verify invariant tests

Run the TypedOptimized invariant suites and confirm no regressions:

```
cd /work/compiler && npx elm-test-rs --project build-xhr --fuzz 1 \
    tests/TestLogic/LocalOpt/TypedOptTypesTest.elm \
    tests/TestLogic/LocalOpt/TypedOptimizedTypePreservationTest.elm \
    tests/TestLogic/LocalOpt/AnnotationsPreservedTest.elm \
    2>&1 | tee /tmp/test_output.txt
```

These check TOPT_001 / TOPT_003 / TOPT_004 respectively. The new `If` path
must produce type-preserving output.

### Step 5 — Verify the failing E2E tests now pass

```
TEST_FILTER=BoolShortCircuit cmake --build /work/build --target full \
    2>&1 | tee /tmp/test_output.txt
```

Expected:

- `BoolShortCircuitTest` prints both `shortAnd: False` and `shortOr: True`
  without overflowing.
- `BoolShortCircuitParserIdiomTest` no longer segfaults on the boundary
  index case.

### Step 6 — Full test sweep

```
cmake --build /work/build --target full 2>&1 | tee /tmp/test_output.txt
```

Then `grep` for `FAIL` / `Error` in the output; do not re-run the suite.

## Expected Diff Size

- `LocalOpt/Typed/Expression.elm`: ~30 lines (new helpers + replaced arm)
- `Generate/MLIR/Intrinsics.elm`: +5 lines comment
- `Generate/JavaScript/Expression.elm`: +2 lines comment
- No new files, no AST changes.

## Resolved Design Decisions

1. **Canonical name of `&&` / `||`.** Match on
   `binopHome == ModuleName.basics && name == "and" || "or"`. This is
   unambiguous: `Basics.and` / `Basics.or` are the only boolean `and`/`or`
   in `Basics`; bitwise `and`/`or` live under `Bitwise` as separate
   intrinsics (`Intrinsics.elm:424-428`). No extra Bool-type guard is
   needed.

2. **`tvar` for synthesized `Bool` literals.** Thread the *outer* `Binop`
   `tvar` into the injected `True` / `False` nodes. Matches the existing
   `Chr` / `Str` treatment (lines 390/393) and preserves
   XSNAP_001 / XSNAP_002. Step 1's `boolLit` signature reflects this.

3. **Tail-call asymmetry is pre-existing, not a regression.**
   `optimizeTailExpr` has no `Can.Binop` arm today — binops in tail position
   *already* fall through to the non-tail path, so `a && b` never helped
   TCO for `b`. This rewrite preserves current behaviour. If we ever want
   to recover TCO through `&&` / `||` on the RHS, a follow-up can add a
   small `Can.Binop` arm in `optimizeTailExpr` that recognizes Basics
   `and` / `or`, rewrites to `If`, and recurses into the taken branch via
   `optimizeTail`. Out of scope for this plan.

4. **JS backend: keep the special case + add a comment.** The arms at
   `Generate/JavaScript/Expression.elm:725-729` remain useful for
   first-class uses of `Basics.and` / `Basics.or`, emitting JS `&&` / `||`.
   Operator uses will now become `TOpt.If` and hit the regular `if`
   emission path. Step 3's comment records this split.

5. **Nested chains `a && b && c` (left-associative).** Rewriting
   layer-by-layer yields:

   - `a && b` → `if a then b else False`
   - `(a && b) && c` → `if (if a then b else False) then c else False`
     — which is operationally equivalent to
     `if a then (if b then c else False) else False`.

   Correct left-to-right short-circuit by construction; no extra logic
   required.

6. **Downstream impact is limited to the two sites already surveyed.**
   Only the JS backend infix mapping (Step 3) and the MLIR `eco.bool.and` /
   `eco.bool.or` intrinsics (Step 3) special-case `Basics.and` / `Basics.or`.
   Monomorphization is generic over TypedOptimized and treats the
   synthesized `If` like any other `If`. A quick
   `grep -rn "Basics.*and\|Basics.*or" compiler/src` at implementation time
   is sufficient to confirm no new site has appeared.

## Open Questions / Assumptions to Confirm

None remaining — all six items above are resolved. Proceed to
implementation.

## Done-When

1. Both short-circuit E2E tests pass under the native backend with
   `cmake --build build --target full`.
2. TOPT_001, TOPT_003, TOPT_004 invariant tests still pass.
3. No other E2E failures introduced (`TEST_FILTER` unset sweep).
4. The strict intrinsics `eco.bool.and` / `eco.bool.or` still emit from
   first-class `Basics.and` / `Basics.or` function calls (manual
   spot-check: grep a post-monomorphization MLIR dump for `eco.bool.and`
   when compiling a snippet like `List.foldl (&&) True [True, False]`).
