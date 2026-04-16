# GC Diagnostics Guide

Instrumentation recipes for debugging stale HPointer and GC root coverage issues. All changes are temporary — strip them once the bug is resolved.

## 1. Enhanced stale-pointer diagnostic dump

In `NurserySpace.cpp`, replace the bare assert in `debugAssertValidNurseryPointer` with a detailed dump that prints the full nursery layout, the pointed-at memory, and a C++ backtrace before aborting.

**Requires:** `#include <execinfo.h>` at the top of NurserySpace.cpp.

```cpp
// In NurserySpace.cpp debugAssertValidNurseryPointer(), replace:
//   assert(ok && "HPointer into nursery free region ...");
// with:

    if (!ok) {
        const std::vector<char*>& from_blocks = from_is_low_ ? low_blocks_ : high_blocks_;
        const std::vector<char*>& to_blocks   = from_is_low_ ? high_blocks_ : low_blocks_;
        std::fprintf(stderr,
            "[gc-debug] STALE nursery pointer: ptr=%p in_minor_gc=%d from_is_low=%d\n"
            "  from_space: current_from_idx=%zu alloc_ptr=%p (%zu blocks)\n"
            "  to_space:   current_to_idx=%zu   copy_ptr=%p  (%zu blocks)\n",
            ptr, (int)in_minor_gc_, (int)from_is_low_,
            current_from_idx_, (void*)alloc_ptr_, from_blocks.size(),
            current_to_idx_,   (void*)copy_ptr_,  to_blocks.size());
        for (size_t i = 0; i < from_blocks.size(); ++i) {
            char* bs = from_blocks[i];
            char* be = bs + block_size_;
            const char* role = (i < current_from_idx_) ? "full"
                             : (i == current_from_idx_ ? "cur" : "free");
            std::fprintf(stderr, "  from[%zu]=%p..%p (%s)%s\n",
                         i, (void*)bs, (void*)be, role,
                         (ptr >= bs && ptr < be) ? " <-- PTR" : "");
        }
        for (size_t i = 0; i < to_blocks.size(); ++i) {
            char* bs = to_blocks[i];
            char* be = bs + block_size_;
            const char* role = (i < current_to_idx_) ? "full"
                             : (i == current_to_idx_ ? "cur" : "free");
            std::fprintf(stderr, "  to  [%zu]=%p..%p (%s)%s\n",
                         i, (void*)bs, (void*)be, role,
                         (ptr >= bs && ptr < be) ? " <-- PTR" : "");
        }
        uint64_t* w = reinterpret_cast<uint64_t*>(ptr);
        std::fprintf(stderr, "  *ptr   = 0x%016lx\n", w[0]);
        std::fprintf(stderr, "  ptr[1] = 0x%016lx\n", w[1]);
        std::fprintf(stderr, "  ptr[2] = 0x%016lx\n", w[2]);
        std::fprintf(stderr, "  ptr[3] = 0x%016lx\n", w[3]);
        std::fflush(stderr);
        void* bt[40];
        int n = backtrace(bt, 40);
        backtrace_symbols_fd(bt, n, fileno(stderr));
    }
    assert(ok && "HPointer into nursery free region (stale pointer into unallocated space)");
```

## 2. Scan parent tracking

Track which heap object is currently being scanned during Cheney scan, so that when a stale child pointer is found, the parent's tag, size, and fields are printed.

Add file-scope globals in `NurserySpace.cpp` (before `namespace Elm {`):

```cpp
thread_local void* g_scan_parent = nullptr;
thread_local int g_scan_tag = -1;
thread_local Elm::u32 g_scan_size = 0;
```

At the top of `scanObject()`, before the `switch`:

```cpp
g_scan_parent = obj;
g_scan_tag = hdr->tag;
g_scan_size = hdr->size;
```

In the diagnostic dump (section 1), add after the backtrace:

```cpp
if (g_scan_parent) {
    std::fprintf(stderr, "  SCAN PARENT: obj=%p tag=%d size=%u\n",
                 g_scan_parent, g_scan_tag, (unsigned)g_scan_size);
    uint64_t* pw = reinterpret_cast<uint64_t*>(g_scan_parent);
    for (int x = 0; x < (int)g_scan_size + 3 && x < 12; x++) {
        std::fprintf(stderr, "  parent[%d] = 0x%016lx\n", x, pw[x]);
    }
}
```

## 3. GC phase tracing

Add phase-entry logging in `minorGC()` to identify which GC phase contains the stale pointer. Insert before each phase's loop:

```cpp
std::fprintf(stderr, "[gc] minorGC start from_is_low=%d\n", (int)from_is_low_);
// Phase 1a:
std::fprintf(stderr, "[gc] phase 1a: %zu long-lived roots\n", root_set.getRoots().size());
// Phase 1b:
std::fprintf(stderr, "[gc] phase 1b: %zu stack roots\n", root_set.getStackRoots().size());
// Phase 1c:
std::fprintf(stderr, "[gc] phase 1c: %zu jit roots\n", root_set.getJitRoots().size());
// Phase 1e:
std::fprintf(stderr, "[gc] phase 1e: %zu stack root ranges\n", root_set.getStackRootRanges().size());
// Phase 1d:
std::fprintf(stderr, "[gc] phase 1d: %zu external scanners\n", root_set.getExternalRootScanners().size());
// Phase 2:
std::fprintf(stderr, "[gc] phase 2: Cheney scan starts\n");
```

## 4. Per-object scan tracing (Custom)

Add detailed field-by-field dump inside `scanObject()` for `Tag_Custom`:

```cpp
case Tag_Custom: {
    Custom *c = static_cast<Custom *>(obj);
    std::fprintf(stderr, "[scan-custom] obj=%p ctor=%u unboxed=0x%lx size=%u\n",
                 obj, (unsigned)c->ctor, (unsigned long)c->unboxed, (unsigned)hdr->size);
    for (u32 i = 0; i < hdr->size && i < 48; i++) {
        bool is_boxed = !(c->unboxed & (1ULL << i));
        std::fprintf(stderr, "[scan-custom]   field[%u]%s raw=0x%016lx\n",
                     i, is_boxed ? " boxed" : " unboxed", (unsigned long)c->values[i].i);
        std::fflush(stderr);
        evacuateUnboxable(c->values[i], is_boxed, oldgen, promoted_objects);
    }
    break;
}
```

## 5. eco_pap_extend tracing

In `RuntimeExports.cpp`, add before the `hpointerToPtr` call in `eco_pap_extend`:

```cpp
std::fprintf(stderr, "[pap_extend] closure_hptr=0x%016lx num_newargs=%u new_unboxed_bitmap=0x%lx\n",
             closure_hptr, num_newargs, new_unboxed_bitmap);
for (uint32_t i = 0; i < num_newargs; ++i) {
    std::fprintf(stderr, "  arg[%u]=0x%016lx%s\n", i, args[i],
                 ((new_unboxed_bitmap >> i) & 1) ? " (unboxed)" : "");
}
std::fflush(stderr);
```

**Warning:** This is extremely high-volume. Redirect stderr to a file and use grep/tail to find the relevant entries.

## 6. Catch stale writes at store time

In `RuntimeExports.cpp eco_store_field()`, add before the `hpointerToPtr(obj_hptr)` call:

```cpp
#if ECO_GC_DEBUG
    hpointerToPtr(value);  // triggers debugAssertValidNurseryPointer on stale values
#endif
```

This catches stale HPointers at the moment they're written to a heap field, producing a backtrace that shows which compiled function wrote the stale value. Requires `ThreadLocalHeap.hpp` and `NurserySpace.hpp` includes.

## 7. EcoGCPrepare root logging

In `EcoGCPrepare.cpp`, add after computing liveRoots for alloc group leaders:

```cpp
if (liveRoots.size() > before) {
    llvm::errs() << "[EcoGCPrepare-FIX] Added " << (liveRoots.size() - before)
                 << " operand roots to " << group.front()->getName()
                 << " at " << group.front()->getLoc() << "\n";
}
```

This verifies that the operand-union fix is actually adding roots.

## Typical investigation workflow

1. Run Stage 7 with `ECO_GC_DEBUG=1` (default in Debug builds).
2. If the assert fires, add section 1 (diagnostic dump) to see WHERE the stale pointer is.
3. Add section 2 (scan parent) to identify WHICH heap object contains it.
4. Add section 6 (store field validation) to catch the write at the moment it happens — if it fires with `in_minor_gc=0`, the stale write is from mutator code and the backtrace shows the exact compiled function.
5. If the stale write isn't caught by section 6, the value was stored inside a C++ runtime function (eco_alloc_cons, eco_pap_extend, etc.) — add section 5 to trace the specific call.
6. Use `grep` on the stale HPointer value to find its last valid use in the log, counting GC cycles between valid use and stale detection.
