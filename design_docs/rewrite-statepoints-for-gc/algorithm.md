# RewriteStatepointsForGC — Algorithm Detail

## Entry Point: `runOnFunction`

```
runOnFunction(F, DT, TTI, TLI):
  1. Canonicalize: fold single-entry PHIs, sink comparisons
  2. Canonicalize GEPs with mixed scalar/vector operands
  3. Inline @gc.get.pointer.base / @gc.get.pointer.offset intrinsics
  4. insertParsePoints(F, DT, TTI, ParsePointsNeeded)
```

`ParsePointsNeeded` is the list of all calls/invokes in `F` that may trigger
GC. A call is a parse point if:
- It is NOT marked `gc-leaf-function`.
- It is NOT an LLVM intrinsic (unless it's a deoptimize or element-unordered
  memcpy/memmove).
- It is in a function with a GC strategy that says `shouldRewriteStatepointsIn`.

---

## Phase A: Compute Live GC Pointers

```
findLiveReferences(F, DT, ToUpdate, Records):
  1. computeLiveInValues(DT, F, OriginalLivenessData)
     - Standard backward dataflow:
       For each BB:
         Kill[BB] = all GC-pointer-typed instructions defined in BB
         Gen[BB]  = all GC-pointer-typed operands used in BB (excl. PHIs, constants)
         LiveOut[BB] = seed from successor PHI inputs
         LiveIn[BB]  = (Gen ∪ LiveOut) − Kill
       Iterate worklist until LiveIn stabilizes.

  2. For each safepoint call:
     analyzeParsePointLiveness(DT, LivenessData, Call, Result):
       - Start from LiveOut[BB]
       - Walk instructions backwards from BB end to Call
       - Apply Kill/Gen per instruction
       - Remove Call's own result
       - Result.LiveSet = remaining set
```

### Commentary

The key design choice: **liveness is computed on actual LLVM IR types**, using
`isGCPointerType(T)` which checks `GCStrategy::isGCManagedPointer`. This
means the pass sees ALL GC pointers regardless of how they were introduced —
by the frontend, by optimizations, or by earlier passes. Nothing can "fall
through the cracks" because the type system enforces visibility.

This contrasts with Eco's approach where liveness is computed at a higher IR
level (Eco IR) and carried down as explicit operands. At the LLVM level, the
type distinction between HPointers and raw integers is lost (both are `i64`),
so LLVM-level liveness cannot distinguish them.

---

## Phase B: Find Base Pointers

```
findBasePointers(LiveSet, PointerToBase):
  For each live pointer P:
    Base = findBasePointer(P)
    PointerToBase[P] = Base
```

### findBasePointer Algorithm

For a given pointer `I`, determine which allocation it is derived from:

1. **Walk the def chain** via `findBaseDefiningValue`:
   - Arguments, loads, calls/invokes, atomics, extractvalue → **known base**
     (the value IS a base pointer)
   - Constants → null pointer (base of constant)
   - IntToPtr → itself (ill-defined, treat as base)
   - GEP → recurse on pointer operand
   - Cast → recurse through casts
   - Freeze → recurse
   - PHI, Select → **base-defining value (BDV)** — may merge different bases

2. **Fixed-point iteration on BDVs** (PHI/Select merge points):
   - Build a lattice: `Unknown → Base(V) → Conflict`
   - For each BDV, compute the meet of its inputs' states
   - If all inputs have the same base → `Base(V)`
   - If inputs have different bases → `Conflict`
   - Iterate until stable

3. **Conflict resolution**:
   - For each Conflict BDV, clone the instruction (PHI/Select) to create a
     parallel "base" version
   - Wire up the base version's inputs to the bases of the original inputs
   - This produces a `base_phi` or `base_select` that tracks which base
     pointer flows into each path

### Commentary

Base pointer inference is the most complex part of RS4GC. In a language like
Java, derived pointers (interior pointers, GEP results) are common, and the
GC needs to know the base object to update the derived pointer correctly.

**For Eco, this complexity is unnecessary.** Eco's HPointers are encoded as
offsets from a fixed heap base. They are not interior pointers — they ARE the
base. When GC moves an object, the HPointer's offset is updated directly. So
Eco doesn't need the base/derived distinction, and can treat every `!eco.value`
as its own base.

---

## Phase B': Recompute Liveness

After inserting base PHIs/Selects, new GC pointers exist that weren't in the
original live set. Re-run liveness to pick them up.

Dummy `__tmp_use` calls are inserted after each safepoint to keep base
pointers alive. These are removed after re-computation.

---

## Phase C: Rematerialization

Before building statepoints, check if any derived pointer can be cheaply
recomputed from its (relocated) base instead of being relocated itself.

```
findRematerializationCandidates(PointerToBase):
  For each (Derived, Base) pair where Derived ≠ Base:
    Walk Derived → Base via GEPs and no-op casts
    If chain length ≤ 10 and cost < RematerializationThreshold:
      Record as rematerialization candidate

rematerializeLiveValuesAtUses:  (optional, rs4gc-remat-derived-at-uses)
  If candidate has more statepoints-live-across than uses:
    Clone the chain before each use instead of relocating

rematerializeLiveValues:
  For each statepoint, for each live candidate:
    Remove from LiveSet
    Clone chain after statepoint, substituting relocated base
    Record in RematerializedValues map
```

### Commentary

Rematerialization reduces the live set size, which means fewer gc.relocate
instructions and less register pressure. It's purely an optimization — the
relocated version would be equally correct.

---

## Phase D: Make Statepoints Explicit

```
makeStatepointExplicit(Call, BasePtrs, LiveVars, Result):
  1. Build argument lists:
     - CallArgs: original call arguments
     - DeoptArgs: from "deopt" operand bundle
     - TransitionArgs: from "gc-transition" operand bundle
     - GCLive: all live GC pointers (both base and derived)

  2. Create gc.statepoint:
     For CallInst:
       %token = call token @llvm.experimental.gc.statepoint(
           id, num_patch_bytes, callee, num_call_args, flags,
           <call_args>, <deopt_args>, gc-live(<gc_live_ptrs>))
       %result = call T @llvm.experimental.gc.result(%token)

     For InvokeInst:
       %token = invoke token @llvm.experimental.gc.statepoint(...)
           to label %normal unwind label %unwind

  3. Create gc.relocate for each live variable:
     %relocated = call ptr addrspace(1) @llvm.experimental.gc.relocate(
         %token, base_index, derived_index)

  4. Replace original call with gc.result (deferred RAUW)
```

### gc.statepoint Semantics

The gc.statepoint intrinsic:
- **Calls the target function** with the original arguments
- **Declares gc-live pointers** in an operand bundle
- **Produces a token** used by gc.result and gc.relocate
- Is treated as a **full memory barrier** by the optimizer (it may relocate
  the entire heap)

The gc.relocate intrinsic:
- Takes the statepoint token and two indices (base index and derived index)
  into the gc-live list
- Returns the post-relocation value of the derived pointer
- The base index tells the GC which object was moved

---

## Phase E: Relocation via Alloca

This phase rewrites all uses of GC pointers to use their relocated versions.
The algorithm uses an alloca-based approach:

```
relocationViaAlloca(F, DT, Live, Records):
  1. For each unique live GC pointer V:
     Create alloca A_V in entry block

  2. For each statepoint S with gc.relocate results:
     For each relocated value R corresponding to original V:
       Store R into A_V   (after the statepoint)

  3. For each use U of original V:
     Insert load from A_V before U
     Replace V with the loaded value at U

  4. Store initial value of V into A_V after V's definition

  5. Run PromoteMemToReg to convert allocas → SSA
```

### Commentary

The alloca approach is elegant: it reduces the complex problem of "which
version of a pointer is correct at each program point" to a simple
store/load/mem2reg pattern. After mem2reg, the allocas become SSA phi nodes
that correctly select between the pre-relocation and post-relocation values
based on control flow.

**This is essentially the same pattern Eco's StatepointConversion uses.** The
critical difference is that RS4GC's alloca covers ALL live pointers (because
it computed them itself), while Eco's version only covers pointers from the
`__eco_safepoint_marker` arguments.

### Why allocas don't get optimized to Constant(0)

In RS4GC, every live GC pointer:
1. Is stored into its alloca at its **definition point** (step 4)
2. Has **all uses** rewritten to loads from the alloca (step 3)
3. Is stored again after each gc.relocate (step 2)

Because step 3 rewrites ALL uses, the alloca is always **read** (not just
written). This prevents the optimizer from eliminating it as a dead store. The
loads and stores form a proper def-use chain that mem2reg converts into clean
SSA.

In contrast, Eco's StatepointConversion Phase 2 only rewrites uses of values
that appear in gc-live. If a value is a call argument but never used after the
call by the CALLER, there are no loads from its alloca in the caller — only
the gc.relocate store. LLVM sees the alloca as write-only and optimizes it to
`Constant(0)` in the stackmap.

---

## Phase F: Attribute Stripping

```
stripNonValidData(M):
  For each function F:
    Remove: dereferenceable, noalias, readonly, writeonly, nofree
    Remove: llvm.invariant.start calls
    Remove: !nonnull, !dereferenceable, !dereferenceable_or_null metadata
    Remove: !noalias, !alias.scope metadata
```

After RS4GC, any gc.statepoint might relocate any object, invalidating these
guarantees.

---

## Data Structures

### GCPtrLivenessData
Per-block maps for the dataflow:
- `KillSet[BB]`: GC pointer instructions defined in BB
- `LiveSet[BB]`: GC pointer operands used in BB (Gen set)
- `LiveIn[BB]`: GC pointers live on entry to BB
- `LiveOut[BB]`: GC pointers live on exit from BB

### PartiallyConstructedSafepointRecord
Per-safepoint state during construction:
- `LiveSet`: GC pointers live at this safepoint
- `StatepointToken`: the gc.statepoint instruction
- `UnwindToken`: the landing pad for invoke statepoints
- `RematerializedValues`: derived pointers recomputed instead of relocated

### PointerToBaseTy
`MapVector<Value*, Value*>` mapping each live pointer to its base pointer.

### BDVState
Lattice state for base-pointer inference:
- `Unknown`: initial state
- `Base(V)`: known base pointer V
- `Conflict`: inputs have different bases, need a base-phi/select
