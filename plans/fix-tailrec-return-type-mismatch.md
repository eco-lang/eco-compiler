# Fix Tail-Recursive Return Type Mismatch

## Problem Statement

Tail-recursive functions return `!eco.value` (boxed) when they should return unboxed primitives like `i64`. This causes:
- Type mismatch between callee signature and caller expectation
- Wrong runtime values (pointer values instead of integers)

Example from `TailRecursiveSumTest`:
```
Expected: sum1: 15, sum2: 55, sum3: 5050
Actual:   sum1: 67108864, sum2: 67108868, sum3: 67108872
```

The values 67108864 = 2^26 are pointer values, not integers.

### Generated MLIR showing the bug

```mlir
// Caller expects i64 return:
%2 = "eco.call"(%n, %1) <{callee = @sumHelper_$_4}> : (i64, i64) -> i64

// But callee signature returns !eco.value:
"func.func"() ({
    ^bb0(%n: i64, %acc: i64):
      ...
      "eco.return"(%7) {_operand_types = [!eco.value]} : (!eco.value) -> ()
}) {function_type = (i64, i64) -> (!eco.value), sym_name = "sumHelper_$_4", ...}
```

---

## Root Cause

In `specializeFuncDefInCycle`, the `TOpt.TailDef` branch:

1. **Stores only return type** instead of full function type in `MonoTailFunc`
2. **Uses base substitution** instead of augmented substitution for return type

This violates the invariant that `MonoTailFunc` carries a full `MFunction [argTypes] retType`.

---

## Invariants

- **MONO_TAIL_001**: Every `MonoTailFunc` node must carry a full function type `MFunction [argTypes] retType`
- **MONO_TAIL_002**: The tail function's return type must be computed under the augmented substitution (same as body)
- **ABI_001**: `MInt` maps to `I64`, `MFloat` maps to `F64` via `monoTypeToAbi`

---

## Implementation

### Step 1: Fix `specializeFuncDefInCycle` in Specialize.elm

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`
**Function:** `specializeFuncDefInCycle`

**Current code (buggy):**
```elm
TOpt.TailDef _ _ args body returnType ->
    let
        monoArgs = List.map (specializeArg subst) args
        ...
        ( monoBody, state1 ) = specializeExpr body augmentedSubst stateWithParams

        monoReturnType =
            TypeSubst.applySubst subst returnType  -- BUG: uses base subst
    in
    ( Mono.MonoTailFunc monoArgs monoBody monoReturnType, state1 )  -- BUG: stores only return type
```

**Fixed code:**
```elm
TOpt.TailDef _ _ args body returnType ->
    let
        monoArgs =
            List.map (specializeArg subst) args

        newVarTypes =
            List.foldl
                (\( name, monoParamType ) vt -> Dict.insert identity name monoParamType vt)
                state.varTypes
                monoArgs

        stateWithParams =
            { state | varTypes = newVarTypes }

        augmentedSubst =
            List.foldl
                (\( ( _, canParamType ), ( _, monoParamType ) ) s ->
                    case canParamType of
                        Can.TVar varName ->
                            Dict.insert identity varName monoParamType s

                        _ ->
                            s
                )
                subst
                (List.map2 Tuple.pair args monoArgs)

        ( monoBody, state1 ) =
            specializeExpr body augmentedSubst stateWithParams

        -- FIX 1: Use augmentedSubst so return type reflects param constraints
        monoReturnType =
            TypeSubst.applySubst augmentedSubst returnType

        -- FIX 2: Store the FULL function type: MFunction args returnType
        monoFuncType =
            Mono.MFunction (List.map Tuple.second monoArgs) monoReturnType
    in
    ( Mono.MonoTailFunc monoArgs monoBody monoFuncType, state1 )
```

### Step 2: Verify `Context.extractNodeSignature` assumptions

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`
**Function:** `extractNodeSignature`

The existing code already expects `MonoTailFunc` to have a full function type:

```elm
Mono.MonoTailFunc params _ monoType ->
    let
        returnType =
            case monoType of
                Mono.MFunction _ ret ->
                    ret

                _ ->
                    -- Shouldn't happen per MONO_004 invariant
                    monoType
    in
    Just
        { paramTypes = List.map Tuple.second params
        , returnType = returnType
        , callModel = StageCurried
        }
```

With the fix in Step 1, `monoType` will always be `MFunction args ret`, so:
- The `Mono.MFunction _ ret` branch always fires
- The fallback `_ -> monoType` is defensive only

**No changes needed here**, but verify this assumption holds.

### Step 3: Confirm downstream behavior (no changes needed)

**File:** `compiler/src/Compiler/Generate/MLIR/Types.elm`

`monoTypeToAbi` correctly maps:
- `MInt` -> `I64`
- `MFloat` -> `F64`
- `MVar _ CNumber` -> `I64`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

`createDummyValue` correctly emits:
- `I64` -> `arith.constant : i64`
- `F64` -> `arith.constant : f64`

Once `monoReturnType` is correctly specialized to `MInt`, the pipeline produces:
```mlir
%3 = "arith.constant"() {value = 0 : i64} : () -> i64  -- CORRECT
```

Instead of:
```mlir
%3 = "eco.constant"() {kind = 1 : i32} : () -> !eco.value  -- WRONG
```

---

## Testing

### Unit Tests

1. Construct a tail-recursive function:
   ```elm
   sumHelper : Int -> Int -> Int
   sumHelper n acc =
       if n <= 0 then acc
       else sumHelper (n - 1) (acc + n)
   ```

2. Assert post-monomorphization:
   - `MonoNode` for `sumHelper` is `MonoTailFunc params body monoType`
   - `monoType` is `MFunction [MInt, MInt] MInt`
   - No `MVar _ CNumber` remains at MLIR boundary

3. Assert in generated MLIR:
   - Function signature: `(i64, i64) -> i64`
   - Dummy result in `scf.while` state: `arith.constant : i64`

### E2E Regression Test

`TailRecursiveSumTest.elm` should produce:
```
sum1: 15
sum2: 55
sum3: 5050
```

### Expected MLIR Pattern (after fix)

```mlir
"func.func"() ({
    ^bb0(%n: i64, %acc: i64):
      %2 = "arith.constant"() {value = false} : () -> i1
      %3 = "arith.constant"() {value = 0 : i64} : () -> i64  -- Correct dummy value
      %4, %5, %6, %7 = "scf.while"(%n, %acc, %2, %3) ({
          ...
      }, {
          ...
          "eco.yield"(%23, %24, %25, %26) : (i64, i64, i1, i64) -> ()  -- i64 result
      }) : (i64, i64, i1, i64) -> (i64, i64, i1, i64)
      "eco.return"(%7) : (i64) -> ()  -- Correct return type
}) {function_type = (i64, i64) -> (i64), sym_name = "sumHelper_$_4", ...}
```

---

## Files to Modify

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm` | Fix `TOpt.TailDef` branch: use augmentedSubst, store full MFunction type |

---

## Success Criteria

1. `TailRecursiveSumTest` passes with correct output values
2. All tail-recursive functions with primitive return types produce unboxed MLIR
3. No type mismatch between callee signature and caller expectation
4. `elm-test-rs` continues to pass (6892 tests)
