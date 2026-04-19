# Plan: JIT `.eh_frame` section-style registration for LLVM libunwind

## Problem

EcoRunner links against LLVM's libunwind (`eco::llvm_libunwind`) for stack
unwinding in GC root scanning. AOT binaries work because the dynamic loader
registers `.eh_frame` once per loaded section, which is what LLVM libunwind's
`__register_frame` expects.

JIT is broken: ORC's default `SectionMemoryManager::registerEHFrames()` walks
the `.eh_frame` block and calls `__register_frame(fde)` once per FDE. LLVM
libunwind treats each FDE as a malformed "section" and rejects it. Net effect:
JIT `.eh_frame` is never successfully registered, libunwind cannot step
through JIT frames, and the GC stack walker misses roots in JIT-compiled
code — manifesting as bogus roots, misaligned stackmap offsets in deeper
frames, and crashes such as `Invalid tag after forward resolution` and
`eco_pap_extend: new_n_values exceeds max_values`.

## Approach (Option 2)

Keep linking against LLVM libunwind. Provide a custom
`SectionMemoryManager` for ORC that overrides `registerEHFrames` /
`deregisterEHFrames` to call `__register_frame(Addr)` /
`__deregister_frame(Addr)` exactly **once per `.eh_frame` section** (i.e. with
the start address of the chained CIE/FDE block, not per individual FDE). This
matches LLVM libunwind's section-style API.

AOT binaries are unaffected — their `.eh_frame` is registered by the ELF
loader, not by our memory manager.

## Current state (read before editing)

- `runtime/src/jit/EcoJIT.h`
  - Lines 45–46: outdated comment claiming
    `RTDyldMemoryManager::registerEHFrames()` handles `.eh_frame` automatically.
- `runtime/src/jit/EcoJIT.cpp`
  - Already includes `llvm/ExecutionEngine/Orc/RTDyldObjectLinkingLayer.h`
    (line 23) and `llvm/ExecutionEngine/SectionMemoryManager.h` (via header).
  - The LLJIT is constructed in `EcoJIT::create()` (lines 182–258), **not** in
    `EcoJIT::initialize()` as the original Option-2 design assumed.
    `initialize()` only calls `jit_->initialize(MainJITDylib)`.
  - Object linking layer creator is already wired via
    `setObjectLinkingLayerCreator` at lines 213–225, currently constructing
    an `RTDyldObjectLinkingLayer` with the default `SectionMemoryManager`.
    The factory signature is `[](const MemoryBuffer &) { ... }`.
  - `StackMapListener::notifyObjectLoaded` (lines 87–94) carries an outdated
    comment explaining why we deliberately do **not** call `__register_frame`
    in the listener (because doing so on the file-bytes view used pre-relocation
    addresses). With the new memory-manager-based registration, the
    pre-relocation concern is moot — the memory manager sees the post-link
    loaded address — so the comment must be updated to reflect the new design.
- `runtime/src/codegen/CMakeLists.txt`
  - `EcoRunner` already links `eco::llvm_libunwind` PUBLIC at line 460.
  - `EcoRuntimeStatic` already links the same at line 494 (for AOT).
  - No CMake changes required.

## Step-by-step implementation plan

### 1. Pre-flight: confirm libunwind exports the entry points

Before writing any code, verify that the libunwind shared object resolved by
`eco::llvm_libunwind` exports both `__register_frame` and
`__deregister_frame`. LLVM libunwind generally exports them for libgcc
compatibility, but it is build-flag dependent and not guaranteed.

```bash
# Locate the libunwind .so used by the build, then:
nm -D <path/to/libunwind.so> | grep -E '__(de)?register_frame'
# Or:
objdump -T <path/to/libunwind.so> | grep -E '__(de)?register_frame'
```

Both symbols must appear with default visibility. If they are missing, choose
one of the fallbacks before proceeding:

- Switch the calls to `_Unwind_RegisterEhFrames` /
  `_Unwind_DeregisterEhFrames` (the libunwind-native section-style API), or
- Add a tiny C shim that defines `__register_frame`/`__deregister_frame` as
  thin wrappers around `_Unwind_RegisterEhFrames`/`_Unwind_DeregisterEhFrames`
  and link it ahead of libunwind.

### 2. Add `EcoSectionMemoryManager` in `EcoJIT.cpp`

Place the class itself in an anonymous namespace inside `EcoJIT.cpp`. Place
the libunwind entry-point declarations at **file scope** (outside the
anonymous namespace, outside `namespace eco`) so they have ordinary external
"C" linkage, not member or internal linkage:

```cpp
extern "C" void __register_frame(void *);
extern "C" void __deregister_frame(void *);
```

The class:

- Subclass `llvm::SectionMemoryManager`.
- Override `registerEHFrames(uint8_t *Addr, uint64_t LoadAddr, size_t Size)`:
  - Guard on `Addr && Size`.
  - Call `__register_frame(Addr)` — single call with the section base address.
  - Ignore `LoadAddr`; `Size` is used only for the empty-section guard.
- Override `deregisterEHFrames(uint8_t *Addr, uint64_t LoadAddr, size_t Size)`:
  - Same guard, then `__deregister_frame(Addr)`.
- Do **not** chain to `SectionMemoryManager::registerEHFrames`. Upstream's
  base implementation is just a per-FDE walk over the same range with no
  hidden bookkeeping, so fully replacing it is correct.

Add an 5–8 line implementation-level comment immediately above the class
explaining: (a) why we register section-style instead of per-FDE,
(b) that this matches LLVM libunwind's expectations and is incompatible with
the default base-class behavior, and (c) that ORC guarantees the same
`(Addr, Size)` is handed to `deregisterEHFrames` later.

### 3. Wire the new memory manager into the object linking layer

In `EcoJIT::create()`, modify the existing `objectLinkingLayerCreator` lambda
(lines 213–225). Replace only the inner factory passed to
`RTDyldObjectLinkingLayer`:

- From: `[](const MemoryBuffer &) { return std::make_unique<SectionMemoryManager>(); }`
- To:   `[](const MemoryBuffer &) { return std::make_unique<EcoSectionMemoryManager>(); }`

Leave everything else in `create()` unchanged: target machine setup,
`setupTargetTripleAndDataLayout`, `packFunctionArguments`,
`compileFunctionCreator`, `LLJITBuilder` chain, transformer application, IR
module addition, `DynamicLibrarySearchGenerator` registration, and stack map
listener registration on the object layer.

### 4. Update the obsolete `.eh_frame` comments

Place comments at two levels of detail:

- `EcoJIT.h` lines 45–46: a short 2–3 line **API-level** note that JIT code's
  `.eh_frame` is registered via a custom memory manager defined in
  `EcoJIT.cpp`, while AOT binaries continue to rely on the ELF loader.
  Mentions the AOT split explicitly so future readers don't worry that AOT is
  affected.
- `EcoJIT.cpp` lines 87–94 (inside `StackMapListener::notifyObjectLoaded`):
  shorten to a one-line pointer that EH-frame registration now lives in
  `EcoSectionMemoryManager::registerEHFrames`, not here. The deeper
  per-FDE / pre-relocation rationale belongs above
  `EcoSectionMemoryManager` itself (see step 2).

### 5. Optional: document AOT-untouched in CMake

Add a one-line comment near the `EcoRuntimeStatic` target in
`runtime/src/codegen/CMakeLists.txt` noting that AOT consumers do not go
through ORC and therefore are not affected by `EcoSectionMemoryManager`. This
is purely documentation; no build-system changes.

### 6. Build sanity

- `cmake --build build --target EcoRunner` to confirm compilation and that
  `__register_frame` / `__deregister_frame` resolve at link time against
  `eco::llvm_libunwind`.
- Then `cmake --build build` for the full runtime.

### 7. Validation (in this order)

1. **EH callbacks fire.** Add a temporary `fprintf(stderr, ...)` in
   `EcoSectionMemoryManager::registerEHFrames` logging `(Addr, Size)`.
   Run a JIT-driven test (e.g. one of the previously failing 23 JIT-heavy Elm
   tests) and confirm exactly **one** registration per JIT object load — not
   one per FDE. Confirm matching deregistrations on teardown if the test
   exits cleanly. Remove the logging once verified.
2. **Unwinding correctness.** Reuse an existing GC stress test that walks JIT
   frames; verify libunwind reports JIT frame PCs inside the JIT'd function
   PC ranges and that CFA/RSP/RBP reconstruction matches a disassembly
   spot-check.
3. **GC + stackmap correctness.** Re-run:
   - The 23 JIT-heavy Elm tests that regressed under LLVM libunwind.
   - Earlier GC stress tests that surfaced bogus roots (`0x1`, `0x2`, `0xe`,
     `0x58`), misaligned stackmap offsets in deeper frames,
     `Invalid tag after forward resolution`, and
     `eco_pap_extend: new_n_values exceeds max_values`.
   Stackmap Indirect locations should now resolve onto real `HPointer`s and
   previously missed roots should be discovered.

## Files touched

- `runtime/src/jit/EcoJIT.cpp` — new `EcoSectionMemoryManager`, file-scope
  `extern "C"` declarations for `__register_frame` / `__deregister_frame`,
  factory swap in `EcoJIT::create()`, listener comment update.
- `runtime/src/jit/EcoJIT.h` — short API-level comment update.
- `runtime/src/codegen/CMakeLists.txt` — optional one-line documentation
  comment near `EcoRuntimeStatic` noting AOT is unaffected.
- No build-system changes (no new sources, no new link dependencies).
- No public API changes; `EcoJIT`'s class shape is unchanged.

## Resolved decisions (previously open questions)

1. **`extern "C"` placement.** File-scope, outside both the anonymous
   namespace and `namespace eco`. Nested `extern "C"` *definitions* inside a
   class body are invalid C++; declarations there would create class members,
   which is not what we want. File-scope declarations are the standard
   pattern.

2. **Symbol availability.** Treated as a pre-flight verification step
   (step 1). LLVM libunwind generally exports `__register_frame` /
   `__deregister_frame` for libgcc compatibility, but it is build-flag
   dependent. If `nm -D` shows them missing, fall back to either the native
   `_Unwind_RegisterEhFrames` / `_Unwind_DeregisterEhFrames` API (functionally
   equivalent for our purposes) or a thin C shim. Decide before writing the
   class.

3. **AOT path.** Confirmed untouched. `EcoRuntimeStatic` is a static library
   used only by AOT binaries; it never instantiates `EcoSectionMemoryManager`
   because it never uses ORC/LLJIT. `.eh_frame` for AOT code is registered
   by the ELF loader and consumed by libunwind via the system unwinder path,
   exactly as today. Documented in the `EcoJIT.h` comment and (optionally)
   in `runtime/src/codegen/CMakeLists.txt` near the `EcoRuntimeStatic`
   target.

4. **`SectionMemoryManager` base behavior.** Confirmed safe to fully
   override. The base implementation is a thin wrapper around per-FDE
   `__register_frame` calls with no internal bookkeeping that other base
   methods rely on. Replacing it (rather than chaining) is correct.

5. **Teardown / threading.** LLVM libunwind supports concurrent unwinding
   while another thread registers/deregisters frames (a precondition for
   C++ exceptions and `dlclose` in multi-threaded programs). Our invariant
   is that `__deregister_frame` only runs as part of JIT object teardown,
   at which point no Elm code is executing in that object and the GC thread
   is not walking those frames. ORC will not free the code segment until
   after `deregisterEHFrames` returns. As long as we never evict a JIT
   object while live stacks reference its code, we're fine — a constraint
   that is independent of EH registration.

6. **Object eviction.** ORC's `RTDyldObjectLinkingLayer` always passes the
   same `(Addr, Size)` to `deregisterEHFrames` that it passed to
   `registerEHFrames` for the same object. Our plan preserves the section
   base address verbatim, so this contract is satisfied. If a future JIT
   object happens to land at the same virtual address, the new
   `registerEHFrames` call handles it naturally.

7. **Comment placement.** Two-tier: a short API-level note in `EcoJIT.h`,
   and a more precise implementation-level explanation immediately above
   `EcoSectionMemoryManager` in `EcoJIT.cpp` covering the per-FDE vs
   whole-section nuance and the LLVM libunwind rationale. The
   `StackMapListener` comment shortens to a one-line pointer.

8. **Scope.** EH-frame registration only. `StackMapData`,
   `StackMapListener`, `StackMap.cpp`, and `StackUnwind.cpp` are unchanged
   in this PR.
