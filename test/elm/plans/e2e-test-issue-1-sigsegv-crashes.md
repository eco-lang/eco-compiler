# E2E Test Issue 1: SIGSEGV Crashes in Comparison/Conversion Functions

## Affected Tests (9)

- BitwiseShiftRightTest.elm
- CompareCharTest.elm
- CompareFloatTest.elm
- CompareIntTest.elm
- CompareStringTest.elm
- ToFloatTest.elm
- TupleMapSecondTest.elm
- TuplePairFuncTest.elm
- TupleTripleTest.elm

## Analysis

### Symptom
Tests crash with `SIGSEGV (Segmentation fault)` during execution.

### Root Cause
The kernel functions like `Elm_Kernel_Utils_compare` expect **boxed heap pointers** encoded as `uint64_t` (representing `HPointer`), but the generated code passes **raw unboxed values** through `eco.box`.

Looking at `CompareIntTest.mlir`:
```mlir
%2 = "eco.box"(%arg0) {_operand_types = [i64]} : (i64) -> !eco.value
%3 = "eco.box"(%arg1) {_operand_types = [i64]} : (i64) -> !eco.value
%4 = "eco.call"(%2, %3) <{callee = @Elm_Kernel_Utils_compare}> : (!eco.value, !eco.value) -> !eco.value
```

The kernel function at `UtilsExports.cpp:12`:
```cpp
uint64_t Elm_Kernel_Utils_compare(uint64_t a, uint64_t b) {
    HPointer result = Utils::compare(Export::toPtr(a), Export::toPtr(b));
    return Export::encode(result);
}
```

The `Export::toPtr(a)` function interprets the value as an `HPointer` structure and attempts to dereference it:
```cpp
inline void* toPtr(uint64_t val) {
    HPointer h = decode(val);
    if (h.constant != 0) return nullptr;
    return reinterpret_cast<void*>(h.ptr);  // Dereferences raw integer as pointer!
}
```

When a raw integer like `1` or `2` is passed, it gets interpreted as a memory address and dereferenced, causing a segfault.

### The Mismatch

| Component | Expectation |
|-----------|-------------|
| Compiler (`eco.box`) | Creates heap-allocated boxed value, returns `!eco.value` |
| Kernel (`Elm_Kernel_Utils_compare`) | Expects `uint64_t` encoding an `HPointer` to a heap object |

The `eco.box` operation allocates a heap object and returns a pointer to it. But `Utils::compare` then tries to read type information from that heap object to determine how to compare - it expects an Int/Float/String/etc heap object, not a generic boxed value.

## Proposed Solution

### Option A: Type-Specific Compare Functions (Recommended)

Create separate kernel functions for each comparable type that take raw values:

```cpp
// In UtilsExports.cpp - add new functions
extern "C" {

int64_t Elm_Kernel_Utils_compareInt(int64_t a, int64_t b) {
    if (a < b) return 0;  // LT tag
    if (a > b) return 2;  // GT tag
    return 1;             // EQ tag
}

int64_t Elm_Kernel_Utils_compareFloat(double a, double b) {
    if (a < b) return 0;  // LT tag
    if (a > b) return 2;  // GT tag
    return 1;             // EQ tag
}

int64_t Elm_Kernel_Utils_compareChar(int32_t a, int32_t b) {
    if (a < b) return 0;
    if (a > b) return 2;
    return 1;
}

// String compare still needs heap pointers
uint64_t Elm_Kernel_Utils_compareString(uint64_t a, uint64_t b) {
    // existing implementation
}

}
```

Then update the compiler to emit calls to the appropriate type-specific function based on the known type at compile time.

### Option B: Fix eco.box to Create Proper Heap Objects

Ensure `eco.box` creates heap objects with proper type tags that `Utils::compare` can interpret:

1. `eco.box` for `i64` should create a heap `Int` object
2. `eco.box` for `f64` should create a heap `Float` object
3. `eco.box` for `i32` (char) should create a heap `Char` object

This requires updating the MLIR lowering to emit proper heap allocation with correct headers.

### Option C: Hybrid Approach

For primitive types (Int, Float, Char), use unboxed comparisons directly in generated code:
```mlir
// Instead of calling kernel, emit inline comparison
%result = arith.cmpi slt, %a, %b : i64
```

For complex types (String, List, Custom), continue using the kernel compare function.

## Implementation Steps

1. **Add type-specific compare functions** to `UtilsExports.cpp`
2. **Update compiler** to emit calls to type-specific functions when type is known
3. **Update eco.box lowering** to handle the Order return type (LT/EQ/GT as tags 0/1/2)
4. **Add tests** for each compare function independently

## Files to Modify

- `elm-kernel-cpp/src/core/UtilsExports.cpp` - Add new compare functions
- `elm-kernel-cpp/src/core/Utils.cpp` - Add implementation
- `compiler/` - Update codegen to use type-specific compares
- MLIR dialect lowering passes

## Estimated Complexity

Medium - Requires changes in both kernel and compiler, but the pattern is clear.
