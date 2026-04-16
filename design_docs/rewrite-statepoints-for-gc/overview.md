# RewriteStatepointsForGC — Overview

LLVM's `RewriteStatepointsForGC` (RS4GC) pass transforms IR so that pointer
relocations performed by a garbage collector are made explicit. It is the
standard LLVM mechanism for precise, relocating GC support.

**Source:** `llvm/lib/Transforms/Scalar/RewriteStatepointsForGC.cpp` (3377 lines)

## Purpose

In a relocating GC, the collector may move heap objects during collection.
After movement, every pointer to a moved object must be updated (relocated).
RS4GC makes this process explicit in the IR by:

1. Finding every call that might trigger GC (a *safepoint*).
2. Computing which GC-managed pointers are live at each safepoint.
3. Wrapping each safepoint call in a `gc.statepoint` intrinsic that lists all
   live GC pointers.
4. Inserting `gc.relocate` intrinsics after each statepoint so that every
   post-safepoint use of a GC pointer reads the relocated version.

## Key Difference from Eco's StatepointConversion

| Aspect | LLVM RS4GC | Eco StatepointConversion |
|--------|-----------|--------------------------|
| GC pointer identification | Uses `GCStrategy::isGCManagedPointer()` on pointer types | Relies on `__eco_safepoint_marker` arguments |
| Liveness computation | Full inter-procedural dataflow over the CFG | Delegated to EcoGCPrepare on Eco IR, not recomputed at LLVM level |
| gc-live population | Automatically includes ALL live GC pointers | Only includes values explicitly in the marker call |
| Base pointer tracking | Full base-pointer inference (PHI/select chains) | Not needed (Eco HPointers are self-describing) |
| Relocation | `gc.relocate` + `relocationViaAlloca` + `PromoteMemToReg` | `gc.relocate` + alloca + `PromoteMemToReg` (similar) |

The critical gap: **RS4GC computes its own liveness at the LLVM IR level**, so
it never misses a live pointer. Eco's pipeline computes liveness at the Eco IR
level (EcoGCPrepare) and passes the result down, but the custom
StatepointConversion does not independently verify or augment it.

## Algorithm Phases

The pass operates in these phases (detailed in [algorithm.md](algorithm.md)):

1. **Identify safepoints** — find all calls/invokes that may trigger GC.
2. **Compute liveness** — standard dataflow to find all GC pointers live at
   each safepoint.
3. **Find base pointers** — for each live pointer, determine which base object
   it is derived from (needed for gc.relocate).
4. **Recompute liveness** — base pointer insertion may create new live values;
   re-run dataflow.
5. **Rematerialize** — optionally recompute cheap derived pointers instead of
   relocating them.
6. **Make statepoints explicit** — replace each call with `gc.statepoint` +
   `gc.result` + `gc.relocate`.
7. **Relocation via alloca** — rewrite all post-safepoint uses of live
   pointers to use relocated versions (alloca + mem2reg pattern).
8. **Strip invalid attributes** — remove metadata/attributes that are
   invalidated by potential GC relocation.

## Invariants

See [invariants.md](invariants.md) for the full list.
