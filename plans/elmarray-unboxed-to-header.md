# Plan: Move ElmArray.unboxed into Header.unboxed

## Problem

`ElmArray` has a dedicated `u32 unboxed : 1` field, but `Header` already provides a 3-bit `unboxed` field (currently used only by Cons, Tuple2, Tuple3). This wastes structural space and is inconsistent with how other types store their unboxing metadata.

Additionally, the GC and printing code treats `arr->unboxed` as a per-element bitmap (`arr->unboxed & (1ULL << i)`), but since the field is only 1 bit wide, this only works for element 0. Elements at index 1+ are always treated as boxed regardless of the flag. This is a latent bug that this change also fixes.

## Solution

Move the single unboxed bit into `Header.unboxed` (bit 0) for `Tag_Array` objects. Remove the dedicated field from `ElmArray`, leaving only padding. Fix GC/printing code to use the uniform flag correctly.

## Changes

### Step 1: Modify ElmArray struct in Heap.hpp

Remove the `unboxed` bit-field from ElmArray. The struct becomes:

```cpp
typedef struct {
    Header header;     // header.size = capacity; header.unboxed bit 0 = all-unboxed flag
    u32 length;        // Current number of elements in use
    u32 padding;       // Alignment padding
    Unboxable elements[];
} ElmArray;
```

Update the doc comment on `Header.unboxed` to mention arrays:
```
u32 unboxed : 3; // Unboxed flags for Cons, Tuple2, Tuple3, ElmArray (bit 0).
```

### Step 2: Update HeapHelpers.hpp allocation/helper functions

**`allocArray`** (~line 614):
- Change `arr->unboxed = 0;` → `arr->header.unboxed = 0;`
- Remove `arr->padding = 0;` or keep just `arr->padding = 0;`

**`createBoxedArray`** (~line 637):
- Change `arr->unboxed = 0;` → `arr->header.unboxed = 0;`
- Remove `arr->padding = 0;` or keep

**`createUnboxedArray`** (~line 655):
- Change `arr->unboxed = 1;` → `arr->header.unboxed = 1;`

**`arrayPush`** (~line 705):
- Change `a->unboxed = is_boxed ? 0 : 1;` → `a->header.unboxed = is_boxed ? 0 : 1;`

**`arrayIsUnboxed`** (~line 733):
- Change `return a->unboxed != 0;` → `return a->header.unboxed != 0;`

### Step 3: Fix GC scanning in NurserySpace.cpp

Current code (~line 793) treats `arr->unboxed` as a per-element bitmap:
```cpp
evacuateUnboxable(arr->elements[i], !(arr->unboxed & (1ULL << i)), ...);
```

Replace with uniform flag check:
```cpp
bool is_boxed = !arr->header.unboxed;
for (u32 i = 0; i < arr->length; i++) {
    evacuateUnboxable(arr->elements[i], is_boxed, oldgen, promoted_objects);
}
```
This also removes the artificial split at index 64.

### Step 4: Fix GC marking in OldGenSpace.cpp

**Marking** (~line 449): Same pattern — replace per-element bitmap with uniform flag:
```cpp
bool is_boxed = !arr->header.unboxed;
for (u32 i = 0; i < arr->length; i++) {
    markUnboxable(arr->elements[i], is_boxed);
}
```

**Fixup** (~line 1091): Same:
```cpp
bool is_boxed = !arr->header.unboxed;
for (u32 i = 0; i < arr->length; i++) {
    fixUnboxable(arr->elements[i], is_boxed);
}
```

### Step 5: Fix RuntimeExports.cpp debug printing

Current code (~line 1041) uses bitmap-style check:
```cpp
if (array->unboxed & (1ULL << i)) {
```

Replace with:
```cpp
if (array->header.unboxed) {
```
Hoist the check outside the loop for clarity.

### Step 6: Update JsArrayExports.cpp

**`Elm_Kernel_JsArray_get`** (~line 105):
- Change `arr->unboxed` → `arr->header.unboxed`

**Array append** (~line 215):
- Change `resultArr->unboxed = destArr->unboxed;` → `resultArr->header.unboxed = destArr->header.unboxed;`

### Step 7: Update JsArray.cpp

Any calls to `alloc::arrayIsUnboxed()` are already abstracted and will work via the Step 2 change to that helper. Verify no direct `->unboxed` access exists in this file.

### Step 8: Update documentation

**TypeInfo.hpp** (~line 35): Update comment:
```
 *   - ElmArray: header.unboxed bit 0 (uniform: all boxed or all unboxed)
```

## Files touched

| File | Nature of change |
|------|------------------|
| `runtime/src/allocator/Heap.hpp` | Remove `unboxed` field from ElmArray; update Header comment |
| `runtime/src/allocator/HeapHelpers.hpp` | `arr->unboxed` → `arr->header.unboxed` in 5 functions |
| `runtime/src/allocator/NurserySpace.cpp` | Fix GC scanning to use uniform flag |
| `runtime/src/allocator/OldGenSpace.cpp` | Fix GC marking and fixup to use uniform flag |
| `runtime/src/allocator/RuntimeExports.cpp` | Fix debug printing to use uniform flag |
| `elm-kernel-cpp/src/core/JsArrayExports.cpp` | `arr->unboxed` → `arr->header.unboxed` |
| `elm-kernel-cpp/src/core/JsArray.cpp` | Verify no direct access (likely no changes) |
| `runtime/src/allocator/TypeInfo.hpp` | Update documentation comment |

## Bug fix included

The GC per-element bitmap treatment is fixed as part of this change. Since `ElmArray.unboxed` was always a 1-bit uniform flag (set to 0 or 1 for the whole array), the bitmap-style `& (1ULL << i)` only worked for element 0. All other elements were always treated as boxed. After this change, the uniform flag is correctly applied to all elements.

## New Tests (in test/allocator/)

### A. Boxed array basics (HeapHelpersTest)

1. **`testCreateBoxedArrayRoundtrip`** — Create a boxed array of heap pointers (e.g. ElmInt), verify `arrayIsUnboxed()` returns false, verify each element resolves correctly.
2. **`testBoxedArrayPush`** — Push boxed values (HPointers) into an array, verify unboxed flag stays 0.

### B. Boxed array GC survival

3. **`testBoxedArraySurvivesMinorGC`** — Create a boxed array pointing to heap objects, trigger minor GC, verify all element pointers resolve to correct values after GC.
4. **`testBoxedArraySurvivesMajorGC`** — Same but trigger major GC cycle (mark-sweep), verify elements survive and resolve.

### C. Unboxed array GC

5. **`testUnboxedArraySurvivesMajorGC`** — Unboxed int array survives major GC, all elements intact.

### D. Header.unboxed flag correctness

6. **`testArrayUnboxedFlagInHeader`** — Verify `arr->header.unboxed` is 0 for boxed arrays and 1 for unboxed arrays (directly checks the header field).
7. **`testArrayUnboxedFlagPreservedAcrossGC`** — Create both boxed and unboxed arrays, trigger GC, verify the unboxed flag is preserved in the header after evacuation/compaction.

### E. GC scanning correctness (the latent bug fix)

8. **`testBoxedArrayElementsTracedByGC`** — Create a boxed array with N>1 elements pointing to heap objects that are *only* reachable through the array. Trigger GC. Verify all elements (not just element 0) survive. This directly exercises the fix to the per-element bitmap bug.
9. **`testUnboxedArrayElementsNotTracedByGC`** — Create an unboxed array, trigger GC, verify elements are treated as raw integers (not followed as pointers) — no crash from GC trying to trace integer bit patterns as pointers.

### F. Edge cases

10. **`testEmptyArraySurvivesGC`** — Empty array (length 0) survives GC without issues.
11. **`testLargeBoxedArraySurvivesGC`** — Boxed array with 100+ elements, all survive GC (tests beyond the old index-64 boundary in the GC code).

## Running tests

```bash
cmake --build build && cmake --build build --target check
```

All existing E2E tests should pass — the semantic meaning hasn't changed, only the storage location of the bit and correctness of GC scanning for unboxed arrays (which are rare in current Elm programs).
