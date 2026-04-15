# Plan: Nursery Ghost-Data Safety Net & Stale-Pointer Debug Assertions

## Goal

Two complementary nursery GC hardening measures:
1. **Ghost-data safety net**: Zero the free region of to-space after each minor GC, eliminating stale headers that could make ghost objects look live.
2. **Debug-time stale-pointer detection**: Assertions (gated by `ECO_GC_DEBUG`) that crash immediately when any HPointer points into nursery free space.

---

## Decisions (resolved)

| # | Decision |
|---|----------|
| Q1 | `clearToSpaceFreeRegion()` is **unconditional** (not debug-gated). If profiling shows cost, optimize later with high-water-mark clear in Release, full clear under `ECO_GC_DEBUG`. |
| Q2 | Call `clearToSpaceFreeRegion()` **after** `checkAndGrow()` so newly added to-space blocks are also zeroed before flip. |
| Q3 | Add a thin **forwarder on `ThreadLocalHeap`** (`debugAssertValidNurseryPointer(void*)`) that delegates to `nursery_.debugAssertValidNurseryPointer(p)` under `#if ECO_GC_DEBUG`. Keeps `NurserySpace` debug API private; `Allocator::resolve()` calls the `ThreadLocalHeap` forwarder. |
| Q4 | **Yes**, also instrument `evacuateJitPtr()` with the debug check. Any path interpreting a nursery pointer gets the same guard. |
| Q5 | Plain `bool in_minor_gc_` — no synchronization needed. `NurserySpace` is per-thread; minor GC is stop-the-world per that thread. |
| Q6 | Confirmed. `copy_ptr_` advances monotonically during GC; spine cells allocated via `copyToSpace()` are always below `copy_ptr_` by the time they're checked. |
| Q7 | Confirmed. Debug check fires before the forward check; forwarded objects are in from-space allocated region and pass. No issue. |
| Q8 | **CMake option**: `option(ECO_GC_DEBUG "Enable extra GC debug checks" ON)` defaulting ON in Debug, OFF in Release. Drives `-DECO_GC_DEBUG=1` compile definition. More discoverable than manual `#define`. |

---

## Files to modify

| File | Change |
|------|--------|
| `runtime/src/allocator/AllocatorCommon.hpp` | Add `ECO_GC_DEBUG` macro (fallback `#ifndef` guard) |
| `runtime/src/allocator/NurserySpace.hpp` | Add `clearToSpaceFreeRegion()` decl + debug helper decls + `in_minor_gc_` field |
| `runtime/src/allocator/NurserySpace.cpp` | Implement `clearToSpaceFreeRegion()`, debug helpers, instrument `minorGC()`, `evacuate()`, `evacuateJitPtr()` |
| `runtime/src/allocator/ThreadLocalHeap.hpp` | Add `debugAssertValidNurseryPointer(void*)` forwarder under `#if ECO_GC_DEBUG` |
| `runtime/src/allocator/Allocator.cpp` | Instrument `resolve()` with debug nursery pointer check via `ThreadLocalHeap` forwarder |
| `CMakeLists.txt` | Add `ECO_GC_DEBUG` CMake option, wire to compile definition |

---

## Steps

### Step 1: Add `ECO_GC_DEBUG` CMake option

In the top-level or runtime `CMakeLists.txt`, add:

```cmake
# Default ON for Debug, OFF for Release.
if(CMAKE_BUILD_TYPE STREQUAL "Debug")
    option(ECO_GC_DEBUG "Enable extra GC debug checks" ON)
else()
    option(ECO_GC_DEBUG "Enable extra GC debug checks" OFF)
endif()

if(ECO_GC_DEBUG)
    target_compile_definitions(ecor PRIVATE ECO_GC_DEBUG=1)
endif()
```

### Step 2: Define `ECO_GC_DEBUG` fallback in AllocatorCommon.hpp

In `AllocatorCommon.hpp`, inside the include guard, before `namespace Elm {` (around line 21), add:

```cpp
// Enable extra GC assertions and nursery invariants in debug builds.
// Normally set via CMake (-DECO_GC_DEBUG=1); this provides a safe fallback.
#ifndef ECO_GC_DEBUG
#define ECO_GC_DEBUG 0
#endif
```

### Step 3: Declare new members in NurserySpace.hpp

Add to the `NurserySpace` class (private section):

1. **After `ThreadLocalHeap* thread_heap_` (line 86), before `// ========== Internal Methods ==========`:**
   ```cpp
   #if ECO_GC_DEBUG
       bool in_minor_gc_ = false;  // True only during minorGC execution.
   #endif
   ```

2. **After `void minorGC(OldGenSpace &oldgen);` (line 98):**
   ```cpp
       // Zeros the free region of to-space after evacuation completes.
       // Prevents ghost headers from surviving into the next GC cycle.
       // Unconditional (not debug-gated) — this is a safety net, not just a check.
       void clearToSpaceFreeRegion();

   #if ECO_GC_DEBUG
       // Debug helpers: validate that a nursery pointer is in an allocated region.
       bool isInFromSpaceAllocatedRegion(void* ptr) const;
       bool isInToSpaceAllocatedRegion(void* ptr) const;
       void debugAssertValidNurseryPointer(void* ptr) const;
   #endif
   ```

3. **In `NurserySpaceTestAccess`, add test access:**
   ```cpp
   static void clearToSpaceFreeRegion(NurserySpace& nursery) {
       nursery.clearToSpaceFreeRegion();
   }
   ```

### Step 4: Add forwarder on ThreadLocalHeap.hpp

In `ThreadLocalHeap`, add a public method:

```cpp
#if ECO_GC_DEBUG
    void debugAssertValidNurseryPointer(void* ptr) {
        nursery_.debugAssertValidNurseryPointer(ptr);
    }
#endif
```

This keeps `NurserySpace`'s debug API private while giving `Allocator::resolve()` a clean call path.

### Step 5: Implement `clearToSpaceFreeRegion()` in NurserySpace.cpp

Add `#include <cstring>` if not already present. Implement:

```cpp
void NurserySpace::clearToSpaceFreeRegion() {
    std::vector<char*>& to_blocks = from_is_low_ ? high_blocks_ : low_blocks_;
    if (to_blocks.empty() || current_to_idx_ >= to_blocks.size())
        return;

    for (size_t i = current_to_idx_; i < to_blocks.size(); ++i) {
        char* block_start = to_blocks[i];
        char* block_end   = block_start + block_size_;
        char* start       = (i == current_to_idx_) ? copy_ptr_ : block_start;
        if (start < block_end) {
            std::memset(start, 0, static_cast<size_t>(block_end - start));
        }
    }
}
```

**Key**: zeros from `copy_ptr_` (end of survivors) through end of all to-space blocks. This is unconditional — runs in both Debug and Release.

### Step 6: Wire `clearToSpaceFreeRegion()` into `minorGC()`

In `NurserySpace::minorGC()`:

**At entry** (after the `#if ENABLE_GC_STATS` block, around line 394):
```cpp
#if ECO_GC_DEBUG
    in_minor_gc_ = true;
#endif
```

**After Phase 4, before Phase 5** (between `checkAndGrow()` at line 460 and `from_is_low_ = !from_is_low_` at line 463):
```cpp
    // Phase 4: Check occupancy and grow if needed.
    checkAndGrow();

    // Safety net: zero free to-space region to prevent ghost headers.
    // Called after checkAndGrow() so newly added blocks are also zeroed.
    clearToSpaceFreeRegion();

    // Phase 5: Swap spaces by flipping which is from/to.
    from_is_low_ = !from_is_low_;
```

**Before stats recording** (around line 473, before `#if ENABLE_GC_STATS`):
```cpp
#if ECO_GC_DEBUG
    in_minor_gc_ = false;
#endif
```

### Step 7: Implement debug helpers in NurserySpace.cpp

Under `#if ECO_GC_DEBUG`, implement three functions:

- **`isInFromSpaceAllocatedRegion(void* ptr)`**: Returns true if `ptr` is in a fully-filled from-space block (index < `current_from_idx_`) or in `[block_start, alloc_ptr_)` of the `current_from_idx_` block. Returns false for blocks after `current_from_idx_`.

- **`isInToSpaceAllocatedRegion(void* ptr)`**: Same logic but for to-space blocks using `current_to_idx_` / `copy_ptr_`.

- **`debugAssertValidNurseryPointer(void* ptr)`**:
  - Asserts `contains(ptr)`.
  - Mutator phase (`!in_minor_gc_`): asserts pointer is in from-space allocated region only.
  - GC phase (`in_minor_gc_`): asserts pointer is in from-space OR to-space allocated region.
  - Assertion message: `"HPointer into nursery free region (stale pointer into unallocated space)"`.

### Step 8: Instrument `evacuate()` and `evacuateJitPtr()` with debug checks

**In `evacuate()`** (NurserySpace.cpp:506), after the constant/null checks and `fromPointerRaw` (line 510-511), before the heap-bounds assertions:

```cpp
#if ECO_GC_DEBUG
    if (contains(obj)) {
        debugAssertValidNurseryPointer(obj);
    }
#endif
```

**In `evacuateJitPtr()`**, after converting the raw `uint64_t` to a `void*` pointer and before processing:

```cpp
#if ECO_GC_DEBUG
    if (contains(obj)) {
        debugAssertValidNurseryPointer(obj);
    }
#endif
```

### Step 9: Instrument `Allocator::resolve()` with debug check

In `Allocator::resolve()` (Allocator.cpp:391), after `fromPointerRaw(ptr)` (line 394) and the heap-bounds assertions, before the forwarding loop:

```cpp
#if ECO_GC_DEBUG
    ThreadLocalHeap* heap = getThreadHeap();
    if (heap != nullptr && heap->isInNursery(obj)) {
        heap->debugAssertValidNurseryPointer(obj);
    }
#endif
```

This calls the `ThreadLocalHeap` forwarder (Step 4), which delegates to `NurserySpace`. Catches stale nursery pointers from the mutator side, outside of GC.

### Step 10: Build and test

1. Build debug: `cmake --preset ninja-clang-lld-linux-debug && cmake --build build`
2. Run E2E: `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`
3. Verify no assertions fire on existing passing tests.
4. Verify `clearToSpaceFreeRegion` runs (can add temporary `fprintf` or check via debugger).
5. Build release (with `ECO_GC_DEBUG=OFF`): confirm `clearToSpaceFreeRegion` still runs but debug assertions are compiled out.
