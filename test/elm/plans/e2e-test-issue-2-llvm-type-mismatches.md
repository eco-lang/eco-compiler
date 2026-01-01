# E2E Test Issue 2: LLVM Type Mismatches in Function Calls

## Affected Tests (18)

### 2a: Boolean type mismatch (`i1` vs `i64`) - 2 tests
- CaseBoolTest.elm
- TuplePairTest.elm

### 2b: Float-to-Int conversion (`f64` vs `i64`) - 4 tests
- CeilingToIntTest.elm
- FloorToIntTest.elm
- RoundToIntTest.elm
- TruncateToIntTest.elm

### 2c: Int width mismatch (`i64` vs `i32`) - 2 tests
- CharIsAlphaTest.elm
- CharIsDigitTest.elm

### 2d: Return type mismatch - 2 tests
- ComparableMinMaxTest.elm
- ResultWithDefaultTest.elm

### 2e: Pointer vs integer mismatch (`!llvm.ptr` vs `i64`) - 3 tests
- CustomTypeMultiFieldTest.elm
- CustomTypeNestedTest.elm
- CustomTypePatternTest.elm
- RecordAccessorFunctionTest.elm

### 2f: Function callee type mismatch - 4 tests
- MaybeAndThenTest.elm
- MaybeMapTest.elm
- ResultAndThenTest.elm
- ResultMapTest.elm

## Analysis

### Symptom
Tests fail during MLIR-to-LLVM lowering with errors like:
```
error: 'llvm.call' op operand type mismatch for operand 0: 'i1' != 'i64'
error: 'llvm.call' op operand type mismatch for operand 0: 'f64' != 'i64'
error: 'llvm.return' op mismatching result types
```

### Root Cause
The compiler generates MLIR with type annotations that don't match the actual function signatures. During LLVM lowering, MLIR validates that call operand types match function parameter types, and these mismatches cause verification failures.

### Subcategory Analysis

#### 2a: Boolean (`i1` vs `i64`)

Generated call:
```mlir
%2 = "eco.call"(%1) <{_operand_types = [i1], callee = @CaseBoolTest_boolToStr_$_1}> : (i1) -> !eco.value
```

But function signature is:
```mlir
{function_type = (!eco.value) -> (!eco.value), sym_name = "CaseBoolTest_boolToStr_$_1"}
```

The caller passes `i1`, but the function expects `!eco.value`.

#### 2b: Float-to-Int (`f64` vs `i64`)

The `Basics_ceiling_$_1` wrapper is called with `f64`:
```mlir
%2 = "eco.call"(%1) <{_operand_types = [f64], callee = @Basics_ceiling_$_1}> : (f64) -> i64
```

But somewhere in the lowering chain, this gets converted incorrectly, or the kernel declaration has the wrong type.

#### 2c: Char operations (`i64` vs `i32`)

Elm Char is a Unicode code point. The compiler uses `i64` but some char operations expect `i32`.

#### 2d: Return type mismatch

Functions return one type but the caller expects another. This happens with polymorphic functions like `min`/`max` or `withDefault`.

#### 2e: Pointer vs integer

Custom type field access generates pointer operations but the calling convention expects `i64`.

#### 2f: Higher-order function type mismatch

Functions like `Maybe.map` and `Maybe.andThen` take function callbacks, but the generated types for the callback don't match.

## Proposed Solution

### Step 1: Establish Consistent Type Representation

Define a clear mapping between Elm types and LLVM types:

| Elm Type | LLVM Type | Notes |
|----------|-----------|-------|
| `Int` | `i64` | Unboxed when possible |
| `Float` | `f64` | Unboxed when possible |
| `Bool` | `i64` | Use 0/1 encoding, NOT `i1` |
| `Char` | `i32` | Unicode code point |
| `String` | `!eco.value` (ptr) | Always boxed |
| `List a` | `!eco.value` (ptr) | Always boxed |
| `Custom types` | `!eco.value` (ptr) | Always boxed |
| `Records` | `!eco.value` (ptr) | Always boxed |
| `Functions` | `!eco.value` (ptr) | Always boxed (closures) |

### Step 2: Fix Boolean Representation

**Never use `i1` for Elm Booleans.** Always use `i64` with values 0 (False) or 1 (True).

In the compiler, when generating boolean constants:
```mlir
// WRONG
%1 = "arith.constant"() {value = true} : () -> i1

// CORRECT
%1 = "arith.constant"() {value = 1 : i64} : () -> i64
```

### Step 3: Fix Float/Int Conversion Functions

Update wrapper functions to have correct signatures:

```mlir
// Wrapper should take f64 and return i64
"func.func"() ({
    ^bb0(%arg0: f64):  // Takes float
      %1 = "llvm.call"(@Elm_Kernel_Basics_ceiling, %arg0) : (f64) -> i64
      "eco.return"(%1) : (i64) -> ()
}) {function_type = (f64) -> (i64), sym_name = "Basics_ceiling_$_1"}
```

### Step 4: Fix Char Type Consistency

Decide on `i32` for Char and use it consistently:
- All Char operations should take/return `i32`
- When converting Char to/from Int, insert explicit conversion

### Step 5: Fix Polymorphic Return Types

For functions with polymorphic return types, either:
1. Generate type-specialized versions at call sites
2. Use `!eco.value` universally and box/unbox as needed

### Step 6: Fix Higher-Order Function Signatures

Ensure callback function types are correctly propagated. The `_operand_types` attribute should match actual function parameter types.

## Implementation Steps

1. **Audit all type representations** in the compiler's codegen
2. **Change Bool from `i1` to `i64`** everywhere
3. **Fix float-to-int wrappers** to properly declare parameter types
4. **Standardize Char as `i32`**
5. **Add type conversion ops** where needed (e.g., `llvm.sext` for i32 to i64)
6. **Update kernel function declarations** in the MLIR lowering pass
7. **Add validation pass** to catch type mismatches before LLVM lowering

## Files to Modify

- Compiler codegen for literal emission
- Compiler codegen for function call emission
- MLIR eco dialect type definitions
- MLIR lowering passes (eco -> llvm)
- Kernel function declaration registration

## Estimated Complexity

High - This is a systemic issue requiring careful audit of the entire type system in the compiler and runtime interface.
