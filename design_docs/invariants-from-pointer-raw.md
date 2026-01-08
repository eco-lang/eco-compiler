# Invariant Investigation: `fromPointerRaw` Returning nullptr for Constants

## Issue Summary

The `Allocator::fromPointerRaw` function returns `nullptr` when passed an `HPointer` with `constant != 0`. This silent conversion of "wrong kind of pointer" into "null pointer" may mask bugs if callers don't properly handle this case.

## Location

**File**: `runtime/src/allocator/Allocator.hpp:182-187`

```cpp
static inline void* fromPointerRaw(HPointer ptr) {
    if (ptr.constant != 0) return nullptr;
    char* heap_base = instance().heap_base;
    uintptr_t byte_offset = static_cast<uintptr_t>(ptr.ptr) << 3;
    return heap_base + byte_offset;
}
```

**Test helper**: `AllocatorTestAccess::fromPointer` at line 214-216 (passthrough to `fromPointerRaw`).

## Intended Invariant

- `ptr.constant != 0` means "embedded constant" (Nil, True, False, Unit, EmptyString).
- All call sites of `fromPointerRaw` should only pass heap-object pointers (`ptr.constant == 0`).

## Call Site Analysis

### Internal GC Call Sites (runtime/src/allocator/)

| Location | Check Before Call | Handles nullptr |
|----------|------------------|-----------------|
| `OldGenSpace.cpp:308` (startMark) | **NO** - iterates roots blindly | YES - `if (obj && ...)` |
| `OldGenSpace.cpp:474` (markHPointer) | **YES** - `if (ptr.constant != 0) return;` | YES |
| `OldGenSpace.cpp:1118` (fixHPointer) | **YES** - `if (ptr.constant != 0) return;` | YES |
| `NurserySpace.cpp:492` (evacuate) | **YES** - `if (ptr.constant != 0) return;` | YES |
| `NurserySpace.cpp:749` (evacuateCons) | **NO** - assumes tail is heap ptr | **RISKY** |
| `NurserySpace.cpp:847` (processCheney) | **NO** - iterates from-space | YES - validates with isInFromSpace |
| `NurserySpace.cpp:987` (processList) | **NO** - assumes cons tail | **RISKY** |
| `Allocator.cpp:355` (resolve) | **YES** - `if (ptr.constant != 0) return nullptr;` | Caller handles |

### Test Call Sites (test/allocator/)

| Location | Check Before Call | Handles nullptr |
|----------|------------------|-----------------|
| `ElmTest.cpp:71,108,208` | **NO** | **NO** - dereferences result |
| `AllocatorTest.cpp:36` | **NO** | **NO** - dereferences result |
| `HeapSnapshot.hpp` (35+ calls) | **NO** | Some check, some don't |

## Risk Assessment

### High Risk Areas

1. **`NurserySpace.cpp:749`** - In `evacuateCons`, the code does:
   ```cpp
   void* tail_obj = Allocator::fromPointerRaw(c->tail);
   ```
   If `c->tail` is `Nil` (a constant), this returns `nullptr`. The subsequent code may dereference it.

2. **`NurserySpace.cpp:987`** - In `processList`, iterates cons cells assuming tail is always a heap pointer. If tail is `Nil`, returns `nullptr` and may dereference.

3. **Test code** - Many test helpers in `HeapSnapshot.hpp` call `fromPointer` without checking if the result is `nullptr` or if the input is a constant.

### Medium Risk Areas

1. **`OldGenSpace.cpp:308`** - In `startMark`, roots are pushed without constant check. However, the subsequent `if (obj && alloc.isInHeap(obj))` catches `nullptr`.

## Findings

After detailed examination:

1. **GC-internal code is mostly safe**: Most GC code explicitly checks `ptr.constant != 0` before calling `fromPointerRaw`, OR checks the result for `nullptr`/heap membership.

2. **Cons cell handling is risky**: The `evacuateCons` and `processList` functions assume that cons cells always have heap pointers in their `tail` field. This is semantically correct (a `Nil` tail would be encoded as a constant in the `HPointer`), but the code doesn't explicitly guard against it.

3. **Test code is vulnerable**: Test helpers assume all pointers are heap objects. If a test accidentally stores a constant in a root slot, the test would crash with a null dereference.

## Recommended Guardrails

### Option 1: Fail Fast with Assert (Recommended)

```cpp
static inline void* fromPointerRaw(HPointer ptr) {
    assert(ptr.constant == 0 && "fromPointerRaw called on constant HPointer");
    char* heap_base = instance().heap_base;
    uintptr_t byte_offset = static_cast<uintptr_t>(ptr.ptr) << 3;
    return heap_base + byte_offset;
}
```

**Benefits**:
- Catches misuse immediately in debug builds
- Clear error message identifying the problem
- No runtime cost in release builds

### Option 2: Assert + Release Safety

```cpp
static inline void* fromPointerRaw(HPointer ptr) {
    assert(ptr.constant == 0 && "fromPointerRaw called on constant HPointer");
    if (ptr.constant != 0) return nullptr;  // Release safety
    char* heap_base = instance().heap_base;
    uintptr_t byte_offset = static_cast<uintptr_t>(ptr.ptr) << 3;
    return heap_base + byte_offset;
}
```

**Benefits**:
- Catches bugs in debug, graceful degradation in release
- Preserves current release behavior

### Option 3: Test Helper Hardening

```cpp
// In AllocatorTestAccess
static void* fromPointer(HPointer ptr) {
    assert(ptr.constant == 0 && "Test bug: fromPointer called on constant");
    return Allocator::fromPointerRaw(ptr);
}
```

## Specific Code Areas Needing Attention

### NurserySpace.cpp - evacuateCons

```cpp
// Line ~749
void* tail_obj = Allocator::fromPointerRaw(c->tail);
// SUGGESTION: Add guard
if (c->tail.constant != 0) return;  // Nil tail, nothing to evacuate
void* tail_obj = Allocator::fromPointerRaw(c->tail);
```

### NurserySpace.cpp - processList

```cpp
// Line ~987
void* next = Allocator::fromPointerRaw(cons->tail);
// SUGGESTION: Check before use
if (cons->tail.constant != 0) break;  // Reached Nil
void* next = Allocator::fromPointerRaw(cons->tail);
```

### HeapSnapshot.hpp - All traversal code

Add constant checks before calling `fromPointer`:

```cpp
// Example fix
if (cons->tail.constant == 0) {
    void* child = AllocatorTestAccess::fromPointer(cons->tail);
    // ... process child
}
```

## Conclusion

The current behavior is **mostly safe** due to existing null checks, but several code paths rely on implicit invariants that aren't enforced. Adding assertions would:

1. Document the intended contract
2. Catch bugs during development
3. Make invariant violations visible rather than silent

**Priority**: Medium - The code works correctly when invariants are upheld, but adding explicit checks would improve robustness and debuggability.
