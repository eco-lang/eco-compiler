# Type-Aware `buildEvaluatorArgs` Per Slot

## Status: READY FOR IMPLEMENTATION

## Goal

Make `buildEvaluatorArgs` aware of the concrete type (Int/Float/Char/Boxed) of each
evaluator parameter slot, so unboxed captures are re-boxed with the correct heap
allocator (`eco_alloc_int`, `eco_alloc_float`, `eco_alloc_char`) instead of
unconditionally calling `eco_alloc_int` for every unboxed slot.

## Current Behavior (the bug)

`buildEvaluatorArgs` (RuntimeExports.cpp:829-853) treats **all** unboxed captured
values identically:

```cpp
if ((bitmap >> i) & 1) {
    val = eco_alloc_int(static_cast<int64_t>(val));  // ← always Int
}
```

This means an unboxed Float stored in a closure gets boxed as `ElmInt` (wrong tag),
and an unboxed Char gets boxed as `ElmInt` (wrong tag). The evaluator receives a
`void*[]` and has no way to detect the mis-tag — it trusts the caller.

The compiler policy (`canUnbox`) explicitly allows unboxing for `MInt`, `MFloat`, and
`MChar`. The `eco.papCreate` `unboxed_bitmap` is computed by checking whether each
capture MLIR type is unboxable (`i64`, `f64`, `i16`). So Float/Char captures **can**
be stored unboxed, and this is a forward-looking correctness fix that aligns the
runtime with the documented invariants.

New args to `eco_closure_call_saturated` are expected to be already HPointer-encoded,
so the inline lowering path (`emitInlineClosureCall`) pre-boxes them correctly on
the compiler side. But captures are only boxed at runtime by `buildEvaluatorArgs`,
which lacks type information.

---

## Resolved Questions

### Q1: Do Float/Char captures actually get stored unboxed today?
**RESOLVED: Yes, the policy allows it.** `canUnbox` returns `True` for `MInt`,
`MFloat`, and `MChar`. Closure capture invariants say "only `i64`, `f64`, `i16`
operands are stored unboxed." `eco.papCreate`'s `unboxed_bitmap` is computed by
checking whether each capture MLIR type is unboxable. Int is the common case;
Float/Char unboxing is supported but less common. This is a **forward-looking
correctness fix** that aligns the runtime with documented invariants.

### Q2: Should `buildEvaluatorArgs` handle unboxed new args in phase 1?
**RESOLVED: No.** Phase 1 uses the layout **only for captured values**. The inline
saturated `papExtend` lowering already has explicit logic for boxing new args by type
(bitcasts `f64`↔`i64`, etc.). The biggest semantic hazard is captured Float/Char
values re-boxed incorrectly as ElmInt. Fixing captures first hits the main correctness
risk while leaving new-arg handling as-is.

### Q3: Over-saturated calls via `eco_apply_closure` still pass `nullptr`?
**RESOLVED: Yes, acceptable for phase 1.** `eco_apply_closure` is the generic apply
path — args are pre-boxed and passed as HPointers. Keeping `layout = nullptr` there
preserves existing semantics. Typed layout support targets the typed PAP saturated
path; generic/over-saturated can be extended later.

### Q4: Kernel callers — do any pass unboxed args?
**RESOLVED: No.** Kernel C++ code consumes closures passed from Elm but doesn't
construct closures with primitive captures on the C++ side. All closure creation with
unboxed captures goes through `eco.papCreate` from MLIR. Kernel callers pass
already-boxed HPointer args, so `nullptr` layout is correct for all of them.

### Q5: JIT symbol registration — any issues with extra parameter?
**RESOLVED: No.** `RuntimeSymbols.h` registers symbols by name via `fromPtr()`. The
execution engine resolves function addresses by symbol without re-validating the
signature at link time. Just update: `RuntimeExports.h` declaration, `.cpp` definition,
call sites in runtime code, and the LLVM function type in `EcoRuntime` helpers.

### Q6: `emitFastClosureCall` and `emitClosureCall` — affected?
**RESOLVED: No.** These paths call the evaluator directly (fast clone or generic clone)
without going through `eco_closure_call_saturated`. They load captures from the closure
and pass them as direct LLVM arguments. They already handle types correctly via their
compiled signatures.

### Q7: GC root range mask correctness
**RESOLVED: No changes needed.** The GC mask registers all slots as HPointers. After
`buildEvaluatorArgs` runs, all slots ARE HPointers (unboxed values have been boxed).
The layout only affects WHICH allocator is called, not the resulting representation.

---

## Implementation Plan

### Step 1: Define `ParamKind` and `EvalParamLayout` in the runtime

**Files:** `runtime/src/allocator/Heap.hpp`

Add near the `Closure` struct (after line ~233):

```cpp
enum ParamKind : uint8_t {
    PK_Boxed  = 0,
    PK_Int    = 1,
    PK_Float  = 2,
    PK_Char   = 3,
};

struct EvalParamLayout {
    uint8_t num_params;
    uint8_t kinds[];  // flexible array member, length = num_params
};
```

**Rationale:** Put it near `Closure` since it's closure-specific metadata. Using a
flexible array member keeps it compact and matches the LLVM global layout we'll emit.

---

### Step 2: Add `layout` parameter to `eco_closure_call_saturated`

**Files:**
- `runtime/src/allocator/RuntimeExports.h` (line 221) — update declaration
- `runtime/src/allocator/RuntimeExports.cpp` (line 979) — update definition
- `runtime/src/codegen/RuntimeSymbols.cpp` (line 218-221) — symbol registration unchanged (function pointer address)
- `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` (line 342-345) — update LLVM function type
- `runtime/src/codegen/Passes/EcoToLLVMInternal.h` (line 241) — update declaration if needed

New signature:
```cpp
uint64_t eco_closure_call_saturated(
    uint64_t closure_hptr,
    uint64_t* new_args,
    uint32_t num_newargs,
    const EvalParamLayout* layout  // nullptr = legacy behavior
);
```

LLVM function type changes from `(i64, ptr, i32) -> i64` to `(i64, ptr, i32, ptr) -> i64`.

---

### Step 3: Rewrite `buildEvaluatorArgs` to use layout (captures only)

**File:** `runtime/src/allocator/RuntimeExports.cpp` (line 829-853)

Update signature to accept `const EvalParamLayout* layout`. **Phase 1 scope: layout
applies only to captured values (slots 0..n_captured-1). New args remain unchanged
(assumed HPointer-encoded, as today).**

Behavior for captured values:

- **Boxed slot** (`bitmap bit == 0`): copy through unchanged (no change from today).
- **Unboxed slot** (`bitmap bit == 1`):
  - If `layout == nullptr`: call `eco_alloc_int()` (legacy behavior, no regression).
  - If `layout != nullptr`: switch on `layout->kinds[i]`:
    - `PK_Int` → `eco_alloc_int(static_cast<int64_t>(raw))`
    - `PK_Float` → `memcpy` raw bits to double, `eco_alloc_float(f)`
    - `PK_Char` → `eco_alloc_char(static_cast<uint32_t>(raw & 0xFFFF))`
    - `PK_Boxed` → invariant violation (bitmap says unboxed but layout says boxed), crash

New args loop (slots n_captured..total-1) remains identical to today: copy through
as HPointer-encoded `void*`.

Add a debug assert: when `layout != nullptr`, `layout->num_params == n_captured + num_newargs`.

Updated signature:
```cpp
size_t buildEvaluatorArgs(
    Closure* closure,
    const uint64_t* new_args, uint32_t num_newargs,
    void** out_args,
    const EvalParamLayout* layout  // new parameter
);
```

No `new_unboxed_bitmap` parameter needed in phase 1 — new args pass through as-is.

---

### Step 4: Update `eco_closure_call_saturated` to thread layout through

**File:** `runtime/src/allocator/RuntimeExports.cpp` (line 979-1017)

Pass the new `layout` parameter to `buildEvaluatorArgs`. No other changes needed —
GC root range registration, stack allocation, evaluator call are all unchanged.

---

### Step 5: Update internal runtime callers to pass `nullptr` layout

**Files:**
- `runtime/src/allocator/RuntimeExports.cpp`:
  - `eco_apply_closure` line 868, 878 → add `/*layout=*/nullptr`

These are the generic apply path — args are pre-boxed, `nullptr` is correct.

---

### Step 6: Update kernel callers to pass `nullptr` layout

**Files:**
- `elm-kernel-cpp/src/core/StringExports.cpp` (lines 149, 160, 168)
- `elm-kernel-cpp/src/core/ListExports.cpp` (lines 26, 31, 36, 42, 48)
- `elm-kernel-cpp/src/core/JsArrayExports.cpp` (lines 42, 49, 56, 63)
- `elm-kernel-cpp/src/bytes/BytesExports.cpp` (line 362) — also update the `extern "C"` forward declaration at line 18

All kernel callers pass already-boxed HPointer args, so `nullptr` layout is correct.

---

### Step 7: Update MLIR lowering to pass `nullptr` layout for all existing paths

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

- `emitInlineClosureCall` (line 854-860): Currently calls `eco_closure_call_saturated`
  with 3 args. Add a 4th arg: `llvm::ConstantPointerNull` for `ptr`.

- `getOrCreateClosureCallSaturated` in EcoToLLVMRuntime.cpp (line 342-345): Update
  the LLVM function type to `(i64, ptr, i32, ptr) -> i64`.

**BUILD-GREEN CHECKPOINT:** After steps 1-7, `cmake --build build --target full`
should pass with identical behavior. All paths pass `nullptr`, so `buildEvaluatorArgs`
falls back to `eco_alloc_int` exactly as before. This validates the signature change
is wired correctly before adding layout emission.

---

### Step 8: Propagate `_capture_abi` to all typed-mode `eco.papExtend` ops

**Decision:** Propagate `_capture_abi` to all typed-mode papExtend ops derived from
`CallInfo.captureAbi`, regardless of `_dispatch_mode`. No need (and often impossible)
to add it to the genuinely generic papExtend/CallGenericApply path.

**Current state:** `_capture_abi` is **not emitted anywhere** today. The infrastructure
exists:
- The Elm AST has `captureAbi : Maybe CaptureABI` on `CallInfo` (Monomorphized.elm:587,1143)
- EcoToLLVMClosures.cpp reads `_capture_abi` (lines 731, 1248)
- But the Elm compiler always sets `captureAbi = Nothing` and the MLIR emitter never
  emits the attribute

**Implementation — two sub-steps:**

#### Step 8a: Populate `captureAbi` in the Elm AST

**Files:** The Staging/Rewriter and GlobalOpt passes that construct `CallInfo` records.

Where `CallInfo` is built for typed closure calls (calls with known callee and
`remaining_arity`), populate `captureAbi` from the callee's closure definition:
- Look up the callee's capture types from the monomorphized definition
- Build `CaptureABI { captureTypes = [...], paramTypes = [...], returnType = ... }`
- Set `captureAbi = Just abi` instead of `Nothing`

This only applies to typed-mode call sites where the callee's capture layout is known
at compile time. Generic apply sites (`CallGenericApply`) keep `captureAbi = Nothing`.

**Key files to modify (all currently set `captureAbi = Nothing`):**
- `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm` (lines 577, 644)
- `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` (lines 448, 504, 546, 682, 1887, 1998)
- `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm` (line 1500)
- `compiler/src/Compiler/Monomorphize/Specialize.elm` (line 619)
- `compiler/src/Compiler/Monomorphize/ResolveAccessorValues.elm` (line 224)

Not all of these need to change — only sites where the callee's capture types are
known. Sites that genuinely don't know the captures keep `Nothing`.

#### Step 8b: Emit `_capture_abi` in MLIR text output

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

In `applyByStages` (lines 1570-1705), where `papExtendAttrs` is built (lines 1668-1683):
- When `callInfo.captureAbi` is `Just abi`:
  - Emit `_capture_abi = [type1, type2, ...]` as an ArrayAttr of TypeAttrs
  - Map each `MonoType` in `abi.captureTypes` to its MLIR type (`i64`, `f64`, `i16`, `!eco.value`)
- When `callInfo.captureAbi` is `Nothing`:
  - Omit the attribute (same as today)

This ensures `_capture_abi` appears on typed-mode papExtend ops where capture types
are known, and is absent on generic apply ops. EcoToLLVMClosures.cpp already handles
the absent case by falling back to the inline path without layout.

---

### Step 9: Add `getOrCreateEvalLayout` helper to emit layout globals

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` (new static helper)

Create a helper that, given a list of `ParamKind` values, emits a constant LLVM global:

```
@__eco_eval_layout_<hash> = private constant { i8, [N x i8] } { i8 N, [N x i8] [i8 k0, i8 k1, ...] }
```

Use a `DenseMap<SmallVector<uint8_t>, GlobalVariable*>` cache (or equivalent MLIR-level
cache) to deduplicate layouts with identical kind sequences. Many evaluators will share
common patterns like `[PK_Boxed, PK_Boxed]`.

The struct layout must match the C `EvalParamLayout` in memory: first byte is count,
followed by contiguous `uint8_t` kinds.

---

### Step 10: Compute `ParamKind` per slot at typed saturated call sites

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

In the saturated branch of `PapExtendOpLowering` (around line 1228+), when we have
typed metadata (`remaining_arity` present) and the dispatch goes through the
**inline/legacy path** (i.e., `emitInlineClosureCall`):

**For captures** (from `_capture_abi` ArrayAttr — now available after Step 8):
- Map each capture type: `i64` → `PK_Int`, `f64` → `PK_Float`, `i16` → `PK_Char`, `ptr`/`!eco.value` → `PK_Boxed`
- Cross-reference with the closure's `unboxed` bitmap: if bitmap bit is 0, force `PK_Boxed`

**For new args** (positions n_captured..total-1):
- In phase 1, all set to `PK_Boxed` (since new args are pre-boxed by the compiler and
  `buildEvaluatorArgs` passes them through unchanged).

Assemble into `SmallVector<uint8_t>` and call `getOrCreateEvalLayout`.

If `_capture_abi` is absent (generic path), no layout is computed — pass `nullptr`.

---

### Step 11: Pass layout pointer at typed saturated call sites

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

**For `emitInlineClosureCall` path:**
- Add an optional `Value layoutPtr` parameter (default: nullptr constant).
- When `_capture_abi` metadata is available: compute the layout per Step 10 and pass it.
- When metadata is missing: continue passing nullptr.

**For `emitFastClosureCall` and `emitClosureCall` paths:**
- No changes needed — they call the evaluator directly without going through
  `eco_closure_call_saturated`.

**BUILD-GREEN CHECKPOINT:** After steps 8-11, `cmake --build build --target full`
should pass. Closures with typed metadata now get correct per-type re-boxing of
captures. Closures without metadata fall back to legacy behavior.

---

### Step 12: (Future / Phase 2) Extend segmentation-unknown path

**Not in initial scope.** Currently `eco_apply_segmentation_unknown` delegates to
`eco_apply_closure` for saturated/over-saturated cases, which passes `nullptr` layout.

Future enhancement: pass a `const EvalParamLayout*` through `eco_apply_segmentation_unknown`
and forward it to `eco_closure_call_saturated`. This would let us remove the pre-boxing
of `boxed_args` in the segmentation-unknown lowering, which currently duplicates work.

### Step 13: (Future / Phase 2) Move new-arg boxing into `buildEvaluatorArgs`

**Not in initial scope.** Once the layout infrastructure is proven, extend
`buildEvaluatorArgs` to accept a `new_unboxed_bitmap` and handle new-arg boxing via
the layout as well. This would let `emitInlineClosureCall` stop pre-boxing new args
on the compiler side, simplifying the lowering.

---

## Files Modified (Summary)

| File | Change |
|------|--------|
| `runtime/src/allocator/Heap.hpp` | Add `ParamKind` enum, `EvalParamLayout` struct |
| `runtime/src/allocator/RuntimeExports.h` | Update `eco_closure_call_saturated` signature |
| `runtime/src/allocator/RuntimeExports.cpp` | Rewrite `buildEvaluatorArgs`, update `eco_closure_call_saturated`, update `eco_apply_closure` calls |
| `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | Update LLVM function type for `eco_closure_call_saturated` |
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | Add layout emission helper, compute ParamKinds, pass layout at call sites |
| `runtime/src/codegen/RuntimeSymbols.cpp` | No change needed (function pointer address, not type-checked) |
| `elm-kernel-cpp/src/core/StringExports.cpp` | Pass `nullptr` for layout |
| `elm-kernel-cpp/src/core/ListExports.cpp` | Pass `nullptr` for layout |
| `elm-kernel-cpp/src/core/JsArrayExports.cpp` | Pass `nullptr` for layout |
| `elm-kernel-cpp/src/bytes/BytesExports.cpp` | Update extern decl + pass `nullptr` for layout |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Emit `_capture_abi` attr on typed-mode papExtend ops |
| `compiler/src/Compiler/GlobalOpt/Staging/Rewriter.elm` | Populate `captureAbi` on typed CallInfo records |
| `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm` | Populate `captureAbi` on typed CallInfo records |
| `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm` | Populate `captureAbi` on typed CallInfo records (if applicable) |

---

## Test Plan

1. **Build green with nullptr everywhere (after Steps 1-7):** `cmake --build build --target full`
   — Verifies no regressions from the signature change alone.

2. **Verify `_capture_abi` in MLIR output (after Step 8):**
   - Compile a test with closures capturing mixed types.
   - Inspect emitted MLIR for `_capture_abi` attributes on typed-mode papExtend ops.
   - Verify generic-mode papExtend ops do NOT have `_capture_abi`.

3. **Verify layout globals in LLVM IR (after Steps 9-11):**
   - Compile a test with mixed closure types (Int + Float + Char captures).
   - Inspect IR for `@__eco_eval_layout_*` globals with correct kind bytes.

4. **E2E: Char-in-closure test cases:**
   - Test programs where a Char is captured in a closure and passed through saturation.
   - Previously would produce `ElmInt`-tagged heap object; now should produce `ElmChar`.

5. **E2E: Float-in-closure test cases:**
   - Same as above for Float. Verify correct `ElmFloat` tag after re-boxing.

6. **Regression: existing test suites:**
   - `cmake --build build --target full` (all E2E tests)
   - `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` (front-end tests)

---

## No Remaining Open Issues

All questions resolved. Plan is ready for implementation.
