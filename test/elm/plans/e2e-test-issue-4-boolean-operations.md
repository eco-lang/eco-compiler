# E2E Test Issue 4: Boolean Operations Return Wrong Results

## Affected Tests (6)

- BoolAndTest.elm
- BoolNotTest.elm
- BoolOrTest.elm
- BoolShortCircuitTest.elm
- BoolXorTest.elm

## Analysis

### Symptom
Boolean operations return incorrect results. For example:
```
Expected: and2: False
Actual:   and2: True

Expected: not2: True
Actual:   not2: False
```

All boolean operations seem to return `True` regardless of input.

### Root Cause
The kernel functions expect `int64_t` with simple 0/1 encoding, but the generated code boxes booleans and passes pointers.

Generated MLIR for `BoolAndTest`:
```mlir
%1 = "arith.constant"() {value = true} : () -> i1          // i1 boolean
%2 = "arith.constant"() {value = false} : () -> i1         // i1 boolean
%3 = "eco.call"(%1, %2) <{callee = @Basics_and_$_1}> : (i1, i1) -> i1

// Basics_and_$_1 wrapper:
^bb0(%arg0: i1, %arg1: i1):
  %2 = "eco.box"(%arg0) : (i1) -> !eco.value   // Box the i1
  %3 = "eco.box"(%arg1) : (i1) -> !eco.value   // Box the i1
  %4 = "eco.call"(%2, %3) <{callee = @Elm_Kernel_Basics_and}> : (!eco.value, !eco.value) -> i1
```

The kernel function at `BasicsExports.cpp:115`:
```cpp
int64_t Elm_Kernel_Basics_and(int64_t a, int64_t b) {
    return Export::encodeBool(Basics::and_(Export::decodeBool(a), Export::decodeBool(b)));
}
```

Where:
```cpp
inline bool decodeBool(int64_t val) {
    return val != 0;  // Any non-zero is true!
}
```

### The Problem Chain

1. Compiler generates `i1` boolean constants (`true`/`false`)
2. Wrapper boxes them with `eco.box`, creating heap pointers
3. Kernel receives the **pointer values** (large non-zero integers like `0x7fff12345678`)
4. `decodeBool()` sees non-zero and returns `true`
5. Both `a` and `b` are always "true" from kernel's perspective
6. Result is always based on `and_(true, true)`, `or_(true, true)`, etc.

### Why This Produces Wrong Results

| Operation | Inputs (as seen by kernel) | Result |
|-----------|---------------------------|--------|
| `True && False` | `(non-zero, non-zero)` = `(true, true)` | `True` (wrong!) |
| `not False` | `(non-zero)` = `(true)` | `False` (wrong!) |
| `True xor True` | `(true, true)` | `False` (correct by accident) |

## Proposed Solution

### Option A: Pass Booleans as Unboxed i64 (Recommended)

Don't box booleans at all. Pass them directly as `i64` with 0/1 values:

```mlir
// BEFORE (broken):
%1 = "arith.constant"() {value = true} : () -> i1
%2 = "eco.box"(%1) : (i1) -> !eco.value
%3 = "eco.call"(%2, ...) <{callee = @Elm_Kernel_Basics_and}>

// AFTER (fixed):
%1 = "arith.constant"() {value = 1 : i64} : () -> i64      // Use i64, not i1
%2 = "eco.call"(%1, %arg2) <{callee = @Elm_Kernel_Basics_and}> : (i64, i64) -> i64
```

Changes needed:
1. Compiler emits `i64` constants (1 for True, 0 for False) instead of `i1`
2. Remove boxing for boolean values
3. Direct calls to kernel with unboxed values

### Option B: Inline Boolean Operations

Don't call kernel functions for simple boolean ops. Generate LLVM directly:

```mlir
// For (a && b):
%result = "arith.andi"(%a, %b) : (i64, i64) -> i64

// For (not a):
%one = "arith.constant"() {value = 1 : i64} : () -> i64
%result = "arith.xori"(%a, %one) : (i64, i64) -> i64

// For (a || b):
%result = "arith.ori"(%a, %b) : (i64, i64) -> i64

// For (a xor b):
%result = "arith.xori"(%a, %b) : (i64, i64) -> i64
```

This is more efficient and avoids the calling convention issues entirely.

### Option C: Fix eco.box for Booleans

Make `eco.box` for `i1` produce `i64` directly, not a heap allocation:

```mlir
// eco.box for i1 should lower to:
%extended = "arith.extui"(%bool_i1) : (i1) -> i64
// Return the i64 directly, not a pointer
```

## Implementation Steps

### For Option A:
1. **Change boolean constant emission** from `i1` to `i64`
2. **Remove eco.box for booleans** in the wrapper functions
3. **Ensure kernel functions receive i64** directly
4. **Update Debug.log** to handle i64 booleans (print "True"/"False")

### For Option B:
1. **Add pattern matching** in compiler for boolean operations
2. **Emit arith ops** instead of function calls
3. **Still need to handle Debug.log** for display

### For Option C:
1. **Modify eco.box lowering** to detect i1 input type
2. **Emit zero-extend** instead of heap allocation
3. **Ensure !eco.value can represent unboxed integers**

## Recommended Approach

**Combine Options A and B:**
- Use `i64` for all boolean values
- Inline simple boolean operations (and, or, not, xor)
- Keep kernel functions for complex operations if any
- Ensure consistent representation throughout

## Files to Modify

- Compiler codegen for boolean literals
- Compiler codegen for boolean operations (&&, ||, not, xor)
- MLIR lowering for eco.box (if keeping it)
- Wrapper function generation in compiler

## Test Verification

After fix, verify:
```
and1: True   (True && True)
and2: False  (True && False)
and3: False  (False && True)
and4: False  (False && False)

not1: False  (not True)
not2: True   (not False)

xor1: False  (True xor True)
xor2: True   (True xor False)
xor3: True   (False xor True)
xor4: False  (False xor False)
```

## Estimated Complexity

Low-Medium - Focused fix on boolean handling, but need to ensure consistency across all boolean usage sites.
