## USER
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

---

Some of these test fixes seem a little "messy". There is a danger of hacking in a fix in a later pass to correct an error in an earlier pass which may lead to more brittle code and a breakdown of a cleaner theory.

Look over this text fix summary and give your opinion on it.

## ASSISTANT
Based on your summary and (extrapolating) typical compiler/runtime design goals, the situation looks like this:

---

## 1. High‑level assessment

- You’ve made **real, nontrivial progress**: all tests passing across codegen, runtime, and Elm E2E is significant.
- The concern you’re feeling is valid: there are multiple fixes that look like they **patch invariants late** instead of enforcing them early and centrally. That’s the main smell.

I’d separate what you have into:

- Changes that **clarify a clean theory** and are fine.
- Changes that **implicitly admit “we don’t fully trust our invariants”** and should be treated as debt to pay down.

---

## 2. Changes that look conceptually sound

These are “sharpen the model” rather than “band‑aid”:

### Bug 1 – `Debug.log` / `forceResultVar` shadowing

- Localized change in `Expr.elm`; the fix matches the mental model: *don’t reuse names when they’d shadow existing SSA-ish vars*.
- This is good hygiene and close to the right abstraction level (the compiler front‑end / MLIR emitter).

### Bug 2 – Self‑referential `eco.papCreate`

- Detecting self‑captures (`hasSelfCapture`) and explicitly marking them via `self_capture_indices`, with a runtime backpatch, is actually a **standard solution** for self‑recursive closures in a heap‑allocated closure world.
- This is a “real feature” of your closure representation, not a hack, as long as:
  - self‑captures are treated as a first‑class concept,
  - the attribute and backpatch behavior are clearly specified as part of the closure ABI.

### Bug 5 – `Debug.toString` typed printing

- Passing a `type_id` from the compiler and using a typed printer in the runtime is exactly the right direction.
- The fact that `Debug.toString` gets a special case is not inherently bad: it’s a special function in Elm anyway.
- This is only problematic if the pattern spreads into many one‑off “intrinsics” with ad‑hoc special cases; for a single flagship intrinsic, it’s fine.

### Bug 8 – Kernel functions referenced only via `papCreate`

- Ensuring `func.func` declarations exist and have correct param types, and scanning papCreate/papExtend sites to infer ABI types, brings the IR **closer to reality**: verbs and their types are explicit.
- This is a constructive fix; it’s trying to make the IR match the real ABI rather than hiding mismatches.

Overall, these are fine and move the design toward a clearer theory.

---

## 3. Changes that smell like “layered band‑aids”

These are where your unease is most justified.

### 3.1 `eco.call` result type mismatch (Bug 3)

You have:

- `EcoPAPSimplify.cpp` modifying patterns and inserting `eco.unbox`, and
- `EcoRunner.cpp` running `fixCallResultTypes()` **after parsing but before verification** to:
  - correct `eco.call` result types to match callee declarations, and
  - insert `eco.unbox` / `eco.box`.

This is a classic “fix an early invariant late” pattern:

- There are now **two places** that are responsible for “making `eco.call` types sane”:
  - the compile‑time MLIR pass,
  - the runner’s post‑parse patcher.
- The runner is effectively saying: *we don’t trust the IR to be self‑consistent, so we’ll repair it just before verification*.

Long‑term, you want:

- Exactly **one stage** responsible for:
  - ensuring each `eco.call`’s operand and result types match the callee’s signature, and
  - inserting necessary conversions.
- The verifier should then only **check**, not fix.

Right now, this is a pragmatic fix to get tests passing; it’s also a clear piece of technical debt to plan to remove.

### 3.2 Boxing/unboxing and closure ABI (Bugs 4 & 7 especially)

You’ve clearly done the hard work of **settling on a convention**:

> The evaluator wrapper expects ALL args in the `void**` array as HPointer-encoded values

and then:

- `getOrCreateWrapper` unboxes from HPointer to typed params and boxes results back.
- C++ kernels (`ListExports.cpp`, `JsArrayExports.cpp`, `StringExports.cpp`) have `loadCapturedValues()` helpers boxing captured values based on `unboxed` bitmap.
- Runtime functions (`eco_closure_call_saturated`, `eco_apply_closure`) also perform capture boxing.
- Bytes kernel (`BytesExports.cpp`) explicitly boxes `0` via `eco_alloc_int(0)` before calling the decoder.

This is both the best and worst part:

- **Good**: you now have a reasonably well‑specified closure ABI: how arguments, captures, primitives, and `!eco.value` are represented and passed.
- **Worrying**: knowledge of that ABI is **duplicated across several passes and kernel implementations**, with subtle details (like the unboxed bitmap and previous `>> 12` bug) repeated.

That’s how you ended up with:

> Unboxed bitmap fix: `closure->unboxed` directly instead of `closure->unboxed >> 12`

which was a very small, very ABI‑specific bug with massive consequences.

The pattern here is:

- The theory exists (HPointer representation, unboxed bitmap, closure layout), but it’s *encoded procedurally* in a bunch of different places instead of in one authoritative abstraction.

### 3.3 Post‑hoc type/ABI inference

Bug 8’s runtime scan (inferring kernel param types from papCreate/papExtend usage) is clever but hints at a deeper issue:

- The compiler is the one that actually **knows** the Elm function type; the runtime pass is **reconstructing** a shadow of that knowledge from how things are used.
- That can drift over time: if the compiler changes its calling convention or type flattening, the inference pass can silently become wrong.

It’s not wrong to do this, but it’s an additional moving part to keep in sync, and it’s a classic “temporarily necessary but fragile” fix.

---

## 4. Risks if you leave it as‑is

If you don’t consolidate this work, over time you risk:

1. **Hard‑to‑debug regressions**  
   Small ABI changes (e.g., a new primitive, or a tweak to box/unbox rules) will require updates in:
   - MLIR lowering passes,
   - C++ kernel helpers,
   - the runner patcher,
   - and possibly new special‑case compiler logic.  
   Missing one will pass compilation but crash at runtime.

2. **Invariants that are only “eventually” true**  
   Example: “`eco.call` types match callee signatures” is currently *only guaranteed after* `fixCallResultTypes()` runs in the runner. That makes reasoning and tooling (e.g., analysis passes, verification) harder.

3. **Increased cognitive load**  
   New contributors (or you in six months) won’t know which part of the stack is “the place” to make a change. They’ll be tempted to apply another late‑stage fix rather than cleaning up earlier ones.

---

## 5. What I’d do next (cleanup roadmap)

Now that all tests are green, you’re in a good position to **refactor toward a cleaner theory** without flying blind. A concrete, staged plan:

### 5.1 Write down the “eco ABI” as a spec

Even a short text doc in your repo:

- How `!eco.value`, HPointer, and primitive types are represented.
- Closure layout:
  - what `unboxed` means,
  - how captures are stored,
  - when/how self‑captures are represented (`self_capture_indices`).
- What the evaluator wrapper promises: all args are HPointer; where boxing/unboxing happens.
- Invariants about `eco.call` and kernel calls.

This doesn’t change code; it just turns implicit knowledge into something you can align code to.

### 5.2 Designate single “owners” for key invariants

For each of these, pick **one layer** as canonical and make the others trust/verify, not fix:

1. **`eco.call` typing**
   - Owner: a specific MLIR pass (likely `EcoPAPSimplify` or a dedicated “EcoTypeNormalize” pass).
   - Runner: stop changing types; only verify and assert if they’re wrong.

2. **Boxing/unboxing of closure args and captures**
   - Owner: `EcoToLLVMClosures.cpp` + a small shared helper library (for C++ kernels) that does boxing/unboxing based on a single definition of the layout.
   - Kernel code: delegate to those helpers, avoid reimplementing bit‑twiddling.

3. **Kernel function type information**
   - Owner: the Elm compiler + MLIR module.  
     The runtime should eventually *not* need to infer types from papCreate/papExtend; it should read them from function declarations with confidence.

### 5.3 Centralize ABI helpers

Refactor toward:

- A small C++ header/implementation that exposes:
  - `box_int`, `box_float`, `box_char`, etc.
  - `unbox_int`, `unbox_char`, etc.
  - `load_captures(closure)` that understands `unboxed` and produces a uniform representation for kernels.
- A small MLIR utility (or clearly‑scoped helper functions) used by lowering passes to:
  - generate correct boxing/unboxing IR,
  - inspect closure types and unboxed bitmaps.

Goal: remove *hand‑coded* use of the same bitfield math and HPointer assumptions from scattered sites.

### 5.4 Systematize “intrinsics” like `Debug.toString`

Instead of one‑off compiler cases:

- Introduce a notion of **intrinsic functions** with a small, explicit table:
  - `Debug.toString` → needs `type_id` argument.
  - Potentially others in the future.
- Centralize the logic that:
  - looks up or creates type IDs,
  - extends argument lists and calls the right runtime support.

Then “special‑casing” isn’t ad‑hoc; it’s a known extension point.

### 5.5 Tighten verification

Once invariants have an owner:

- Add MLIR verification passes that assert:
  - `eco.call` signatures match callee types.
  - closure wrappers’ argument/return types are consistent with origFuncTypes.
  - no self‑captures without `self_capture_indices`, etc.
- Kill off runner‑side “repair” code once you trust the passes.

---

## 6. Overall opinion

Your worry is **accurate but fixable**:

- Some of these fixes *are* messy in the sense that they repair deeper issues downstream rather than fixing root invariants.
- But they also crystallized a lot of otherwise fuzzy design decisions: closure ABI, boxing conventions, kernel call semantics, typed debugging.

Given that:

- You’re in a **good position now**: all tests pass, and the “messy” areas are visible and well‑documented in your own notes.
- If you treat the runner patchers, ABI duplication, and type‑inference scans as **explicit debt items** and schedule cleanup, you can absolutely recover a clean theory.

If you like, next step we can pick **one** of these (e.g., removing `fixCallResultTypes()` by tightening the MLIR side) and sketch a concrete refactor sequence.

