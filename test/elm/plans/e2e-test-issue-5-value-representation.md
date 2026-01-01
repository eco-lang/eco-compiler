# E2E Test Issue 5: Values Display as Addresses or Wrong Values

## Affected Tests (~40)

- AddTest.elm
- IntAddTest.elm, IntSubTest.elm, IntMulTest.elm, IntDivTest.elm
- FloatAddTest.elm, FloatSubTest.elm, FloatMulTest.elm, FloatDivTest.elm
- CharToCodeTest.elm, CharFromCodeTest.elm
- LetBasicTest.elm, LetMultipleTest.elm, LetNestedTest.elm
- FunctionBasicTest.elm, FunctionMultiArgTest.elm
- RecordCreateTest.elm, RecordAccessTest.elm
- ListLiteralTest.elm, ListEmptyTest.elm, ListConsTest.elm
- MaybeJustTest.elm, ResultOkTest.elm
- And many more...

## Analysis

### Symptom
Tests produce output where expected values are replaced with:
- Large numbers that look like memory addresses (e.g., `140414090739712`)
- Corrupted integers (e.g., `2818572296` instead of `42`)
- `Ctor0` instead of strings or custom type names

Example:
```
Expected: AddTest: 42
Actual:   AddTest: 140414090739712
```

### Root Cause Analysis

#### Issue 5a: Debug.log Return Value Misuse

Looking at `AddTest.mlir`:
```mlir
%result = "eco.construct"(%0) {tag = 0} : (i64) -> !eco.value   // Box 42
%1 = "eco.string_literal"() {value = "AddTest"} : () -> !eco.value
%2 = "eco.box"(%result) : (!eco.value) -> !eco.value            // Double-box?
%3 = "eco.call"(%1, %2) <{callee = @Elm_Kernel_Debug_log}> : (!eco.value, !eco.value) -> i64
%_v0 = "eco.construct"(%3) {tag = 0} : (i64) -> !eco.value      // Construct from return value
```

The `Debug.log` return value (an `i64`) is being used to construct another value. The return value from Debug.log should be the logged value itself (for chaining), but it's being treated as a raw integer.

#### Issue 5b: Double Boxing

Values are sometimes boxed twice:
```mlir
%result = "eco.construct"(%0) : (i64) -> !eco.value   // First box
%2 = "eco.box"(%result) : (!eco.value) -> !eco.value  // Second box (of a pointer!)
```

When you box an already-boxed value, you're boxing the pointer, not the original value.

#### Issue 5c: eco.box Creates Heap Objects, But Values Interpreted as Raw

The `eco.box` operation creates heap-allocated boxed values. But when these pointers are passed to functions or used in Debug.log, they might be interpreted as raw integers.

The display shows the pointer value (e.g., `140414090739712` = `0x7FB1C8000000`) instead of dereferencing it to get the actual value.

#### Issue 5d: Arithmetic Operations Type Mismatch

For `IntAddTest`, the arithmetic kernels expect `double` (for polymorphic add):
```cpp
double Elm_Kernel_Basics_add(double a, double b) {
    return Basics::add(a, b);
}
```

But the compiler might be passing `int64_t` or boxed values. The bit pattern of an integer interpreted as a double gives garbage.

### The Boxing/Unboxing Problem

| Operation | What Happens | Problem |
|-----------|--------------|---------|
| `eco.box(42)` | Creates heap object with value 42, returns pointer | Pointer is large number |
| Pass to kernel | Kernel receives pointer value | Kernel might interpret as integer |
| Return from kernel | Returns pointer or raw value | Caller doesn't know which |
| Display | Prints the number | Shows pointer, not value |

## Proposed Solution

### Step 1: Clarify Value Representation Strategy

Define when to use boxed vs unboxed values:

| Type | Representation | When to Box |
|------|---------------|-------------|
| Int | Unboxed `i64` | Only when storing in polymorphic containers |
| Float | Unboxed `f64` | Only when storing in polymorphic containers |
| Bool | Unboxed `i64` (0/1) | Never (always fits in 64 bits) |
| Char | Unboxed `i32` | Only when storing in polymorphic containers |
| String | Always boxed (pointer) | Always |
| List | Always boxed (pointer) | Always |
| Custom | Always boxed (pointer) | Always |
| Record | Always boxed (pointer) | Always |

### Step 2: Fix Debug.log Implementation

Debug.log should:
1. Accept any value type (boxed or unboxed)
2. Print the value correctly based on its type
3. Return the **same value** (for chaining in let expressions)

```cpp
// In DebugExports.cpp
uint64_t Elm_Kernel_Debug_log(uint64_t tag_ptr, uint64_t value) {
    // Print tag string
    std::string tag = getString(tag_ptr);

    // Print value based on its type
    printValue(value);  // Need type info or tagged pointer

    // Return the value unchanged for chaining
    return value;
}
```

### Step 3: Use Tagged Pointers or Separate Functions

Either:

**Option A: Type-specific Debug.log functions**
```cpp
void Elm_Kernel_Debug_log_Int(uint64_t tag_ptr, int64_t value);
void Elm_Kernel_Debug_log_Float(uint64_t tag_ptr, double value);
void Elm_Kernel_Debug_log_String(uint64_t tag_ptr, uint64_t str_ptr);
void Elm_Kernel_Debug_log_Value(uint64_t tag_ptr, uint64_t value_ptr);  // For boxed values
```

**Option B: NaN-boxing or tagged pointers**
Use a representation where the type can be determined from the value itself:
- Small integers: Store directly with a tag
- Floats: Use NaN-boxing
- Pointers: Ensure they're distinguishable

### Step 4: Fix Arithmetic Operations

For integer arithmetic, use integer-specific kernels:
```cpp
int64_t Elm_Kernel_Basics_addInt(int64_t a, int64_t b) {
    return a + b;
}
```

Or emit inline arithmetic:
```mlir
%result = "arith.addi"(%a, %b) : (i64, i64) -> i64  // Integer add
%result = "arith.addf"(%a, %b) : (f64, f64) -> f64  // Float add
```

### Step 5: Remove Double Boxing

Ensure values are boxed exactly once when needed:
```mlir
// WRONG - double boxing
%1 = "eco.construct"(%0) : (i64) -> !eco.value
%2 = "eco.box"(%1) : (!eco.value) -> !eco.value

// CORRECT - single boxing
%1 = "eco.box"(%0) : (i64) -> !eco.value
```

Or better, don't box primitives at all when calling kernels.

## Implementation Steps

1. **Audit all eco.box usages** - identify double-boxing
2. **Create type-specific Debug.log** or fix the generic one
3. **Create type-specific arithmetic** kernels for Int operations
4. **Update compiler** to emit correct calls based on known types
5. **Fix return value handling** for Debug.log (return input, not status)
6. **Add type inference** in compiler to track when boxing is needed

## Files to Modify

- `elm-kernel-cpp/src/core/DebugExports.cpp` - Fix Debug.log
- `elm-kernel-cpp/src/core/BasicsExports.cpp` - Add int-specific ops
- Compiler codegen for let expressions
- Compiler codegen for function calls
- MLIR eco.box lowering

## Estimated Complexity

High - This is a fundamental calling convention issue that affects most tests. Requires careful coordination between compiler output and kernel expectations.
