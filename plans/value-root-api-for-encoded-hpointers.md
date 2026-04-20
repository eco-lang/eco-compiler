# Value Root API for Encoded HPointers (Option B)

## Problem

Some encoded HPointers (e.g. `PlatformRuntime::modelStorage_`, `Scheduler::stepProcess`'s `procEncoded`, `RootedProc::encoded`) are currently registered through the **raw-pointer JIT root path** (`eco_gc_add_root` / `RootSet::addJitRoot`). The nursery collector treats those as raw addresses, so when the value is actually an encoded HPointer it is skipped ("in_heap=0 — skip") and never updated. Stage 7 debug runs confirmed this mis-registration.

## Goal

Give encoded Elm values (HPointers) their own dedicated root API and wire Scheduler / PlatformRuntime to use it, while preserving the existing raw JIT root path for truly raw heap addresses.

Root taxonomy after this work:

- **HPointer roots (`HPointer*`)** — `RootSet::addRoot/removeRoot`, scanned as encoded HPointers.
- **JIT roots (`uint64_t*` raw addresses)** — `RootSet::addJitRoot/removeJitRoot`, used by `eco_gc_add_root` for `ptr<1>` LLVM globals. Evacuated via `NurserySpace::evacuateJitPtr`, marked via `OldGenSpace::startMark(..., jit_roots, ...)`.
- **External root scanners for encoded value slots (`uint64_t*`)** — `RootSet::ExternalRootScanner` callbacks; GC invokes with an `EvacuateFn` over each `uint64_t&` slot holding an encoded HPointer.

## Invariants touched

- HEAP_010 / HEAP_014: HPointer with `constant != 0` are embedded constants — must not be traced or resolved as heap addresses.
- "HPointer is the only heap reference type" — `modelStorage_` should match this, not pretend to be a raw address.

## Assumptions (resolved design questions)

These are load-bearing assumptions the design relies on. If any flips, revisit the relevant patch.

1. **`Scheduler` is a singleton.** `Scheduler::instance()` owns the run queue; the process does not construct/destroy multiple schedulers. Its external root scanner is registered at first construction and lives for the lifetime of the thread/heap. No removal API is required.
2. **`RootSet` has no removal API for external scanners today** (only `addExternalRootScanner` + `reset()`). We rely on (1) to make this a non-issue. If short-lived scheduler instances become a thing later, extend `RootSet` with a handle-based remove and call it from the scheduler dtor.
3. **Thread-local stop-the-world GC.** Each mutator thread runs GC on its own `ThreadLocalHeap`; there is no separate collector thread. Each `ThreadLocalHeap` owns its own `RootSet`, and external scanners are invoked by the owning thread during its own GC cycle. Therefore iterating `runQueue_` from inside the external scanner needs no additional synchronization beyond "GC never runs while the run-queue mutex is held", which the scheduler already upholds.
4. **`HPointer` encoding.** 40-bit offset (`ptr`), 4-bit `constant` kind (bits 40–43), remaining bits are padding (expected 0). This matches existing `HPointer` helpers and the embedded-constant invariants.

---

## Patch 1 — New C API: value roots for encoded HPointers

### 1.1 `runtime/src/codegen/RuntimeExports.h`

Add under the existing GC interface (alongside `eco_gc_add_root`):

```cpp
/// Registers an Elm value slot as a GC root (encoded HPointer).
/// @param value_ptr Pointer to a location holding an encoded Elm value
///        (HPointer representation: heap offsets + embedded constants).
/// The collector treats *value_ptr as an HPointer: heap objects are traced
/// and updated in place; embedded constants (constant!=0) are ignored.
void eco_gc_add_value_root(uint64_t* value_ptr);

/// Unregisters an Elm value root previously registered with eco_gc_add_value_root.
void eco_gc_remove_value_root(uint64_t* value_ptr);
```

Do **not** change `eco_gc_add_root`'s semantics or header comment — keep it explicitly a JIT / raw-pointer API for `ptr<1>` globals.

### 1.2 `runtime/src/codegen/RuntimeExports.cpp`

Add next to the existing `eco_gc_add_root` implementation:

```cpp
void eco_gc_add_value_root(uint64_t* value_ptr) {
    auto& alloc = Elm::Allocator::instance();
    auto& rootSet = alloc.getRootSet();
    rootSet.addRoot(reinterpret_cast<Elm::HPointer*>(value_ptr));
}

void eco_gc_remove_value_root(uint64_t* value_ptr) {
    auto& alloc = Elm::Allocator::instance();
    auto& rootSet = alloc.getRootSet();
    rootSet.removeRoot(reinterpret_cast<Elm::HPointer*>(value_ptr));
}
```

`HPointer` is a 64-bit struct with `ptr`/`constant`/`padding` bitfields — reinterpret_cast from a `uint64_t*` holding the encoded bits is safe at the storage level, and GC never inspects the fields without going through HPointer helpers.

---

## Patch 2 — Nursery: evacuate external encoded value slots with HP semantics

### 2.1 `runtime/src/allocator/NurserySpace.hpp`

Add next to the existing evacuate/scan declarations:

```cpp
/// Evacuates an encoded HPointer stored in a uint64_t slot (value root).
/// Interprets 'encoded' as Elm::HPointer representation (heap offset +
/// embedded constant). Constants (constant != 0) are ignored.
void evacuateValueSlot(uint64_t &encoded, OldGenSpace &oldgen,
                       std::vector<void*> *promoted_objects);
```

### 2.2 `runtime/src/allocator/NurserySpace.cpp`

Implement next to `evacuate` / `evacuateJitPtr`:

```cpp
void NurserySpace::evacuateValueSlot(uint64_t &encoded,
                                     OldGenSpace &oldgen,
                                     std::vector<void*> *promoted_objects) {
    HPointer &hp = reinterpret_cast<HPointer&>(encoded);

    // Constants (constant != 0) are non-heap per HEAP_010/014.
    if (hp.constant != 0) {
        return;
    }

    evacuate(hp, oldgen, promoted_objects);
    // evacuate updates hp in place; encoded now holds relocated HPointer bits.
}
```

### 2.3 Wire external scanners into minorGC

In `NurserySpace::minorGC`, augment the "external roots" section to use the new helper:

```cpp
for (const auto& scanner : root_set.getExternalRootScanners()) {
    scanner([&](uint64_t& encoded) {
        evacuateValueSlot(encoded, oldgen, &promoted_objects);
    });
}
```

This matches the documented semantics of `ExternalRootScanner` ("encoded HPointer needing evacuation") but now actually runs with HPointer semantics rather than treating slots as raw pointers.

No changes to `OldGenSpace` mark/sweep — it already separates `HPointer&` roots and `jit_roots` in `startMark`.

---

## Patch 3 — PlatformRuntime: root `modelStorage_` as a value

### 3.1 `runtime/src/platform/PlatformRuntime.cpp`

In `initWorker` / model bootstrap (the step currently labelled "Root model as GC root"):

```cpp
// Before:
eco_gc_add_root(&modelStorage_);

// After:
eco_gc_add_value_root(&modelStorage_);
```

If a corresponding teardown or reinitialization path calls `eco_gc_remove_root(&modelStorage_)`, change it to `eco_gc_remove_value_root(&modelStorage_)`.

`modelStorage_` continues to hold the encoded Elm value (HPointer representation); GC now patches it using HPointer semantics and it no longer pollutes the JIT raw-pointer root set.

---

## Patch 4 — Scheduler: run queue + current process

Goals:

1. Trace `runQueue_` (deque of `RootedProc{uint64_t encoded}`) via an external root scanner with HP semantics.
2. Trace the currently executing process in `stepProcess` as a **stack HP root**, not a JIT/raw root.

### 4.1 External scanner over `runQueue_`

In `Scheduler::Scheduler()` (private constructor), after existing initialization:

```cpp
auto& alloc = Elm::Allocator::instance();
auto& rootSet = alloc.getRootSet();

rootSet.addExternalRootScanner(
    [this](Elm::RootSet::EvacuateFn evacuate) {
        for (auto& slot : runQueue_) {
            if (slot.encoded != 0) {
                evacuate(slot.encoded);
            }
        }
    });
```

Because `NurserySpace::minorGC` now calls `scanner(evacuateValueSlot)`, each `RootedProc::encoded` HPointer is evacuated and updated in place when its nursery block is reused.

### 4.2 Stack root for `procEncoded` in `stepProcess`

Use the existing shadow-stack C API (`eco_gc_stack_range_point` / `eco_gc_push_stack_range` / `eco_gc_restore_stack_range_point`) — already intended for "contiguous stack arrays as GC root ranges so the collector can trace HPointers stored in alloca- or stack-backed args arrays".

Add an RAII guard near `Scheduler`:

```cpp
namespace {

struct EncodedStackRootGuard {
    size_t saved_;
    EncodedStackRootGuard(uint64_t* slot) {
        saved_ = eco_gc_stack_range_point();
        // Single HPointer-encoded slot; mask bit 0 = 1.
        eco_gc_push_stack_range(slot, 1, /*hpointer_mask=*/1);
    }
    ~EncodedStackRootGuard() {
        eco_gc_restore_stack_range_point(saved_);
    }

    EncodedStackRootGuard(const EncodedStackRootGuard&) = delete;
    EncodedStackRootGuard& operator=(const EncodedStackRootGuard&) = delete;
};

} // namespace
```

### 4.3 Re-resolve rule (instead of safepoint enumeration)

To avoid a fragile, ever-growing list of "GC-capable calls" inside `stepProcess`, adopt and document a stronger invariant:

> **`procEncoded` is the authoritative handle. A raw `Process*` is valid only until the next call that may allocate or invoke Elm. After any such call, obtain a fresh `Process*` via `resolveProc(procEncoded)` before dereferencing again.**

Concretely this applies (non-exhaustively) to closure calls (`callClosure1/2/4`, binding / receive / effect-manager callbacks), allocating helpers (`pushStack`, `mailboxPushBack`, task constructors, `rawSend`), and anything that transitively goes through `Allocator` / `ThreadLocalHeap`. Don't try to whitelist safe calls — treat every call out as a potential safepoint.

Add a tiny helper co-located with `Scheduler`:

```cpp
static inline Process* resolveProc(uint64_t procEncoded) {
    return static_cast<Process*>(Elm::Allocator::instance().resolve(procEncoded));
}
```

Rewrite `Scheduler::stepProcess`:

```cpp
void Scheduler::stepProcess(uint64_t procEncoded) {
    // Root the current process handle as an encoded HPointer value
    // for the duration of this function. GC will update procEncoded in place.
    EncodedStackRootGuard root_guard(&procEncoded);

    // Invariant: never reuse a Process* across a potentially GC-capable call.
    // Always go through resolveProc(procEncoded) after such a call.
    Process* proc = resolveProc(procEncoded);

    // ... interpret Task, call closures, etc. After any outbound call that
    // may allocate or invoke Elm, discard 'proc' and call resolveProc again
    // before the next dereference.
    //
    // When re-enqueuing, push the current procEncoded:
    //     runQueue_.push_back(RootedProc{ procEncoded });
}
```

Remove any existing `addJitRoot(&procEncoded)` / `removeJitRoot(&procEncoded)` usage in `stepProcess`.

---

## Patch 5 — Keep JIT raw roots for real JIT globals only

The remaining legitimate use of `eco_gc_add_root` is MLIR-generated `__eco_init_globals` for compiled Elm modules — LLVM globals that hold full raw heap addresses (`ptr<1>` lowered to `i64` via `PtrToIntOp`). No changes required there; `NurserySpace::evacuateJitPtr` continues to be the right semantics.

In production, `eco_gc_add_root` trusts its caller and stays a simple registration hook. No heuristic "looks like an HP" filter — that would be noisy and semantically wrong (MLIR-generated globals start at 0 / uninitialized).

Debug-build sanity check (optional, behind `ECO_GC_DEBUG`): assert that the slot's current bits are a plausible HP encoding *only if* we can distinguish it from a raw pointer cleanly. A precise predicate:

```cpp
static inline bool isPlausibleHPtrEncoding(uint64_t x) {
    if (x == 0) return true; // uninitialized globals are allowed
    uint64_t padding  = x >> 44;
    uint64_t constant = (x >> 40) & 0xF;
    return padding == 0 && constant <= MaxConstantKind;
}
```

Use it only for best-effort assertions; heap-bounds checks belong at GC time (via existing `isInHeap` / `isInNursery`), not at registration.

CI hygiene: add a grep-based invariant test that `eco_gc_add_root` is not called from hand-written C++ (`runtime/src`, `elm-kernel-cpp/`) — only from MLIR-generated code paths.

---

## Summary of file changes

1. **`runtime/src/codegen/RuntimeExports.h`** — declare `eco_gc_add_value_root` / `eco_gc_remove_value_root`.
2. **`runtime/src/codegen/RuntimeExports.cpp`** — implement in terms of `RootSet::addRoot` / `removeRoot` on `reinterpret_cast<HPointer*>(value_ptr)`.
3. **`runtime/src/allocator/NurserySpace.hpp`** — declare `evacuateValueSlot`.
4. **`runtime/src/allocator/NurserySpace.cpp`** — implement `evacuateValueSlot`; in `minorGC`, invoke external root scanners with `EvacuateFn` calling `evacuateValueSlot`.
5. **`runtime/src/platform/PlatformRuntime.cpp`** — replace `eco_gc_add_root(&modelStorage_)` with `eco_gc_add_value_root(&modelStorage_)` (and matching remove).
6. **`runtime/src/platform/Scheduler.cpp`** —
   - In constructor: register external scanner over `runQueue_`.
   - Add `EncodedStackRootGuard` RAII helper and `resolveProc(procEncoded)` helper.
   - In `stepProcess`: remove any `addJitRoot`/`removeJitRoot`; use `EncodedStackRootGuard root_guard(&procEncoded);`; obtain every `Process*` via `resolveProc(procEncoded)` and never reuse it across a GC-capable call.
7. **Optional** — `isPlausibleHPtrEncoding` debug assert in `eco_gc_add_root`; grep-based invariant test that only MLIR-generated code calls `eco_gc_add_root`.

---

## Tests / guardrails

Use the existing runtime-side GC hooks for deterministic tests — no need to shrink the nursery or spam allocations from Elm unless the test is pure Elm:

- `ThreadLocalHeap::minorGC()` (public method on the current thread's heap).
- `eco_minor_gc` exported C symbol (alongside `eco_safepoint`).

Concrete test cases:

1. **Run-queue survives a minor GC.**
   - Enqueue a process so `RootedProc::encoded` sits in `runQueue_`.
   - Call `eco_minor_gc()`.
   - Dispatch via `Scheduler::drain()` / `stepProcess`; assert the process resolves to a valid `Process*` and runs to its expected next state.
2. **`procEncoded` survives GC inside `stepProcess`.**
   - Start a process whose task triggers allocation (closure call / `mailboxPushBack`).
   - Force a minor GC mid-step (via a debug hook that calls `eco_minor_gc()` at a known point, or a process whose first task deliberately over-allocates).
   - Assert `procEncoded` was updated in place and `resolveProc(procEncoded)` returns a valid `Process*` after the call.
3. **`modelStorage_` survives a minor GC.**
   - After `initWorker`, call `eco_minor_gc()`.
   - Assert the decoded model pointer is still a valid heap object with the expected record shape.
4. **Stage 7 stress test.** Re-run with the current baseline (8/31 passing); the baseline should improve measurably once this lands, not regress.
5. **Grep-based invariant.** No `eco_gc_add_root` call sites outside MLIR-generated init globals.

---

## Why this fixes Stage 7

- `Scheduler::stepProcess`'s `procEncoded` is a **stack HPointer root**, updated via the shadow stack; no more "in_heap=0 — skip".
- `Scheduler::runQueue_[i].encoded` is traced via external scanner + `evacuateValueSlot`, so queued processes' HPointers are updated when nursery blocks are reused.
- `PlatformRuntime::modelStorage_` is rooted as an encoded Elm value via `eco_gc_add_value_root`, matching its actual representation.
- `eco_gc_add_root` retains its intended audience: JIT/global raw heap pointers.

Separate, explicit APIs for HP-encoded value roots vs. raw JIT roots, each GC path using the right semantics.
