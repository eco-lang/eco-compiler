# Plan: Complete elm/core Kernel Functions

## Overview

This plan implements the 12 remaining stubbed kernel functions in `elm/core` (excluding 4 browser-dependent Debugger stubs that intentionally remain unimplemented).

**Current state:** 109/125 functions implemented (87%)
**Target state:** 121/125 functions implemented (97%)

The remaining 4 Debugger stubs (download, open, scroll, upload) require browser APIs and will remain stubbed.

## Functions to Implement

### JsArray Module (6 functions)
| Function | Signature | Description |
|----------|-----------|-------------|
| `initialize` | `(size, offset, closure) -> Array` | Create array by calling `closure(offset + i)` for each index |
| `initializeFromList` | `(max, list) -> Tuple2(Array, List)` | **Already implemented in JsArray.cpp** - just needs export wiring |
| `map` | `(closure, array) -> Array` | Transform each element via `closure(elem)` |
| `indexedMap` | `(closure, offset, array) -> Array` | Transform each element via `closure(offset + i, elem)` |
| `foldl` | `(closure, acc, array) -> acc` | Left fold: `closure(elem, acc)` |
| `foldr` | `(closure, acc, array) -> acc` | Right fold: `closure(elem, acc)` |

### List Module (6 functions)
| Function | Signature | Description |
|----------|-----------|-------------|
| `map2` | `(closure, xs, ys) -> List` | Zip two lists: `closure(x, y)` |
| `map3` | `(closure, xs, ys, zs) -> List` | Zip three lists: `closure(x, y, z)` |
| `map4` | `(closure, ws, xs, ys, zs) -> List` | Zip four lists: `closure(w, x, y, z)` |
| `map5` | `(closure, vs, ws, xs, ys, zs) -> List` | Zip five lists: `closure(v, w, x, y, z)` |
| `sortBy` | `(closure, list) -> List` | Sort by key extracted via `closure(elem)` |
| `sortWith` | `(closure, list) -> List` | Sort by custom comparator `closure(a, b) -> Order` |

## Implementation Pattern

Use the **StringExports pattern** for closure calling - direct `closure->evaluator(args)` calls:

```cpp
// Helper pattern (from StringExports.cpp:142-156)
static ResultType callClosureWithArgs(void* closure_ptr, Arg1 arg1, ...) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    void* args[16];
    // Copy captured values
    for (uint32_t i = 0; i < n_values; i++) {
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    // Add call arguments (pass directly as uint64_t, NO boxing)
    args[n_values] = reinterpret_cast<void*>(arg1);
    // ... more args

    void* result = closure->evaluator(args);
    return interpret_result(result);
}
```

**Key points:**
- Works for **saturated calls only** (closure arity matches argument count)
- **Do NOT box** array elements before passing to closures — pass directly as raw `uint64_t`
- Order type is heap-allocated Custom with ctor tag 0/1/2 for LT/EQ/GT
- List Cons cells have `header.unboxed` flag — check it to determine if head is boxed or unboxed

## Step-by-Step Implementation

### Phase 0: ElmArray Structure Simplification

The current `ElmArray` uses a 64-bit unboxed bitmap, but arrays are **uniform** — either all elements are boxed or all are unboxed. Simplify to a single bit flag.

#### Step 0.1: Update ElmArray in runtime/src/allocator/Heap.hpp

**Before:**
```cpp
typedef struct {
    Header header;     // header.size = capacity (allocated element count)
    u32 length;        // Current number of elements in use
    u32 padding;       // Alignment padding
    u64 unboxed;       // Bitmap: bit N set means elements[N] is unboxed primitive
    Unboxable elements[];  // Flexible array of values (up to 64 elements with unboxing)
} ElmArray;
```

**After:**
```cpp
typedef struct {
    Header header;     // header.size = capacity (allocated element count)
    u32 length;        // Current number of elements in use
    u32 unboxed : 1;   // Flag: 1 = all elements unboxed, 0 = all elements boxed
    u32 padding : 31;  // Alignment padding
    Unboxable elements[];  // Flexible array of values
} ElmArray;
```

#### Step 0.2: Update HeapHelpers functions

Update these functions to use the single-bit flag:
- `arrayIsUnboxed(void*, u32)` → `arrayIsUnboxed(void*)` (no index needed)
- `arrayPush(void*, Unboxable, bool isBoxed)` — set the flag on first push, verify consistency on subsequent pushes
- Any other functions that read/write the `unboxed` field

#### Step 0.3: Update JsArray.cpp and JsArrayExports.cpp

Update all code that uses per-element unboxing to use the uniform flag.

### Phase 1: JsArrayExports Higher-Order Functions

#### Step 1.1: Add closure-calling helpers to JsArrayExports.cpp

Add helpers that pass elements directly (no boxing):
- `callUnaryMapClosure(closure, elem) -> uint64_t` — for `map`
- `callBinaryIndexMapClosure(closure, index, elem) -> uint64_t` — for `indexedMap`
- `callBinaryFoldClosure(closure, elem, acc) -> uint64_t` — for `foldl`/`foldr`
- `callUnaryInitClosure(closure, index) -> uint64_t` — for `initialize`

```cpp
// Example: call closure with one argument (element or index)
static uint64_t callUnaryMapClosure(void* closure_ptr, uint64_t arg) {
    Closure* closure = static_cast<Closure*>(closure_ptr);
    uint32_t n_values = closure->n_values;

    void* args[16];
    for (uint32_t i = 0; i < n_values; i++) {
        args[i] = reinterpret_cast<void*>(closure->values[i].i);
    }
    args[n_values] = reinterpret_cast<void*>(arg);

    return reinterpret_cast<uint64_t>(closure->evaluator(args));
}
```

#### Step 1.2: Implement `Elm_Kernel_JsArray_initialize`

```cpp
uint64_t Elm_Kernel_JsArray_initialize(uint32_t size, uint32_t offset, uint64_t closure) {
    void* closure_ptr = Export::toPtr(closure);
    HPointer arr = alloc::allocArray(size);
    auto& allocator = Allocator::instance();

    for (uint32_t i = 0; i < size; i++) {
        uint64_t value = callUnaryInitClosure(closure_ptr, offset + i);
        void* arrObj = allocator.resolve(arr);
        // Push result (all results are boxed HPointers from closure)
        Unboxable elem;
        elem.p = Export::decode(value);
        alloc::arrayPush(arrObj, elem, true);  // isBoxed=true
    }
    return Export::encode(arr);
}
```

#### Step 1.3: Fix `Elm_Kernel_JsArray_initializeFromList`

JsArray.cpp already has the implementation. The export just needs to call it:

```cpp
uint64_t Elm_Kernel_JsArray_initializeFromList(uint32_t max, uint64_t list) {
    HPointer result = JsArray::initializeFromList(max, Export::decode(list));
    return Export::encode(result);
}
```

#### Step 1.4: Implement `Elm_Kernel_JsArray_map`

```cpp
uint64_t Elm_Kernel_JsArray_map(uint64_t closure, uint64_t array) {
    void* closure_ptr = Export::toPtr(closure);
    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    bool srcUnboxed = src->unboxed;

    HPointer arr = alloc::allocArray(len);
    auto& allocator = Allocator::instance();

    for (uint32_t i = 0; i < len; i++) {
        // Pass element directly as uint64_t (no boxing)
        uint64_t elem = srcUnboxed ? src->elements[i].i
                                   : Export::encode(src->elements[i].p);
        uint64_t result = callUnaryMapClosure(closure_ptr, elem);

        void* arrObj = allocator.resolve(arr);
        Unboxable val;
        val.p = Export::decode(result);
        alloc::arrayPush(arrObj, val, true);  // results are boxed
    }
    return Export::encode(arr);
}
```

#### Step 1.5: Implement `Elm_Kernel_JsArray_indexedMap`

Similar to map but pass `(offset + i, element)` to closure.

#### Step 1.6: Implement `Elm_Kernel_JsArray_foldl`

```cpp
uint64_t Elm_Kernel_JsArray_foldl(uint64_t closure, uint64_t acc, uint64_t array) {
    void* closure_ptr = Export::toPtr(closure);
    void* srcPtr = Export::toPtr(array);
    ElmArray* src = static_cast<ElmArray*>(srcPtr);
    uint32_t len = src->length;
    bool srcUnboxed = src->unboxed;

    uint64_t accumulator = acc;
    for (uint32_t i = 0; i < len; i++) {
        uint64_t elem = srcUnboxed ? src->elements[i].i
                                   : Export::encode(src->elements[i].p);
        accumulator = callBinaryFoldClosure(closure_ptr, elem, accumulator);
    }
    return accumulator;
}
```

#### Step 1.7: Implement `Elm_Kernel_JsArray_foldr`

Same as foldl but iterate right-to-left (`i = len-1` down to `0`).

### Phase 2: ListExports Higher-Order Functions

#### Step 2.1: Update listToVector to handle unboxed Cons heads

The existing `listToVector` must check `header.unboxed` to correctly interpret elements:

```cpp
std::vector<uint64_t> listToVectorU64(HPointer list) {
    std::vector<uint64_t> result;
    Allocator& allocator = Allocator::instance();

    HPointer current = list;
    while (!alloc::isNil(current)) {
        void* ptr = allocator.resolve(current);
        if (!ptr) break;

        Header* hdr = static_cast<Header*>(ptr);
        if (hdr->tag != Tag_Cons) break;

        Cons* cons = static_cast<Cons*>(ptr);
        // Check unboxed flag in header to determine how to interpret head
        if (hdr->unboxed & 1) {
            // Head is unboxed primitive - pass raw i64
            result.push_back(static_cast<uint64_t>(cons->head.i));
        } else {
            // Head is boxed HPointer - encode it
            result.push_back(Export::encode(cons->head.p));
        }
        current = cons->tail;
    }

    return result;
}
```

#### Step 2.2: Add closure-calling helpers to ListExports.cpp

Extend the existing `callClosure` helper or add specialized variants:
- `callBinaryClosure(closure, arg1, arg2) -> uint64_t`
- `callTernaryClosure(closure, arg1, arg2, arg3) -> uint64_t`
- `callQuaternaryClosure(closure, arg1, arg2, arg3, arg4) -> uint64_t`
- `callQuinaryClosure(closure, arg1, arg2, arg3, arg4, arg5) -> uint64_t`

#### Step 2.3: Implement `Elm_Kernel_List_map2`

```cpp
uint64_t Elm_Kernel_List_map2(uint64_t closure, uint64_t xs, uint64_t ys) {
    void* closure_ptr = Export::toPtr(closure);
    HPointer xList = Export::decode(xs);
    HPointer yList = Export::decode(ys);
    auto& allocator = Allocator::instance();

    std::vector<uint64_t> results;

    while (!alloc::isNil(xList) && !alloc::isNil(yList)) {
        Cons* xCons = static_cast<Cons*>(allocator.resolve(xList));
        Cons* yCons = static_cast<Cons*>(allocator.resolve(yList));
        Header* xHdr = &xCons->header;
        Header* yHdr = &yCons->header;

        // Check unboxed flag for each list's head
        uint64_t x = (xHdr->unboxed & 1) ? static_cast<uint64_t>(xCons->head.i)
                                         : Export::encode(xCons->head.p);
        uint64_t y = (yHdr->unboxed & 1) ? static_cast<uint64_t>(yCons->head.i)
                                         : Export::encode(yCons->head.p);

        uint64_t result = callBinaryClosure(closure_ptr, x, y);
        results.push_back(result);

        xList = xCons->tail;
        yList = yCons->tail;
    }

    return Export::encode(vectorToList(results));
}
```

#### Step 2.4: Implement `Elm_Kernel_List_map3`

Same pattern as map2, but iterate three lists.

#### Step 2.5: Implement `Elm_Kernel_List_map4`

Same pattern, four lists.

#### Step 2.6: Implement `Elm_Kernel_List_map5`

Same pattern, five lists.

#### Step 2.7: Implement `Elm_Kernel_List_sortBy`

1. Convert list to vector
2. Extract keys for each element: `key = closure(elem)`
3. Sort vector using `std::stable_sort` with key comparison via `Utils::compare`
4. Convert back to list

```cpp
uint64_t Elm_Kernel_List_sortBy(uint64_t closure, uint64_t list) {
    void* closure_ptr = Export::toPtr(closure);
    std::vector<uint64_t> elements = listToVectorU64(Export::decode(list));
    auto& allocator = Allocator::instance();

    // Build key cache
    std::vector<uint64_t> keys;
    for (uint64_t elem : elements) {
        uint64_t key = callUnaryClosure(closure_ptr, elem);
        keys.push_back(key);
    }

    // Create index array and sort by keys using Utils::compare
    std::vector<size_t> indices(elements.size());
    std::iota(indices.begin(), indices.end(), 0);
    std::stable_sort(indices.begin(), indices.end(), [&](size_t a, size_t b) {
        // Utils::compare returns Order (heap Custom with ctor 0=LT, 1=EQ, 2=GT)
        HPointer orderHP = Utils::compare(
            Export::toPtr(keys[a]),
            Export::toPtr(keys[b])
        );
        Custom* order = static_cast<Custom*>(allocator.resolve(orderHP));
        return order->ctor == 0;  // LT
    });

    // Reorder elements and convert to list
    std::vector<uint64_t> sorted;
    for (size_t i : indices) sorted.push_back(elements[i]);
    return Export::encode(vectorU64ToList(sorted));
}
```

#### Step 2.8: Implement `Elm_Kernel_List_sortWith`

Use closure directly as comparator. Order is heap-allocated Custom with ctor 0/1/2:

```cpp
uint64_t Elm_Kernel_List_sortWith(uint64_t closure, uint64_t list) {
    void* closure_ptr = Export::toPtr(closure);
    std::vector<uint64_t> elements = listToVectorU64(Export::decode(list));
    auto& allocator = Allocator::instance();

    std::stable_sort(elements.begin(), elements.end(), [&](uint64_t a, uint64_t b) {
        uint64_t order = callBinaryClosure(closure_ptr, a, b);
        // Order is heap-allocated Custom: ctor 0=LT, 1=EQ, 2=GT
        HPointer orderHP = Export::decode(order);
        Custom* orderVal = static_cast<Custom*>(allocator.resolve(orderHP));
        return orderVal->ctor == 0;  // LT means a < b
    });

    return Export::encode(vectorU64ToList(elements));
}
```

### Phase 3: Testing

#### Step 3.1: Create test cases for JsArray functions

Add E2E tests covering:
- `Array.initialize` with various closures
- `Array.map` and `Array.indexedMap`
- `Array.foldl` and `Array.foldr`

#### Step 3.2: Create test cases for List functions

Add E2E tests covering:
- `List.map2` through `List.map5` with short and equal-length lists
- `List.sortBy` with simple key extraction
- `List.sortWith` with custom comparators

#### Step 3.3: Run full test suite

```bash
cmake --build build --target check
```

### Phase 4: Update Documentation

#### Step 4.1: Update kernel-impl.md

Change status from ❌ Stubbed to ✅ for all implemented functions.

## File Changes Summary

| File | Changes |
|------|---------|
| `runtime/src/allocator/Heap.hpp` | Simplify ElmArray unboxed field from u64 bitmap to u1 flag |
| `runtime/src/allocator/HeapHelpers.hpp/.cpp` | Update arrayIsUnboxed, arrayPush for uniform unboxing |
| `elm-kernel-cpp/src/core/JsArray.cpp` | Update for uniform unboxing |
| `elm-kernel-cpp/src/core/JsArrayExports.cpp` | Implement 6 higher-order function exports |
| `elm-kernel-cpp/src/core/ListExports.cpp` | Implement 6 higher-order function exports, update listToVector |
| `kernel-impl.md` | Update status to reflect completions |

## Resolved Questions

1. **Order type representation**: Order is a **heap-allocated Custom** with ctor tags 0/1/2 for LT/EQ/GT.

2. **Element boxing in array iteration**: Elements should **NOT be boxed** before passing to closures. Pass directly as raw `uint64_t` values (same as StringExports pattern with chars).

3. **GC safety during closure calls**: `std::vector<void*>` is acceptable. Raw pointers are safe but cannot be passed as HPointers (HPointer is only for heap references).

4. **File location**: `runtime/src/allocator/Heap.hpp` contains the ElmArray typedef.

5. **Utils::compare**: Use `Utils::compare()` which returns heap-allocated Order (Custom with ctor 0/1/2), not a raw int.

6. **Cons.head unboxing**: List Cons cells have `header.unboxed` flag (bit 0) indicating if head is unboxed. Must check this flag when reading list elements.

## Assumptions

1. All closures passed to these kernel functions are **saturated** (arity matches expected arguments). Partial application is handled by the compiler before reaching kernel code.

2. The existing `callClosure` helper in ListExports.cpp correctly handles captured values + new arguments.

3. `Utils::compare` can compare any comparable Elm values for sortBy key comparison.

4. Arrays are **uniform** in their boxing — either all elements are boxed HPointers or all are unboxed primitives (Int/Float/Char). This allows simplifying the unboxed field from a 64-bit bitmap to a single bit flag.
