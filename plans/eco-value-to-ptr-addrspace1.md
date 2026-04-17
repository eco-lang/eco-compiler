# Plan: eco.value → ptr addrspace(1) in LLVM IR

## Context

Currently, the EcoToLLVM pass converts `!eco.value` (the MLIR type for GC-managed Elm heap values) to `i64` in the LLVM dialect. This means GC roots are indistinguishable from plain integers in LLVM IR, requiring explicit `inttoptr`/`ptrtoint` conversions around every safepoint and preventing LLVM's GC infrastructure (RS4GC, statepoints) from natively tracking roots.

The goal is to change `!eco.value → ptr<i8, addrspace(1)>` ("ptr<1>") so that:
- All SSA values representing HPointers are pointer-typed, letting LLVM's GC statepoint machinery track them natively.
- `ptrtoint`/`inttoptr` only appear at heap/global/closure storage boundaries (i64 memory slots) and for embedded constant encoding.
- Runtime C++ stays at `uint64_t` ABI; the JIT module just declares those functions with `ptr<1>` types, relying on ABI register equivalence.

---

## Files to modify

| # | File | Summary |
|---|------|---------|
| 1 | `runtime/src/codegen/Passes/EcoToLLVMInternal.h` | Type converter doc, add `isHPtrLLVMType`, `getHPtrLLVMType`, `valueToI64`, `i64ToValue` helpers |
| 2 | `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | EcoTypeConverter: eco.value→ptr<1>; all runtime decls: HPointer i64→HPTR_TY; safepoint markers: remove inttoptr |
| 3 | `runtime/src/codegen/Passes/EcoToLLVMFunc.cpp` | Kernel declarations: eco.value→ptr<1> instead of i64 |
| 4 | `runtime/src/codegen/Passes/EcoToLLVMTypes.cpp` | eco.constant, eco.string_literal: emit ptr<1> via inttoptr of i64 constant |
| 5 | `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` | Heap stores/loads: valueToI64/i64ToValue at storage boundary; alloc-group: replace castToI64/UnrealizedConversionCast |
| 6 | `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | Closure args array: valueToI64 for i64 heap slots; direct ptr<1> for calls |
| 7 | `runtime/src/codegen/Passes/EcoToLLVMControlFlow.cpp` | Case scrutinee: icmp eq on ptr<1> constants directly |
| 8 | `runtime/src/codegen/Passes/EcoToLLVMArith.cpp` | Bool HPointer constants: emit as ptr<1> |
| 9 | `runtime/src/codegen/Passes/EcoToLLVMGlobals.cpp` | Global load/store: i64ToValue/valueToI64 at boundary |
| 10 | `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp` | Safepoint: roots already ptr<1>, remove inttoptr; crash/dbg: adapt to ptr<1> |
| 11 | `runtime/src/codegen/Passes/BFToLLVM.cpp` | BFTypeConverter: eco.value→ptr<1>; BF heap stores: use helpers |
| 12 | `runtime/src/codegen/Passes/StatepointConversion.cpp` | stripIntToPtr→identity; isGCManagedType→check ptr AS1; allocas→ptr<1> typed; remove ptrtoint after gc.relocate |
| 13 | `design_docs/invariants.csv` | Update CGEN_012; add REP_LLVM_001 |
| 14 | `design_docs/theory/pass_eco_to_llvm_theory.md` | Update type mapping table, safepoint section |

---

## Step-by-step plan

### Step 1: Shared infrastructure (`EcoToLLVMInternal.h`)

1. Update `EcoTypeConverter` doc comment: `eco.value → ptr<i8, 1>`.
2. Add inline helpers:
   - `isHPtrLLVMType(Type t)` — checks `LLVMPointerType` with AS=1
   - `getHPtrLLVMType(MLIRContext &ctx)` — returns `LLVMPointerType::get(i8, 1)`
   - `valueToI64(builder, loc, v)` — if ptr<1>: ptrtoint to i64; if already i64: passthrough
   - `i64ToValue(builder, loc, i)` — if i64: inttoptr to ptr<1>; if already ptr<1>: passthrough

### Step 2: Type converter (`EcoToLLVMRuntime.cpp:28-56`)

1. Change `addConversion` lambda: `eco::ValueType → LLVMPointerType::get(IntegerType::get(ctx, 8), 1)`.
2. Source/target materializations: keep `UnrealizedConversionCastOp` (works for arbitrary types).
3. Update comment from "i64 (tagged pointer)" to "ptr<i8,1> (GC-managed pointer)".

### Step 3: Runtime function declarations (`EcoToLLVMRuntime.cpp:78-575`)

Add `#define HPTR_TY getHPtrLLVMType(*ctx)` alongside existing macros.

For each `getOrCreate*` method, change every `I64_TY` that represents an HPointer to `HPTR_TY`. Preserve `I64_TY` for actual integer params (unboxed int values, sizes, bitmaps).

**Concrete classification** (HPointer → HPTR_TY):
- **Alloc results**: all `eco_alloc_*` returns, `eco_init_*_at` returns → HPTR_TY
- **HPointer params**: `eco_alloc_cons(head, tail, ...)` head/tail when boxed; `eco_store_field(obj, idx, val)` obj and val; `eco_get_tag(val)` val; `eco_resolve_hptr(hptr)` hptr; `eco_crash(msg)` msg; `eco_cons_head_*(cons)` cons param; `eco_clone_array(arr)` arr; `eco_pap_extend(closure, ...)` closure; `eco_closure_call_saturated(closure, ...)` closure; `eco_apply_closure(closure, ...)` closure; `eco_apply_segmentation_unknown(closure, ...)` closure; `Elm_Kernel_Utils_equal(a, b)` a, b and return; `eco_set_unboxed(obj, bitmap)` obj
- **Keep i64**: `eco_alloc_int(value)` value param (actual unboxed int); `eco_alloc_record(field_count, bitmap)` both params; `eco_alloc_custom(ctor, count, bytes)` all params; `eco_alloc_string(len)` param; `eco_int_pow(base, exp)` both params; sizes, counts, bitmaps, indices everywhere
- **Keep f64**: float params
- **Keep ptr (AS0)**: function pointers, raw data pointers

**Special cases:**
- `eco_alloc_cons(head: i64, tail: i64, unboxed: i32)` — head and tail are passed as i64 in the runtime C++ ABI but conceptually may be HPointers or unboxed. The design says to declare them as HPTR_TY since the type converter maps !eco.value→ptr<1>. However, head *can* be an unboxed int/float stored as i64. **QUESTION 1** below.
- `eco_init_cons_at(ptr, head: i64, tail: i64, unboxed: i32)` — same question.
- `eco_store_field*(obj: i64, idx: i32, val: i64)` — obj is always HPointer, val could be HPointer or unboxed.

### Step 4: Kernel declarations (`EcoToLLVMFunc.cpp`)

Replace the manual type-conversion loop (lines 48-65) with the `EcoTypeConverter`. Instead of `if (isa<ValueType>(t)) → i64`, use the converter which now maps `eco.value → ptr<1>`.

```cpp
auto funcType = funcOp.getFunctionType();
auto convertedType = typeConverter.convertFunctionSignature(funcType, ...);
```

Or simply change lines 52-53 and 61-62 to emit `getHPtrLLVMType(*ctx)` instead of `IntegerType::get(ctx, 64)`.

### Step 5: Constants and strings (`EcoToLLVMTypes.cpp`)

- `eco.constant` for HPointer constants (True, False, Nil, etc.): emit `i64` constant, then `IntToPtrOp` to ptr<1>. Replace op with ptr<1> result.
- `eco.string_literal`: empty string → same inttoptr pattern. Non-empty → runtime call now returns ptr<1> directly.

### Step 6: Heap operations (`EcoToLLVMHeap.cpp`)

1. **Replace `castToI64`** with `valueToI64` (from the new helpers).
2. **Replace `UnrealizedConversionCastOp(i64 → eco.value)`** in alloc-group merge blocks with `i64ToValue`.
3. **Field stores**: use `valueToI64` before `eco_store_field` for eco.value fields.
4. **Field loads**: use `i64ToValue` after loading i64 from heap slots.
5. **Box/Unbox**: runtime calls now return/accept ptr<1> directly; remove extra casts.
6. **Alloc-group safepoint marker** (line 1333-1338): roots are now ptr<1>, remove `castToI64` + `IntToPtrOp` — pass directly.

### Step 7: Closures and calls (`EcoToLLVMClosures.cpp`)

1. **emitRootedBoxedArgsArray**: when building i64* args array, use `valueToI64` for eco.value args before store. Use `origFuncTypes` to determine which params are HPointers vs primitives.
2. **Closure captures**: stored as i64 heap slots → `valueToI64`/`i64ToValue` at store/load.
3. **Direct Elm→Elm calls**: adaptor gives ptr<1> operands, callee expects ptr<1> — no casts.
4. **Kernel calls**: same as Elm→Elm now (declarations use ptr<1>).
5. **getOrCreateWrapper**: load i64 from args array → `i64ToValue` for eco.value params → call target → `valueToI64` for result if storing back.

### Step 8: Control flow (`EcoToLLVMControlFlow.cpp`)

- Case scrutinee equality: scrutinee is ptr<1>, constants are ptr<1> (from Step 5). Emit `icmp eq ptr<1>` directly. Remove any `ptrtoint` for tag testing.
- Joinpoints, jumps, returns: type converter handles threading ptr<1> through.

### Step 9: Arithmetic and booleans (`EcoToLLVMArith.cpp`)

- Bool HPointer results (True/False): emit as ptr<1> constants via inttoptr.
- Comparisons of eco.value booleans: pointer equality, no ptrtoint.
- Primitives (int, float): unchanged.

### Step 10: Globals (`EcoToLLVMGlobals.cpp`)

- Global type stays i64 (heap slot).
- `LoadGlobalOpLowering`: load i64, then `i64ToValue` → ptr<1> result.
- `StoreGlobalOpLowering`: `valueToI64` → store i64.
- `createGlobalRootInitFunction`: no change (works on AS0 addresses).

### Step 11: Error, debug, safepoints (`EcoToLLVMErrorDebug.cpp`)

1. **SafepointOpLowering** (line 54-111): `adaptor.getLiveRoots()` now returns ptr<1> values. Remove the `IntToPtrOp` loop (lines 75-80). Pass roots directly to `__eco_safepoint_marker`.
2. **CrashOpLowering**: msg is ptr<1>; `eco_crash` now declared with ptr<1>. Remove casts.
3. **DbgOpLowering**: for eco.value args, use `valueToI64` before passing to `eco_dbg_print` (which still expects i64 for the debug array).

### Step 12: Safepoint emission helpers (`EcoToLLVMRuntime.cpp:607-741`)

- `emitAllocWithSafepoint` (line 607): `liveRoots` are now ptr<1>. Remove `IntToPtrOp` loop (lines 639-643). Pass directly to marker.
- `emitSafepointMarker` (line 667): same — remove inttoptr.
- `emitWrapperSafepointMarker` (line 715): same — remove inttoptr.

### Step 13: BF dialect (`BFToLLVM.cpp`)

- Change BFTypeConverter's eco.value conversion from i64 to ptr<1> (use `getHPtrLLVMType`).
- BF ops that call runtime: runtime functions now use ptr<1>, so no casts needed.
- BF ops that access heap slots: use `valueToI64`/`i64ToValue`.

### Step 14: StatepointConversion (`StatepointConversion.cpp`)

This is the LLVM IR-level pass (post-MLIR translation).

1. **`stripIntToPtr`** (line 51-56): Marker args are now directly ptr<1> (no inttoptr wrapper). Change to return the value itself. The function should extract the operand if it IS an IntToPtrInst (for backwards compat during transition) or return the value as-is.
2. **`isGCManagedType`** (line 79-81): Change from `isIntegerTy(64)` to checking `PointerType` with AS=1.
3. **Phase 1** (line 87-235): `originalInts` concept changes — now roots are directly ptr<1> values. `stripIntToPtr` returns the ptr<1> value itself. `LiveRoots` stores ptr<1> values instead of i64.
4. **Phase 2** (line 241-401):
   - Allocas: type changes from `i64Ty` to `PointerType::get(ctx, 1)`.
   - Initial stores: store ptr<1> directly.
   - After gc.relocate: result is already ptr<1>. Remove `CreatePtrToInt` (line 327). Store ptr<1> directly.
   - Use rewriting: loads produce ptr<1>. Remove gc-live special case (lines 370-393) — all uses expect ptr<1> now.
5. **`removeDeadGCRelocates`** (line 420-508): Simplify peephole — no more `PtrToIntInst` after gc.relocate. Just check for unused gc.relocate calls.

### Step 15: Documentation

1. `design_docs/invariants.csv`: Update CGEN_012 description; add REP_LLVM_001.
2. `design_docs/theory/pass_eco_to_llvm_theory.md`: Update type mapping table, safepoint section.

### Step 16: Tests

1. Structural: verify `llvm.func` signatures use ptr<1> for eco.value.
2. Constant equality: verify `icmp eq ptr addrspace(1)` for Nil/True/False checks.
3. Alloc-group: verify no `unrealized_conversion_cast` remains; all HPointer SSA values are ptr<1>.
4. Statepoint: verify gc-live bundle entries are ptr<1>; allocas are ptr<1> typed.
5. E2E: full test suite (`cmake --build build --target full`).

---

## Execution order and dependencies

```
Step 1  (helpers in header)          — no deps
Step 2  (type converter)             — depends on Step 1
Step 3  (runtime decls)              — depends on Step 1
Step 4  (kernel decls)               — depends on Step 1
  ↓
Step 5  (constants/strings)          — depends on Step 1
Step 6  (heap)                       — depends on Steps 1-3
Step 7  (closures)                   — depends on Steps 1-3
Step 8  (control flow)               — depends on Step 5
Step 9  (arith/bool)                 — depends on Step 5
Step 10 (globals)                    — depends on Step 1
Step 11 (error/debug/safepoint)      — depends on Steps 1-3
Step 12 (safepoint helpers)          — depends on Steps 1-3
Step 13 (BF dialect)                 — depends on Step 1
  ↓
Step 14 (StatepointConversion)       — depends on Steps 11-12
Step 15 (docs)                       — any time
Step 16 (tests)                      — after all code changes
```

Steps 1-4 must go first. Steps 5-13 can be done in any order after that. Step 14 depends on the safepoint changes. Build and test after everything.

---

## Questions and open issues

### Q1: Runtime alloc functions with mixed HPointer/unboxed params

`eco_alloc_cons(head, tail, head_unboxed)` — the C++ runtime takes `uint64_t` for both head and tail. When head is unboxed (e.g., an Int), the caller passes raw `i64` bits. When boxed, it passes an HPointer.

**Problem**: If we declare `eco_alloc_cons` with `ptr<1>` for head/tail, we'd need to `inttoptr` unboxed int values too, which is semantically wrong (they're not pointers).

**Options**:
- (a) Keep head/tail as `i64` in the declaration (matching C++ ABI literally). Use `valueToI64` at call sites for eco.value args. This means alloc functions are a "storage boundary" like heap slots.
- (b) Declare with `ptr<1>` and accept that unboxed values go through inttoptr (ABI-safe but semantically dubious).
- (c) Have two variants per alloc function (one for boxed, one for unboxed head) — complex.

**Recommendation**: Option (a) — keep alloc functions with `i64` params for fields that may be unboxed, and use `valueToI64` at call sites. Only change the *return type* to `ptr<1>` (all alloc results are HPointers). This matches the design's principle: "i64 ↔ ptr<1> conversions only at storage boundaries."

### Q2: `eco_store_field(obj, idx, val)` — val may be HPointer or unboxed

Same issue as Q1. The `val` parameter can be either an HPointer or an unboxed primitive, depending on context.

**Recommendation**: Keep `val` as `i64` in the declaration. Callers use `valueToI64` for eco.value, or pass i64 directly for primitives. Only `obj` becomes `HPTR_TY` (it's always an HPointer).

### Q3: How far to push ptr<1> into alloc-group lowering?

The alloc-group pass (`lowerOneAllocGroup` in EcoToLLVMHeap.cpp) currently operates in mixed Eco+LLVM IR space, using `castToI64` + `UnrealizedConversionCastOp`. It runs *before* the main EcoToLLVM conversion patterns.

**Options**:
- (a) Keep alloc-group results as `i64` in the merge block (matching heap slot representation), and let the main conversion patterns handle the i64→ptr<1> transition via `i64ToValue`. This means the `UnrealizedConversionCastOp(i64 → eco.value)` at line 1378 stays but is resolved by the type converter's materialization.
- (b) Change alloc-group merge blocks to produce ptr<1> directly via `i64ToValue`, removing the unrealized cast.

**Recommendation**: Option (a) initially — minimal change to alloc-group logic. The existing `UnrealizedConversionCastOp(i64 → eco.value)` will be resolved by the type converter when the main patterns run. We only need to update `castToI64` to handle ptr<1> inputs (in case some values are already converted).

### Q4: `eco_dbg_print` takes a `ptr` to an array of values — what type for array elements?

The debug print functions (`eco_dbg_print(ptr, count)`) take a pointer to an array of i64 values. The individual values in the array are HPointers stored as i64.

**Recommendation**: Keep the array as i64 elements. Use `valueToI64` when populating the array. The debug function declarations stay unchanged.

### Q5: Backwards compatibility of StatepointConversion during incremental development

If we change EcoToLLVM first but haven't updated StatepointConversion yet, the LLVM IR will have ptr<1> marker args but StatepointConversion still expects to strip inttoptr.

**Recommendation**: Update StatepointConversion in the same commit/PR. Make `stripIntToPtr` handle both old and new patterns during development (return value as-is if it's already ptr<1>, strip if it's inttoptr). Final cleanup removes the inttoptr path.

### Q6: Region alloc returns `ptr` (AS0) — should this change?

`eco_gc_alloc_region_fast/slow` return `ptr` (raw pointer to region start), not `i64` HPointer. The group lowering uses this raw pointer for GEP-based initialization.

**Recommendation**: No change. Region alloc returns a raw pointer for bump-allocation bookkeeping. The `eco_init_*_at` functions take this raw pointer and return an HPointer (which should be ptr<1>).

### Q7: `eco_resolve_hptr(hptr) -> ptr` — hptr param becomes ptr<1>?

This function converts an HPointer to a raw dereferenceable pointer. The input is logically an HPointer.

**Recommendation**: Yes, change hptr param to `HPTR_TY`. Return stays `ptr` (AS0, raw pointer).
