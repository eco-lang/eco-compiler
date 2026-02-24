# Test Status Report

**Date:** 2026-02-24
**Tests run:** 818 | **Passed:** 818 | **Failed:** 0 | **XFAIL (skipped):** 13

**ALL TESTS PASSING.**

---

## Test Suite Breakdown

| Category | Tests | Description |
|----------|-------|-------------|
| C++ unit tests | ~200 | GC (minor/major), allocator, heap helpers, object sizing, constants |
| codegen/ | 218 | MLIR codegen lowering tests (7 XFAIL) |
| codegen-bf/ | 88 | BytesFusion codegen tests (6 XFAIL) |
| encode/ | 7 | Encoder integration tests |
| elm/ | 160 | Elm-to-MLIR E2E tests (compiler + runtime) |
| elm-bytes/ | 65 | Bytes.Encode/Decode E2E tests |
| elm-core/ | 36 | Core library E2E (Array, List, String, Dict, Debug, etc.) |
| elm-json/ | 11 | Json.Decode/Encode E2E tests |
| elm-regex/ | 5 | Regex E2E tests |
| elm-url/ | 3 | Url parsing E2E tests |
| elm-http/ | 2 | Http E2E tests |
| elm-time/ | 2 | Time E2E tests |

### XFAIL Tests (13 expected failures, skipped)

These are known-unimplemented features, not regressions:

- `codegen/crash_empty_message.mlir`
- `codegen/crash_with_construct.mlir`
- `codegen/free_noop.mlir`
- `codegen/global_uninitialized_read.mlir`
- `codegen/pap_arity_63.mlir`
- `codegen/refcount_noop.mlir`
- `codegen/reset_noop.mlir`
- `codegen-bf/bf_integration_length_prefix.mlir`
- `codegen-bf/bf_roundtrip_utf8.mlir`
- `codegen-bf/bf_write_utf8.mlir`
- `codegen-bf/bf_write_utf8_ascii.mlir`
- `codegen-bf/bf_write_utf8_empty.mlir`
- `codegen-bf/bf_write_utf8_multibyte.mlir`

---

## Previously Fixed Bugs (all resolved)

### Bug 1: `Debug.log` codegen emits undefined `%_v*` operand — FIXED

Fixed by adding `isVarDefinedInOps` helper and modifying `generateLet` in `Expr.elm` to detect
when `forceResultVar` would shadow an outer-scope variable. The fix generates a fresh variable
name instead of reusing the pattern `%_v*` name when it's already defined in the current ops.

**Files changed:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

---

### Bug 2: Self-referential `eco.papCreate` in `Array_foldr` — FIXED

Fixed with a two-part solution:
1. **Elm compiler** (`Expr.elm`): `hasSelfCapture` detects when a closure captures itself,
   `fixSelfCaptures` replaces self-references with a Unit placeholder and marks the closure
   with `self_capture_indices` attribute.
2. **C++ runtime** (`EcoToLLVMClosures.cpp`): `PapCreateOpLowering` backpatches the closure's
   own HPointer into the capture slots marked by `self_capture_indices`.

**Files changed:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`, `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

---

### Bug 3: `eco.call` result type mismatch — FIXED

Fixed with a two-part solution:
1. **C++ pass** (`EcoPAPSimplify.cpp`): Modified `SaturatedPapToCallPattern` to look up the
   callee function's actual return type and insert `eco.unbox` when it differs from the
   papExtend's expected type.
2. **C++ runner** (`EcoRunner.cpp`): Added `fixCallResultTypes()` walk that runs after MLIR
   parsing (with verification disabled) but before verification. It corrects eco.call result
   types to match callee declarations and inserts `eco.unbox`/`eco.box` conversion ops.

**Files changed:** `runtime/src/codegen/Passes/EcoPAPSimplify.cpp`, `runtime/src/codegen/EcoRunner.cpp`

---

### Bug 4: Char (i16) not widened for `String_foldr` callback — FIXED

Fixed with a multi-part solution:
1. **MLIR lowering** (`EcoToLLVMHeap.cpp`): `ListConstructOpLowering` now zero-extends i16
   head values to i64 before calling `eco_alloc_cons`.
2. **Closure wrapper** (`EcoToLLVMClosures.cpp`): `getOrCreateWrapper` now unboxes HPointer
   args for i16 target params (resolveHPtr + load from offset 8) instead of truncating.
3. **C++ kernels** (`StringExports.cpp`): `callFoldClosure`, `callCharToCharClosure`, and
   `callCharToBoolClosure` now box chars via `eco_alloc_char` before passing to callbacks.
4. **Elm-side closure calls** (`EcoToLLVMClosures.cpp`): `emitInlineClosureCall` and
   `PapExtendOpLowering` now box i16 args before storing in the args array.
5. **String.fromList** (`String.cpp`): Fixed `fromList` to handle both unboxed (raw i16 in
   cons head) and boxed (HPointer to ElmChar) char representations using `header.unboxed`.

**Files changed:** `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`, `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`, `elm-kernel-cpp/src/core/StringExports.cpp`, `elm-kernel-cpp/src/core/String.cpp`

---

### Bug 5: `Debug.toString` doesn't handle custom type constructor names — FIXED

`Debug.toString (Just 5)` printed `"Ctor0 5"` instead of `"Just 5"` because the untyped
`print_value` path doesn't have access to the type graph's constructor name table.

Fixed by adding a type_id parameter to `Elm_Kernel_Debug_toString`:
1. **Elm compiler** (`Expr.elm`): Added special case for `Debug.toString` that computes the
   type_id via `getOrCreateTypeIdForMonoType` and passes it as a second argument.
2. **C++ runtime** (`RuntimeExports.cpp`): Added `eco_value_to_string_typed(value, type_id)`
   that uses `print_typed_value()` when a valid type_id is available, falling back to
   the untyped `print_value()` for unknown types.
3. **C++ kernel** (`DebugExports.cpp`): Changed `Elm_Kernel_Debug_toString` signature to
   `(uint64_t value, int64_t type_id)` and call the typed variant.

**Files changed:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`, `runtime/src/allocator/RuntimeExports.cpp`, `runtime/src/allocator/RuntimeExports.h`, `elm-kernel-cpp/src/core/DebugExports.cpp`, `elm-kernel-cpp/src/KernelExports.h`

---

### Bug 6: Missing `eco_clone_array` symbol — FIXED (session 1)

The `eco_clone_array` C++ kernel function was not implemented. Added implementation for
Array.set operations that need to clone the array before modification.

---

### Bug 7: Closure wrapper boxing/unboxing convention — FIXED

The evaluator wrapper and C++ kernel closure-calling code had inconsistent boxing/unboxing
conventions, causing crashes and incorrect values when closures with typed parameters
(Int, Float, Char) were called from C++ kernel functions.

Fixed with a comprehensive multi-part solution establishing the convention that the evaluator
wrapper expects ALL args in the `void**` array as HPointer-encoded values:

1. **Closure wrapper** (`EcoToLLVMClosures.cpp`): `getOrCreateWrapper` uses `origFuncTypes` to
   unbox params from HPointer (resolve + load for Int/Float/Char, pass-through for !eco.value)
   and box results to HPointer (eco_alloc_int/float/char for primitives, IntToPtr for !eco.value).
2. **Inline closure call** (`EcoToLLVMClosures.cpp`): `emitInlineClosureCall` boxes new args
   based on original types and copies captures with unboxed bitmap boxing via scf.while/scf.if.
3. **C++ kernels** (`ListExports.cpp`, `JsArrayExports.cpp`, `StringExports.cpp`): Added
   `loadCapturedValues()` helpers that box unboxed captures based on the closure's unboxed
   bitmap bitfield before calling the evaluator.
4. **Runtime** (`RuntimeExports.cpp`): Fixed `eco_closure_call_saturated` and implemented
   `eco_apply_closure` (was a stub) with capture boxing.
5. **Unboxed bitmap fix**: Fixed all C++ `loadCapturedValues` to use `closure->unboxed`
   directly instead of `closure->unboxed >> 12`. The `unboxed` field is a C bitfield that
   already extracts bits 12-63 from the packed word — the `>> 12` was double-shifting,
   zeroing out the bitmap and preventing capture boxing.
6. **BytesExports offset boxing**: Fixed `Elm_Kernel_Bytes_decode` to box the initial offset
   `0` via `eco_alloc_int(0)` before passing to the decoder closure.

**Files changed:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`, `elm-kernel-cpp/src/core/ListExports.cpp`, `elm-kernel-cpp/src/core/JsArrayExports.cpp`, `elm-kernel-cpp/src/core/StringExports.cpp`, `runtime/src/allocator/RuntimeExports.cpp`, `elm-kernel-cpp/src/bytes/BytesExports.cpp`

---

### Bug 8: Kernel function origFuncTypes for papCreate-only references — FIXED

Kernel functions referenced only via `papCreate` (not directly called) had no `func.func`
declaration in the MLIR. Without the declaration, `getOrCreateWrapper` couldn't determine
parameter types and defaulted to pass-through, causing HPointer values to be passed as raw
integers to C++ functions expecting typed parameters (e.g., `int64_t offset` in Bytes read
functions). This caused SIGSEGV in all 8 elm-bytes integration tests and 2 elm-regex tests.

Fixed with a two-part solution:
1. **Runtime** (`EcoToLLVM.cpp`): Added papCreate/papExtend scan to infer kernel function
   parameter types from captured operand types and papExtend new arg types, instead of
   assuming all-i64.
2. **Elm compiler** (`Expr.elm`, `Types.elm`): Added `registerKernelCall` for kernel functions
   referenced via papCreate (not just direct calls), so `func.func` declarations with correct
   parameter types are emitted. Added `flattenFunctionType` helper to extract ABI param types
   from curried MonoType.

**Files changed:** `runtime/src/codegen/Passes/EcoToLLVM.cpp`, `compiler/src/Compiler/Generate/MLIR/Expr.elm`, `compiler/src/Compiler/Generate/MLIR/Types.elm`

---

## Historical Test Progression

| Session | Tests Run | Passed | Failed | Notes |
|---------|-----------|--------|--------|-------|
| Start | 815 | 810 | 5 | Bugs 1-5 identified |
| Session 1 end | 815 | 815 | 0 | Bugs 1-4, 6 fixed |
| Session 2 start | 818 | 805 | 13 | Closure wrapper regressions during fix |
| Session 2 end | 818 | 806 | 12 | Wrapper convention established |
| Session 3 start | 818 | 806 | 12 | Continued from session 2 |
| Session 3 mid | 818 | 809 | 9 | origFuncTypes scan + unboxed bitmap fix |
| Session 3 end | 818 | 818 | 0 | All bugs fixed |
