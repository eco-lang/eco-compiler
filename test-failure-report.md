# Test Failure Report — Full Trace Evidence

## Summary

| Suite | Passed | Failed |
|-------|--------|--------|
| Elm frontend (elm-test-rs) | 10,751 | 4 |
| E2E backend (cmake check) | 867 | 5 |

**9 total failures across 5 distinct bugs:**

| Bug ID | Frontend Failures | E2E Failures | Root Cause |
|--------|-------------------|--------------|------------|
| BUG-1: Bool closure capture | — | ClosureCaptureBoolTest | Missing `eco.box` before `papCreate` for Bool operands |
| BUG-2: PapExtend arity | CGEN_052 x2 | PapExtendArityTest | `sourceArityForCallee` returns total arity instead of first-stage arity |
| BUG-3: Saturated papExtend result type | CGEN_056 x1 | PapSaturatePolyPipeMinimalTest | MonoInlineSimplify preserves inner `CEcoValue` result type through `apR` inlining |
| BUG-4: Tail-rec Bool carry | — | TailRecBoolCarryTest, TailRecDeciderSearchTest | `compileTailCallStep` yields `i1` where `scf.while` carry expects `!eco.value` |
| BUG-5: Dbg type IDs | CGEN_036 x1 | — | Hardcoded `-1` in `arg_type_ids` for string label |

---

## BUG-1: Bool Closure Capture — `i1` operand in `papCreate` with `unboxed_bitmap=0`

### Error
```
'eco.papCreate' op unboxed_bitmap bit 0 doesn't match operand type: bit is unset but operand type is 'i1'
```

### Affected Tests
- **E2E**: `ClosureCaptureBoolTest.elm`

### MLIR Evidence

From `/work/test/elm/eco-stuff/mlir/ClosureCaptureBoolTest.mlir` lines 3-6:

```mlir
%4 = "arith.constant"() {value = true} : () -> i1                          <- Bool as i1 (SSA type)
%0 = "eco.papCreate"(%4) {_operand_types = [i1], arity = 2,
     function = @ClosureCaptureBoolTest_lambda_1$clo,
     num_captured = 1, unboxed_bitmap = 0} : (i1) -> !eco.value            <- BUG: operand is i1 but bit 0 is unset
```

**What should happen**: Before passing `%4` to `papCreate`, the codegen should insert `eco.box`:
```mlir
%4 = "arith.constant"() {value = true} : () -> i1
%4b = "eco.box"(%4) : (i1) -> !eco.value                                   <- MISSING
%0 = "eco.papCreate"(%4b) {_operand_types = [!eco.value], ..., unboxed_bitmap = 0}
```

**Note**: The `$cap` and `$clo` functions are generated correctly — they accept `!eco.value` and unbox internally:
```mlir
// lambda_1$cap (line 62): parameter is !eco.value, unboxes to i1 inside
^bb0(%mono_inline_0: !eco.value, %dummy: i64):
    %2 = "eco.unbox"(%mono_inline_0) : (!eco.value) -> i1                  <- Correct
```

### Source Code Trace

**`/work/compiler/src/Compiler/Generate/MLIR/Expr.elm`** — `generateClosure` function:

1. **Lines 884-914**: Captured expressions are generated with `Expr.generateExpr`, which returns SSA types. For Bool, `resultType = I1`:
   ```elm
   captureVarsWithTypes =
       List.map (\result -> ( result.resultVar, result.resultType )) capturedExpressions
       -- For Bool: ( "%4", I1 )
   ```

2. **Lines 931-944**: `unboxedBitmap` correctly marks Bool as *not* unboxable (bit = 0):
   ```elm
   if Types.isUnboxable mlirTy then  -- I1 is NOT unboxable per REP_CLOSURE_001
       Bitwise.shiftLeftBy i 1
   else
       0  -- Bool gets bitmap bit = 0 -> expects !eco.value
   ```

3. **Line 907** — **THE BUG**: No boxing is applied:
   ```elm
   -- Comment says: "No boxing - use captures with their actual types (typed closure ABI)"
   captureVarNames = List.map Tuple.first captureVarsWithTypes   -- ["%4"]
   captureTypesList = List.map Tuple.second captureVarsWithTypes -- [I1] <- WRONG
   ```

4. **Lines 1043-1047**: papCreate is emitted with the raw SSA variables and types:
   ```elm
   Ops.mlirOp ctx2 "eco.papCreate"
       |> Ops.opBuilder.withOperands captureVarNames  -- ["%4"] which is i1
   ```

**The fix location**: Between lines 907 and 1043 — the captured expressions need closure-boundary normalization (boxing Bool `i1` -> `!eco.value`).

**Contrast — papExtend does this correctly** at lines 1577-1606 via `boxArgsForClosureBoundary`:
```elm
boxArgsForClosureBoundary boxAllPrimitives ctx argsWithTypes =
    ...
    needsBoxing =
        if boxAllPrimitives then
            not (Types.isEcoValueType mlirTy)
        else
            mlirTy == I1  -- Bool needs boxing at closure boundary
```
This function is only called for `papExtend`, not `papCreate`.

### Invariants Violated
- **REP_CLOSURE_001**: "only immediate operands [Int, Float, Char] are stored in unboxed fields and all other values (including Bool) are stored as !eco.value"
- **FORBID_CLOSURE_001**: "Bool must be represented as !eco.value in heap and closures"

---

## BUG-2: PapExtend `remaining_arity` Mismatch for Multi-Stage Function Types

### Errors
- **Frontend**: `eco.papExtend remaining_arity=4 but source PAP has remaining=2` (CGEN_052, Function expressions)
- **Frontend**: `eco.papExtend remaining_arity=2 but source PAP has remaining=1` (CGEN_052, Partial application type)
- **E2E**: Runtime SIGABRT assertion `closure->n_values + num_newargs == max_values` (PapExtendArityTest)

### Affected Tests
- **Elm-test**: CGEN_052 x2
- **E2E**: `PapExtendArityTest.elm`

### MLIR Evidence

From `/work/test/elm/eco-stuff/mlir/PapExtendArityTest.mlir`:

**Pattern 1** — `applyPartial` (line 46):
```mlir
// applyPartial calls f a -- f has type (Int -> Int -> Int) which is multi-stage: (Int -> (Int -> Int))
// First-stage arity = 1, but codegen uses total arity = 2
^bb0(%f: !eco.value, %a: i64):
    %2 = "eco.papExtend"(%f, %a) {newargs_unboxed_bitmap = 1,
         remaining_arity = 2}                                               <- BUG: should be 1
         : (!eco.value, i64) -> !eco.value
```

The source PAP `%f` was created by `curried_$_1` (line 31):
```mlir
^bb0(%x: i64):
    %1 = "eco.papCreate"(%x) {arity = 2, function = @...lambda_6$clo,
         num_captured = 1, unboxed_bitmap = 1} : (i64) -> !eco.value       <- arity=2, remaining=2-1=1
```

So the PAP has `remaining = arity - num_captured = 2 - 1 = 1`, but `papExtend` says `remaining_arity = 2`.

**Pattern 2** — `flip` (line 36):
```mlir
^bb0(%f: !eco.value, %b: i64, %a: i64):
    %3 = "eco.papExtend"(%f, %a, %b) {newargs_unboxed_bitmap = 3,
         remaining_arity = 2}                                               <- BUG: should be 1
         : (!eco.value, i64, i64) -> i64
```

Adding 2 args with `remaining_arity=2` means the codegen thinks the PAP originally had remaining=2. But the PAP's first stage only has remaining=1. The runtime catches this mismatch.

**Runtime crash** at `/work/runtime/src/allocator/RuntimeExports.cpp:624`:
```cpp
assert(closure->n_values + num_newargs == max_values
       && "eco_closure_call_saturated: argument count mismatch");
```

### Source Code Trace

**`/work/compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`**:

1. **Lines 1488-1497** — `sourceArityForCallee`:
   ```elm
   sourceArityForCallee graph env funcExpr =
       case sourceArityForExpr graph env funcExpr of
           Just arity -> arity
           Nothing ->
               -- Fallback: use TOTAL arity for unknown callees
               countTotalArityFromType (Mono.typeOf funcExpr)               <- THE BUG
   ```

2. **Lines 1502-1509** — `countTotalArityFromType`:
   ```elm
   countTotalArityFromType monoType =
       case monoType of
           Mono.MFunction argTypes resultType ->
               List.length argTypes + countTotalArityFromType resultType    <- Sums ALL stages
           _ -> 0
   ```
   For type `Int -> (Int -> Int)` this returns `1 + 1 = 2` instead of first-stage `1`.

3. **Lines 1237-1261** — `varSourceArity` tracking: Only populated from `MonoDef` bindings. **Function parameters** (like `f` in `applyPartial f a`) are NOT in `varSourceArity`, so lookup returns `Nothing`, triggering the fallback.

4. **Lines 1722-1724** — `initialRemaining` assignment:
   ```elm
   initialRemaining = sourceArity  -- = sourceArityForCallee = 2 (wrong)
   ```

### Chain
1. `f` is a function parameter with type `Int -> Int -> Int` (multi-stage: `MFunction [Int] (MFunction [Int] Int)`)
2. `sourceArityForExpr` returns `Nothing` (not in `varSourceArity`)
3. Fallback to `countTotalArityFromType` -> returns 2 (total) instead of 1 (first-stage)
4. `papExtend` emits `remaining_arity=2`
5. Runtime assertion fails: PAP has remaining=1 but codegen said 2

### Invariant Violated
- **CGEN_052**: "papExtend remaining_arity must match the source PAP's actual remaining arity"

---

## BUG-3: Saturated PapExtend Result Type Mismatch After `apR` Inlining

### Error
```
'eco.papExtend' op saturated papExtend result type '!eco.value' does not match function result type 'i64'
```

### Affected Tests
- **Elm-test**: CGEN_056 (Partial application type)
- **E2E**: `PapSaturatePolyPipeMinimalTest.elm`

### MLIR Evidence

From `/work/test/elm/eco-stuff/mlir/PapSaturatePolyPipeMinimalTest.mlir` lines 20-26:

```mlir
// polyWithDefault inlines apR, creating papCreate + papExtend chain:
^bb0(%default: i64, %mx: !eco.value):
    %4 = "eco.papCreate"() {arity = 2, function = @Maybe_withDefault_$_6, ...}
                                                                    : () -> !eco.value
    %3 = "eco.papExtend"(%4, %default) {remaining_arity = 2}
                                                                    : (!eco.value, i64) -> !eco.value
    %6 = "eco.papExtend"(%3, %mx) {remaining_arity = 1}
                                                                    : (!eco.value, !eco.value) -> !eco.value  <- BUG
    %7 = "eco.unbox"(%6) : (!eco.value) -> i64
```

The second `papExtend` is a **saturated** call (adds 1 arg with `remaining_arity=1` -> fully applied). Its result type should match the target function's return type. But `Maybe_withDefault_$_6` returns `i64`:

```mlir
// Lines 45-56: Maybe_withDefault_$_6 returns i64
^bb0(%default: i64, %maybe: !eco.value):
    ...
    "eco.return"(%7) : (i64) -> ()
}) {function_type = (i64, !eco.value) -> (i64), sym_name = "Maybe_withDefault_$_6"}
```

So the saturated `papExtend` should produce `i64`, not `!eco.value`.

### Source Code Trace

**`/work/compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`**:

1. **Lines 1498-1530** — Over-application inlining of `apR`:
   ```elm
   -- apR body is: f x (i.e., apply function to value)
   -- After substitution + inlining, creates:
   innerExpr =
       wrapInLetsForInline bindings substituted (Mono.typeOf body)
   inlined =
       MonoCall A.zero innerExpr extraArgs resultType Mono.defaultCallInfo
       --                                   ^^^^^^^^^^
       -- resultType comes from the INNER call's type (CEcoValue from apR's polymorphic monomorphization)
   ```

2. **Lines 1189-1194** — `substitute` preserves the original `MonoCall.resultType`:
   ```elm
   MonoCall region func args resultType callInfo ->
       MonoCall region (substitute ...) (List.map (substitute ...) args)
           resultType  -- <- PRESERVED AS-IS (CEcoValue instead of MInt)
           callInfo
   ```

3. **`/work/compiler/src/Compiler/AST/Monomorphized.elm` lines 1051-1060** — `defaultCallInfo`:
   ```elm
   defaultCallInfo =
       { isSingleStageSaturated = False  -- Missing metadata!
       , initialRemaining = 0
       , remainingStageArities = []
       , ... }
   ```

4. **`/work/compiler/src/Compiler/Generate/MLIR/Expr.elm` lines 1328-1336** — `applyByStages`:
   ```elm
   resultMlirType =
       if isSaturatedCall then
           saturatedReturnType  -- Derived from CEcoValue -> !eco.value (WRONG, should be i64)
       else
           funcMlirType
   ```

### Chain
1. `mx |> Maybe.withDefault default` desugars to `Basics.apR mx (Maybe.withDefault default)`
2. `MonoInlineSimplify` inlines `apR`'s body: `f x` -> `(Maybe.withDefault default) mx`
3. The inner `MonoCall` retains `resultType = CEcoValue` (from `apR`'s polymorphic signature)
4. New outer `MonoCall` gets `defaultCallInfo` with `isSingleStageSaturated = False`
5. MLIR generation routes through `generateClosureApplication` (not saturated direct call)
6. `applyByStages` sees saturated papExtend but uses the wrong `CEcoValue`-derived return type
7. Produces `!eco.value` instead of `i64`

### Invariant Violated
- **CGEN_056**: "Saturated papExtend result type must match the target function's return type"

---

## BUG-4: Tail-Recursive Bool Carry Type Mismatch (`i1` vs `!eco.value`)

### Errors
- `'eco.case' op alternative 0 eco.yield operand 0 has type 'i1' but eco.case result 0 has type '!eco.value'`
- `use of value '%1' expects different type than prior uses: '!eco.value' vs 'i1'`

### Affected Tests
- **E2E**: `TailRecBoolCarryTest.elm`, `TailRecDeciderSearchTest.elm`

### MLIR Evidence — TailRecBoolCarryTest

From `/work/test/elm/eco-stuff/mlir/TailRecBoolCarryTest.mlir` lines 49-93:

The function signature uses ABI types (correct):
```mlir
^bb0(%found: !eco.value, %acc: i64, %list: !eco.value):          <- Bool param is !eco.value (ABI)
```

The `scf.while` carry types (line 53):
```mlir
%5, %6, %7, %8, %9 = "scf.while"(%found, %acc, %list, %3, %4)
    <- carry types: (!eco.value, i64, !eco.value, i1, i64)
    <- first carry is !eco.value for the Bool param
```

**THE BUG** — in the `x > 5` branch (lines 79-84), the tail call yields:
```mlir
%38 = "arith.constant"() {value = true} : () -> i1               <- True as i1 (SSA type)
%39 = "eco.int.add"(%18, %34) : (i64, i64) -> i64
"eco.yield"(%38, %39, %35, %40, %41)
    {_operand_types = [i1, i64, !eco.value, i1, i64]}            <- BUG: first operand is i1
```

First yield operand is `i1` but the corresponding carry type is `!eco.value`. This is because `searchList True (acc + x) xs` generates `True` as `i1` via `generateExpr`, but the while-loop carry for `found` was established as `!eco.value` (ABI type).

### MLIR Evidence — TailRecDeciderSearchTest

From `/work/test/elm/eco-stuff/mlir/TailRecDeciderSearchTest.mlir`:

**Outer function** `search_$_5` (line 45):
```mlir
%1 = "eco.papCreate"() {arity = 1, function = @_tail_firstInlineExpr_31, ...}
     : () -> !eco.value                                                    <- %1 = !eco.value
```

**Inner lambda** `_tail_firstInlineExpr_31` (line 90-91):
```mlir
%1 = "arith.constant"() {value = false} : () -> i1                        <- %1 REDEFINED as i1!
%2 = "eco.constant"() {kind = 1 : i32} : () -> !eco.value
```

**Self-reference** (line 121):
```mlir
%32 = "eco.papExtend"(%1, %30) {...}                                       <- Uses %1, expects !eco.value
```

`%1` was allocated as the closure variable in the outer function (`!eco.value`), but inside the lambda, `nextVar` starts at 1 (number of params), so `freshVar` allocates `%1` again — this time as `i1` for the `doneInitVar` boolean constant.

### Source Code Trace — Bool Carry

**`/work/compiler/src/Compiler/Generate/MLIR/TailRec.elm`** lines 370-416, `compileTailCallStep`:

```elm
-- Line 383: Generate tail call arguments using generateExpr
( argOps, argResult, ctxAcc ) = Expr.generateExpr ctxAcc argExpr
-- For Bool True: argResult.resultType = I1 (SSA type)

-- Line 386: Store raw SSA type
argVars = ( argResult.resultVar, argResult.resultType )  -- ("%38", I1)

-- Line 411: Return as nextParams -- these become scf.yield operands
{ nextParams = argVars, ... }
```

**Line 278** in `buildAfterRegion`: yield operands use `stepResult.nextParams` directly **without any type conversion**.

**But the carry types are set up with ABI types** at lines 114-119 in `compileTailFuncToWhile`:
```elm
paramTypes = List.map Tuple.second paramPairs  -- From monoTypeToAbi: Bool -> !eco.value
```

So carries are `!eco.value` but yields are `i1`.

### Source Code Trace — SSA Var Collision

**`/work/compiler/src/Compiler/Generate/MLIR/Lambdas.elm`** lines 128-135:

```elm
varMappingsWithSiblings =
    Dict.union varMappingsWithArgs lambda.siblingMappings
    -- siblingMappings has: "firstInlineExpr" -> VarInfo{ssaVar="%1", mlirType=!eco.value}

ctxWithArgs =
    { ctx | varMappings = varMappingsWithSiblings,
            nextVar = nextVarAfterParams }
    -- nextVarAfterParams = List.length allArgPairs = 1 (just "decider")
    -- But %1 is already used by siblingMappings!
```

**`/work/compiler/src/Compiler/Generate/MLIR/TailRec.elm`** lines 97-103:
```elm
( doneInitVar, ctx1 ) = Ctx.freshVar ctx    -- nextVar=1 -> allocates "%1"
-- %1 is now i1 (false constant), colliding with the sibling's !eco.value
```

**`/work/compiler/src/Compiler/Generate/MLIR/Context.elm`** lines 451-457:
```elm
freshVar ctx =
    ( "%" ++ String.fromInt ctx.nextVar      -- Returns "%1"
    , { ctx | nextVar = ctx.nextVar + 1 } )  -- nextVar becomes 2
```

### Chain (TailRecBoolCarryTest)
1. `searchList` is tail-recursive with Bool param `found` -> compiled to `scf.while`
2. Carry type for `found` is `!eco.value` (ABI type, correct)
3. Inside the loop body, `searchList True (acc + x) xs` generates `True` as `i1` via `generateExpr`
4. `compileTailCallStep` stores `i1` directly in `nextParams`
5. `buildAfterRegion` yields `i1` where `!eco.value` is expected
6. MLIR verifier rejects the type mismatch

### Chain (TailRecDeciderSearchTest)
1. Outer function allocates `%1` as `!eco.value` closure for `firstInlineExpr`
2. `siblingMappings` stores `"firstInlineExpr" -> {ssaVar="%1", type=!eco.value}`
3. Lambda `_tail_firstInlineExpr_31` is compiled with `nextVar = 1` (only 1 param)
4. `freshVar` allocates `%1` as `i1` (boolean `false` for `doneInitVar`)
5. Later, self-reference looks up `"firstInlineExpr"` -> gets `%1` -> expects `!eco.value`
6. MLIR verifier: `%1` can't be both `!eco.value` and `i1`

---

## BUG-5: `eco.dbg` Hardcoded `-1` Type ID for String Label

### Error
```
eco.dbg arg_type_ids[0]=-1 out of range [0,0]
```

### Affected Tests
- **Elm-test**: CGEN_036 (Kernel intrinsics)

### MLIR Evidence

From `/work/test/elm/eco-stuff/mlir/ClosureCaptureBoolTest.mlir` line 11:
```mlir
"eco.dbg"(%10, %2) {arg_type_ids = array<i64: -1, 0>}
                                             ^^
                                             First element is -1 (invalid)
```

Type table (line 88):
```mlir
"eco.type_table"() {types = [[0, 0, 0]]}     <- Only 1 entry, valid range is [0, 0]
```

### Source Code Trace

**`/work/compiler/src/Compiler/Generate/MLIR/Expr.elm`** lines 2327-2331:
```elm
( "arg_type_ids"
, ArrayAttr (Just I64)
      [ IntAttr Nothing -1    -- <- HARDCODED -1 for string label
      , IntAttr Nothing typeId -- valid typeId for the value
      ]
)
```

The comment says "-1 for string label (to be printed as string)" — this is an intentional sentinel value, but the CGEN_036 invariant checker at `/work/compiler/tests/TestLogic/Generate/CodeGen/DbgTypeIds.elm` lines 86-105 rejects any `typeId < 0`.

### Fix Options
1. Register String in the type table and use its valid ID
2. Exempt the label position from type ID validation
3. Use a different sentinel that the validator understands

---

## Root Cause Groupings

### Group A: Bool Representation at Boundaries (BUG-1, BUG-4)

All three E2E tests (`ClosureCaptureBoolTest`, `TailRecBoolCarryTest`, `TailRecDeciderSearchTest`) share the same underlying issue: **Bool is emitted as `i1` (SSA type) at boundaries that require `!eco.value` (ABI type)**.

| Boundary | Where | Missing |
|----------|-------|---------|
| Closure capture (`papCreate`) | `Expr.elm` generateClosure, line 907 | `eco.box` for Bool before `papCreate` |
| Tail-rec yield (`scf.while`) | `TailRec.elm` compileTailCallStep, line 386 | `eco.box` for Bool before `eco.yield` |
| Lambda `nextVar` | `Lambdas.elm` line 135 | Account for sibling SSA indices in `nextVar` |

### Group B: Arity/Type Propagation in GlobalOpt (BUG-2, BUG-3)

Both involve incorrect metadata surviving through optimization passes:

| Issue | Where | Wrong value |
|-------|-------|-------------|
| `remaining_arity` | `MonoGlobalOptimize.elm` sourceArityForCallee, line 1497 | Total arity instead of first-stage arity |
| Result type | `MonoInlineSimplify.elm` over-application, line 1517 | `CEcoValue` from inner call instead of concrete type |

### Group C: Dbg Type Table (BUG-5)

Standalone issue — hardcoded `-1` sentinel in `arg_type_ids`.
