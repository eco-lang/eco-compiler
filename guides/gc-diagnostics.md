# GC Diagnostics Guide

Instrumentation recipes for debugging stale HPointer and GC root coverage
issues. Sections 1–6 are manual code patches (apply/strip as needed). Sections
7–12 are **currently live in the codebase** behind compile-time flags (see
flag reference below).

---

## Compile-time flag

All GC diagnostics are behind a single flag: **`ECO_GC_DEBUG`**.

| Flag | Defined by CMake? | Default | Targets |
|------|------------------|---------|---------|
| `ECO_GC_DEBUG` | Yes — CMake option | ON for Debug, OFF for Release | `EcoPasses`, `ecoc`, `EcoRunner`, `EcoRuntimeStatic`, `EcoEntryStatic` |

The flag controls both compile-time instrumentation (sections 7–9, which fire
during MLIR→LLVM lowering inside the compiler) and runtime instrumentation
(sections 10–12, which fire during program execution). All output goes to
stderr.

To force-enable in a Release build: `cmake -DECO_GC_DEBUG=ON ...`

**Warning:** The compile-time instrumentation (sections 7–9) produces enormous
output — one log line per GCRootCarrier op per function. Redirect stderr to a
file and use grep to find the relevant entries.

---

## Pipeline overview

A stale HPointer can originate at four points in the pipeline:

| # | Layer | File(s) | What to check |
|---|-------|---------|---------------|
| 1 | Eco IR liveness | `EcoGCPrepare.cpp` | Are all live `!eco.value` included in GCRootCarrier roots? |
| 2 | MLIR→LLVM lowering | `EcoToLLVMRuntime.cpp`, `EcoToLLVMHeap.cpp`, `EcoToLLVMClosures.cpp` | Do liveRoots survive into `__eco_safepoint_marker` args? |
| 3 | LLVM statepoints | `StatepointConversion.cpp` | Do marker args appear in `gc.statepoint` gc-live bundles? |
| 4 | Runtime stackmap | `ThreadLocalHeap.cpp`, `StackMap.cpp` | Does the GC actually read & evacuate these roots at runtime? |

---

## Currently live instrumentation

### Compile-time instrumentation (fires during compilation)

These fire during MLIR→LLVM lowering inside `eco-compiler` / `eco-boot`.
Output goes to stderr of the compiler process and is enormous; redirect to a
file.

#### 7. EcoGCPrepare — per-carrier root dump + strict self-check

**File:** `EcoGCPrepare.cpp`  
**Flag:** `ECO_GC_DEBUG`

At the end of `processBlock()`, every `GCRootCarrier` op in the block is
dumped with its `!eco.value` operands and attached roots:

```
[gc-liveness] func=Dict_insertHelp_$_5182 op=eco.construct.custom loc=...
  eco.value operands: %arg0 %arg1 %arg2 %arg3 %arg4
  attached roots (5): %arg0 %arg1 %arg2 %arg3 %arg4
```

After all functions are processed, a **strict self-check** re-runs
`computeLiveRoots` + operand union for every carrier and reports any value
that should be rooted but isn't:

```
[gc-liveness-CHECK] MISSING ROOT in func=... op=eco.papExtend at ...
  missing value: %42
  attached roots (3): ...
```

#### 8. Eco→LLVM lowering — safepoint marker root dump

**File:** `EcoToLLVMRuntime.cpp`  
**Flag:** `ECO_GC_DEBUG`

`emitAllocWithSafepoint` and `emitSafepointMarker` log the function, op, and
every LLVM i64 value passed as a live root:

```
[gc-lowering] emitAllocWithSafepoint func=Dict_RBNode_elm_builtin_$_5183 op=eco.construct.custom alloc=eco_alloc_custom liveRoots=5
  root[0] = %arg0
  root[1] = %arg1
  ...
```

#### 9. StatepointConversion — gc-live bundle dump

**File:** `StatepointConversion.cpp`  
**Flag:** `ECO_GC_DEBUG`

After building each `gc.statepoint`, the function name, target call, marker
arg count, and every gc-live value (stripped back to i64) are logged:

```
[gc-statepoint] func=Dict_RBNode_elm_builtin_$_5183 target=eco_alloc_custom marker_args=5 gc-live=5
  gc-live[0] = %arg0
  gc-live[1] = %arg1
  ...
```

### Runtime instrumentation (ECO_GC_DEBUG)

These fire at runtime during program execution. Enabled by default in Debug
builds via the `ECO_GC_DEBUG` CMake option.

#### 10. Runtime stackmap scanning — per-frame root dump

**File:** `ThreadLocalHeap.cpp`  
**Flag:** `ECO_GC_DEBUG`

During `collectStackRootsFromStackMap()`, each frame's IP and root count are
logged, and every Indirect root location is decoded with its raw HPointer
value, resolved physical address, and object tag:

```
[gc-stackmap] frame IP=0x55a14bf6f811 numLocs=3
  root[0] kind=Indirect reg=7 off=-48 -> raw=0x0000000004002f3c phys=0x7f21dffb3960 tag=7
  root[1] kind=Indirect reg=7 off=-56 -> constant (raw=0x0000050000000000)
  root[2] kind=Indirect reg=7 off=-64 -> raw=0x0000000004003a7d phys=0x7f21dffc53e8 tag=11
```

Also logs warnings when no stackmap records are found (`[gc-stackmap] WARNING`),
missed frame IPs (`[gc-stackmap] MISS`), and non-Indirect location kinds that
are skipped.

#### 11. StackMap parse — record dump

**File:** `StackMap.cpp`  
**Flag:** `ECO_GC_DEBUG`

During `StackMap::parse()`, the first 20 stackmap records are logged with
their function address, instruction offset, computed return address key, and
location count:

```
[stackmap-parse] record 0: func=0x55a14bf6f000 instOff=123 -> key=0x55a14bf6f07b numLocs=3
[stackmap-parse] record 1: func=0x55a14bf6f000 instOff=456 -> key=0x55a14bf6f1c8 numLocs=2
```

This helps verify that the stackmap section was found and parsed correctly,
and that function addresses align with expected code layout.

#### 12. Startup stackmap init — parse status

**File:** `eco_entry.cpp`  
**Flag:** `ECO_GC_DEBUG`

During AOT binary startup, `initStackMapFromSelf()` prints the result of
parsing the `.llvm_stackmaps` ELF section:

```
[init] stackmap: data=0x55a14c000000 size=1234 parsed=1 hasRecords=1
```

Or, if the section is not found:

```
[init] stackmap: NOT FOUND (data=(nil) size=0)
```

---

## Manual instrumentation recipes (apply as needed)

### 1. Enhanced stale-pointer diagnostic dump

In `NurserySpace.cpp`, replace the bare assert in
`debugAssertValidNurseryPointer` with a detailed dump that prints the full
nursery layout, the pointed-at memory, and a C++ backtrace before aborting.

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

### 2. Scan parent tracking

Track which heap object is currently being scanned during Cheney scan, so
that when a stale child pointer is found, the parent's tag, size, and fields
are printed.

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

### 3. GC phase tracing

Add phase-entry logging in `minorGC()` to identify which GC phase contains
the stale pointer. Insert before each phase's loop:

```cpp
std::fprintf(stderr, "[gc] minorGC start from_is_low=%d\n", (int)from_is_low_);
// Before Phase 1a:
std::fprintf(stderr, "[gc] phase 1a: %zu long-lived roots\n", root_set.getRoots().size());
// Before Phase 1b:
std::fprintf(stderr, "[gc] phase 1b: %zu stack roots\n", root_set.getStackRoots().size());
// Before Phase 1c:
std::fprintf(stderr, "[gc] phase 1c: %zu jit roots\n", root_set.getJitRoots().size());
// Before Phase 1e:
std::fprintf(stderr, "[gc] phase 1e: %zu stack root ranges\n", root_set.getStackRootRanges().size());
// Before Phase 1d:
std::fprintf(stderr, "[gc] phase 1d: %zu external scanners\n", root_set.getExternalRootScanners().size());
// Before Phase 2:
std::fprintf(stderr, "[gc] phase 2: Cheney scan starts\n");
```

### 4. Per-object scan tracing (Custom)

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

### 5. eco_pap_extend tracing

In `RuntimeExports.cpp`, add before the `hpointerToPtr` call in
`eco_pap_extend`:

```cpp
std::fprintf(stderr, "[pap_extend] closure_hptr=0x%016lx num_newargs=%u new_unboxed_bitmap=0x%lx\n",
             closure_hptr, num_newargs, new_unboxed_bitmap);
for (uint32_t i = 0; i < num_newargs; ++i) {
    std::fprintf(stderr, "  arg[%u]=0x%016lx%s\n", i, args[i],
                 ((new_unboxed_bitmap >> i) & 1) ? " (unboxed)" : "");
}
std::fflush(stderr);
```

**Warning:** This is extremely high-volume. Redirect stderr to a file and use
grep/tail to find the relevant entries.

### 6. Catch stale writes at store time

In `RuntimeExports.cpp eco_store_field()`, add before the
`hpointerToPtr(obj_hptr)` call:

```cpp
#if ECO_GC_DEBUG
    hpointerToPtr(value);  // triggers debugAssertValidNurseryPointer on stale values
#endif
```

This catches stale HPointers at the moment they're written to a heap field,
producing a crash + backtrace that shows which compiled function wrote the
stale value. Requires `ThreadLocalHeap.hpp` and `NurserySpace.hpp` includes.

---

## Investigation workflow

### Heap-side (where the stale pointer is found)

1. Run Stage 7 with `ECO_GC_DEBUG=1` (default in Debug builds).
2. If the assert fires, apply section 1 (diagnostic dump) to see WHERE the
   stale pointer is.
3. Apply section 2 (scan parent) to identify WHICH heap object contains it.
4. Apply section 6 (store field validation) to catch the write at the moment
   it happens — if it fires with `in_minor_gc=0`, the stale write is from
   mutator code and the backtrace shows the exact compiled function.
5. If the stale write isn't caught by section 6, the value was stored inside a
   C++ runtime function (eco_alloc_cons, eco_pap_extend, etc.) — apply
   section 5 to trace the specific call.
6. Use `grep` on the stale HPointer value to find its last valid use in the
   log, counting GC cycles between valid use and stale detection.

### Pipeline-side (why the root was missed)

To trace exactly where a live `!eco.value` fell out of the root set, use the
**live instrumentation** (sections 7–10) which is already compiled in:

1. **Redirect stderr** to a file (output is enormous):
   ```bash
   bin/eco-compiler make ... 2>/tmp/gc-trace.log
   ```

2. **Find the crashing function** from the gdb backtrace (e.g.
   `Dict_RBNode_elm_builtin_$_5183`).

3. **Check section 7** (`[gc-liveness]`): grep for the function name. Verify
   all `!eco.value` operands appear in the attached roots. If any are missing,
   the bug is in EcoGCPrepare.

4. **Check section 8** (`[gc-lowering]`): grep for `emitAllocWithSafepoint`
   or `emitSafepointMarker` for the same function. Verify liveRoots count
   matches. If roots were present in step 3 but absent here, the bug is in
   how the lowering splits operands from roots (e.g. `splitAdaptedRoots`,
   `adaptor.getLiveRoots()`).

5. **Check section 9** (`[gc-statepoint]`): grep for the function. Verify
   gc-live count matches the marker arg count. If roots were present in step 4
   but absent here, the bug is in `StatepointConversion` (e.g.
   `findTargetCall` latching onto the wrong call).

6. **Check section 10** (`[gc-stackmap]`): grep for the frame IP of the
   crashing function. Verify all gc-live values appear as Indirect roots with
   valid register/offset. If roots were present in step 5 but absent here,
   the bug is in LLVM stackmap emission or `StackMap` parsing.

The **first point in the chain** where a value is missing is where the
Layer-2 bug is.
