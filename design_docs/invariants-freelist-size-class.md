# Invariant Investigation: `getFreeList` Size-Class Bounds

## Issue Summary

The `OldGenSpaceTestAccess::getFreeList` function returns `nullptr` when passed an invalid size class (`cls >= NUM_SIZE_CLASSES`). This silent behavior could mask bugs in size-class calculation logic, causing tests to incorrectly interpret `nullptr` as "empty free list" rather than "invalid size class."

## Location

**File**: `runtime/src/allocator/OldGenSpace.hpp:381-383`

```cpp
static FreeCell* getFreeList(const OldGenSpace& oldgen, size_t cls) {
    return cls < NUM_SIZE_CLASSES ? oldgen.free_lists_[cls] : nullptr;
}
```

**Related Constants** (same file):

```cpp
static constexpr size_t NUM_SIZE_CLASSES = 32;
static constexpr size_t MAX_SMALL_SIZE = 256;
```

**Size Class Calculation** (lines 229-234):

```cpp
static size_t sizeClass(size_t size) {
    size = (size + 7) & ~7;  // Align to 8 bytes.
    if (size <= MAX_SMALL_SIZE) {
        return (size / 8) - 1;  // Classes 0-31 map to sizes 8-256.
    }
    return NUM_SIZE_CLASSES;  // Large object indicator.
}
```

## Intended Invariant

- Valid size classes are `0 <= cls < NUM_SIZE_CLASSES` (i.e., 0-31).
- Size class `NUM_SIZE_CLASSES` (32) is the "large object" indicator, not a valid free list index.
- Tests using `getFreeList` should only pass valid size class indices.

## Size Class Mapping

| Size Class | Allocation Size (bytes) | Notes |
|------------|------------------------|-------|
| 0 | 8 | Minimum object size |
| 1 | 16 | |
| ... | ... | |
| 31 | 256 | Maximum small object |
| 32 | N/A | Large object indicator (no free list) |

## Current Usage Analysis

### Test Code Search

Grep for `getFreeList` in test files found **no current usages**.

This means the function exists in the API but isn't being exercised by tests yet. When tests do start using it, they may encounter the issue.

### Internal OldGenSpace Usage

The free lists are accessed directly in `OldGenSpace.cpp` via `free_lists_[cls]`. The `sizeClass()` function is used to compute the index:

```cpp
// From lazySweep
size_t cls = sizeClass(obj_size);
if (cls < NUM_SIZE_CLASSES) {
    // Add to free list
    cell->next = free_lists_[cls];
    free_lists_[cls] = cell;
}
```

Internal code correctly checks `cls < NUM_SIZE_CLASSES` before accessing the array.

## Risk Assessment

### Low-Medium Risk

Since `getFreeList` isn't currently used in tests, the risk is **theoretical**. However:

1. **Future test development**: When someone writes tests for free-list behavior, they might:
   ```cpp
   size_t cls = OldGenSpaceTestAccess::sizeClass(some_size);
   FreeCell* list = OldGenSpaceTestAccess::getFreeList(oldgen, cls);
   // If some_size > 256, cls == 32, list is nullptr
   // Test might interpret this as "free list is empty" rather than "invalid class"
   ```

2. **Arithmetic errors**: A test might compute a size class incorrectly:
   ```cpp
   size_t cls = (obj_size / 8);  // WRONG: should be (obj_size / 8) - 1
   FreeCell* list = OldGenSpaceTestAccess::getFreeList(oldgen, cls);
   ```

3. **Boundary conditions**: Testing objects of exactly 256 bytes vs 264 bytes requires careful size-class handling.

## Recommended Guardrails

### Option 1: Assert on Invalid Class (Recommended)

```cpp
static FreeCell* getFreeList(const OldGenSpace& oldgen, size_t cls) {
    assert(cls < NUM_SIZE_CLASSES &&
           "getFreeList: invalid size class (>= NUM_SIZE_CLASSES)");
    return oldgen.free_lists_[cls];
}
```

**Benefits**:
- Catches misuse immediately
- Clear error message
- Forces callers to validate their size class calculation

### Option 2: Separate "Try" Variant

If there's a legitimate use case for querying any size class:

```cpp
// Strict version - asserts on invalid class
static FreeCell* getFreeList(const OldGenSpace& oldgen, size_t cls) {
    assert(cls < NUM_SIZE_CLASSES &&
           "getFreeList: invalid size class");
    return oldgen.free_lists_[cls];
}

// Permissive version - returns nullptr for invalid class (explicit in name)
static FreeCell* tryGetFreeList(const OldGenSpace& oldgen, size_t cls) {
    return cls < NUM_SIZE_CLASSES ? oldgen.free_lists_[cls] : nullptr;
}
```

### Option 3: Document and Validate at Test Level

Add helper that validates the relationship:

```cpp
// In test code
static FreeCell* getFreeListForSize(const OldGenSpace& oldgen, size_t obj_size) {
    size_t cls = OldGenSpaceTestAccess::sizeClass(obj_size);
    if (cls >= NUM_SIZE_CLASSES) {
        // Large objects don't use free lists
        return nullptr;
    }
    return OldGenSpaceTestAccess::getFreeList(oldgen, cls);
}
```

## Additional Recommendations

### Validate sizeClass/classToSize Inverse

Add test assertions that the size class functions are inverses:

```cpp
// Test invariant: classToSize(sizeClass(size)) >= size for small objects
for (size_t size = 1; size <= MAX_SMALL_SIZE; size++) {
    size_t cls = OldGenSpaceTestAccess::sizeClass(size);
    assert(cls < NUM_SIZE_CLASSES);
    size_t roundTrip = OldGenSpaceTestAccess::classToSize(cls);
    assert(roundTrip >= size);
    assert(roundTrip <= size + 7);  // At most 7 bytes of padding
}

// Test invariant: sizes > MAX_SMALL_SIZE return NUM_SIZE_CLASSES
for (size_t size = MAX_SMALL_SIZE + 1; size <= MAX_SMALL_SIZE + 100; size++) {
    size_t cls = OldGenSpaceTestAccess::sizeClass(size);
    assert(cls == NUM_SIZE_CLASSES);
}
```

### Document the API Contract

Add documentation to the header:

```cpp
/**
 * Returns the head of the free list for the given size class.
 *
 * @pre cls < NUM_SIZE_CLASSES (asserts in debug builds)
 * @param cls Size class index (0-31). Use sizeClass() to compute from object size.
 * @return Pointer to first free cell, or nullptr if list is empty.
 *
 * Note: For objects > MAX_SMALL_SIZE (256 bytes), sizeClass() returns
 * NUM_SIZE_CLASSES, which is NOT a valid free list index. Large objects
 * use bump allocation, not free lists.
 */
static FreeCell* getFreeList(const OldGenSpace& oldgen, size_t cls);
```

## Conclusion

The current `nullptr` return for invalid size classes is a **silent failure mode** that could mask test bugs. While the risk is currently theoretical (no test usages found), the fix is simple and defensive.

**Priority**: Low - No current impact, but adding assert is cheap insurance.

**Recommended Action**: Add `assert(cls < NUM_SIZE_CLASSES)` to fail fast on invariant violation.
