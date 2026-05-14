# GC Diagnostics Guide

Instrumentation recipes for debugging stale HPointer and GC root coverage
issues. Sections 1–6 are manual code patches (apply/strip as needed). Sections
7–12 are **currently live in the codebase** behind compile-time flags (see
flag reference below).

---

## Compile-time flags

GC diagnostics are split into two independent flags:

| Flag | Default | Targets | What it controls |
|------|---------|---------|-----------------|
| `ECO_GC_DEBUG` | ON for Debug, OFF for Release | `ecor`, `EcoRunner`, `EcoRuntimeStatic`, `EcoEntryStatic` (+ top-level `add_compile_definitions`) | Runtime instrumentation: stale-pointer checks, GC phase tracing, stackmap scanning, store-time validation |
| `ECO_GC_DEBUG_COMP` | OFF | `obj.EcoPasses` | Compile-time instrumentation: GCRootCarrier root dumps during MLIR lowering |
| `ECO_GC_DEBUG_LIVENESS` | OFF | `obj.EcoPasses`, `ecoc`, `obj.EcoRunner`, `eco-boot-native` | Post-RS4GC verification: `EcoGCLivenessAudit` (pre-RS4GC MLIR-level) and `EcoPtrIntVerify` (post-RS4GC LLVM-level ptr<1>↔i64 boundary check) |

The flags are independent. Enable only `ECO_GC_DEBUG` for runtime-only
investigation (the common case). Enable `ECO_GC_DEBUG_COMP` when you need to
trace root sets through the MLIR compilation pipeline.

```bash
# Runtime diagnostics only (recommended for Stage 7 investigation)
cmake --preset ninja-clang-lld-linux -DECO_GC_DEBUG=ON

# Compile-time diagnostics only (produces enormous output)
cmake --preset ninja-clang-lld-linux -DECO_GC_DEBUG_COMP=ON

# Both
cmake --preset ninja-clang-lld-linux -DECO_GC_DEBUG=ON -DECO_GC_DEBUG_COMP=ON
```

**Warning:** `ECO_GC_DEBUG_COMP` produces enormous output — one log line per
GCRootCarrier op per function. Redirect stderr to a file and use grep.

---

## Pipeline overview (RS4GC)

With the RS4GC migration, GC root tracking is handled by LLVM's
`RewriteStatepointsForGC` pass. A stale HPointer can originate at these
points:

| # | Layer | File(s) | What to check |
|---|-------|---------|---------------|
| 1 | Eco IR liveness | `EcoGCPrepare.cpp` | Are all live `!eco.value` included in GCRootCarrier roots? (Note: RS4GC computes its own liveness, so EcoGCPrepare roots are informational only) |
| 2 | gc-leaf-function attrs | `EcoToLLVMRuntime.cpp` | Is a may-GC function incorrectly marked `gc-leaf-function`? RS4GC skips gc-leaf calls. |
| 3 | RS4GC liveness | Post-RS4GC LLVM IR | Does RS4GC insert `gc.statepoint` around the right calls? Are all live `ptr addrspace(1)` values in `gc-live` bundles? Use `--dump-rs4gc-ir <file>` on eco-boot-native/ecoc. |
| 4 | Runtime stackmap | `ThreadLocalHeap.cpp`, `StackMap.cpp` | Does the GC actually read & evacuate these roots at runtime? |

**Key difference from old pipeline:** Layers 2-3 used to be `__eco_safepoint_marker` emission
and `StatepointConversion`. Now RS4GC handles both automatically. The main new failure modes are:
- A non-leaf function marked `gc-leaf-function` (RS4GC skips it entirely)
- RS4GC's liveness analysis misses a live root due to complex control flow
- A `ptr addrspace(1)` value is cast to/from a non-GC type, hiding it from RS4GC

### EcoPtrIntVerify (post-RS4GC LLVM-level)

`EcoPtrIntVerify` is a post-RS4GC LLVM `FunctionPass` that scans for
`ptrtoint`/`inttoptr` instructions involving `ptr addrspace(1)` and rejects any
that escape the allowed boundary patterns. It catches the "HPtr → i64 →
untracked → ptr<1>" loophole by construction.

**When to use:** enable `ECO_GC_DEBUG_LIVENESS` and rebuild. The pass runs
automatically after `RewriteStatepointsForGC` in all pipelines (ecoc,
EcoRunner, eco-boot-native).

```bash
cmake -B build -DECO_GC_DEBUG_LIVENESS=ON
cmake --build build --target full
```

**Diagnostic format:** hard error via `llvm::report_fatal_error`:
```
EcoPtrIntVerify: ptrtoint ptr addrspace(1) result escapes allowed patterns in function <F>; may be live across GC
EcoPtrIntVerify: inttoptr i64 -> ptr addrspace(1) from non-heap/non-args source in <F>
```

**Relationship to EcoGCLivenessAudit:** `EcoGCLivenessAudit` operates at the
MLIR level *before* RS4GC and verifies eco.value liveness annotations.
`EcoPtrIntVerify` operates at the LLVM IR level *after* RS4GC and verifies
that ptr<1>↔i64 crossings respect the allowed boundary patterns. Both are
gated by the same `ECO_GC_DEBUG_LIVENESS` flag.

---

## Currently live instrumentation

### Compile-time instrumentation (fires during compilation)

These fire during MLIR→LLVM lowering inside `eco-compiler` / `eco-boot`.
Output goes to stderr of the compiler process and is enormous; redirect to a
file.

#### 7. EcoGCPrepare — per-carrier root dump + strict self-check

**File:** `EcoGCPrepare.cpp`  
**Flag:** `ECO_GC_DEBUG_COMP`

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

#### 8. ~~Eco→LLVM lowering — safepoint marker root dump~~ (REMOVED — RS4GC migration)

No longer applicable. `emitAllocWithSafepoint` and `emitSafepointMarker` are
now no-ops; RS4GC computes liveness automatically from `ptr addrspace(1)` types.

#### 9. ~~StatepointConversion — gc-live bundle dump~~ (REMOVED — RS4GC migration)

No longer applicable. `StatepointConversion.cpp` has been deleted. RS4GC
handles gc.statepoint/gc.relocate insertion automatically.

**Replacement:** Use `--dump-rs4gc-ir <file>` on `eco-boot-native` or `ecoc`
to dump LLVM IR after RS4GC runs, then grep for `gc.statepoint` and `gc-live`
bundles for the function of interest.

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

## Manual instrumentation recipes

Recipes 1–3 and 6 are now **live behind `ECO_GC_DEBUG`** (applied during
the RS4GC migration). Recipes 4–5 remain manual-apply due to high output
volume.

### 1. Enhanced stale-pointer diagnostic dump (LIVE — ECO_GC_DEBUG)

In `NurserySpace.cpp`, `debugAssertValidNurseryPointer` prints the full
nursery layout, pointed-at memory, C++ backtrace, and scan parent info
before the assert fires. Also applied to the `evacuate` tag assertion.

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

### 2. Scan parent tracking (LIVE — ECO_GC_DEBUG)

Tracks which heap object is currently being scanned during Cheney scan.
When a stale child pointer is found, the parent's tag, size, and fields
are printed. Implemented via thread-local globals in `NurserySpace.cpp`.

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

### 3. GC phase tracing (LIVE — ECO_GC_DEBUG)

Phase-entry logging in `minorGC()` identifies which GC phase contains the
stale pointer. Logs root counts for each phase:

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

### 6. Catch stale writes at store time (LIVE — ECO_GC_DEBUG)

In `RuntimeExports.cpp eco_store_field()`, the value pointer is validated
early to catch stale writes at the moment they happen:

```cpp
#if ECO_GC_DEBUG
    hpointerToPtr(value);  // triggers debugAssertValidNurseryPointer on stale values
#endif
```

This catches stale HPointers at the moment they're written to a heap field,
producing a crash + backtrace that shows which compiled function wrote the
stale value. Requires `ThreadLocalHeap.hpp` and `NurserySpace.hpp` includes.

---

## How to enable diagnostics for Stage 7

Build everything with `ECO_GC_DEBUG=ON` so the debug runtime is linked into
the native `eco-compiler` binary. Then recompile `eco-compiler` from its MLIR
with the debug-enabled `eco-boot-native`, and run Stage 7 with stderr captured.

```bash
# 1. Configure and build with runtime GC debug ON (compile-time OFF to avoid noise)
cd /work
cmake --preset ninja-clang-lld-linux -DECO_GC_DEBUG=ON -DECO_GC_DEBUG_COMP=OFF
cmake --build build

# 2. Rebuild eco-compiler with debug runtime (Stage 6)
#    Also dump the post-RS4GC IR for pipeline-side investigation.
./build/runtime/src/codegen/eco-boot-native \
    --dump-rs4gc-ir /tmp/rs4gc-compiler.ll \
    build/compiler/build-kernel/bin/eco-compiler.mlir \
    -o build/compiler/build-kernel/bin/eco-compiler

# 3. Run Stage 7 with stderr captured
cd build/compiler/build-kernel
bin/eco-compiler make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler-boot.mlir \
    /work/compiler/src/Terminal/Main.elm \
    2>/tmp/stage7-gc.log

# 4. Investigate the crash
grep '\[gc-debug\]' /tmp/stage7-gc.log         # stale pointer / invalid tag details
grep '\[gc\] phase' /tmp/stage7-gc.log          # which GC phase crashed
grep 'SCAN PARENT' /tmp/stage7-gc.log           # parent object being scanned at crash
grep 'INVALID TAG' /tmp/stage7-gc.log           # invalid tag in evacuate
tail -100 /tmp/stage7-gc.log                    # last output before crash

# 5. Inspect post-RS4GC IR for the crashing function
#    (get function name from backtrace in step 4)
grep -A30 'define.*@FunctionName' /tmp/rs4gc-compiler.ll \
    | grep -E 'gc.statepoint|gc-live|gc.relocate'
```

**Note:** Steps 1-4 assume Stages 1-5 have already been run (MLIR exists at
`build/compiler/build-kernel/bin/eco-compiler.mlir`). If not, run the bootstrap
stages 1-5 first per `guides/bootstrap.md`.

---

## Investigation workflow

### Heap-side (where the stale pointer is found)

1. Build with `ECO_GC_DEBUG=ON`: `cmake -DECO_GC_DEBUG=ON -DECO_GC_DEBUG_COMP=OFF ...`
   Recipes 1–3 and 6 are now live — no manual patching needed.
2. Run Stage 7. The enhanced assert will print:
   - Nursery layout (from/to blocks with PTR marker)
   - Raw memory at the stale pointer
   - C++ backtrace
   - Scan parent (which heap object was being scanned)
3. If recipe 6 (store field validation) fires with `in_minor_gc=0`, the
   stale write is from mutator code — the backtrace shows the compiled function.
4. If the stale write isn't caught by recipe 6, the value was stored inside a
   C++ runtime function (eco_alloc_cons, eco_pap_extend, etc.) — apply
   recipe 5 manually to trace the specific call.
5. Use `grep` on the stale HPointer value to find its last valid use in the
   log, counting GC cycles between valid use and stale detection.

### Pipeline-side (why the root was missed — RS4GC)

With RS4GC, root tracking is automatic. The main failure modes are:

1. **Wrong gc-leaf-function:** A function that can trigger GC is marked
   `gc-leaf-function` → RS4GC skips it → roots not tracked across the call.
   - **Check:** Dump post-RS4GC IR (`--dump-rs4gc-ir`), find the call to the
     suspect function, verify it has a `gc.statepoint` wrapper.

2. **RS4GC liveness miss:** A live `ptr addrspace(1)` value isn't in the
   `gc-live` bundle of a statepoint.
   - **Check:** In the post-RS4GC IR, find the `gc.statepoint` at the crash
     site, verify the value appears in its `gc-live` operand bundle, and
     verify there's a corresponding `gc.relocate`.

3. **Type escape:** A `ptr addrspace(1)` value is cast to `i64` or `ptr`
   (addrspace 0) before a GC-triggering call, hiding it from RS4GC.
   - **Check:** In the pre-RS4GC IR (dump MLIR→LLVM translation output via
     `-emit=llvm`), look for `ptrtoint` or `addrspacecast` on the value.

**Diagnostic commands:**

```bash
# Dump post-RS4GC IR for a specific compilation
./build/runtime/src/codegen/eco-boot-native \
    --dump-rs4gc-ir /tmp/rs4gc.ll \
    build/compiler/build-kernel/bin/eco-compiler.mlir \
    -o /dev/null

# Find statepoints for a specific function
grep -A20 'define.*@FunctionName' /tmp/rs4gc.ll | grep -E 'gc.statepoint|gc-live|gc.relocate'

# Check gc-leaf-function attributes
grep 'gc-leaf-function' /tmp/rs4gc.ll
```

### Runtime stackmap investigation

Use the **live instrumentation** (sections 10–12) which is compiled in
behind `ECO_GC_DEBUG`:

1. **Redirect stderr** to a file (output is enormous):
   ```bash
   bin/eco-compiler make ... 2>/tmp/gc-trace.log
   ```

2. **Check section 10** (`[gc-stackmap]`): grep for the frame IP of the
   crashing function. Verify all gc-live values appear as Indirect roots with
   valid register/offset.

3. **Check section 11** (`[stackmap-parse]`): verify the stackmap section
   was parsed correctly and function addresses align.

4. **Check section 12** (`[init]`): verify the `.llvm_stackmaps` ELF section
   was found and parsed at startup.
