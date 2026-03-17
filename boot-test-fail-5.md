# Error 5: `eco.case` yield `i1` vs `!eco.value` (3 errors)

## Root Cause

**File:** `compiler/src/Compiler/Generate/MLIR/TailRec.elm`, `compileTailCallStep` (~line 370-416)

When compiling tail-call arguments inside a while-loop body:

1. `Expr.generateExpr` evaluates each argument, producing SSA types (Bool -> `i1`)
2. The resulting values are placed directly into `nextParams` **without coercion** to ABI types
3. The `scf.while` carry types use ABI representation (`!eco.value` for Bool)
4. The `eco.case` yield type must match the carry type, but bare `i1` is yielded where `!eco.value` is expected

For comparison, `compileBaseReturnStep` (line 430) correctly coerces via `Expr.coerceResultToType`. The omission is specific to `compileTailCallStep`.

### Missing coercion

After line 396 (where `argVars` is built from `generateExpr` results), there should be a coercion step that matches each argument's actual SSA type against the corresponding carry type (ABI type from `loopSpec.paramVars`). For each `(argVar, argType)` in `argVars` and corresponding `(_, paramType)` in `loopSpec.paramVars`, the code should call `Expr.coerceResultToType` to box `i1` -> `!eco.value` when needed.

## MLIR Evidence

Location 1 (line 60260) — `Compiler_Elm_Package_chompName_$_5208`:
```mlir
// scf.while carry types: (!eco.value, !eco.value, i64, i64, !eco.value, i1, !eco.value)
%79..%85 = "eco.case"(%40) ({
    "eco.yield"(%23, %24, %42, %26, %43, %44, %45)
    // operand types:  !eco.value, !eco.value, i64, i64, i1,  i1, !eco.value
    //                                                   ^^
    // operand 4 is i1 (%43 = false), but eco.case result 4 expects !eco.value
}, { ... })
```

Location 2 (line 353167) — Dict_foldl-related, alternative 1, operand 3.

Location 3 (line 535240) — `_tail_go_309331` string escape processing:
```mlir
%66..%70 = "eco.case"(%28) ({
    "eco.yield"(%31, %34, %29, %35, %36)
    // types:    i1,  !eco.value, !eco.value, i1, !eco.value
    //           ^^-- operand 0 is i1, but case result 0 expects !eco.value
}, { ... })
```

## Failing Test

`test/elm/src/TailRecBoolCarryTest.elm` — **FAILS** with: `'eco.case' op alternative 0 eco.yield operand 0 has type 'i1' but eco.case result 0 has type '!eco.value'`

## Fix Direction

Add a coercion pass in `compileTailCallStep` after evaluating tail-call arguments with `generateExpr`. Each argument's SSA type should be matched against the corresponding `scf.while` carry type, and `i1` values should be boxed to `!eco.value` via `Expr.coerceResultToType` or `boxToEcoValue`.
