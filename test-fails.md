# Test Failure Analysis Report

**Date:** 2026-01-11
**Tests Run:** 545
**Passed:** 494
**Failed:** 51

## Executive Summary

The 51 failing tests fall into 6 distinct categories, each with different root causes:

| Category | Count | Root Cause |
|----------|-------|------------|
| SIGSEGV (Segmentation fault) | 18 | Closure/PAP runtime errors returning 0, null pointer dereference |
| SIGABRT (Assertion failures) | 8 | Type/tag mismatches in runtime, invalid heap pointers |
| JIT Lowering Pipeline Failed | 4 | Missing conversion patterns for cf.br, missing function definitions |
| JIT LLVM Translation Failed | 3 | Unrealized type conversions for scf.if with !eco.value |
| MLIR Parse Failed | 1 | Type mismatch in generated MLIR (i64 vs !eco.value) |
| Wrong Output | 17 | Codegen bug: incorrect function signatures and unboxed_bitmap |

---

## Category 1: SIGSEGV (Segmentation Fault) - 18 Tests

### Affected Tests
- AnonymousFunctionTest.elm
- CaseDeeplyNestedTest.elm
- CaseMaybeTest.elm
- CaseNestedTest.elm
- FunctionBasicTest.elm
- FunctionMultiArgTest.elm
- LetBasicTest.elm
- LetMultipleTest.elm
- ListConcatTest.elm
- ListFilterTest.elm
- ListFoldrTest.elm
- ListMapTest.elm
- MaybePatternMatchTest.elm
- MaybeWithDefaultTest.elm
- PartialAppChainTest.elm
- PartialApplicationTest.elm
- RecursiveFibonacciTest.elm
- RecursiveListLengthTest.elm
- StringLengthTest.elm

### Root Cause Analysis

The SIGSEGV failures share a common pattern: they all involve **higher-order functions, closures, partial application, or recursion**.

**Primary Cause: Closure/PAP Runtime Error Handling**

The closure runtime functions return `0` on error conditions:

1. `eco_pap_extend` returns 0 if `old_n_values + num_newargs > max_values`
2. `eco_closure_call_saturated` returns 0 if `n_values + num_newargs != max_values`
3. `eco_apply_closure` is **completely unimplemented** - it logs "not yet implemented" and returns 0

When any of these return 0:
- The compiled code treats 0 as a valid `!eco.value` (HPointer)
- `inttoptr 0` produces a null pointer
- Subsequent projections or pattern matches dereference null → **SIGSEGV**

**Secondary Cause: List Kernel Stubs**

Many List.* kernel functions are still stubs (`assert(false)` or returning garbage):
- `List.map`, `List.filter`, `List.foldl`, `List.foldr` may hit these stubs
- When assertions are disabled, these return uninitialized values
- These garbage values are later dereferenced → **SIGSEGV**

**Contributing Factors:**
- Incorrect `max_values` in closure metadata (e.g., using captured count vs. full arity)
- Wrong `remaining_arity` annotations causing incorrect dispatch between `papExtend` and `closure_call_saturated`
- Off-by-one errors in curried function handling

---

## Category 2: SIGABRT (Assertion Failures) - 8 Tests

### Affected Tests

**Subgroup A: Tag_Custom assertion (6 tests)**
- CustomTypeMultiFieldTest.elm
- ListHeadTailTest.elm
- MaybeAndThenTest.elm
- MaybeMapTest.elm
- ResultAndThenTest.elm
- ResultMapTest.elm

**Subgroup B: MLIR Block terminator assertion (1 test)**
- CaseListTest.elm

**Subgroup C: Heap pointer bounds assertion (1 test)**
- CompositionTest.elm

### Root Cause Analysis

#### Subgroup A: `header->tag == Tag_Custom` Assertion

**Location:** `RuntimeExports.cpp:1543` in `print_typed_value()`

**Cause:** Type graph says the value is `EcoTypeKind::Custom`, but the actual heap object has a different tag.

Possible reasons:
1. **Single-constructor wrappers erased by DT.Unbox**: The wrapper is eliminated at runtime but still registered as Custom in the type graph
2. **Wrong type_id passed to eco.dbg**: The MLIR backend picks wrong `Mono.MonoType` when recording `arg_type_ids`
3. **Closure call encoding bug**: `eco_closure_call_saturated` returns raw pointer bits instead of proper HPointer, corrupting subsequent value interpretation

These tests use `List.head`, `Maybe.map`, `Maybe.andThen`, `Result.map`, `Result.andThen` - all return custom types (Maybe/Result) and flow through higher-order functions.

#### Subgroup B: `mightHaveTerminator()` Assertion

**Location:** `Block.cpp:245` (MLIR library)

**Cause:** A basic block in the generated MLIR doesn't have a proper terminator operation. This is a codegen bug in the case expression lowering for list patterns.

#### Subgroup C: Pointer Bounds Assertion

**Location:** `Allocator.cpp:372` - `"Pointer above heap end"`

**Cause:** A value is being treated as a heap pointer but the address falls outside the reserved heap region. This indicates either:
- A corrupted HPointer value (garbage bits)
- A raw pointer accidentally treated as heap offset
- Result of closure runtime returning garbage

---

## Category 3: JIT Lowering Pipeline Failed - 4 Tests

### Affected Tests

**Subgroup A: cf.br legalization failure (2 tests)**
- CaseIntTest.elm
- CaseManyBranchesTest.elm

**Subgroup B: Missing global reference (1 test)**
- RecordAccessorFunctionTest.elm

### Root Cause Analysis

#### Subgroup A: `failed to legalize operation 'cf.br'`

**Cause:** During case expression lowering, `eco.case` is converted to control flow with `cf.br` (branch) operations. The LLVM dialect conversion then fails because `cf.br` is marked illegal but no conversion pattern removes it.

This suggests the ECO case lowering doesn't fully convert case expressions to LLVM IR when the case scrutinizes integers (vs. custom types).

#### Subgroup B: `llvm.mlir.addressof` Must Reference Defined Global

**Error:** `'llvm.mlir.addressof' op must reference a global defined by 'llvm.mlir.global', 'llvm.mlir.alias' or 'llvm.func'`

**Cause:** In RecordAccessorFunctionTest.mlir, the code references:
```mlir
%25 = "eco.papCreate"() {arity = 1, function = @accessor_name, num_captured = 0}
```

But `@accessor_name` and `@accessor_x` are never defined in the module. The Elm compiler failed to generate the accessor function definitions.

---

## Category 4: JIT LLVM Translation Failed - 3 Tests

### Affected Tests
- ComparableMinMaxTest.elm
- FloatMinMaxTest.elm
- IntMinMaxTest.elm

### Root Cause Analysis

**Error:** `LLVM Translation failed for operation: builtin.unrealized_conversion_cast`

**Cause:** The `scf.if` operation is used with `!eco.value` result types:

```mlir
%3 = "scf.if"(%2) ({
      "scf.yield"(%x) {_operand_types = [!eco.value]} : (!eco.value) -> ()
}, {
      "scf.yield"(%y) {_operand_types = [!eco.value]} : (!eco.value) -> ()
}) {_operand_types = [i1]} : (i1) -> !eco.value
```

The SCF-to-LLVM conversion doesn't know how to handle `!eco.value` types, so it inserts `unrealized_conversion_cast` operations that aren't resolved before LLVM translation.

This affects `Basics.min` and `Basics.max` which use conditional expressions internally.

---

## Category 5: MLIR Parse Failed - 1 Test

### Affected Test
- ListTakeDropTest.elm

### Root Cause Analysis

**Error:** `use of value '%13' expects different type than prior uses: 'i64' vs '!eco.value'`

**Location:** Line 184 of generated MLIR

**Cause:** The compiler generates invalid MLIR where a value is defined with one type but used with another:

```mlir
%13 = "eco.constant"() {kind = 1 : i32} : () -> !eco.value
"eco.return"(%13) {_operand_types = [i64]} : (i64) -> ()
```

`%13` is defined as `!eco.value` but the `eco.return` annotation claims it's `i64`. This is a codegen bug in joinpoint/case expression handling.

---

## Category 6: Wrong Output - 17 Tests

### Affected Tests
- CaseCustomTypeTest.elm
- CaseStringTest.elm
- CharUnicodeTest.elm
- HigherOrderTest.elm
- ListEmptyTest.elm
- ListFoldlTest.elm
- ListLengthTest.elm
- ListReverseTest.elm
- MaybeJustTest.elm
- PipelineTest.elm
- RecordUpdateTest.elm
- ResultErrTest.elm
- ResultOkTest.elm
- ResultWithDefaultTest.elm
- TailRecursiveSumTest.elm
- TupleMapFirstTest.elm
- TupleMapSecondTest.elm

### Root Cause Analysis

**Primary Pattern: Integer Values Become 0**

Examples:
- `Just 42` → `Just 0`
- `Ok 42` → `Ok 0`
- `Err 404` → `Err 0`
- `sum: 15` → `sum: 0`

String values work correctly:
- `Just "hello"` → `Just "hello"` ✓
- `Ok "success"` → `Ok "success"` ✓

**Root Cause: Function Signature and unboxed_bitmap Mismatch**

Examining `MaybeJustTest.mlir`:

```mlir
// Call passes i64
%1 = "arith.constant"() {value = 42 : i64} : () -> i64
%2 = "eco.call"(%1) <{_operand_types = [i64], callee = @Maybe_Just_$_1}> : (i64) -> !eco.value

// But function expects !eco.value
"func.func"() ({
    ^bb0(%arg0: !eco.value):  // ← WRONG TYPE!
        %1 = "eco.construct.custom"(%arg0) {unboxed_bitmap = 0} ...
```

The call passes an unboxed `i64`, but the function signature declares `!eco.value`. Additionally, `unboxed_bitmap = 0` means the constructor treats the field as a boxed pointer, not an unboxed integer.

For Bool (which works):
```mlir
// Function correctly takes i1 and uses unboxed_bitmap = 1
"func.func"() ({
    ^bb0(%arg0: i1):
        %1 = "eco.construct.custom"(%arg0) {unboxed_bitmap = 1} ...
```

**Secondary Pattern: Value 65 Appears**

- `mapFirst1: (2, 10)` → `(65, 10)`
- `mapSecond1: (1, 20)` → `(1, 65)`

65 is ASCII 'A'. This suggests the value being passed is somehow being misinterpreted, possibly due to:
- Wrong calling convention for the mapping function
- Closure captured value corruption
- Pointer arithmetic error

---

## Summary and Recommendations

### High Priority Fixes

1. **Closure/PAP Runtime**
   - Implement `eco_apply_closure` properly (currently returns 0)
   - Change error returns from 0 to a crash/abort (0 is a valid heap offset)
   - Add better arity checking and error messages

2. **Codegen Function Signatures**
   - Fix signature generation for monomorphized custom type constructors
   - Ensure unboxed types (i64, i16, i1) match between call site and function definition
   - Ensure `unboxed_bitmap` correctly reflects which fields are unboxed

3. **Case Expression Lowering**
   - Add conversion pattern for `cf.br` to LLVM
   - Fix joinpoint return type generation
   - Ensure block terminators are always generated

4. **SCF-to-LLVM Conversion**
   - Add type conversion for `!eco.value` in `scf.if` results
   - Or avoid using `scf.if` with eco types, use explicit `cf.cond_br` instead

### Medium Priority Fixes

5. **Accessor Function Generation**
   - Ensure record accessor functions are actually emitted
   - Fix `eco.papCreate` references to non-existent functions

6. **Type Graph Accuracy**
   - Handle single-constructor wrapper types correctly
   - Ensure type_ids passed to eco.dbg match actual runtime representation

### Testing Improvements

7. Add more granular test categories to isolate issues
8. Add compiler-level MLIR validation before JIT execution
9. Add runtime assertions with better error messages (not just returning 0)
