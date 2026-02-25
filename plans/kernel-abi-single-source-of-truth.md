# Kernel ABI Single Source of Truth Refactor

## Goal

Make the **compiler the single source of truth** for kernel ABI types, so that:
- MLIR IR is self-consistent by construction (papCreate/papExtend match function declarations)
- EcoToLLVM never reconstructs types from usage — it just reads them from `func.func`

This eliminates the "Bug 8" tech debt where `EcoToLLVM.cpp` scans `papCreate`/`papExtend` ops to infer kernel parameter types from captured/new-arg operand types.

## Current State Assessment

### Already Done (no work needed)

**MLIR Verifiers — COMPLETE.** Both verifiers in `EcoOps.cpp` already enforce full type checks:

- `PapCreateOp::verify()` (lines 262-362): Looks up `func.func` via function attr (or `_fast_evaluator`), checks arity matches param count (CGEN_051), and validates each captured operand type against the corresponding parameter type.
- `PapExtendOp::verify()` (lines 364-500): Traces the closure-def chain back to root `papCreate`, computes parameter indices, validates each newarg type, checks `remaining_arity` consistency (CGEN_052), and validates saturated call result types (CGEN_056).

**Compiler kernel registration infrastructure — COMPLETE:**

- `Context.registerKernelCall` (Context.elm:622-648): Records `(List MlirType, MlirType)` per kernel name in `ctx.kernelDecls`, crashes on signature mismatch.
- `Functions.generateKernelDecl` (Functions.elm:1022-1068): Emits `func.func` with `is_kernel=true`, `function_type`, stub body, private visibility.
- `Backend.generateMlirModule` (Backend.elm): Iterates `finalCtx.kernelDecls` via `Dict.foldl` and calls `generateKernelDecl` for each entry.
- `Ops.ecoCallNamed` (Ops.elm:428-457): Auto-registers any direct call to `Elm_Kernel_*` via `registerKernelCall`.
- `Expr.generateVarKernel` (Expr.elm): Calls `registerKernelCall` before `papCreate` for function-typed kernels with arity > 0.

### Remaining Work

The sole remaining tech debt is in the **EcoToLLVM pass** (`runtime/src/codegen/Passes/EcoToLLVM.cpp`), where lines 252-319 contain a second scan over `papCreate`/`papExtend` ops that reconstructs kernel parameter types from usage for kernels that lack `func::FuncOp` declarations.

---

## Resolved Investigation Questions

### Q1: Are there kernels that bypass `registerKernelCall`?

**Answer: No, based on code analysis.** All kernel PAP paths flow through `generateVarKernel` and therefore go through `registerKernelCall`. Specifically:

- **VarKernel paths** (Expr.elm `generateVarKernel`): When a function-typed kernel has arity > 0, it computes flattened ABI types via `Types.flattenFunctionType`, calls `Ctx.registerKernelCall`, then emits `eco.papCreate`. This is explicitly the compiler half of the Bug 8 fix.
- **Direct kernel calls** (non-function type): Call `Ops.ecoCallNamed`, which auto-registers `Elm_Kernel_*` symbols. These don't go through `getOrCreateWrapper` so they're irrelevant to the origFuncTypes/PAP issue.
- **Non-kernel PAP sites** (`generateVarGlobal`, lambda closures): Not kernel-specific, generate PAPs for regular `func.func` definitions. No `registerKernelCall` needed by design.
- **Lambdas.elm**: Confirmed NO kernel papCreate emissions.

**Residual risk:** There could be an edge case not visible in the code review. Phase 1 empirically confirms the scan is dead code by instrumenting it.

### Q2: Does `getOrCreateWrapper` need its multi-tier fallback after the refactor?

**Answer: No.** After the refactor, `getOrCreateWrapper` should:
- Look up the kernel symbol in `origFuncTypes` (populated from `func.func is_kernel` declarations).
- If not found for a kernel function, emit a **hard error** (`report_fatal_error`).
- Do **not** silently assume an ABI or infer from PAP usage.
- The all-i64 fallback and PAP-inference code should be deleted entirely for kernel functions.

### Q3: Should verifiers hard-error on missing kernel declarations?

**Answer: Yes.** For the refactored design:
- `PapCreate`/`PapExtend` verifiers should treat "no `func.func` found for `Elm_Kernel_*` symbol" as an immediate `emitOpError`, not something to skip.
- Combined with `UndefinedFunctionPass` for `eco.call`, this makes "kernel used without declaration" impossible to slip through to EcoToLLVM, which in turn lets us delete the PAP scan and the all-i64 fallback safely.

---

## Implementation Plan

### Phase 1: Empirically Confirm the Scan is Dead Code

**Goal:** Verify that the compiler already emits `func.func is_kernel` declarations for ALL kernels referenced in PAPs.

#### Step 1.1: Add a temporary assertion in the EcoToLLVM scan

In `EcoToLLVM.cpp` at line ~265 (inside the papCreate scan, where it checks whether a kernel already has a `func::FuncOp`), add an assertion that fires if a kernel does NOT have a declaration:

```cpp
// Temporary assertion: verify all kernel PAPs have declarations
if (!module.lookupSymbol<func::FuncOp>(funcName)) {
    llvm::errs() << "ASSERTION: kernel " << funcName
                 << " referenced in papCreate has no func::FuncOp declaration\n";
    assert(false && "kernel missing func.func declaration");
}
```

Run the full test suite:
```bash
cmake --build build --target check
cmake --build build --target full
```

- **If no assertions fire:** The scan is confirmed dead code. Proceed directly to Phase 3.
- **If assertions fire:** Identify which kernels lack declarations, fix in Phase 2.

### Phase 2: Fix Compiler Gaps (only if Phase 1 finds gaps)

#### Step 2.1: Add missing `registerKernelCall` calls

For any kernel identified in Phase 1 as lacking a declaration, trace the code path that emits its `papCreate` and add a `registerKernelCall` call:

```elm
( paramTypes, resultType ) = Types.flattenFunctionType monoType
ctxWithKernel = Ctx.registerKernelCall ctx kernelName paramTypes resultType
```

**Files to check if gaps exist:**
- `compiler/src/Compiler/Generate/MLIR/Expr.elm` — `generateVarKernel`
- `compiler/src/Compiler/Generate/MLIR/Ops.elm` — `ecoCallNamed`

#### Step 2.2: Verify both ABI policies produce declarations

Check that both `AllBoxed` (List, Utils, String.fromNumber, JsArray, Json.wrap) and `ElmDerived` (Basics, Bitwise, Char, etc.) kernels flow through `registerKernelCall` regardless of their ABI policy.

### Phase 3: Simplify EcoToLLVM (Core Refactor)

#### Step 3.1: Remove the papCreate/papExtend type-inference scan

**File:** `runtime/src/codegen/Passes/EcoToLLVM.cpp`

**Delete** lines ~252-319 (the second scan). Keep the first scan (lines 248-250) that walks `func::FuncOp` ops and populates `origFuncTypes`:
```cpp
module.walk([&](func::FuncOp funcOp) {
    runtime.origFuncTypes[funcOp.getSymName()] = funcOp.getFunctionType();
});
```

This first scan already captures all `func::FuncOp` declarations including kernel declarations (which have `is_kernel=true`). With all kernels having declarations, this single scan is sufficient.

#### Step 3.2: Harden `getOrCreateWrapper` in EcoToLLVMClosures.cpp

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

In the lookup strategy (lines 175-228), replace the last-resort "all-i64" fallback with a hard error for kernel functions:

```cpp
// If function starts with "Elm_Kernel_" and we don't have orig types,
// that's a compiler bug — the declaration should have been emitted.
if (funcName.starts_with("Elm_Kernel_")) {
    llvm::report_fatal_error(
        "missing original function types for kernel " + funcName +
        "; compiler must emit func.func is_kernel declaration");
}
```

Keep the all-i64 fallback only for non-kernel external functions (if any exist).

#### Step 3.3: Document the `origFuncTypes` invariant

**File:** `runtime/src/codegen/Passes/EcoToLLVMInternal.h`

Update the comment on `origFuncTypes`:
```cpp
/// Pre-scanned original function types (before LLVM type conversion).
/// Populated exclusively from func::FuncOp declarations in the module.
/// For kernel functions (is_kernel=true), the types come from the Elm
/// compiler's registerKernelCall -> generateKernelDecl pipeline.
/// EcoToLLVM must NOT attempt to infer or reconstruct these types.
/// Missing entries for Elm_Kernel_* functions are treated as fatal errors.
llvm::StringMap<mlir::FunctionType> origFuncTypes;
```

### Phase 4: Strengthen Verifiers

Make verifiers strict about missing kernel declarations so that IR bugs are caught at verification time, not during EcoToLLVM lowering.

#### Step 4.1: PapCreateOp::verify() — hard error for missing kernel decls

**File:** `runtime/src/codegen/EcoOps.cpp`

In `PapCreateOp::verify()`, after the `lookupFunc` call, if the function is a kernel and no declaration is found, emit an error instead of skipping type checks:

```cpp
auto targetFuncOp = lookupFunc(getOperation(), fastEvalAttr ? fastEvalAttr : getFunctionAttr());
if (!targetFuncOp) {
    auto funcName = getFunctionAttr().getValue();
    if (funcName.starts_with("Elm_Kernel_")) {
        return emitOpError("kernel function ") << funcName
               << " has no func.func declaration; compiler must emit one";
    }
    // For non-kernel functions without fast_evaluator, skip signature checks
    // (two-clone closures validate against _fast_evaluator, not the generic clone)
}
```

#### Step 4.2: PapExtendOp::verify() — hard error for missing kernel decls

Same treatment in `PapExtendOp::verify()`: when the closure-def chain traces back to a `papCreate` referencing a kernel symbol, and `lookupFunc` fails, emit an error.

### Phase 5: Testing

#### Step 5.1: Full regression suite

```bash
cmake --build build --target check
cmake --build build --target full
cd compiler && npx elm-test-rs --fuzz 1
```

#### Step 5.2: Kernel ABI coverage

Verify existing tests exercise both ABI policies:
- **AllBoxed** kernels: List.cons, String operations, JsArray, Json.wrap
- **ElmDerived** kernels: Basics arithmetic, Bitwise ops, Char operations

Check `test/codegen/` and `test/elm/` for coverage.

#### Step 5.3: Negative test (optional)

Construct a small MLIR test that references a kernel in `papCreate` without a `func.func is_kernel` declaration. Verify the verifier catches it with the new hard error from Phase 4.

---

## New Invariant

**CGEN_057: Kernel Declaration Completeness**
> Every kernel function symbol (`Elm_Kernel_*`) that appears in a `papCreate`, `papExtend`, or `eco.call` operation MUST have a corresponding `func.func` declaration with `is_kernel=true` and a `function_type` attribute whose parameter and result types match the ABI-level types computed by the Elm compiler from MonoType via `monoTypeToAbi`.

Enforced by:
- **Compiler:** `Context.registerKernelCall` + `Functions.generateKernelDecl` (construction-time guarantee)
- **MLIR verifiers:** `PapCreateOp::verify()` and `PapExtendOp::verify()` hard-error on missing kernel declarations
- **UndefinedFunctionPass:** Catches `eco.call` to undeclared symbols (CGEN_011)
- **EcoToLLVM:** Hard error on missing `origFuncTypes` entry for kernel functions (defense-in-depth)

---

## Risk Assessment

**Low risk.** The verifiers are already in place and passing. The compiler already emits kernel declarations for all known kernel PAP paths. The main change is removing a defensive scan that is very likely dead code.

**Mitigation strategy:**
- Phase 1 empirically confirms whether the scan is dead code before deleting it.
- If it's dead: the refactor is essentially deleting code + adding hard errors + documenting invariants.
- If it's not dead: Phase 2 fixes the compiler gaps first, making it safe to then delete the scan.
- Verifier hardening (Phase 4) provides an additional safety net at IR validation time.

## Files Changed

| File | Phase | Change |
|------|-------|--------|
| `runtime/src/codegen/Passes/EcoToLLVM.cpp` | 1, 3 | Add temp assertion (P1), then delete papCreate/papExtend scan (P3) |
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | 3 | Replace all-i64 fallback with hard error for kernels |
| `runtime/src/codegen/Passes/EcoToLLVMInternal.h` | 3 | Document `origFuncTypes` invariant |
| `runtime/src/codegen/EcoOps.cpp` | 4 | Hard-error in verifiers for missing kernel declarations |
| `design_docs/invariants.csv` | 5 | Add CGEN_057 |

If Phase 1 reveals compiler gaps (unlikely):

| File | Phase | Change |
|------|-------|--------|
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | 2 | Add missing `registerKernelCall` calls |
