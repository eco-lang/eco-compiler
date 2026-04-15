# Root MVar store, saved runtime state; harden `Export::toPtr`

## Context

Three related GC-safety defects in the Eco kernel:

1. **`Eco::Kernel::MVar::s_mvars`** (`eco-kernel-cpp/src/eco/MVar.cpp:21`) is a
   `std::unordered_map<int64_t, MVarSlot>` where each slot holds a raw
   `HPointer`. It is never registered as a GC root, so any GC that moves the
   pointed-to object leaves the stored `HPointer` stale.
2. **`Eco::Kernel::Runtime::s_savedState`** (`eco-kernel-cpp/src/eco/Runtime.cpp:12`)
   is a bare `HPointer` set by `saveState` and read by `loadState`. It is also
   not a GC root, so `loadState` can return a dangling pointer after a GC.
3. **`Eco::Kernel::Export::toPtr`** (`eco-kernel-cpp/src/eco/ExportHelpers.hpp:36`)
   has two "suspicious" branches that `reinterpret_cast<void*>(val)` when
   `constant != 0` (and `>7`) or `padding != 0`. This fabricates raw C++
   pointers out of tagged `eco.value` bits and lets bugs silently become heap
   corruption.

The external-root-scanner pattern is already in use by `PlatformRuntime`
(`runtime/src/platform/PlatformRuntime.cpp:69`) and `Scheduler`
(`runtime/src/platform/Scheduler.cpp:46`): each registers a lambda with
`Allocator::instance().getRootSet().addExternalRootScanner(...)` in its
constructor/startup, and the lambda calls `evacuate(uint64_t&)` on each
encoded HPointer it owns. `RootSet::EvacuateFn` (`runtime/src/allocator/RootSet.hpp:104`)
takes a `uint64_t&` — so callers that keep `HPointer` storage must
encode/evacuate/decode.

## Plan

### Step 1 — Add MVar GC root scanner

In `eco-kernel-cpp/src/eco/MVar.cpp`:

- Add includes for `allocator/Allocator.hpp` and `allocator/RootSet.hpp` (and
  `ExportHelpers.hpp` for `Export::encode`/`decode`).
- Add a function `void registerGcRootScanner()` inside
  `namespace Eco::Kernel::MVar` that:
  - Calls `Elm::Allocator::instance().getRootSet().addExternalRootScanner(...)`.
  - In the lambda, iterates `s_mvars`; for each slot with `value.has_value()`,
    encodes the `HPointer` to `uint64_t`, calls `evacuate(encoded)`, then
    decodes back and writes it to `slot.value`.
  - Skips empty slots.
  - Performs no allocation.

### Step 2 — Add Runtime saved-state GC root scanner

In `eco-kernel-cpp/src/eco/Runtime.cpp`:

- Add the same includes.
- Add `void registerGcRootScanner()` inside `namespace Eco::Kernel::Runtime`
  that registers a scanner which, when `s_hasState`, encodes `s_savedState`,
  calls `evacuate`, and decodes the result back into `s_savedState`.

### Step 3 — Expose C-linkage registration hooks

In `eco-kernel-cpp/src/eco/KernelExports.h`, declare:

```cpp
void Eco_Kernel_MVar_register_gc_roots();
void Eco_Kernel_Runtime_register_gc_roots();
```

Add the `extern "C"` definitions in `MVarExports.cpp` and `RuntimeExports.cpp`,
each delegating to the corresponding namespaced `registerGcRootScanner()`.

### Step 4 — Call the hooks from the runtime entry

In `runtime/src/codegen/eco_entry.cpp`, inside `eco_main_thread`, immediately
after `Elm::Allocator::instance().initThread()` (line 119) and before
`initStackMapFromSelf()`:

```cpp
Eco_Kernel_MVar_register_gc_roots();
Eco_Kernel_Runtime_register_gc_roots();
```

Add matching `extern "C"` forward declarations near the existing extern block
(lines 93–106).

Rationale for placement: `initThread()` creates the thread-local heap and
`RootSet`; registering before `__eco_init_globals`/`Env::init`/`eco_main`
ensures any GC triggered during early Elm execution will see these roots.

### Step 5 — Harden `Export::toPtr`

In `eco-kernel-cpp/src/eco/ExportHelpers.hpp`, replace the body of `toPtr`
(lines 36–52) with:

```cpp
inline void* toPtr(uint64_t val) {
    HPointer h = decode(val);
    if (h.constant != 0) return nullptr;       // all embedded constants
    assert(h.padding == 0 && "Export::toPtr: invalid eco.value (padding bits set)");
    return Allocator::instance().resolve(h);
}
```

- Removes both `reinterpret_cast<void*>(val)` paths.
- Collapses the `constant` range check into a single non-zero test (no
  legitimate caller should treat any embedded constant as a heap pointer).
- Keeps the normal heap path via `Allocator::resolve`.

### Step 6 — Wire the hooks into the JIT/test entry path

`EcoRunner` / `eco::EcoJIT` share the same runtime and `ThreadLocalHeap`, and
also call `initThread()`. Without calling the new registration hooks there,
MVar and runtime-state roots would be untracked under JIT.

- Locate the JIT entry point (`runtime/src/codegen/EcoRunner.cpp` and/or
  `EcoRunner.hpp`; also any `EcoJIT` startup path) that pairs with
  `Allocator::initThread()`.
- Add the same two `Eco_Kernel_MVar_register_gc_roots()` /
  `Eco_Kernel_Runtime_register_gc_roots()` calls immediately after
  `initThread()`, before any Elm code runs.
- Prefer a single shared helper (e.g. `Eco_Kernel_register_all_gc_roots()` in
  `RuntimeExports.cpp`) so AOT and JIT entry paths call one function and
  cannot drift.

### Step 7 — Build and test

- `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`
- Inspect for new failures. Expected exposure: any caller currently feeding
  a non-heap `eco.value` into `toPtr` will now either return `nullptr`
  (dereference likely crashes) or fire the padding assert — treat such sites
  as real bugs, fix at the call site, do not relax the assert.
- Optionally, add or extend a Stage 7 / MVar test under heavy allocation to
  confirm stored MVar values survive GC (out of scope for first pass if no
  easy hook exists).

## Files touched

- `eco-kernel-cpp/src/eco/MVar.cpp` — add includes + `registerGcRootScanner`.
- `eco-kernel-cpp/src/eco/Runtime.cpp` — add includes + `registerGcRootScanner`.
- `eco-kernel-cpp/src/eco/MVarExports.cpp` — add `extern "C"` wrapper.
- `eco-kernel-cpp/src/eco/RuntimeExports.cpp` — add `extern "C"` wrapper.
- `eco-kernel-cpp/src/eco/KernelExports.h` — declare the two new exports.
- `eco-kernel-cpp/src/eco/ExportHelpers.hpp` — rewrite `toPtr`.
- `runtime/src/codegen/eco_entry.cpp` — extern decls + registration call(s)
  after `initThread()`.
- `runtime/src/codegen/EcoRunner.cpp` (and any other JIT startup TU that calls
  `initThread()`) — same registration call(s) after `initThread()`.
- Optional: add a single `Eco_Kernel_register_all_gc_roots()` aggregator in
  `RuntimeExports.cpp` so AOT and JIT call one symbol.

## Resolved decisions

1. MVar.hpp/Runtime.hpp do not expose any GC registration surface today; GC
   API lives in `RootSet`. New `registerGcRootScanner()` helpers live in the
   `.cpp` that owns the static globals, reached via `extern "C"` wrappers.
2. `toPtr` is made strict — no legitimate caller should hand in a
   non-HPointer `eco.value`. Any resulting `nullptr`/assert is a real bug to
   fix at the call site.
3. JIT/test path (`EcoRunner` / `EcoJIT`) must call the same registration
   hook after `initThread()`. Addressed in Step 6 and in the files-touched
   list. Prefer one aggregator symbol (`Eco_Kernel_register_all_gc_roots`)
   shared by AOT and JIT to prevent drift.
4. Constant handling: any non-zero `constant` ⇒ `nullptr`. Consistent with
   `hpointerToPtr`; no caller relies on "weird constant encodings" being
   reinterpreted as raw pointers.
5. Explicit registration call (not ctor-based). RootSet lives in the
   thread-local heap; registration must happen after `initThread()`, so
   static-init-order coupling is avoided deliberately.
6. Multithreading: each thread has its own `ThreadLocalHeap`/`RootSet` and
   stop-the-world is per-thread, so scanners need no locks on
   `s_mvars`/`s_savedState` today. Revisit when MVar gains real blocking /
   cross-thread sharing — either confine MVars per heap or add
   synchronization around scanner-visible structures.

## Remaining open items

- Confirm the exact JIT startup site(s) that pair with `initThread()` in
  `EcoRunner.cpp` / `EcoJIT` and insert the aggregator call there. If there
  are multiple such sites (e.g. per test harness thread), all must call it.
