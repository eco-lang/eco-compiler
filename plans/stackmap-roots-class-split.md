# Split Stackmap Roots From RootSet Into A Dedicated `StackMapRoots` Class

## Motivation

Today `RootSet` mixes three conceptually different root kinds:

1. **Long-lived roots** (`roots`, `jit_roots`) — registered by the runtime.
2. **Shadow-stack range roots** (`stack_root_ranges`) — pushed by kernel/C++ code
   and compiled `alloca`-backed arg arrays via `pushStackRootRange`.
3. **Stackmap-derived single-slot roots** (`stack_roots`) — populated from scratch
   each GC cycle by `ThreadLocalHeap::collectStackRootsFromStackMap()` via
   `pushStackRoot` / `restoreStackRootPoint(0)`.

The mixing has already caused a bug: `collectStackRootsFromStackMap()` calls
`restoreStackRootPoint(0)` to wipe the previous cycle's stackmap roots, but that
same vector was available to kernel code via `pushStackRoot`, so any kernel use
of the single-slot API got wiped mid-GC.

The existing comment in `ThreadLocalHeap.cpp:305-309` documents the convention
("kernel code must use `pushStackRootRange`"), but the convention is only
enforced by comments. Callers that still use the old API exist today — e.g.
`eco-kernel-cpp/src/eco/Http.cpp:201-214` and
`eco-kernel-cpp/src/eco/KernelHelpers.hpp:112-119` — and are latent bugs under
this convention.

**Goal:** make it *structurally impossible* for runtime/kernel code to use the
stackmap-scratch API by moving it onto a separate class that only GC-internal
code can reach.

## Non-goals

- Changing range-root semantics or the `StackRootGuard` / `StackRootRangeGuard`
  RAII helpers.
- Changing JIT root, long-lived root, or external scanner behavior.
- Changing the stackmap unwinder logic itself (only where it writes to).
- Changing any MLIR/LLVM statepoint lowering.

## Design Summary

Introduce `StackMapRoots` as a dedicated per-thread container owned by
`ThreadLocalHeap`. Remove the `stack_roots` vector, its public API, and
`replaceHead` from `RootSet`. GC code in `ThreadLocalHeap` walks the thread
stack into `StackMapRoots` and then hands *all* root sources to the nursery
(or old-gen marker) as explicit parameters — `NurserySpace` does not walk
the stack and does not own any stack-root container.

```
ThreadLocalHeap                             (GC orchestration)
├── NurserySpace (owns RootSet)
│   └── RootSet                             (runtime + kernel roots)
│       ├── roots              (long-lived)       — runtime addRoot/removeRoot
│       ├── jit_roots          (JIT 64-bit ptrs)  — runtime addJitRoot/removeJitRoot
│       ├── stack_root_ranges  (shadow-stack)     — kernel/C++ via Guards & C ABI
│       └── external_scanners                     — runtime addExternalRootScanner
└── StackMapRoots                                 — GC-internal only
    └── roots_                                    — collectStackRootsFromStackMap
```

## Step-By-Step Implementation Plan

### Step 1 — Add `runtime/src/allocator/StackMapRoots.hpp`

New header with a single class:

- `push(HPointer*)` — push a root (skip null).
- `clear()` — wipe all entries; called at GC start.
- `point()` / `restore(size_t)` — optional checkpointing (mirrors RootSet shape).
- `get() const` — read-only access for GC consumers.

Kept intentionally narrow: no range API, no JIT, no external scanners.

### Step 2 — Remove single-slot stack root API from `RootSet`

In `runtime/src/allocator/RootSet.hpp`:

- Delete public members: `stackRootPoint`, `pushStackRoot`, `replaceHead`,
  `restoreStackRootPoint`, `getStackRoots`.
- Delete private member: `std::vector<HPointer*> stack_roots`.
- Keep everything else unchanged: long-lived, JIT, ranges, external scanners.

`replaceHead` goes away outright — no current non-test caller depends on its
in-place semantics (range-based rooting achieves the same thing by updating
`*slot` directly through the registered pointer).

In `runtime/src/allocator/RootSet.cpp`:

- Update `RootSet::reset()` to drop the `stack_roots.clear();` line.

### Step 3 — Own a `StackMapRoots` on `ThreadLocalHeap`

In `runtime/src/allocator/ThreadLocalHeap.hpp`:

- `#include "StackMapRoots.hpp"`.
- Add private field `StackMapRoots stack_map_roots_;`.
- Add public accessor `StackMapRoots& getStackMapRoots()` and its const overload
  (GC-internal callers only; not for kernel/runtime use).

`getRootSet()` stays as-is (delegates to nursery's `RootSet`).

### Step 4 — Rewrite `collectStackRootsFromStackMap()`

In `runtime/src/allocator/ThreadLocalHeap.cpp`:

- Replace the `RootSet& roots = nursery_.getRootSet(); roots.restoreStackRootPoint(0);`
  header with `StackMapRoots& sm = stack_map_roots_; sm.clear();`.
- Replace `roots.pushStackRoot(slot);` (line 358) with `sm.push(slot);`.
- Update the debug dump loop (lines 366-375) to read from `sm.get()` instead
  of `roots.getStackRoots()`.
- The range-root debug dump block (lines 377-387) stays on `RootSet` unchanged.

Result: this function now touches only `StackMapRoots`; `RootSet` is untouched.

### Step 5 — Reshape `ThreadLocalHeap::collectRoots()` to long-lived only

Current `collectRoots()` returns a merged `unordered_set<HPointer*>` folding
long-lived + stack-single-slot + stack-ranges. New shape:

- `collectRoots()` returns *only* `RootSet::getRoots()` (long-lived HPointer*).
- Callers that need other root sources access them directly:
  - `majorGC` already reads `RootSet::getJitRoots()` separately into
    `old_gen_.startMark`.
  - Stackmap roots and range roots are marked via explicit loops that call
    `old_gen_.markHPointer` on each slot, not via the merged set.

`OldGenSpace::startMark(roots, jit_roots, ...)` keeps its current signature;
we just stop folding stack-based roots into `roots`.

### Step 6 — Rework minor GC orchestration

Orchestrate minor GC from `ThreadLocalHeap::minorGC()` so that `NurserySpace`
never walks the stack and never owns a stackmap container. `NurserySpace`
continues to consume the data structures it is handed — it stays aware that
there are two stack-root sources (singletons + ranges) but does not discover
them.

Proposed new signature (to be confirmed against existing `NurserySpace` API):

```cpp
NurserySpace::minorGC(OldGenSpace& oldgen,
                      const StackMapRoots& stackmap_roots);
```

`RootSet` (holding long-lived, JIT, ranges, external scanners) is already
reachable through `root_set` inside `NurserySpace`, so only the stackmap
source needs to be threaded through. `ThreadLocalHeap::minorGC` becomes:

```cpp
collectStackRootsFromStackMap();
nursery_.minorGC(old_gen_, stack_map_roots_);
```

In `NurserySpace.cpp`:

- Phase 1b (line ~442) iterates `stackmap_roots.get()` and evacuates each
  `*HPointer*`.
- Phase 1e (stack ranges, line ~458) stays on `root_set.getStackRootRanges()`.
- Post-GC validation block at line ~529 switches to `stackmap_roots.get()`.

### Step 7 — Major GC wiring

In `ThreadLocalHeap::majorGC()`:

- Call `collectStackRootsFromStackMap()` first (unchanged).
- Build the long-lived set via the slimmed-down `collectRoots()`.
- After `old_gen_.startMark(roots, jit_roots, ...)`, explicitly mark stackmap
  roots and range roots with a loop that calls
  `old_gen_.markHPointer(*slot, ...)` (or the equivalent existing API) on each
  slot discovered in `stack_map_roots_.get()` and every masked index of each
  `StackRootRange`.
- External scanners continue to be invoked as today.

(Exact `markHPointer` call shape to be confirmed against `OldGenSpace.hpp`.)

### Step 8 — Fix callers that still use the removed single-slot API

Grep showed these existing users that will not compile after Step 2:

- `runtime/src/main.cpp:250-260, 274-312` — **legacy standalone runtime
  harness**. Not wired into the active CMake targets (current entry points
  are `EcoRuntimeStatic` / `EcoEntryStatic` via `eco_entry.cpp`). Treat as
  legacy: delete the rooting calls (or the whole file if it's unused)
  rather than migrating. Confirm with a CMake grep before removal.

- `eco-kernel-cpp/src/eco/Http.cpp:201-214` — kernel code. Migrate to
  `StackRootGuard` or range-based pushes: replace
  `for (auto& hp : fileRecords) rs.pushStackRoot(&hp);` with
  `for (auto& hp : fileRecords) rs.pushStackRootRange(&hp, 1, 1);` and swap
  `stackRootPoint` / `restoreStackRootPoint` for
  `stackRangePoint` / `restoreStackRangePoint`.

- `eco-kernel-cpp/src/eco/KernelHelpers.hpp:109-121`
  (`taskSucceedStringList`) — same mechanical migration.

Neither kernel site relies on `replaceHead`; they build into the vector and
read back from it without in-place mutation.

### Step 9 — Documentation sweep (in scope)

Update core docs that describe the previous `RootSet::stack_roots` shape:

- `THEORY.md` — references to `stack_roots` / `pushStackRoot` /
  `getStackRoots`. Rewrite to describe `StackMapRoots` vs `RootSet`.
- `design_docs/theory/heap_representation_theory.md` — same.
- `design_docs/theory/platform_scheduler_theory.md` — verify any
  stack-root references align with the new shape.
- `design_docs/gc_handbook/*`, `design_docs/llvm_backend/*`,
  `design_docs/rewrite-statepoints-for-gc/*` — quick sweep for stale
  language; update if found.

Code-comment cleanup:

- `HeapHelpers.hpp:69-71`: replace "walks `getStackRoots()`" with language
  describing both `StackMapRoots` and `RootSet::stack_root_ranges`.
- `HeapHelpers.hpp:89-91`: drop the "not `pushStackRoot`" warning — that
  API no longer exists.
- `HeapHelpers.hpp:478-480`: same cleanup in the `cons` helper.
- `ThreadLocalHeap.cpp:304-309`: replace the convention comment with a
  simple `StackMapRoots::clear()` note.

### Step 10 — Add invariant rows to `design_docs/invariants.csv`

Next free IDs today are `HEAP_020` and `FORBID_HEAP_003`.

- **`HEAP_020; Runtime_Heap; RootContainerSplit; enforced;`**
  "Stackmap-derived stack roots and runtime/kernel roots are stored in
  disjoint containers: `StackMapRoots` (owned by `ThreadLocalHeap`,
  GC-internal) holds single-slot roots discovered from LLVM stackmaps and
  is cleared at the start of each GC cycle, while `RootSet` (owned by
  `NurserySpace`) holds long-lived roots, JIT roots, shadow-stack ranges,
  and external scanners. Cross-container mutation is prohibited.;
  `ThreadLocalHeap.hpp`, `StackMapRoots.hpp`, `RootSet.hpp`"

- **`FORBID_HEAP_003; Runtime_Heap; ForbiddenAssumptions; enforced;`**
  "Runtime and kernel code must not register GC roots via the stackmap
  root container; all non-stackmap stack rooting must use
  `RootSet::stack_root_ranges` via `StackRootGuard`,
  `StackRootRangeGuard`, or the `eco_gc_stack_range_*` C ABI.;
  `HEAP_020`"

### Step 11 — Build & test

- `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`
- `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1 2>&1 | tee -a /tmp/test_output.txt`

Focus test surfaces:

- Anything exercising nursery GC with stackmap-discovered roots (most
  compiled Elm code).
- Kernel string/list construction paths touched in Step 8 (Http zip-list
  decoding, `taskSucceedStringList`).

## Invariants After the Change

- **`RootSet`** contains only: long-lived roots, JIT roots, stack root ranges,
  external scanners. No single-slot stack roots, no `replaceHead`. Mutated by
  runtime and kernel code through `addRoot`, `addJitRoot`,
  `addExternalRootScanner`, and the `StackRootGuard` / `StackRootRangeGuard`
  RAII wrappers (or the C ABI `eco_gc_stack_range_*` functions).

- **`StackMapRoots`** contains only stackmap-derived single-slot roots.
  Mutated only by `ThreadLocalHeap::collectStackRootsFromStackMap()`. Cleared
  at the start of each GC cycle. No public C ABI, no kernel include exposure.

- **GC** traces all root sources per cycle:
  `RootSet::getRoots()`, `RootSet::getJitRoots()`,
  `RootSet::getStackRootRanges()`, `RootSet::getExternalRootScanners()`,
  `StackMapRoots::get()`. Stack-based sources are no longer merged into
  `collectRoots()`'s unordered_set; the GC visits them via explicit loops.

## Risk / Rollback

- Pure refactor with no semantic change to GC correctness rules. Rollback is
  `git revert` of the patch series.
- Main risks:
  - Step 6/7 wiring (minor/major GC must see every source exactly once; the
    CI GC tests exercise this).
  - Step 8 kernel migrations in `Http.cpp` and `KernelHelpers.hpp` — small,
    local rooting scopes; verify each range bracket covers the allocation
    window.
