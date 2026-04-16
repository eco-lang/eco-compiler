# RewriteStatepointsForGC — Comparison with Eco's Pipeline

## Architecture Comparison

```
LLVM RS4GC pipeline:
  LLVM IR (with GC pointer types in addrspace(1))
    → RS4GC identifies ALL calls as potential safepoints
    → RS4GC computes liveness at LLVM IR level (type-based)
    → RS4GC inserts gc.statepoint + gc.relocate
    → RS4GC rewrites all uses via alloca/mem2reg
    → Backend emits stackmaps

Eco pipeline:
  Eco IR (with !eco.value types)
    → EcoGCPrepare computes liveness at Eco IR level (type-based)
    → EcoGCPrepare attaches roots as operands on GCRootCarrier ops
    → EcoToLLVM lowers to LLVM IR, emitting __eco_safepoint_marker calls
    → StatepointConversion finds markers, wraps next call in gc.statepoint
    → StatepointConversion rewrites roots via alloca/mem2reg
    → Backend emits stackmaps
```

## The Core Gap

RS4GC computes its own liveness at the LLVM IR level using the function's
`GCStrategy` to identify GC-managed pointer types. This means:
- Every GC pointer is identified by its TYPE, not by manual annotation
- Liveness is computed AFTER all MLIR→LLVM lowering and optimizations
- No value can escape tracking because the type system enforces it

Eco's pipeline identifies GC pointers at the Eco IR level (`!eco.value`), but
after lowering to LLVM IR, `!eco.value` becomes `i64`. At the LLVM level,
there is no way to distinguish an HPointer `i64` from a raw integer `i64`.
The only GC root information available is what was explicitly passed through
`__eco_safepoint_marker` calls.

## Why Eco Can't Directly Use RS4GC

RS4GC requires GC pointers to be POINTER types (in a specific address space),
not integers. Eco represents HPointers as `i64` values, which RS4GC cannot
identify as GC-managed.

To use RS4GC, Eco would need to:
1. Represent HPointers as `ptr addrspace(1)` instead of `i64` throughout the
   LLVM IR pipeline
2. Register a GCStrategy that identifies `addrspace(1)` as GC-managed
3. Let RS4GC handle all statepoint insertion and relocation

This is a significant change to the Eco→LLVM lowering but would eliminate the
entire class of "missing GC root" bugs.

## Specific Bug This Solves

The Stage 7 crash is caused by LLVM's optimizer converting gc-live entries
from `Indirect(stack_slot)` to `Constant(0)` when the value has no downstream
SSA use after the statepoint.

RS4GC avoids this because it rewrites ALL uses of every live GC pointer to
loads from an alloca (Phase E, step 3 in algorithm.md). This creates
downstream uses for every value, preventing the optimizer from eliminating the
alloca as dead.

Eco's StatepointConversion does NOT rewrite all uses — it only rewrites uses
of values that appear in the `__eco_safepoint_marker`. Values that are live
but not in the marker (which is the bug) have no alloca and no rewrite.
Even for values that ARE in the marker, if they are only used as call
arguments (passed to the callee) with no post-call use in the caller, the
alloca is write-only and gets eliminated.

## Alternative Fix (Without RS4GC)

If adopting RS4GC is too large a change, the specific Constant(0) bug in
Eco's StatepointConversion can be fixed by ensuring every gc-live value has a
downstream use after the statepoint. Options:

1. **Insert artificial uses** (inline asm side effects) after gc.relocate to
   prevent dead-store elimination of the alloca.

2. **Keep allocas un-promoted** for gc-live values — don't pass them to
   PromoteMemToReg. This ensures they're always Indirect in the stackmap.

3. **Rewrite all uses** of gc-live values (not just gc-live operands) to loads
   from the alloca, mirroring RS4GC's Phase E step 3. This is the most
   correct approach but requires tracking which values are gc-live and finding
   all their uses — essentially reimplementing a subset of RS4GC.
