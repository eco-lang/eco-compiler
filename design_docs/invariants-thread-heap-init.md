# Invariant Investigation: `getThreadHeap` Returning nullptr if `initThread` Not Called

## Issue Summary

The `Allocator::getThreadHeap()` method returns `nullptr` if the calling thread has not called `initThread()`. This creates a risk of null pointer dereferences if public methods don't properly validate the thread heap before use.

## Location

**File**: `runtime/src/allocator/Allocator.hpp:143`

```cpp
// Returns the calling thread's heap, or nullptr if not initialized.
ThreadLocalHeap* getThreadHeap() const { return tl_heap_; }
```

**Thread-local storage**: `runtime/src/allocator/Allocator.cpp:27`

```cpp
thread_local ThreadLocalHeap* Allocator::tl_heap_ = nullptr;
```

## Intended Invariants

1. `Allocator::initialize()` must be called once globally before any thread operations.
2. Every mutator thread must call `initThread()` before calling `allocate`, `minorGC`, `majorGC`, `getRootSet`, etc.
3. Using these APIs on a thread without a thread heap is a programming error.

## Public API Analysis

### Methods That Use Thread Heap

| Method | Current Behavior | Safe? |
|--------|-----------------|-------|
| `allocate(size, tag)` | **Asserts** `tl_heap_` | **YES** |
| `minorGC()` | Silent no-op if nullptr | **PARTIALLY** |
| `majorGC()` | Silent no-op if nullptr | **PARTIALLY** |
| `getRootSet()` | **Auto-initializes** thread | **YES** |
| `isNurseryNearFull()` | Returns false if nullptr | **PARTIALLY** |
| `isInNursery()` | Returns false if nullptr | **PARTIALLY** |
| `isInOldGen()` | Returns false if nullptr | **PARTIALLY** |
| `getOldGenAllocatedBytes()` | Returns 0 if nullptr | **PARTIALLY** |

### Detailed Code Review

**Allocator.cpp:161-163** - `allocate()`:
```cpp
void *Allocator::allocate(size_t size, Tag tag) {
    assert(tl_heap_ && "Thread not initialized - call initThread() first");
    return tl_heap_->allocate(size, tag);
}
```
**Status**: GOOD - Has assertion with clear message.

**Allocator.cpp:167-170** - `minorGC()`:
```cpp
void Allocator::minorGC() {
    if (tl_heap_) {
        tl_heap_->minorGC();
    }
}
```
**Status**: RISKY - Silently does nothing if thread not initialized.

**Allocator.cpp:173-178** - `majorGC()`:
```cpp
void Allocator::majorGC() {
    if (tl_heap_) {
        tl_heap_->majorGC();
    }
}
```
**Status**: RISKY - Silently does nothing if thread not initialized.

**Allocator.cpp:152-158** - `getRootSet()`:
```cpp
RootSet &Allocator::getRootSet() {
    if (!tl_heap_) {
        // Auto-initialize for convenience.
        initThread();
    }
    return tl_heap_->getRootSet();
}
```
**Status**: GOOD - Auto-initializes, but different behavior than other methods.

## Risk Assessment

### High Risk

The silent no-op behavior in `minorGC()` and `majorGC()` is dangerous because:

1. **Memory leaks go undetected**: If a thread forgets `initThread()` but allocates through some other path (e.g., direct kernel call), GC would never run for that thread.

2. **Debugging difficulty**: No error message or crash helps identify the problem.

3. **Inconsistent API contract**: `allocate()` asserts, but `minorGC()` silently succeeds. A developer might assume all methods behave similarly.

### Medium Risk

The query methods (`isNurseryNearFull`, `isInNursery`, `isInOldGen`, `getOldGenAllocatedBytes`) returning default values when thread not initialized could mask bugs where these checks are used for important decisions.

## Test Helper Analysis

**AllocatorTestAccess::getThreadHeap** (line 234-236):
```cpp
static ThreadLocalHeap* getThreadHeap(Allocator& alloc) {
    return alloc.getThreadHeap();
}
```

This directly exposes the nullable pointer to test code, which may then dereference without checking.

**AllocatorTestAccess::getNursery/getOldGen** (lines 400-408):
```cpp
NurserySpace* AllocatorTestAccess::getNursery(Allocator& alloc) {
    ThreadLocalHeap* heap = alloc.getThreadHeap();
    return heap ? &heap->getNursery() : nullptr;
}
```
These correctly handle null, but callers must still check.

## Recommended Guardrails

### Option 1: Internal Helper with Assert (Recommended)

Add a private helper that enforces the invariant:

```cpp
// In Allocator class (private):
ThreadLocalHeap* requireThreadHeap() const {
    ThreadLocalHeap* heap = tl_heap_;
    assert(heap != nullptr &&
           "Allocator: thread heap not initialized. Call initThread() first.");
    return heap;
}
```

Then use it consistently:

```cpp
void Allocator::minorGC() {
    requireThreadHeap()->minorGC();
}

void Allocator::majorGC() {
    requireThreadHeap()->majorGC();
}

bool Allocator::isNurseryNearFull(float threshold) {
    return requireThreadHeap()->isNurseryNearFull(threshold);
}

bool Allocator::isInNursery(void *ptr) {
    return requireThreadHeap()->isInNursery(ptr);
}

bool Allocator::isInOldGen(void *ptr) {
    return requireThreadHeap()->isInOldGen(ptr);
}

size_t Allocator::getOldGenAllocatedBytes() const {
    return requireThreadHeap()->getOldGenAllocatedBytes();
}
```

### Option 2: Add Allocator Initialization Check

Also verify global initialization:

```cpp
ThreadLocalHeap* requireThreadHeap() const {
    assert(initialized && "Allocator::initialize() must be called first");
    ThreadLocalHeap* heap = tl_heap_;
    assert(heap != nullptr &&
           "Thread heap not initialized. Call initThread() first.");
    return heap;
}
```

### Option 3: Debug-Only Logging

For methods where silent no-op might be intentional (rare), add debug logging:

```cpp
void Allocator::minorGC() {
    if (!tl_heap_) {
#ifndef NDEBUG
        fprintf(stderr, "Warning: minorGC called on uninitialized thread\n");
#endif
        return;
    }
    tl_heap_->minorGC();
}
```

### Option 4: Test Helper Hardening

```cpp
static ThreadLocalHeap* getThreadHeap(Allocator& alloc) {
    ThreadLocalHeap* heap = alloc.getThreadHeap();
    assert(heap != nullptr && "Test bug: getThreadHeap on uninitialized thread");
    return heap;
}
```

## Consistency Recommendations

The API should have consistent behavior. Recommended approach:

| Method | Recommended Behavior |
|--------|---------------------|
| `allocate()` | Assert (crash in debug, UB in release) - **KEEP** |
| `minorGC()` | Assert - **CHANGE** |
| `majorGC()` | Assert - **CHANGE** |
| `getRootSet()` | Auto-initialize - **KEEP** (for convenience) |
| `isNurseryNearFull()` | Assert - **CHANGE** |
| `isInNursery()` | Assert - **CHANGE** |
| `isInOldGen()` | Assert - **CHANGE** |
| `getOldGenAllocatedBytes()` | Assert - **CHANGE** |

## Exception: getRootSet Auto-Initialization

The `getRootSet()` auto-initialization is a pragmatic choice that allows:

```cpp
// This "just works" without explicit initThread()
Allocator::instance().getRootSet().add(&myRoot);
```

This is acceptable IF documented. However, consider whether this convenience masks bugs where threads don't properly initialize.

## Conclusion

The current implementation has **inconsistent invariant enforcement**:

- `allocate()` properly asserts
- Other methods silently accept uninitialized state

This inconsistency:
1. Makes bugs harder to diagnose
2. Creates unexpected behavior differences
3. Could lead to silent failures (GC not running)

**Priority**: High for `minorGC()`/`majorGC()` - silent GC failure is serious.
**Priority**: Medium for query methods - wrong results may affect logic.

Adding `assert` statements would make all methods behave consistently and help catch initialization bugs early in development.
