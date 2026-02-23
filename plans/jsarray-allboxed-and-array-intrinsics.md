# JsArray AllBoxed ABI + eco.array.* Intrinsics

## Problem

JsArray kernel functions have typed C ABI signatures (e.g., `uint32_t` index params, `uint32_t` return for `length`) but the MLIR codegen uses `ElmDerived` policy, deriving types from the monomorphized Elm wrapper. Since `Array a` is `MCustom` (not a primitive), element-type arguments resolve to `!eco.value`, while integer arguments like index and length resolve to `i64`. This creates a mismatch with the C++ kernel's `uint32_t` parameters.

Additionally, there's no fast path for primitive array operations — every `unsafeGet`/`unsafeSet`/`length` goes through a kernel call even when the element type is known at compile time.

## Solution Overview

1. **AllBoxed ABI for JsArray kernels** — Make all JsArray C++ exports use uniform `uint64_t` ABI and mark them `AllBoxed` in the compiler. This eliminates signature mismatches.
2. **eco.array.* intrinsics** — Add `eco.array.get`, `eco.array.set`, `eco.array.length` to the Eco MLIR dialect. When element types are statically known, the compiler emits these intrinsics instead of kernel calls, and EcoToLLVM lowers them to direct heap access.

## Questions

### Q1: Which JsArray functions get intrinsics vs just AllBoxed?

Only `length`, `unsafeGet`, and `unsafeSet` get intrinsic treatment. These are the hot-path element-access operations where avoiding a function call matters. All other JsArray functions (`push`, `slice`, `appendN`, `map`, `foldl`, `foldr`, `initialize`, `initializeFromList`, `indexedMap`, `singleton`, `empty`) remain as AllBoxed kernel calls — they're inherently O(n) or involve closures, so call overhead is negligible.

### Q2: Should `eco.array.set` clone the array inline or call a runtime helper?

Call a runtime helper (`eco_clone_array`). Array cloning involves allocation (which may trigger GC), memcpy of variable-length data, and header setup. Inlining this would bloat MLIR and duplicate GC-integration logic. The helper clones the array, then the intrinsic lowering does a single store into the clone. This matches how `eco.construct.record` calls `eco_alloc_record`.

### Q3: What about the `header.unboxed` flag in `eco.array.get` lowering?

For the intrinsic path, the element type is known at compile time from monomorphization. If the result type is primitive (i64/f64/i16), we know the array stores unboxed elements and can read directly. If the result type is `!eco.value`, elements are boxed pointers. We don't need to check `header.unboxed` at runtime — the type system already tells us. The AllBoxed kernel fallback handles the general case (unknown/mixed types at the kernel level).

### Q4: Does `eco.array.get` need HPointer resolution?

Yes. The array argument arrives as `!eco.value` (HPointer). Like all heap projection ops (`eco.project.record`, `eco.project.list_head`, etc.), we must resolve the HPointer to a raw pointer before GEP. This follows the existing pattern in `EcoToLLVMHeap.cpp`.

---

## Phase 1: AllBoxed C++ ABI for JsArray

### Step 1.1: Update JsArray C++ exports to uniform `uint64_t`

**Files:**
- `elm-kernel-cpp/src/KernelExports.h`
- `elm-kernel-cpp/src/core/JsArrayExports.cpp`

**Current signatures with typed params:**
```cpp
uint32_t Elm_Kernel_JsArray_length(uint64_t array);                          // returns uint32_t
uint64_t Elm_Kernel_JsArray_unsafeGet(uint32_t index, uint64_t array);       // uint32_t index
uint64_t Elm_Kernel_JsArray_unsafeSet(uint32_t index, uint64_t value, uint64_t array); // uint32_t index
uint64_t Elm_Kernel_JsArray_slice(int64_t start, int64_t end, uint64_t array); // int64_t params
uint64_t Elm_Kernel_JsArray_appendN(uint32_t n, uint64_t dest, uint64_t source); // uint32_t n
uint64_t Elm_Kernel_JsArray_initialize(uint32_t size, uint32_t offset, uint64_t closure); // uint32_t params
uint64_t Elm_Kernel_JsArray_initializeFromList(uint32_t max, uint64_t list);  // uint32_t max
uint64_t Elm_Kernel_JsArray_indexedMap(uint64_t closure, uint32_t offset, uint64_t array); // uint32_t offset
```

**New signatures (all `uint64_t`):**
```cpp
uint64_t Elm_Kernel_JsArray_length(uint64_t array);
uint64_t Elm_Kernel_JsArray_unsafeGet(uint64_t index, uint64_t array);
uint64_t Elm_Kernel_JsArray_unsafeSet(uint64_t index, uint64_t value, uint64_t array);
uint64_t Elm_Kernel_JsArray_slice(uint64_t start, uint64_t end, uint64_t array);
uint64_t Elm_Kernel_JsArray_appendN(uint64_t n, uint64_t dest, uint64_t source);
uint64_t Elm_Kernel_JsArray_initialize(uint64_t size, uint64_t offset, uint64_t closure);
uint64_t Elm_Kernel_JsArray_initializeFromList(uint64_t max, uint64_t list);
uint64_t Elm_Kernel_JsArray_indexedMap(uint64_t closure, uint64_t offset, uint64_t array);
```

**Implementation changes in JsArrayExports.cpp:**

For integer params that were `uint32_t`/`int64_t`, the new `uint64_t` parameter is a **boxed Elm Int** (`!eco.value` = HPointer to ElmInt). We must unbox:
```cpp
// Helper: unbox a boxed Elm Int (eco.value) to int64_t
static int64_t unboxInt(uint64_t val) {
    void* ptr = Export::toPtr(val);
    ElmInt* elmInt = static_cast<ElmInt*>(ptr);
    return elmInt->value;
}

// Helper: box an int64_t as an Elm Int (eco.value)
static uint64_t boxInt(int64_t val) {
    HPointer h = alloc::allocInt(val);
    return Export::encode(h);
}
```

Functions that change:
- **`length`**: Returns `boxInt(len)` instead of raw `uint32_t`
- **`unsafeGet`**: `index = unboxInt(index_val)` instead of raw `uint32_t`
- **`unsafeSet`**: `index = unboxInt(index_val)` instead of raw `uint32_t`
- **`slice`**: `start = unboxInt(start_val)`, `end = unboxInt(end_val)`
- **`appendN`**: `n = unboxInt(n_val)`
- **`initialize`**: `size = unboxInt(size_val)`, `offset = unboxInt(offset_val)`
- **`initializeFromList`**: `max = unboxInt(max_val)`
- **`indexedMap`**: `offset = unboxInt(offset_val)`

Functions that DON'T change (already all `uint64_t`):
- `empty`, `singleton`, `push`, `map`, `foldl`, `foldr`

### Step 1.2: Mark JsArray as AllBoxed in compiler

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

In `kernelBackendAbiPolicy`, add JsArray to AllBoxed:
```elm
( "JsArray", _ ) ->
    AllBoxed
```

This goes alongside the existing `( "List", _ ) -> AllBoxed` and `( "Utils", _ ) -> AllBoxed`.

**Effect:** All JsArray kernel calls at MLIR level will use `!eco.value` for every argument and return, matching the new uniform C++ ABI. The `registerKernelCall` signature check will never see mismatches regardless of monomorphized element types.

---

## Phase 2: eco.array.* MLIR Ops

### Step 2.1: Add op definitions to Ops.td

**File:** `runtime/src/codegen/Ops.td`

Add after the existing construction/projection section (around line 710, before StringLiteralOp) or at the end of the data structure ops section:

```tablegen
//===----------------------------------------------------------------------===//
// 10. Array operations (ElmArray intrinsics)
//===----------------------------------------------------------------------===//

def Eco_ArrayGetOp : Eco_Op<"array.get", [Pure]> {
  let summary = "Get element from Elm array by index";
  let description = [{
    Load element at index from an ElmArray. The result type is determined
    by the monomorphized element type:
    - i64 for Int elements (read unboxed from elements[])
    - f64 for Float elements (bitcast from i64 in elements[])
    - i16 for Char elements (truncate from i64 in elements[])
    - !eco.value for boxed elements (pointer from elements[])

    No bounds checking is performed (mirrors JsArray.unsafeGet semantics).
  }];
  let arguments = (ins Eco_Value:$array, Eco_Int:$index);
  let results = (outs Eco_AnyValue:$result);
  let assemblyFormat = "$array `[` $index `]` attr-dict `:` type($result)";
}

def Eco_ArraySetOp : Eco_Op<"array.set"> {
  let summary = "Functional update of Elm array element";
  let description = [{
    Return a new ElmArray with element at index replaced by value.
    Allocates a new array (Elm arrays are immutable). The value type
    determines how it's stored in elements[]:
    - i64 stored directly
    - f64 bitcast to i64
    - i16 zero-extended to i64
    - !eco.value stored as pointer bits

    No bounds checking (mirrors JsArray.unsafeSet semantics).
  }];
  let arguments = (ins Eco_Value:$array, Eco_Int:$index, Eco_AnyValue:$value);
  let results = (outs Eco_Value:$result);
  let assemblyFormat =
    "$array `[` $index `]` `=` $value attr-dict `:` type($value)";
}

def Eco_ArrayLengthOp : Eco_Op<"array.length", [Pure]> {
  let summary = "Get length of Elm array";
  let description = [{
    Read the length field from an ElmArray header. Returns the count
    of elements currently in use (not capacity).
  }];
  let arguments = (ins Eco_Value:$array);
  let results = (outs Eco_Int:$result);
  let assemblyFormat = "$array attr-dict";
}
```

### Step 2.2: C++ op class registration

**Files:**
- `runtime/src/codegen/Eco/EcoDialect.cpp` (or wherever ops are registered)
- `runtime/src/codegen/Eco/EcoOps.h` (auto-generated from Ops.td via tablegen)

After running tablegen, the C++ op classes `eco::ArrayGetOp`, `eco::ArraySetOp`, `eco::ArrayLengthOp` are auto-generated. No manual C++ class code needed beyond what tablegen produces.

---

## Phase 3: EcoToLLVM Lowering

### Step 3.1: Add runtime helper for array cloning

**File:** `runtime/src/allocator/HeapHelpers.hpp` (or new file, or inline in EcoToLLVM)

We need a C-linkage runtime function that `eco.array.set` lowering can call:
```cpp
extern "C" uint64_t eco_clone_array(uint64_t array_val);
```

This function:
1. Resolves the source ElmArray from the HPointer
2. Allocates a new ElmArray with the same capacity
3. Copies header flags (including `unboxed`), length, and all elements
4. Returns the new array as an encoded HPointer

Alternatively, reuse the existing `alloc::allocArray` + manual memcpy in the lowering pattern itself (calling `eco_alloc_array` which already exists for `eco.allocate`). The decision depends on whether a dedicated helper or inline LLVM ops is cleaner. A helper is recommended to avoid duplicating GC-safe allocation logic.

### Step 3.2: Lower eco.array.length

**File:** `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` (alongside other heap projection patterns)

Pattern: `ConvertArrayLengthOp`
1. Resolve HPointer → raw pointer (call `eco_resolve_hptr`, same as other projection ops)
2. GEP to `ElmArray.length` field at byte offset 8 (after 8-byte Header)
3. Load `i32`
4. Zero-extend to `i64` (Elm Int)
5. Replace op with the `i64` result

This mirrors `ConvertListHeadOp` / `ConvertRecordProjectOp` patterns.

### Step 3.3: Lower eco.array.get

**File:** `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`

Pattern: `ConvertArrayGetOp`
1. Resolve HPointer → raw pointer
2. GEP to `elements[0]` at byte offset 16 (Header:8 + length:4 + padding:4)
3. GEP by index: `elements_base + index * 8`
4. Load `i64` (Unboxable is 8 bytes)
5. Interpret based on result type:
   - `!eco.value` → use raw `i64` as pointer bits (no conversion)
   - `i64` (Int) → use raw `i64` directly
   - `f64` (Float) → `bitcast i64 → f64`
   - `i16` (Char) → `trunc i64 → i16`
   - `i1` (Bool) → should not occur (Bool arrays use `!eco.value`)

### Step 3.4: Lower eco.array.set

**File:** `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`

Pattern: `ConvertArraySetOp`
1. Call `eco_clone_array(array)` → get new array HPointer
2. Resolve new array HPointer → raw pointer
3. GEP to `elements[index]` (same offset calculation as get)
4. Normalize value to `i64` based on input type:
   - `!eco.value` → use raw `i64` pointer bits
   - `i64` (Int) → use directly
   - `f64` (Float) → `bitcast f64 → i64`
   - `i16` (Char) → `zext i16 → i64`
5. Store `i64` at element slot
6. Return new array as `!eco.value`

### Step 3.5: Register patterns

In the pattern population function (wherever `EcoToLLVMHeap.cpp` patterns are added):
```cpp
patterns.add<ConvertArrayLengthOp, ConvertArrayGetOp, ConvertArraySetOp>(
    converter, context);
```

---

## Phase 4: Intrinsic Detection in Compiler

### Step 4.1: Extend Intrinsic type

**File:** `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm`

Add three new constructors:
```elm
type Intrinsic
    = UnaryInt { op : String }
    | BinaryInt { op : String }
    -- ... existing ...
    | ConstantFloat { value : Float }
    | ArrayGet { elementMlirType : MlirType }
    | ArraySet { elementMlirType : MlirType }
    | ArrayLength
```

`ArrayGet` and `ArraySet` carry the MLIR element type (I64, F64, I16, or EcoValue) so that `generateIntrinsicOp` and `intrinsicResultMlirType` can use it. `ArrayLength` needs no extra info (always returns I64).

### Step 4.2: Add intrinsicOperandTypes cases

```elm
ArrayGet _ ->
    [ Types.ecoValue, I64 ]  -- array : !eco.value, index : i64

ArraySet _ ->
    [ Types.ecoValue, I64, Types.ecoValue ]  -- array, index, value
    -- Note: value type doesn't matter for unboxing; we pass it as-is

ArrayLength ->
    [ Types.ecoValue ]  -- array : !eco.value
```

Actually, `unboxArgsForIntrinsic` only needs to ensure the index is `i64` (not boxed). The array stays as `!eco.value`. The value for `ArraySet` can remain as whatever SSA type it has — the MLIR op accepts `Eco_AnyValue`.

### Step 4.3: Add intrinsicResultMlirType cases

```elm
ArrayGet { elementMlirType } ->
    elementMlirType  -- i64, f64, i16, or !eco.value depending on element type

ArraySet _ ->
    Types.ecoValue  -- always returns boxed array

ArrayLength ->
    I64  -- Elm Int
```

### Step 4.4: Add generateIntrinsicOp cases

```elm
ArrayGet { elementMlirType } ->
    case argVars of
        [ arrayVar, indexVar ] ->
            -- eco.array.get %array[%index] : <elementMlirType>
            Ops.ecoArrayGet ctx resultVar arrayVar indexVar elementMlirType

        _ ->
            -- error fallback
            ...

ArraySet { elementMlirType } ->
    case argVars of
        [ arrayVar, indexVar, valueVar ] ->
            -- eco.array.set %array[%index] = %value : <elementMlirType>
            Ops.ecoArraySet ctx resultVar arrayVar indexVar valueVar elementMlirType

        _ ->
            ...

ArrayLength ->
    case argVars of
        [ arrayVar ] ->
            Ops.ecoArrayLength ctx resultVar arrayVar

        _ ->
            ...
```

We'll need to add `ecoArrayGet`, `ecoArraySet`, `ecoArrayLength` helpers to `Ops.elm` that construct the appropriate MlirOp records.

### Step 4.5: Add Ops.elm helpers

**File:** `compiler/src/Compiler/Generate/MLIR/Ops.elm`

```elm
ecoArrayGet : Context -> String -> String -> String -> MlirType -> ( Context, MlirOp )
ecoArrayGet ctx resultVar arrayVar indexVar elementType =
    -- Produces: %result = eco.array.get %array[%index] : <elementType>
    mlirOp ctx "eco.array.get"
        |> opBuilder.withOperands [ arrayVar, indexVar ]
        |> opBuilder.withResults [ ( resultVar, elementType ) ]
        |> opBuilder.withAttrs
            (Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr Types.ecoValue, TypeAttr I64 ]))
        |> opBuilder.build

ecoArraySet : Context -> String -> String -> String -> String -> MlirType -> ( Context, MlirOp )
ecoArraySet ctx resultVar arrayVar indexVar valueVar valueType =
    -- Produces: %result = eco.array.set %array[%index] = %value : <valueType>
    mlirOp ctx "eco.array.set"
        |> opBuilder.withOperands [ arrayVar, indexVar, valueVar ]
        |> opBuilder.withResults [ ( resultVar, Types.ecoValue ) ]
        |> opBuilder.withAttrs
            (Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr Types.ecoValue, TypeAttr I64, TypeAttr valueType ]))
        |> opBuilder.build

ecoArrayLength : Context -> String -> String -> ( Context, MlirOp )
ecoArrayLength ctx resultVar arrayVar =
    -- Produces: %result = eco.array.length %array
    mlirOp ctx "eco.array.length"
        |> opBuilder.withOperands [ arrayVar ]
        |> opBuilder.withResults [ ( resultVar, I64 ) ]
        |> opBuilder.withAttrs
            (Dict.singleton "_operand_types"
                (ArrayAttr Nothing [ TypeAttr Types.ecoValue ]))
        |> opBuilder.build
```

### Step 4.6: Add kernelIntrinsic dispatch for JsArray

**File:** `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm`

Extend `kernelIntrinsic`:
```elm
kernelIntrinsic home name argTypes resultType =
    case home of
        "Basics" -> basicsIntrinsic name argTypes resultType
        "Bitwise" -> bitwiseIntrinsic name argTypes resultType
        "Utils" -> utilsIntrinsic name argTypes resultType
        "JsArray" -> jsArrayIntrinsic name argTypes resultType
        _ -> Nothing
```

Define `jsArrayIntrinsic`:
```elm
jsArrayIntrinsic : Name.Name -> List Mono.MonoType -> Mono.MonoType -> Maybe Intrinsic
jsArrayIntrinsic name argTypes resultType =
    case name of
        "length" ->
            -- JsArray.length : Array a -> Int
            -- argTypes = [ MCustom _ "Array" [_] ], resultType = MInt
            case resultType of
                Mono.MInt ->
                    Just ArrayLength
                _ ->
                    Nothing

        "unsafeGet" ->
            -- JsArray.unsafeGet : Int -> Array a -> a
            -- argTypes = [ MInt, MCustom _ "Array" [elt] ], resultType = elt
            case argTypes of
                [ Mono.MInt, _ ] ->
                    Just (ArrayGet { elementMlirType = Types.monoTypeToAbi resultType })
                _ ->
                    Nothing

        "unsafeSet" ->
            -- JsArray.unsafeSet : Int -> a -> Array a -> Array a
            -- argTypes = [ MInt, elt, MCustom _ "Array" [elt] ]
            case argTypes of
                [ Mono.MInt, elt, _ ] ->
                    Just (ArraySet { elementMlirType = Types.monoTypeToAbi elt })
                _ ->
                    Nothing

        _ ->
            Nothing
```

**Key design decision:** We don't need to pattern-match on `MCustom _ "Array" [elt]` to extract the element type. For `unsafeGet`, the result type IS the element type. For `unsafeSet`, the second argument IS the element type. We just check that the first argument is `MInt` (the index) and derive the MLIR element type from the appropriate MonoType. This is simpler and more robust than trying to destructure the Array type.

### Step 4.7: Unboxing for array intrinsics

The existing `unboxArgsForIntrinsic` mechanism handles this automatically:
- `intrinsicOperandTypes ArrayLength = [ ecoValue ]` — array stays boxed, no unboxing
- `intrinsicOperandTypes (ArrayGet _) = [ ecoValue, I64 ]` — array stays boxed, index unboxed to i64 if needed
- `intrinsicOperandTypes (ArraySet _) = [ ecoValue, I64, <elementMlirType> ]` — array stays, index unboxed, value stays as-is

For `ArraySet`, the value operand type in `intrinsicOperandTypes` should be the element MLIR type. If the value arrives as `!eco.value` but the element type is `i64`, we need to unbox it. The existing fold in `unboxArgsForIntrinsic` already handles this: it compares actual SSA type vs expected type and inserts `eco.unbox` when needed.

```elm
ArraySet { elementMlirType } ->
    [ Types.ecoValue, I64, elementMlirType ]
```

---

## Phase 5: Integration with Existing Call Dispatch

### How it all fits together

In `Expr.elm`, the kernel call dispatch (around lines 2263-2368) works as:

1. **First**: Try `Intrinsics.kernelIntrinsic` — if JsArray.length/unsafeGet/unsafeSet matches, emit `eco.array.*` op directly. No kernel call, no `registerKernelCall`.

2. **Fallback**: If `kernelIntrinsic` returns `Nothing` (e.g., for `push`, `map`, `foldl`, or if the type pattern doesn't match), fall through to the `AllBoxed` kernel call path. This generates `eco.call @Elm_Kernel_JsArray_*` with all `!eco.value` args/return.

This means:
- Hot-path ops (get/set/length) with known element types → fast intrinsics
- Everything else → correct AllBoxed kernel calls
- No signature mismatches possible

### Call site at line ~1855 (core module path)

The other intrinsic call site (around line 1858) handles `maybeCoreInfo` — this is for functions like `Basics.add` that have both an Elm wrapper and a kernel. JsArray functions are NOT core module functions — they're accessed via `MonoVarKernel`, not `MonoVarGlobal` with a core info annotation. So the relevant dispatch is the one at line 2264, which handles the `MonoVarKernel` path.

**Verification needed:** Confirm that JsArray calls go through the `MonoVarKernel` path (line 2263+) rather than the core module path (line 1855+). If they go through the core path, the intrinsic dispatch needs to be added there too.

---

## Testing Plan

### Unit tests (Elm compiler)
- Add cases to existing intrinsic tests verifying that `jsArrayIntrinsic` returns correct `Intrinsic` variants for known types
- Verify that non-matching types (e.g., `length` with non-Int result) return `Nothing`

### MLIR output tests
- Verify that `eco.array.get`, `eco.array.set`, `eco.array.length` ops appear in generated MLIR for simple Array programs
- Verify that non-intrinsic JsArray calls (e.g., `map`) still generate `eco.call @Elm_Kernel_JsArray_map` with all `!eco.value` types

### E2E tests
```bash
# After C++ changes:
cmake --build build --target check

# After Elm compiler changes:
cmake --build build --target full

# Filter to array-related tests:
TEST_FILTER=array cmake --build build --target check
```

### Specific test programs
- `Array.get 0 (Array.fromList [1,2,3])` → exercises `eco.array.get : i64`
- `Array.length (Array.fromList [1.0, 2.0])` → exercises `eco.array.length`
- `Array.set 0 42 (Array.fromList [1,2,3])` → exercises `eco.array.set : i64`
- `Array.map (\x -> x + 1) arr` → exercises AllBoxed kernel fallback for `map`

---

## File Change Summary

| File | Change Type | Phase |
|------|------------|-------|
| `elm-kernel-cpp/src/KernelExports.h` | Modify signatures | 1.1 |
| `elm-kernel-cpp/src/core/JsArrayExports.cpp` | Box/unbox in implementations | 1.1 |
| `compiler/src/Compiler/Generate/MLIR/Context.elm` | Add JsArray → AllBoxed | 1.2 |
| `runtime/src/codegen/Ops.td` | Add 3 array op definitions | 2.1 |
| `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` | Add 3 lowering patterns | 3.2-3.4 |
| `runtime/src/allocator/HeapHelpers.hpp` (or similar) | Add `eco_clone_array` helper | 3.1 |
| `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm` | Extend Intrinsic type + dispatch | 4.1-4.6 |
| `compiler/src/Compiler/Generate/MLIR/Ops.elm` | Add array op builder helpers | 4.5 |

---

## Implementation Order

1. **Phase 1 first** — AllBoxed ABI is a prerequisite for correctness. Without it, JsArray kernel calls may crash due to signature mismatches.
2. **Phase 2-3 together** — Ops.td and EcoToLLVM lowering are tightly coupled; both must be present for the ops to compile.
3. **Phase 4 last** — Intrinsic detection in the compiler can only be tested once the MLIR ops are lowerable.

Within each phase, the steps are sequential (e.g., can't update JsArrayExports.cpp before knowing the new signatures, can't add lowering patterns before defining the ops).

## Risks and Mitigations

- **Risk**: `eco.array.set` allocation could trigger GC, invalidating pointers. **Mitigation**: The runtime helper handles GC-safe allocation; the lowering just calls the helper and uses the returned pointer.
- **Risk**: JsArray functions that take closures (map, foldl, etc.) have complex ABI where closures must be called correctly. **Mitigation**: These stay as kernel calls — no intrinsic path. The AllBoxed ABI just ensures the closure argument is passed as `!eco.value`.
- **Risk**: MonoType for Array may not always be `MCustom _ "Array" [elt]` if the monomorphizer has edge cases. **Mitigation**: The intrinsic matching doesn't depend on destructuring the Array type — it uses `resultType` (for get) and `argTypes` (for set) to determine element types. If types don't match the expected pattern, `Nothing` is returned and the AllBoxed fallback is used.
