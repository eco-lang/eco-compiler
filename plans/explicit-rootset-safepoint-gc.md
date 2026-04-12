# Plan: Statepoint-Based Safepoint GC (Replace Stack Map Frame Walking)

## Status: READY FOR IMPLEMENTATION

## Motivation

The current GC root discovery walks the x86-64 call stack via RBP frame pointer chaining
and parses `__LLVM_StackMaps` to find heap pointer locations (`ThreadLocalHeap::collectStackRootsFromStackMap()`).
This is fragile (x86-64 only, requires frame pointers, brittle under optimization) and couples
the GC to platform-specific stack layout.

The new design makes `eco.safepoint` lower so that `__eco_safepoint_poll` is the call wrapped
by `gc.statepoint`. LLVM's statepoint/stackmap machinery describes root locations to the GC —
no manual RSP/RBP walking needed.

## Architecture

### Key Design Decisions

**Elm compiled frames use gc.statepoint/gc.relocate exclusively** — they do NOT register roots
via `RootSet.stack_roots`. The allocas created by `StatepointConversion.cpp` Phase 2 exist only
to help SSA construction and `PromoteMemToReg` synthesize phis; they are never observed by
the runtime. `RootSet.stack_roots` remains solely for C++ runtime code using `StackRootGuard`.

**`__eco_safepoint_poll` is the statepoint target call.** The MLIR lowering emits
`call @__eco_safepoint_poll()` immediately after the marker. `StatepointConversion` wraps
this poll call in `gc.statepoint` with the gc-live bundle. Allocation calls (`eco_alloc_*`)
stay as ordinary calls; the safepoint polls that dominate allocations provide the precise
stack-root descriptions.

**GC trigger in `__eco_safepoint_poll`**: Primary trigger = allocator thresholds (nursery
occupancy vs `nursery_gc_threshold`, old-gen size). Secondary = thread-local "force GC" flag
settable by debugger/test harness/`eco_minor_gc`/`eco_major_gc`.

**`extern "C"` access**: Via `Allocator::instance()` which uses `static thread_local
ThreadLocalHeap* tl_heap_` internally.

## Current State (What Already Works)

| Component | File | Status |
|-----------|------|--------|
| `eco.safepoint` op definition | `Ops.td:1110-1131` | Complete |
| `emitSafepoint` in Elm backend | `Expr.elm:98-100` | Complete, called at 16+ sites |
| `EcoGCPrepare` pass (liveness + operand rewriting) | `Passes/EcoGCPrepare.cpp` | Complete, wired at Stage 2.5 |
| `SafepointOpLowering` (eco.safepoint → marker call) | `EcoToLLVMErrorDebug.cpp:56-101` | Complete |
| `convertSafepointMarkers` (marker → gc.statepoint) | `StatepointConversion.cpp:87-215` | Complete (Phase 1) |
| `rewriteGCRootsWithAllocas` (gc.relocate + mem2reg) | `StatepointConversion.cpp:221-382` | Complete (Phase 2) |
| JIT/AOT integration | `ecoc.cpp:186,242`, `EcoRunner.cpp:186` | Complete |
| `RootSet` with stack_roots API | `RootSet.hpp` | Complete |
| Stack map walking GC | `ThreadLocalHeap.cpp:256-324` | Complete (to be replaced) |

**Key insight**: The pipeline from `eco.safepoint` through gc.statepoint is already fully operational.
The main changes are: (1) making `__eco_safepoint_poll` the statepoint target, (2) implementing
the poll function, and (3) disabling the old frame-walking root discovery.

---

## Implementation Phases

### Phase 1: Add `__eco_safepoint_poll` Runtime Function

**Files**: `runtime/src/allocator/ThreadLocalHeap.hpp`, `ThreadLocalHeap.cpp`

Add to `ThreadLocalHeap`:
```cpp
bool shouldCollectAtSafepoint() const;  // inline fast-path: check threshold + force flag
void collectAtSafepoint();               // slow path: minorGC or majorGC
```

Add `extern "C"` function (in `ThreadLocalHeap.cpp` or a dedicated exports file):
```cpp
extern "C" void __eco_safepoint_poll() {
    auto& alloc = Elm::Allocator::instance();
    // Fast path: single branch on threshold + force flag
    if (!alloc.shouldCollectAtSafepoint())
        return;
    alloc.collectAtSafepoint();
}
```

`shouldCollectAtSafepoint()` checks:
- Nursery occupancy vs `nursery_gc_threshold` (minor GC trigger)
- Old-gen size vs its threshold (major GC trigger)
- Thread-local `force_gc_` flag (for debugger/test harness)

`collectAtSafepoint()`:
- Calls `minorGC()` or `majorGC()` as appropriate
- Does NOT call `collectStackRootsFromStackMap()` — roots come from statepoint stackmaps

### Phase 2: Change MLIR Lowering to Emit Poll Call After Marker

**File**: `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp`

Modify `SafepointOpLowering::matchAndRewrite` to emit a `call void @__eco_safepoint_poll()`
immediately after the marker call. Currently the marker is emitted alone and `StatepointConversion`
finds "the next non-intrinsic call" as the target. With the explicit poll call, the target is
always `__eco_safepoint_poll`.

Changes to `SafepointOpLowering`:
1. After emitting the marker call, emit `call void @__eco_safepoint_poll()`
2. Add a `getOrCreatePollFn` helper (similar to existing `getOrCreateMarkerFn`)
3. The poll function declaration: `void @__eco_safepoint_poll()` (no args, no varargs)

### Phase 3: Update StatepointConversion Target Discovery

**File**: `runtime/src/codegen/Passes/StatepointConversion.cpp`

Currently `findTargetCall()` (lines 61-76) finds the first non-intrinsic call after the marker.
With Phase 2, this will naturally find `__eco_safepoint_poll`. Optionally tighten the assertion:

```cpp
assert(targetCall->getCalledFunction()->getName() == "__eco_safepoint_poll"
       && "Statepoint target must be __eco_safepoint_poll");
```

No other changes to StatepointConversion needed — Phase 1 (marker→statepoint) and Phase 2
(gc.relocate + alloca/mem2reg) work unchanged. The allocas exist only transiently for SSA
construction and are eliminated by `PromoteMemToReg`.

### Phase 4: Disable Stack Map Frame Walking in GC

**File**: `runtime/src/allocator/ThreadLocalHeap.cpp`

In `minorGC()` and `majorGC()`:
- Remove calls to `collectStackRootsFromStackMap()`
- Roots for Elm frames are now described by LLVM's statepoint stackmaps (handled by LLVM's
  code generator, not by our manual frame walking)
- `RootSet.stack_roots` continues to work for C++ runtime roots via `StackRootGuard`

Keep `collectStackRootsFromStackMap()` behind `#ifdef ECO_DEBUG_STACKMAP` for diagnostics
during bring-up. Keep `StackMap.hpp`, `StackMap.cpp`, `StackMapListener` in the build but
don't use them from the production GC path. Remove entirely once statepoint path is validated.

### Phase 5: Add Loop Back-Edge Safepoints

**File**: `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Add `emitSafepoint` calls at the end of loop bodies:
- Joinpoint-based tail recursion (before the back-edge jump)
- `scf.while` loop bodies (after `createEcoControlFlowToSCFPass`)
- Any other loop form that can run for many iterations without allocating

Rule: one safepoint per loop back-edge. No need to worry about tiny finite loops that
allocate frequently — those already hit allocation-site safepoints.

`EcoGCPrepare` computes correct live sets for these automatically.

### Phase 6: Clean Up Vestigial Declarations

**File**: `runtime/src/codegen/Passes.h`

- Remove `createSafepointLoweringPass()` declaration (line 82) and its "currently no-op" comment
- The actual lowering is done by `SafepointOpLowering` pattern in `EcoToLLVMErrorDebug.cpp`
- The stale declaration is confusing now that the architecture is "safepoint poll calls +
  StatepointConversion.cpp"

---

## Files Changed

| File | Change |
|------|--------|
| `runtime/src/allocator/ThreadLocalHeap.hpp` | Add `shouldCollectAtSafepoint()`, `collectAtSafepoint()`, `force_gc_` flag |
| `runtime/src/allocator/ThreadLocalHeap.cpp` | Add `__eco_safepoint_poll` extern C function, implement poll methods, remove `collectStackRootsFromStackMap` from GC path |
| `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp` | Emit `call @__eco_safepoint_poll()` after marker in `SafepointOpLowering` |
| `runtime/src/codegen/Passes/StatepointConversion.cpp` | Add assertion that target call is `__eco_safepoint_poll` |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Add loop back-edge safepoint calls |
| `runtime/src/codegen/Passes.h` | Remove vestigial `createSafepointLoweringPass` declaration |

## Risks

1. **gc.statepoint target change**: Changing from wrapping allocation calls to wrapping `__eco_safepoint_poll`
   changes what LLVM considers a GC-triggering call. Need to verify that LLVM's statepoint handling
   correctly generates stackmap entries for the poll call site and that the code generator emits
   the right relocations.

2. **Statepoint stackmap vs manual stackmap**: The old path parsed `__LLVM_StackMaps` manually
   via `StackMap::parse()` and walked frames. The new path relies on LLVM's statepoint machinery
   to communicate root locations to the GC. Need to verify that LLVM's statepoint code generator
   produces the information the GC needs (or that we adapt the GC to consume statepoint-style
   stackmaps).

3. **GC must still see Elm roots during collection**: With the old path, `collectStackRootsFromStackMap()`
   pushed roots into `RootSet.stack_roots` right before collection. With the new path, roots are
   described by statepoint stackmaps. The GC collector (`nursery_.minorGC()`, `old_gen_.startMark()`)
   must be able to find roots from statepoint stackmaps — either by parsing the LLVM-generated
   `__LLVM_StackMaps` section (which statepoints still produce) or by some other mechanism.
   This is the same `StackMap` infrastructure we're keeping behind `#ifdef`, just consumed
   differently.

4. **Bring-up strategy**: Phases 1-3 can be implemented and tested while the old frame-walking
   path is still active (both mechanisms coexist). Phase 4 (disabling frame walking) should only
   happen after end-to-end validation that statepoint-based root discovery works correctly.
