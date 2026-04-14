# Plan: Stackmap + Unwinder-based GC Stack Root Scanning

## Status: Not Started

## Goal

Replace `ThreadLocalHeap::collectStackRootsFromStackMap()`'s RBP-chain + offset guessing with a proper unwinder-based design that:
- Uses **libunwind** to walk frames of the current thread
- For each frame, obtains a **register file** (by DWARF number)
- Applies `StackMapLocation` entries (Indirect/Register) as `value_of(Reg) + offset`
- Works in both **JIT** (`EcoRunner`/`ecoc -emit=jit`) and **AOT** (`EcoRuntimeStatic`)
- Targets **x86-64 Linux** initially; leaves hooks for other architectures

## Constraints

- Keep the existing **statepoint + LLVM v3 stackmap pipeline** unchanged (EcoGCPrepare, StatepointConversion, StackMap parser, etc.)
- Each thread has its own `ThreadLocalHeap` and runs GC stop-the-world only for itself, so unwinding the current thread's stack is sufficient
- Existing `StackMap` API (`findRecord(uint64_t returnAddress)`) stays unchanged

---

## 1. New module: StackUnwind abstraction

### Files
- **NEW** `runtime/src/allocator/StackUnwind.hpp`
- **NEW** `runtime/src/allocator/StackUnwind.cpp`

### Design

Small runtime abstraction over `libunwind`:
- Capture current thread's context
- Step frame by frame from topmost frame downwards
- Query value of arbitrary registers by DWARF register number per frame

### Header: `StackUnwind.hpp`

```cpp
#ifndef ECO_STACK_UNWIND_H
#define ECO_STACK_UNWIND_H

#include <cstdint>
#include <memory>

namespace Elm {
namespace StackUnwind {

class Context {
public:
    Context();
    ~Context() = default;
    Context(const Context&) = delete;
    Context& operator=(const Context&) = delete;
private:
    friend class Cursor;
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

class Cursor {
public:
    explicit Cursor(Context& ctx);
    ~Cursor() = default;
    Cursor(const Cursor&) = delete;
    Cursor& operator=(const Cursor&) = delete;

    bool step();
    uintptr_t ip() const;
    bool getRegister(uint16_t dwarfRegNum, uintptr_t& outValue) const;
private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace StackUnwind
} // namespace Elm

#endif
```

### Implementation: `StackUnwind.cpp`

- Uses `unw_getcontext`, `unw_init_local`, `unw_step`, `unw_get_reg` from libunwind
- DWARF→unwind reg mapping isolated in `mapDwarfToUnwindReg()` — identity for x86-64 GPRs 0..15, extensible for ARM64 later
- `ECO_DEBUG_STACKMAP` logging on failure paths
- Memory managed via `std::unique_ptr<Impl>` (constructed with `std::make_unique<Impl>()`)

---

## 2. Stackmap key semantics with unwinder

- For each frame, the unwinder returns an IP (program counter)
- Existing `StackMap::findRecord(uint64_t returnAddress)` keys by `function_address + instructionOffset`
- Pass `returnAddress = ip` from the unwinder cursor to `findRecord()` exactly as before
- No changes to `StackMap` API required

### IP vs return-address calibration (must verify once)

The current RBP walker uses `rbp[1]` (saved return address in the callee frame). The unwinder's IP for a frame may or may not match this exactly. Concrete verification strategy:

1. Write a small C++ test function with a known safepoint/call:
   ```cpp
   void callee();
   void f() { /* locals */ callee(); /* safepoint */ }
   ```
2. Instrument the current RBP-based walker to print the `returnAddress` (`rbp[1]`) when it finds the stackmap record for this safepoint.
3. In a debug build, also call `unw_get_reg(UNW_REG_IP, &ip)` at the same GC point and print that IP.
4. Compare:
   - If `ip == returnAddress` → key stackmaps by `ip` directly.
   - If `ip == returnAddress ± 1` → adjust once.
5. Codify as a constant: `static constexpr int kIpToReturnAddressBias = 0;` (or `-1`) with a comment explaining the calibration.

This only needs to be done once per platform/ABI.

---

## 3. Rewrite `collectStackRootsFromStackMap()`

### File: `runtime/src/allocator/ThreadLocalHeap.cpp`

Replace the body of `collectStackRootsFromStackMap()` with:

1. Create `StackUnwind::Context` + `Cursor` for current thread
2. For each frame:
   - Get frame's IP via `cur.ip()`
   - Look up `globalStackMap().findRecord(ip + kIpToReturnAddressBias)` for a `StackMapRecord`
   - For each `StackMapLocation` in the record:
     - **Indirect**: `getRegister(loc.dwarfRegNum)` → compute `addr = base + loc.offset` → register as GC root via `roots.pushStackRoot(reinterpret_cast<HPointer*>(addr))`
     - **Register/Direct/Constant/ConstantIndex**: log debug warning (matching existing behavior); Register handling is a future extension
3. Stop when `cur.step()` reports no more frames

### Frame skipping

No explicit frame skipping needed at entry. For non-safepoint frames (collectStackRoots, GC entry, allocator internals), `findRecord(ip)` returns `nullptr` because no stackmap records exist for those addresses. This is functionally correct — just a few extra hash lookups per GC. Can optimize later if profiling shows it matters.

### Implementation sketch

```cpp
void ThreadLocalHeap::collectStackRootsFromStackMap() {
    RootSet& roots = getRootSet();
    StackMap& sm = globalStackMap();
    if (!sm.hasRecords()) return;

    using namespace StackUnwind;
    Context ctx;
    Cursor cur(ctx);

    do {
        uintptr_t ip = cur.ip();
        const StackMapRecord* rec = sm.findRecord(ip + kIpToReturnAddressBias);
        if (!rec) continue;

        for (const StackMapLocation& loc : rec->locations) {
            if (loc.kind == StackMapLocation::Indirect) {
                uintptr_t base = 0;
                if (!cur.getRegister(loc.dwarfRegNum, base)) {
#if ECO_DEBUG_STACKMAP
                    fprintf(stderr,
                        "[ECO_DEBUG_STACKMAP] Failed to read reg %u for IP=%p\n",
                        loc.dwarfRegNum, (void*)ip);
#endif
                    continue;
                }
                uintptr_t addr = base + static_cast<int32_t>(loc.offset);
                auto* slot = reinterpret_cast<HPointer*>(addr);

                Allocator& alloc = Allocator::instance();
                HPointer potential = *slot;
                void* phys = alloc.resolve(potential);
                if (phys != nullptr && alloc.isInHeap(phys)) {
                    roots.pushStackRoot(slot);
                }
            } else {
#if ECO_DEBUG_STACKMAP
                fprintf(stderr,
                    "[ECO_DEBUG_STACKMAP] Non-Indirect location kind=%u at IP=%p\n",
                    loc.kind, (void*)ip);
#endif
            }
        }
    } while (cur.step());
}
```

### Verified APIs
- `RootSet::pushStackRoot(HPointer*)` — appends to `std::vector<HPointer*> stack_roots`
- `Allocator::instance().resolve(HPointer)` — returns `nullptr` for embedded constants
- `Allocator::instance().isInHeap(void*)` — O(1) bounds check

---

## 4. Build system changes

### File: `runtime/src/codegen/CMakeLists.txt`

#### Add `StackUnwind.cpp` to source lists for:
- `ecoc` (JIT compiler executable)
- `EcoRunner` (JIT test library)
- `EcoRuntimeStatic` (AOT runtime static library)

#### Link libunwind

libunwind is a **mandatory dependency** — there is no fallback. The Dockerfile includes `libunwind-dev` (provides headers + linker symlink; runtime `.so` already present).

```cmake
find_library(LIBUNWIND_LIB unwind REQUIRED)
```

Add `${LIBUNWIND_LIB}` to `target_link_libraries` for `ecoc` and `EcoRunner`.

#### EcoRuntimeStatic linking

`EcoRuntimeStatic` is a static library — use CMake `PUBLIC` linking to propagate the dependency transitively to all consumers (including AOT binaries produced by `eco-boot`):

```cmake
target_link_libraries(EcoRuntimeStatic PUBLIC ${LIBUNWIND_LIB})
```

This ensures any executable linking `EcoRuntimeStatic` automatically picks up `-lunwind` without needing to modify `eco-boot`'s link driver or `EcoBootConfig.h`.

---

## 5. JIT unwind info registration (critical for JIT mode)

For libunwind to walk through JIT'd Eco frames, it must be able to see their `.eh_frame` unwind info. LLVM's ORC JIT does **not** automatically call `__register_frame()` for external unwinders like libunwind.

### Required changes in EcoJIT

EcoJIT already has custom listener code to capture `__LLVM_StackMaps` sections from JIT'd objects. Extend this to also:

1. **On JIT object load**: extract the `.eh_frame` section and call `__register_frame(eh_frame_ptr)` to register it with the platform unwinder.
2. **On JIT object unload**: call `__deregister_frame(eh_frame_ptr)` to clean up.

Without this, libunwind will only see C++/AOT frames and will fail to unwind through JIT'd Eco frames, silently missing all JIT stack roots.

### Verification
- In a debug build, confirm that after JIT loading, `libunwind` can step through JIT'd frames (IP resolves to JIT code addresses).
- If `__register_frame` is insufficient (some platforms use `__register_frame_info`), adapt accordingly.

---

## 6. Clean up old RBP-chain walker

- Delete or `#if 0` any RBP-chain based logic in `collectStackRootsFromStackMap()` and related helpers
- Remove RBP/RSP approximations (e.g. `callerRbp + 16` RSP reconstruction)

---

## 7. Documentation updates

- `THEORY.md`: change "walks x86-64 frame pointer chain" → "uses platform unwind info (libunwind) to walk frames and apply stackmaps"
- `design_docs/llvm_stackmap_integration.md`: update description of `collectStackRootsFromStackMap`

---

## 8. Testing and validation

### IP vs RA calibration test (do first)
- Instrument both old walker and new unwinder in parallel in a debug build
- Compare `rbp[1]` vs `unw_get_reg(UNW_REG_IP)` for the same safepoint frame
- Determine and codify `kIpToReturnAddressBias`

### Baseline tests
- Re-run existing GC correctness and E2E tests
- Confirm back to baseline failure count (not 500+ SIGABRTs)

### Targeted RSP-based-root test
- Find/construct case where LLVM emits RSP-based Indirect roots
- Add `ECO_DEBUG_STACKMAP` logging printing each `loc.dwarfRegNum` and offset
- Verify both reg 6 (RBP) and reg 7 (RSP) appear and are handled

### JIT unwind verification
- Confirm libunwind can step through JIT'd frames after `__register_frame` integration
- Verify stack roots from JIT'd code are correctly collected

### Stress tests / bootstrap
- Run Stage 7 self-compile that previously crashed
- Confirm no new GC corruption

### Negative tests
- Temporarily remove unwind info for JIT functions
- Verify `getRegister` fails, debug logging fires, process handles gracefully

---

## 9. Checklist

### New files
- [ ] `runtime/src/allocator/StackUnwind.hpp`
- [ ] `runtime/src/allocator/StackUnwind.cpp`

### Modified files
- [ ] `runtime/src/allocator/ThreadLocalHeap.cpp` — replace `collectStackRootsFromStackMap()` body
- [ ] `runtime/src/allocator/StackMap.cpp` — optional debugging additions
- [ ] `runtime/src/codegen/CMakeLists.txt` — add StackUnwind.cpp sources + libunwind linking
- [ ] `runtime/src/jit/EcoJIT.cpp` (or equivalent) — register/deregister `.eh_frame` for JIT objects
- [ ] `eco-boot` link driver — add `-lunwind` to AOT executable link line
- [ ] `THEORY.md` — update GC stack root description
- [ ] `design_docs/llvm_stackmap_integration.md` — update collectStackRootsFromStackMap description

### Validation
- [ ] IP vs RA calibration test completed, `kIpToReturnAddressBias` determined
- [ ] E2E tests pass at baseline
- [ ] RSP-based roots verified working
- [ ] JIT unwind info registration verified (libunwind walks JIT frames)
- [ ] Stage 7 self-compile passes
- [ ] Negative tests for missing unwind info
- [ ] Old RBP-chain code removed
