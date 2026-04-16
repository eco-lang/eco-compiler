# RewriteStatepointsForGC — Invariants

## GC Pointer Classification

**INV-1: GC pointer identification is type-based.**
A value is a GC pointer iff `GCStrategy::isGCManagedPointer(T)` returns true
for its type. In practice this means pointers in a designated address space
(e.g. `addrspace(1)`). Non-pointer types and pointers in address space 0 are
never GC-managed. The pass queries the function's `GCStrategy` to make this
determination.

**INV-2: Constants are never live.**
Constant pointers (global addresses, null pointers, constant expressions) are
assumed immovable. They are excluded from liveness, never appear in gc-live
bundles, and never get gc.relocate instructions. This includes `undef`,
`poison`, and `inttoptr` of constants.

**INV-3: Function return values are base pointers.**
Any value returned by a call or invoke is assumed to be a base pointer (not a
derived pointer). This simplifies base-pointer inference by treating call
results as roots in the base-defining-value graph.

**INV-4: Function arguments are base pointers.**
Incoming arguments to the function are treated as base pointers of themselves.

## Liveness

**INV-5: Liveness is computed via standard backward dataflow.**
The algorithm computes Kill/Gen/LiveIn/LiveOut sets for each basic block using
the standard equations:
```
Kill[B]  = { defs of GC pointers in B }
Gen[B]   = { GC pointer uses in B, excluding PHI uses and constants }
LiveOut[B] = ∪ LiveIn[S] for each successor S
LiveIn[B]  = (Gen[B] ∪ LiveOut[B]) − Kill[B]
```
PHI node operands contribute to the LiveOut of the *predecessor* block (via
`computeLiveOutSeed`), not the Gen set of the PHI's block.

**INV-6: Live set at a safepoint is computed from LiveOut backwards.**
Starting from the block's LiveOut, the algorithm walks instructions in reverse
from the block end to the safepoint instruction, applying Kill/Gen. The
safepoint instruction's own result is excluded from the live set (it hasn't
been produced yet).

**INV-7: Liveness is recomputed after base pointer insertion.**
Inserting base-phi nodes and base-select instructions may create new GC
pointers that are live at safepoints. A second liveness pass captures these.

## Base Pointer Inference

**INV-8: Every live derived pointer has a base pointer.**
The pass constructs a `PointerToBase` map. For base pointers, the base is
the pointer itself. For derived pointers (GEPs, casts), the base is traced
back through the def chain.

**INV-9: PHI/Select nodes may merge pointers with different bases.**
When a PHI or Select has inputs with different bases, it is marked as a
"conflict". A parallel PHI/Select is inserted to track the base, producing a
`base_phi` or `base_select` instruction.

**INV-10: Base inference uses a fixed-point lattice.**
States: `Unknown → Base(V) → Conflict`. The lattice meets: if two inputs have
different bases, the result is Conflict. The algorithm iterates until no state
changes.

**INV-11: The base of a derived pointer must dominate the derived pointer.**
This is validated with `DT.dominates(base, derived)`.

## Statepoint Construction

**INV-12: gc.statepoint replaces the original call/invoke.**
The original call is removed. Its return value (if any) is replaced by a
`gc.result` intrinsic tied to the statepoint token.

**INV-13: gc-live bundle contains all live GC pointers.**
Both base AND derived pointers appear in the gc-live bundle. The gc.relocate
instructions reference them by index.

**INV-14: gc.relocate is emitted for every live variable.**
After the statepoint, each live pointer gets a gc.relocate that produces the
relocated value. For invokes, relocates are emitted in both normal and unwind
destinations.

**INV-15: Deopt bundle operands that are GC pointers are also live.**
The pass inserts dummy `__tmp_use` calls to keep deopt-bundle GC pointers
alive during liveness computation.

## Relocation via Alloca

**INV-16: Each unique live GC pointer gets one alloca in the entry block.**
The alloca stores the GC pointer's current value. After each statepoint, the
gc.relocate result is stored into the alloca.

**INV-17: All uses of the original pointer are rewritten to loads from the
alloca.**
This includes uses in PHI nodes (load inserted in predecessor block), normal
instructions (load inserted before use), and gc-live bundle operands in
subsequent statepoints.

**INV-18: PromoteMemToReg converts allocas back to SSA.**
After all stores and loads are inserted, `PromoteMemToReg` runs to eliminate
the allocas and produce clean SSA with correct phi nodes for relocated values.

**INV-19: The number of allocas after promotion equals the number before.**
A debug assertion verifies that no extra allocas remain.

## Rematerialization

**INV-20: Derived pointers with cheap recomputation chains can be
rematerialized instead of relocated.**
If the chain from derived to base consists only of GEPs and no-op casts, and
the total cost is below `RematerializationThreshold` (default 6), the derived
pointer is removed from the live set. Instead, the chain is cloned and
inserted after the statepoint, using the relocated base pointer.

**INV-21: Rematerialization at uses is preferred when profitable.**
If a derived pointer is live across many statepoints but has few uses, it is
cheaper to rematerialize before each use than to relocate at every statepoint.

## Attribute Stripping

**INV-22: After RS4GC, gc.statepoint calls semantically "free the entire
heap".**
Attributes implying dereferenceability, noalias, readonly, nofree are stripped
from all functions and call sites, because the GC may relocate any object.
`llvm.invariant.start` instructions are also removed.
