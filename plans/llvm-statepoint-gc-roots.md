# LLVM Statepoints + Stack Maps for GC Root Tracing

## Status: PLANNING
## Priority: High (prerequisite for native bootstrap under GC stress)

---

## 0. Problem Statement

Eco's moving GC (nursery + old-gen) currently only roots **globals** (via `eco_gc_add_root` in `__eco_init_globals()`) and **platform state** (scheduler's `modelStorage_`). Local variables in JIT-compiled functions are **not rooted**. If GC triggers mid-function, local heap pointers on the machine stack are invisible to the collector.

**Goal:** Make Eco's moving GC see all live `eco.value` locals in compiled code via LLVM statepoints and stack maps.

**Approach:** LLVM `gc.statepoint` + `gc.relocate` intrinsics with stack map emission. Full relocating semantics from the outset — no intermediate non-moving prototype.

---

## 1. Current State (Verified)

### 1.1 What exists

| Component | File | Status |
|---|---|---|
| `eco.safepoint` op definition | `runtime/src/codegen/Ops.td:1110-1128` | Defined with `StrAttr:$stack_map`, docs say "lowers to gc.statepoint" |
| `SafepointOpLowering` | `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp:25-35` | **Erases** the op (no-op) |
| `RootSet` (3 categories) | `runtime/src/allocator/RootSet.hpp` | Long-lived, JIT, stack roots all functional |
| Minor GC root evacuation | `runtime/src/allocator/NurserySpace.cpp:410-423` | Evacuates all 3 root categories |
| Major GC root marking | `runtime/src/allocator/OldGenSpace.cpp:284-328` | Marks from all roots |
| `collectRoots()` | `runtime/src/allocator/ThreadLocalHeap.cpp:162-171` | Merges long-lived + stack roots |
| Global root init | `runtime/src/codegen/Passes/EcoToLLVMGlobals.cpp:544-606` | Generates `__eco_init_globals()` |
| `eco_safepoint()` runtime export | `runtime/src/allocator/RuntimeExports.cpp:1795` | No-op stub |
| Standard func-to-LLVM lowering | `runtime/src/codegen/Passes/EcoToLLVM.cpp:277` | Uses `populateFuncToLLVMConversionPatterns` for non-kernel functions |
| Kernel func lowering | `runtime/src/codegen/Passes/EcoToLLVMFunc.cpp:26-80` | Only handles `is_kernel` functions → external declarations |

### 1.2 What does NOT exist

- No `eco.safepoint` ops are emitted by the Elm compiler (grep confirms zero matches in `compiler/src/`)
- No LLVM statepoint/gc.relocate intrinsics anywhere in codebase
- No GC strategy attribute on functions
- No stack map parsing code
- No stack frame walking for root discovery
- `RootSet::stack_roots` is only used by the interpreter (`main.cpp`), never by JIT code

### 1.3 Key architectural facts

- Thread-local stop-the-world GC: each thread owns its `ThreadLocalHeap`, GC runs independently per thread
- `!eco.value` lowers to `i64` (tagged pointer / HPointer encoding)
- Elm's immutability guarantees no old-to-young pointers, so no write barriers
- GC is only triggered by allocation (in `ThreadLocalHeap::allocate` when nursery exceeds threshold)
- Non-kernel `func.func` uses MLIR's standard `populateFuncToLLVMConversionPatterns`
- JIT execution via `EcoRunner` (wraps MLIR ExecutionEngine)

---

## 2. Decisions (Resolved)

### D1: Statepoints, not shadow stack
Statepoints/stack maps are the design. Feasibility is established. Rationale:
- All existing docs and PLAN assume statepoint-based design
- Only approach that cleanly supports moving nursery + compacting old gen
- Even if MLIR lacks first-class statepoint ops, the intrinsics can be declared as `LLVM::LLVMFuncOp` and called via `LLVM::CallOp`

### D2: Full relocating semantics from the start
No "non-relocating prototype" mode. Rationale:
- Collector already assumes moving nursery and supports compaction in old gen
- A non-relocating mode would either disable minor GC in compiled code or pin everything, undermining nursery effectiveness
- LLVM's statepoint model handles SSA rewrites cleanly: statepoint produces token → gc.relocate per live value → downstream uses replaced
- Complexity is confined to the `SafepointOpLowering` pattern in `EcoToLLVMErrorDebug.cpp`

### D3: Over-approximate liveness, refine later
At each safepoint, treat **all currently in-scope `eco.value` SSA values** as live roots. Rationale:
- Avoids building a full liveness analysis in the Elm compiler
- The MLIR generator (`Context.elm`) already tracks an environment of bindings
- Extra roots only increase mark work, not change semantics
- LLVM DCE will eliminate obviously dead gc.relocate calls
- Refinement (dropping dead locals, backward scan) can come later in Phase 4

### D4: Safepoints before allocations + at loop back-edges
GC runs at allocation time on the allocating thread, so we need GC-safe points **before any call that might allocate**:
- Before every `eco.allocate*` / `eco.construct.*` / `eco.string_literal` op
- At loop back-edges: any `scf.while` / tail-recursive function gets a safepoint at the loop header
- NOT needed at every function entry/exit or every call boundary (only allocation-triggering calls matter)

### D5: `eco.safepoint` takes variadic operands, zero results
The Eco-level op takes live roots as operands but produces no results. Relocation is handled entirely at LLVM level during lowering:
- `SafepointOpLowering` emits `gc.statepoint` + `gc.relocate` per operand
- Uses `replaceAllUsesExcept` to redirect downstream SSA uses to relocated values
- This keeps the Eco dialect simple — no SSA rewiring needed in the Elm compiler

### D6: Loop-carried values need no special Eco-level handling (scf.while resolved)
Safepoints inside loops (including `scf.while` with `iter_args`) do **not** require `eco.safepoint` to produce results. The pipeline's phase separation makes this work:

1. **Stage 2** (EcoControlFlowToSCF): Eco joinpoints/cases are lowered to `scf.if` / `scf.while`. Loop-carried variables become `iter_args` / `scf.yield` operands — regular SSA values.
2. **Stage 3** (EcoToLLVM): `eco.safepoint` is lowered here. By this point, loops are already in SCF/CF form.
3. The `SafepointOpLowering` pattern emits `gc.statepoint` + `gc.relocate` and uses `replaceAllUsesExcept` to rebind all downstream uses of each operand to the relocated value.
4. If an operand is loop-carried, the `scf.yield` at the loop body's end will naturally use the relocated value (`%v'`) instead of the original (`%v`), because `replaceAllUsesExcept` rewrites all uses after the safepoint — including the yield.

**Why no Eco-level results are needed:**
- `eco.safepoint` is a side-effecting annotation with `() -> ()` shape in Eco's type system
- Loop semantics are encoded in SCF/CF, not in the safepoint op
- SSA splitting happens entirely at LLVM level during Stage 3

**Edge case:** If the LLVM-level pattern encounters a case where the same SSA name is used on both sides of a safepoint in a way that confuses `replaceAllUsesExcept`, the fix is to adjust the LLVM-level pattern (split critical edges, insert temporary SSA names) — not to add results to `eco.safepoint`.

**Required test (Phase 4):** An `scf.while` loop where some `iter_args` are `!eco.value` and a safepoint appears in the body with those as operands. Verify that after lowering: (a) statepoints and relocates appear in the loop body, (b) the loop's block arguments receive relocated SSA names, (c) the program executes correctly under GC stress.

---

## 3. Implementation Plan

### Phase 1: Dialect Change — `eco.safepoint` with variadic operands

**Files:**
- `runtime/src/codegen/Ops.td`

**Change:** Replace `StrAttr:$stack_map` with variadic `Eco_Value` operands:

```tablegen
def Eco_SafepointOp : Eco_Op<"safepoint"> {
  let summary = "GC safepoint";
  let description = [{
    GC safepoint operation. Marks a point where garbage collection can
    safely occur. The operands are the live eco.value roots at this point.

    During EcoToLLVM lowering, this becomes an llvm.experimental.gc.statepoint
    with gc.relocate operations for each live pointer. Downstream SSA uses
    of each operand are rewritten to use the relocated value.
  }];

  let arguments = (ins Variadic<Eco_Value>:$live_roots);
  let results   = (outs);

  let assemblyFormat = "($live_roots^ `:` type($live_roots))? attr-dict";
}
```

**Why no results:** Relocation is handled at LLVM level by the lowering pattern using `replaceAllUsesExcept`. The Eco dialect stays simple — the Elm compiler doesn't need to thread relocated values through SSA.

**Post-change:**
- Regenerate TableGen outputs
- Update `SafepointOpLowering` in `EcoToLLVMErrorDebug.cpp` to use `adaptor.getLiveRoots()` (still erasing for now)
- Update any existing tests that reference `stack_map` attribute

---

### Phase 2: Emit `eco.safepoint` ops in the Elm compiler

**Files (compiler is in Elm, locations extrapolated):**
- `compiler/src/Compiler/Generate/MLIR/Expr.elm` — main expression lowering
- `compiler/src/Compiler/Generate/MLIR/Context.elm` — environment tracking
- `compiler/src/Compiler/Generate/MLIR/Ops.elm` — op emission helpers

**Safepoint placement policy (initial):**
1. Before every `eco.allocate*` / `eco.construct.*` / `eco.string_literal` emission
2. At `scf.while` loop headers (tail-recursive functions)
3. NOT at every call boundary — only allocation-triggering calls

**Liveness computation (over-approximate):**
1. The MLIR generator already maintains an environment of "known variables" with their MLIR SSA `Value` and type in `Context.elm`
2. When inserting an `eco.safepoint`:
   - Collect all `Value`s in the environment whose type is `!eco.value`
   - Pass them as operands to `eco.safepoint`
3. No separate liveness analysis pass needed — piggyback on existing binding tracking

**Example emitted MLIR:**
```mlir
%v0 = eco.constant 42 : !eco.value
%v1 = eco.construct.cons %head, %tail : !eco.value
eco.safepoint %v0, %v1 : !eco.value, !eco.value
%v2 = eco.allocate_record ...
```

**Deliverable:** Eco dialect IR with explicit safepoints and live roots. Safepoints still erased as no-op during EcoToLLVM (Phase 2 can proceed before Phase 2b is ready).

---

### Phase 2b: EcoToLLVM lowering to statepoints

**Files:**
- `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp` — Replace `SafepointOpLowering`
- `runtime/src/codegen/Passes/EcoToLLVM.cpp` — Add GC strategy attr walk after conversion

**A. GC strategy on functions**

After `applyFullConversion` succeeds (line 342 of `EcoToLLVM.cpp`), before `createGlobalRootInitFunction`:

```cpp
// Set GC strategy on all non-external LLVM functions
module.walk([](LLVM::LLVMFuncOp func) {
    if (!func.isExternal()) {
        func.setGcAttr(StringAttr::get(func.getContext(), "statepoint-example"));
    }
});
```

**B. SafepointOpLowering — full relocating lowering**

Replace the erase-only pattern in `EcoToLLVMErrorDebug.cpp`:

```cpp
struct SafepointOpLowering : public OpConversionPattern<SafepointOp> {
    using OpConversionPattern::OpConversionPattern;

    LogicalResult
    matchAndRewrite(SafepointOp op, OpAdaptor adaptor,
                    ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto liveValues = adaptor.getLiveRoots(); // Already converted to i64

        if (liveValues.empty()) {
            rewriter.eraseOp(op);
            return success();
        }

        // 1. Emit gc.statepoint intrinsic call
        //    Produces a token for gc.relocate.

        // 2. For each live value, emit gc.relocate
        //    Each gc.relocate takes: token, base ptr index, derived ptr index
        //    Returns the potentially-relocated pointer value

        // 3. For each original live value, replace all downstream uses
        //    with the corresponding gc.relocate result:
        //    originalValue.replaceAllUsesExcept(relocatedValue, statepoint);

        rewriter.eraseOp(op);
        return success();
    }
};
```

Two possible approaches for the intrinsic calls:
- **First-class ops:** `LLVM::GCStatepointOp` / `LLVM::GCRelocateOp` if MLIR exposes them
- **Intrinsic-as-function:** Declare `@llvm.experimental.gc.statepoint.*` and `@llvm.experimental.gc.relocate.*` as `LLVMFuncOp`, call via `LLVM::CallOp`

**C. Pattern registration** — No change needed, `SafepointOpLowering` is already registered at `EcoToLLVMErrorDebug.cpp:236`.

**D. Interaction with conversion ordering:**
- Safepoints must lower during `applyFullConversion` alongside other Eco ops
- `SafepointOp` is already marked illegal via `target.addIllegalDialect<EcoDialect>()` at `EcoToLLVM.cpp:206`
- No special ordering needed — the pattern runs during the same conversion pass

**Integration tests:**
- Add FileCheck tests in `test/codegen/` verifying statepoint + gc.relocate emission
- JIT-run a small program with large heap (no GC triggered) to validate relocated SSA doesn't break behavior

---

### Phase 3: Runtime stack map parsing and stack root integration

**New files:**
- `runtime/src/allocator/StackMap.hpp`
- `runtime/src/allocator/StackMap.cpp`

**3.1 Stack map parser**

Parse the `__LLVM_StackMaps` section (LLVM's documented binary format) into C++ structures:

```cpp
namespace Elm {

struct StackMapLocation {
    enum Kind { Register, Direct, Indirect, Constant, ConstantIndex };
    Kind kind;
    uint16_t dwarfRegNum;   // Register number
    int32_t offset;         // Stack offset (for Indirect locations)
};

struct StackMapRecord {
    uint64_t patchPointID;
    uint64_t instructionOffset;  // Relative to function entry
    std::vector<StackMapLocation> locations;
};

class StackMap {
public:
    static StackMap parse(const uint8_t* data, size_t size);
    const StackMapRecord* findRecord(uint64_t returnAddress) const;

private:
    // Keyed by absolute return address (computed from function base + instruction offset)
    std::unordered_map<uint64_t, StackMapRecord> records_;
};

} // namespace Elm
```

**3.2 Hook into JIT loader**

In `EcoRunner.cpp`, after JIT compilation:
1. Locate `__LLVM_StackMaps` section from the ExecutionEngine's object code
   - May require `JITEventListener` or custom `RTDyldMemoryManager`
2. Call `StackMap::parse()`
3. Store the resulting `StackMap` in `Allocator` (accessible to all thread-local heaps)

**3.3 Stack frame walking**

Extend `ThreadLocalHeap`:

```cpp
// ThreadLocalHeap.hpp
void collectStackRootsFromStackMap();

// ThreadLocalHeap.cpp
void ThreadLocalHeap::collectStackRootsFromStackMap() {
    RootSet& roots = nursery_.getRootSet();
    roots.restoreStackRootPoint(0); // Clear previous stack roots

    // Walk stack frames using frame pointer chaining:
    // 1. Get current frame pointer (platform-specific)
    // 2. For each frame:
    //    a. Read return address (*(rbp + 8) on x86-64)
    //    b. Look up in StackMap
    //    c. For each StackMapLocation (Indirect kind):
    //       - Compute slot address: rbp + location.offset
    //       - Push as HPointer* into RootSet stack roots
    //    d. Follow frame pointer chain: rbp = *(rbp)
}
```

**Prerequisites:** JIT'd code must be compiled with frame pointers enabled (`-fno-omit-frame-pointer` or equivalent LLVM flag in `EcoPipeline.cpp`).

**3.4 Integrate with GC entry points**

`ThreadLocalHeap::minorGC()` currently just calls `nursery_.minorGC(old_gen_)` (line 123-125). Change to:

```cpp
void ThreadLocalHeap::minorGC() {
    collectStackRootsFromStackMap();  // Populate stack roots from live frames
    nursery_.minorGC(old_gen_);
}
```

Similarly for `majorGC()` — call `collectStackRootsFromStackMap()` before `collectRoots()` at line 133.

**Key consideration:** Stack roots from stack maps are raw addresses of `i64` stack slots containing HPointer-encoded values. They fit naturally into `RootSet::stack_roots` as `HPointer*` since `HPointer` is `uint64_t`.

**No changes needed** to `NurserySpace` or `OldGenSpace` scanning — they already iterate all three root categories.

---

### Phase 4: Testing and Validation

**4.1 Unit tests — Stack map parser**
- Construct synthetic `__LLVM_StackMaps` binary buffers (matching LLVM's documented format)
- Feed to `StackMap::parse`, verify records and offsets

**4.2 IR-level tests — Statepoint emission**
- FileCheck tests in `test/codegen/`:
  ```mlir
  // RUN: ecoc -emit=llvm %s | FileCheck %s
  // CHECK: call token @llvm.experimental.gc.statepoint
  // CHECK: call {{.*}} @llvm.experimental.gc.relocate
  ```
- Verify gc.relocate count matches live root count
- **Loop-carried values test (D6):** An `scf.while` with `!eco.value` iter_args and a safepoint in the body. Verify that after lowering: statepoints/relocates appear in the loop, loop block arguments use relocated SSA names, and the `scf.yield` feeds back relocated values

**4.3 E2E stress tests — GC under compiled code**
- Compile and run Elm programs that:
  - Recursively build large lists/trees with many live locals across allocations
  - Use loops holding pointers across many GCs
- Configure tiny nursery via `HeapConfig` (`nursery_gc_threshold` etc.)
- Force minor + major GC at high frequency
- Assert program output correctness + no crashes/corruption

**4.4 Bootstrap validation**
- Run self-compiling bootstrap with GC stress flags
- This exercises the full pipeline under realistic load

---

## 4. Dependency Graph

```
Phase 1 (Ops.td: variadic operands)
    ↓
    ├──→ Phase 2 (Emit safepoints in Elm compiler)
    │         ↓
    │    [Eco IR has safepoints, still erased during lowering]
    │
    └──→ Phase 2b (EcoToLLVM: statepoint + gc.relocate lowering)
              ↓
         [LLVM IR has statepoints, stack maps emitted]
              ↓
         Phase 3 (Runtime: stack map parser + stack walking + GC integration)
              ↓
         Phase 4 (Testing: unit, IR, E2E, bootstrap)
              ↓
         [Optional] Phase 5: Safepoint & liveness tuning
```

**Parallelism:** Phases 2 and 2b can be developed concurrently once Phase 1 is done. Phase 3 needs Phase 2b's LLVM IR shape but not the Elm compiler changes.

---

## 5. Remaining Open Questions

1. **MLIR LLVM dialect statepoint API:** Does our MLIR version expose `gc.statepoint` / `gc.relocate` as first-class ops, or must we declare them as `LLVMFuncOp` intrinsics? To be determined during Phase 2b implementation.

2. **JIT ExecutionEngine section access:** Can we retrieve `__LLVM_StackMaps` from MLIR's `ExecutionEngine`? May need `JITEventListener` or custom memory manager. To be determined during Phase 3.

3. **Frame pointer guarantee:** Do we need to add `-fno-omit-frame-pointer` to the JIT compilation flags in `EcoPipeline.cpp`? Or can we use DWARF-based unwinding? Frame pointer chaining is simpler and faster.

4. **AOT support:** Should we also support stack maps in AOT-compiled executables (ELF `__LLVM_StackMaps` section)? Or JIT-only for now?

---

## 6. Risk Assessment

| Risk | Impact | Mitigation |
|---|---|---|
| MLIR lacks first-class statepoint ops | Medium — Phase 2b complexity | Fallback to intrinsic-as-function approach (declare + CallOp) |
| JIT section access for stack maps | Medium — blocks Phase 3 | JITEventListener or custom memory manager; AOT as alternative |
| SSA rewiring in lowering (replaceAllUsesExcept) | Medium — tricky edge cases | Thorough FileCheck tests; start with simple straight-line programs |
| scf.while + safepoint interaction | Low — resolved by D6 | `replaceAllUsesExcept` naturally propagates relocated values through `scf.yield`; add targeted test in Phase 4 |
| Performance regression from safepoint overhead | Low initially | Over-approximate roots only cost extra mark time; optimize in Phase 5 |
| Frame pointer requirement | Low | Standard practice; `-fno-omit-frame-pointer` is trivial to add |

---

## 7. Files Summary

### Modified files
| File | Phase | Change |
|---|---|---|
| `runtime/src/codegen/Ops.td` | 1 | Redefine `Eco_SafepointOp`: variadic `Eco_Value` operands, no results |
| `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp` | 1, 2b | Update adaptor usage (Phase 1); full statepoint lowering (Phase 2b) |
| `runtime/src/codegen/Passes/EcoToLLVM.cpp` | 2b | Add GC strategy attr walk after `applyFullConversion` |
| `runtime/src/allocator/ThreadLocalHeap.hpp` | 3 | Add `collectStackRootsFromStackMap()` |
| `runtime/src/allocator/ThreadLocalHeap.cpp` | 3 | Implement stack walking; call before minorGC/majorGC |
| `runtime/src/codegen/EcoPipeline.cpp` | 3 | Enable frame pointers in JIT compilation flags |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | 2 | Emit `eco.safepoint` ops before allocations |
| `compiler/src/Compiler/Generate/MLIR/Context.elm` | 2 | Expose environment query for in-scope `!eco.value` values |

### New files
| File | Phase | Purpose |
|---|---|---|
| `runtime/src/allocator/StackMap.hpp` | 3 | Stack map binary parser + lookup API |
| `runtime/src/allocator/StackMap.cpp` | 3 | Implementation |
| Test files in `test/codegen/` | 4 | FileCheck tests for statepoint emission |
