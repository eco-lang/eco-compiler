# Plan: GCRootCarrier OpInterface + Call/PapExtend Safepoints

## Problem

`eco.call` and `eco.papExtend` are not treated as GC safepoints. They can trigger
allocation (via callees or runtime helpers like `eco_pap_extend`), but no stackmap
records exist at their return PCs. This means GC cannot relocate roots that are live
across these calls, causing forward-pointer corruption ("new_n_values exceeds
max_values", `hdr->tag < Tag_Forward` assertion).

## Goal

1. Introduce a `GCRootCarrier` OpInterface so all safepoint-carrying ops are handled
   uniformly by EcoGCPrepare.
2. Extend `eco.call`, `eco.papExtend`, and `eco.papCreate` to carry explicit GC roots.
3. Lower call/papExtend through the same marker+statepoint path as allocations.
4. Generalize StatepointConversion to handle arbitrary marker+call pairs (not just
   allocation functions), including indirect calls.

## Resolved Design Decisions

- **Q1 — Append pattern, not AttrSizedOperandSegments.** CallOp/PapExtendOp keep
  their single Variadic. EcoGCPrepare appends roots to the operand list and sets an
  `eco.gc_roots_count` integer attr to mark the boundary. Same idiom as
  RecordConstructOp/CustomConstructOp. No frontend bytecode change.
- **Q2 — Calls get independent safepoints.** Each eco.call/eco.papExtend gets its
  own marker+statepoint with exact roots at that program point. They remain group
  barriers (break adjacent alloc groups) but also receive their own roots.
- **Q3 — musttail calls are non-safepoints.** EcoGCPrepare skips
  `eco.call{musttail=true}` entirely (no roots attached). Lowering skips emitting
  a marker for musttail calls. If doubt arises about a musttail call reaching GC
  in the callee, drop musttail rather than emit an unsound statepoint.
- **Q4 — Indirect call statepoints supported.** Remove `assert(targetFn)` in
  StatepointConversion. `gc.statepoint` natively supports indirect callees. Use
  `targetCall->getCalledOperand()` as the callee Value* regardless of direct/indirect.
- **Q5 — PapCreateOp included.** It allocates a closure on the heap, so it's a
  safepoint. Gets GCRootCarrier. `Pure` trait is compatible (GC/stackmaps are
  internal runtime concerns, not externally visible side effects).
- **Q6 — func::CallOp stays barrier-only.** EcoGCPrepare runs before lowering
  introduces func.call. They remain group barriers in liveness analysis but don't
  get GCRootCarrier. Any GC-capable call must go through an Eco op we control.

---

## Step-by-step Plan

### Phase 1: ODS — Define GCRootCarrier Interface and Extend Ops

**Step 1.1: Define `Eco_GCRootCarrierOpInterface` in `Ops.td`**

Add near the top of `Ops.td` (after includes, before dialect def):
- `getGCRoots() -> ValueRange` — return the GC root operands
- `setGCRoots(ValueRange)` — replace the GC root operands

**Step 1.2: Attach `DeclareOpInterfaceMethods<Eco_GCRootCarrierOpInterface>` to ops**

Add the trait to all ops that carry GC roots (14 ops total):
- `AllocateOp`, `AllocateCtorOp`, `AllocateStringOp`, `AllocateClosureOp`
- `BoxOp`
- `ListConstructOp`, `Tuple2ConstructOp`, `Tuple3ConstructOp`
- `RecordConstructOp`, `CustomConstructOp`
- `SafepointOp`
- `CallOp`, `PapExtendOp`, `PapCreateOp`

**Step 1.3: NO ODS argument changes to CallOp / PapExtendOp / PapCreateOp**

These ops keep their existing argument lists unchanged. Roots are appended to the
existing Variadic by EcoGCPrepare at the operand level, tracked by the
`eco.gc_roots_count` attr. The ODS definition, assembly format, and MLIR bytecode
encoding all stay the same.

**Step 1.4: Re-run ODS codegen**

`cmake --build build` regenerates `EcoOps.h.inc` / `EcoOps.cpp.inc`.

---

### Phase 2: Implement GCRootCarrier Methods

**File: `runtime/src/codegen/EcoOps.cpp`**

Three implementation patterns:

**Step 2.1: Ops with dedicated `$live_roots` segment (9 ops)**

For `AllocateOp`, `AllocateCtorOp`, `AllocateStringOp`, `AllocateClosureOp`,
`BoxOp`, `ListConstructOp`, `Tuple2ConstructOp`, `Tuple3ConstructOp`,
`SafepointOp`:
- `getGCRoots()` → delegates to `getLiveRoots()`
- `setGCRoots(newRoots)` → clears and appends via `getLiveRootsMutable()`

**Step 2.2: Ops with roots appended after fields (2 ops)**

For `RecordConstructOp` (boundary = `field_count`) and `CustomConstructOp`
(boundary = `size`):
- `getGCRoots()` → `getFields().drop_front(boundary)`
- `setGCRoots(newRoots)` → keep first `boundary` operands, replace tail

**Step 2.3: Ops with roots appended after call operands (3 ops — append pattern)**

For `CallOp`, `PapExtendOp`, `PapCreateOp`:
- Use `eco.gc_roots_count` attr (integer, default 0) to mark the root suffix.
- `getGCRoots()`:
  ```cpp
  unsigned rootCount = getOperation()->getAttrOfType<IntegerAttr>(
      "eco.gc_roots_count").getValue().getZExtValue();
  // or 0 if attr absent
  auto allOps = getOperands(); // for CallOp
  return allOps.drop_front(allOps.size() - rootCount);
  ```
- `setGCRoots(newRoots)`:
  ```cpp
  unsigned oldRootCount = ...;  // from attr, or 0
  auto allOps = getOperation()->getOperands();
  unsigned nonRootCount = allOps.size() - oldRootCount;
  SmallVector<Value, 8> ops(allOps.begin(), allOps.begin() + nonRootCount);
  ops.append(newRoots.begin(), newRoots.end());
  getOperation()->setOperands(ops);
  // Update attr:
  OpBuilder b(getOperation());
  getOperation()->setAttr("eco.gc_roots_count",
      b.getI64IntegerAttr(newRoots.size()));
  ```
- For `PapExtendOp`: operand layout is `[closure, newargs..., roots...]`.
  Non-root count = `1 + newargs.size()` (before roots were appended).
- For `PapCreateOp`: operand layout is `[captures..., roots...]`.
  Non-root count = original capture count (before roots).
- For `CallOp`: operand layout is `[operands..., roots...]`.
  Non-root count = original operand count (before roots).

---

### Phase 3: Refactor EcoGCPrepare to Use GCRootCarrier

**File: `runtime/src/codegen/Passes/EcoGCPrepare.cpp`**

**Step 3.1: Replace `setLiveRoots` dyn_cast cascade with interface call**

Current code (lines 107-130) dispatches per op type. Replace with:
```cpp
if (auto carrier = dyn_cast<eco::GCRootCarrier>(op))
    carrier.setGCRoots(roots);
```

Delete the old `setLiveRoots` static function entirely.

**Step 3.2: Extend `isMayAllocOp` to include call-like ops**

Add `CallOp` (non-musttail only), `PapExtendOp`, and `PapCreateOp` to
`isMayAllocOp`. These are safepoints that need roots.

For `CallOp`: skip if `musttail=true` — these are non-safepoints per Q3 decision.

**Step 3.3: Reclassify call-like ops as independent safepoints**

Call/PapExtend/PapCreate remain **group barriers** (they still break allocation
groups). But they also get independent root computation.

New pass flow:
1. Walk block, group adjacent alloc ops (stops at barriers as before).
2. For each alloc group: compute liveness at group leader, set roots on leader,
   mark rest as group members.
3. **NEW:** For each barrier op that is also a GCRootCarrier (Call, PapExtend,
   PapCreate — but NOT musttail calls): compute liveness at that op, call
   `carrier.setGCRoots(roots)`.
4. For explicit `eco.safepoint` ops: compute liveness, set roots.

Steps 2-4 all use the same `GCRootCarrier` interface dispatch.

**Step 3.4: Debug attribute**

Set `eco.gc_roots_count` on all GCRootCarrier ops. For the append-pattern ops
(Call, PapExtend, PapCreate) this is load-bearing (used by `getGCRoots`). For
dedicated-segment ops it's diagnostic-only.

---

### Phase 4: Call Lowering with Safepoints

**Step 4.1: Add `emitCallWithSafepoint` helper**

**Files:** `EcoToLLVMInternal.h` (declaration), `EcoToLLVMRuntime.cpp` (implementation)

Mirrors `emitAllocWithSafepoint`:
```cpp
mlir::LLVM::CallOp emitCallWithSafepoint(
    mlir::Operation *op,
    mlir::ConversionPatternRewriter &rewriter,
    const EcoRuntime &runtime,
    mlir::Value callee,              // FlatSymbolRef or function pointer
    mlir::ValueRange callArgs,
    mlir::ValueRange liveRoots);
```

Implementation:
1. If `liveRoots` non-empty:
   - Convert i64 roots to `ptr addrspace(1)` via IntToPtrOp
   - Emit `call @__eco_safepoint_marker(gcPtrs...)`
2. Emit the actual call (direct or indirect)
3. Return the CallOp

**Step 4.2: Extract GC roots from adapted operands in lowering**

Since CallOp/PapExtendOp/PapCreateOp use the append pattern (no ODS `$live_roots`
segment), the ODS-generated adaptor won't have `getLiveRoots()`. Instead, lowering
must read `eco.gc_roots_count` from the original op and slice the adapted operands:
```cpp
unsigned rootCount = op->getAttrOfType<IntegerAttr>("eco.gc_roots_count")
    .getValue().getZExtValue();
auto allAdapted = adaptor.getOperands();
ValueRange callOperands = allAdapted.drop_back(rootCount);
ValueRange liveRoots = allAdapted.take_back(rootCount);
```

**Step 4.3: Update `CallOpLowering` in `EcoToLLVMClosures.cpp`**

- Extract roots per Step 4.2.
- For musttail calls: skip safepoint, emit direct call as before.
- For all other calls: use `emitCallWithSafepoint`.
- Both direct calls (callee symbol) and indirect calls (closure function pointer)
  go through the same helper.

**Step 4.4: Update `PapExtendOpLowering` in `EcoToLLVMClosures.cpp`**

Both paths (generic runtime helper, typed/saturated evaluator call) use
`emitCallWithSafepoint` with extracted roots. Applies to:
- `eco_pap_extend` / `eco_apply_closure` / `eco_apply_segmentation_unknown`
  runtime helper calls
- Direct evaluator calls (`_cap` fast path, closure call path)

**Step 4.5: Update `PapCreateOp` lowering**

PapCreate allocates via `eco_pap_create` or similar. Wire its roots through
`emitAllocWithSafepoint` (not `emitCallWithSafepoint`, since the semantics are
allocation, not function call).

**Step 4.6: Existing alloc/constructor lowering — no change needed**

They already pass `adaptor.getLiveRoots()` to `emitAllocWithSafepoint`. The only
difference is EcoGCPrepare now fills roots via the interface, but the adaptor API
is unchanged for these ops.

---

### Phase 5: Generalize StatepointConversion

**File: `runtime/src/codegen/Passes/StatepointConversion.cpp`**

**Step 5.1: Remove target function name assertion**

Lines 155-164 currently assert target must be `__eco_safepoint_poll` or
`eco_alloc_*`. Replace with: any `CallBase` following a marker is a valid
statepoint target.

**Step 5.2: Support indirect callees**

Remove `assert(targetFn && ...)` at line 157. When building the statepoint:
- Use `targetCall->getCalledOperand()` as the callee (works for both direct
  and indirect calls).
- `targetFn` may be null for indirect calls — handle gracefully.

**Step 5.3: Add stats/logging categories**

Keep counters for: poll safepoints, alloc safepoints, call safepoints (new),
papExtend safepoints (new). These are diagnostic — not gatekeeping.

Categorize by checking `targetFn->getName()` when direct, or "indirect" when
`targetFn` is null.

---

### Phase 6: Testing

**Step 6.1: MLIR-level FileCheck tests**

- EcoGCPrepare populates roots (via `eco.gc_roots_count`) on `eco.call`,
  `eco.papExtend`, and `eco.papCreate`
- musttail calls get NO roots attached
- RecordConstructOp/CustomConstructOp roots correctly sliced via GCRootCarrier
- GCRootCarrier interface returns correct roots for all 14 op types

**Step 6.2: LLVM IR verification**

- Functions with `eco.call` / `eco.papExtend` have `__eco_safepoint_marker`
  before the lowered call instructions
- `gc.statepoint` wraps both direct and indirect calls after StatepointConversion

**Step 6.3: Stackmap verification**

- `llvm-readobj --stackmap` confirms stackmap records at call/papExtend return PCs
- Root locations match expected live `!eco.value` set

**Step 6.4: E2E regression**

- `cmake --build build --target full`
- Original "new_n_values exceeds max_values" corruption gone
- `hdr->tag < Tag_Forward` assertion no longer fires
- GC logging shows statepoints at alloc, call, papExtend, and papCreate sites

---

## File Change Summary

| File | Changes |
|------|---------|
| `runtime/src/codegen/Ops.td` | Add `Eco_GCRootCarrierOpInterface` def; attach trait to 14 ops; NO argument changes to Call/PapExtend/PapCreate |
| `runtime/src/codegen/EcoOps.cpp` | Implement `getGCRoots`/`setGCRoots` for all 14 ops (3 patterns) |
| `runtime/src/codegen/Passes/EcoGCPrepare.cpp` | Replace dyn_cast cascade with interface dispatch; add Call/PapExtend/PapCreate root population; skip musttail |
| `runtime/src/codegen/Passes/EcoToLLVMInternal.h` | Declare `emitCallWithSafepoint` |
| `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | Implement `emitCallWithSafepoint` (mirrors `emitAllocWithSafepoint`) |
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | Extract roots from adapted operands; use `emitCallWithSafepoint` in CallOp/PapExtendOp lowering; skip musttail |
| `runtime/src/codegen/Passes/StatepointConversion.cpp` | Remove target name assertion; support indirect callees; add call/papExtend stats |
