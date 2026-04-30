# Plan: New Intrinsics To Keep Int/Float/Char Unboxed End-to-End

## Goal

Add MLIR intrinsics that bypass kernel calls for the highest‑volume box/unbox sites
identified in the boxing census. These intrinsics keep `Int` (i64), `Float` (f64),
and `Char` (i16) unboxed across the call boundary, eliminating both `eco.box`
churn and `eco.safepoint` ops attached to the corresponding kernel calls.

Three groups of new intrinsics:
1. **Char comparisons** (`Utils.equal/lt/...` over `Char`).
2. **`Char.toCode` / `Char.fromCode`** routed through existing `eco.char.toInt`/`eco.char.fromInt` ops.
3. **`String.fromNumber`** specialised at `Int -> String` and `Float -> String`.
4. **`JsArray.empty/singleton/push/slice/appendN`** parallel to existing
   `unsafeGet/unsafeSet/length` intrinsics.

Out of scope (explicitly): `Json.wrap`, `Scheduler.succeed`, and any List/PAP
boundary boxing sites.

## Current State (verified)

- `Intrinsics.elm` already defines `IntComparison`, `FloatComparison`,
  `ArrayGet`, `ArraySet`, `ArrayLength` — the new variants will mirror these.
- `kernelIntrinsic` currently dispatches on `Basics`, `Bitwise`, `Utils`,
  `JsArray`. Two new homes will be added: `Char` and `String`.
- `utilsIntrinsic` handles `Int`/`Float` comparisons; `Char` comparisons are
  not yet matched.
- `Ops.td` already defines:
  - `Eco_CharToIntOp` (`eco.char.toInt`, `i16 -> i64`) — line ~2397.
  - `Eco_CharFromIntOp` (`eco.char.fromInt`, `i64 -> i16`) — line ~2411.
  - `Eco_ArrayGetOp` / `Eco_ArraySetOp` / `Eco_ArrayLengthOp` — line ~787.
  - All `Eco_IntEqOp/NeOp/LtOp/...` and `Eco_FloatEqOp/...` ops.
- Lowerings for `CharToIntOp` already exist in `EcoToLLVMArith.cpp`. So the
  Char→Int conversion intrinsic only needs the **compiler-side** work to route
  `Char.toCode`/`Char.fromCode` through them.
- Char comparison ops, `string.from_int`, `string.from_float`, and the new
  `array.empty/singleton/push/slice/append_n` ops do **not** exist yet.
- C++ kernels `Elm_Kernel_String_fromNumber`, `Elm_Kernel_JsArray_empty/
  singleton/push/slice/appendN` exist and take all boxed `HPtr` arguments.

Implication: the design's repeated reference to `Mono.MArray` does not match the
codebase — there is no `MArray` constructor. Array element types are recovered
from `MCustom _ "Array" [elt]` (confirmed canonical name). The existing JsArray
intrinsic already side‑steps this by reading the element type from `resultType`
(for `unsafeGet`) or the value arg (for `unsafeSet`); we will follow the same
pattern rather than introduce `MArray`.

## Resolved Design Decisions

(From follow-up review with the user — these were the open questions in the
original draft of this plan.)

1. **Kernel `home` strings.** Use `"Char"` for `Char.toCode`/`Char.fromCode`
   and `"String"` for `String.fromNumber`. Both match the existing
   `kernelBackendAbiPolicy` mapping.
2. **Array MonoType encoding.** Match `MCustom _ "Array" [elt]`; there is no
   `Mono.MArray`.
3. **Op naming.** Stay with the existing camelCase: `eco.char.toInt`,
   `eco.char.fromInt`. Do **not** introduce `eco.char.to_int`/`from_int`
   variants.
4. **`eco.array.empty` element kind.** Do **not** bake an element-kind
   attribute into the op. The runtime ElmArray's storage kind only matters once
   the array is used by `eco.array.set` / `eco.array.push`, which already carry
   the element MLIR type via the Intrinsic's `elementMlirType`. Specialisation
   stays at the use sites.
5. **`singleton`/`push` lowering strategy.** Start with **Path B** — small C++
   helpers in `elm-kernel-cpp` that take unboxed primitives and reuse existing
   ElmArray code. Inline in EcoToLLVM later only if profiling justifies it.
6. **Scope.** `JsArray.initialize` and `initializeFromList` are explicitly
   **out of scope** for this round. They are higher-order APIs better
   addressed by loop‑based lowering in a follow-up pass.
7. **Char comparison signedness.** Use **unsigned** predicates (`ult`, `ule`,
   `ugt`, `uge`) on `i16`. Equality (`eq`/`ne`) is signedness‑agnostic.
   `Patterns.elm` uses `arith.cmpi "eq"` for Char pattern equality, which is
   compatible.

## Plan

### Step 1 — Add Char comparison ops in `runtime/src/codegen/Ops.td`

Add `Eco_CharEqOp`, `CharNeOp`, `CharLtOp`, `CharLeOp`, `CharGtOp`, `CharGeOp`
under the existing "Character Operations" section (after `Eco_CharFromIntOp`,
~line 2424). All are `[Pure]`, take `(Eco_Char, Eco_Char)`, return `Eco_Bool`
(i1). Assembly format mirrors `Eco_IntEqOp`. Use **unsigned** comparisons
because Elm `Char` is a Unicode code point (no negative values). For `eq`/`ne`
this is signedness-agnostic, so the choice only matters for `<`/`<=`/`>`/`>=`.

Op names: `eco.char.eq`, `eco.char.ne`, `eco.char.lt`, `eco.char.le`,
`eco.char.gt`, `eco.char.ge` — matching the existing `eco.int.*` /
`eco.float.*` naming style (and the existing `eco.char.toInt`).

### Step 2 — Add Char comparison lowering in `EcoToLLVMArith.cpp`

For each new op, add an `OpConversionPattern` parallel to the existing
`IntEqOpLowering` block (~line 600s in that file): emit `LLVM::ICmpOp` with
predicate `eq`, `ne`, `ult`, `ule`, `ugt`, `uge`. Append the new patterns to
the `populateEcoToLLVMArithPatterns` list (the same place where
`CharToIntOpLowering`/`CharFromIntOpLowering` are registered).

### Step 3 — Add `eco.string.from_int` / `eco.string.from_float` ops

Append to `Ops.td` after the existing String section. Both take a primitive
operand and return `Eco_Value`. Not marked `[Pure]` because they allocate.

### Step 4 — Add a runtime helper that takes unboxed numerics

The existing `Elm_Kernel_String_fromNumber(HPtr n)` requires a boxed argument.
Add two new exports in `elm-kernel-cpp/src/core/StringExports.cpp` (and declare
them in `KernelExports.h`):
```
HPtr elm_string_from_int(int64_t n);
HPtr elm_string_from_double(double f);
```
Internally they can box and call `String::fromNumber`, or route through the
existing `String::fromNumber` body once split for the two cases. Register
both symbols in `RuntimeSymbols.cpp` so the JIT can find them.

### Step 5 — Add lowering for the two new string ops

In `EcoToLLVM.cpp` (or `EcoToLLVMRuntime.cpp` — wherever runtime-call lowerings
already live; check existing pattern for `eco.string.literal`/`eco.box`), add
two `OpConversionPattern`s that emit a runtime `LLVM::CallOp` to
`elm_string_from_int` / `elm_string_from_double`. Result is `ptr addrspace(1)`
(the `!eco.value` lowering per `REP_LLVM_001`).

### Step 6 — Add new array ops in `Ops.td`

Append after `Eco_ArrayLengthOp` (~line 853): `Eco_ArrayEmptyOp` (no
operands, no attributes), `Eco_ArraySingletonOp`, `Eco_ArrayPushOp`,
`Eco_ArraySliceOp`, `Eco_ArrayAppendNOp`. All return `Eco_Value`.

- `eco.array.empty` carries **no** element-kind information at the op level.
  Element kind is bound when the array is first written via `eco.array.set` /
  `eco.array.push`, which already accept `Eco_AnyValue` and dispatch by the
  operand's MLIR type.
- `singleton` and `push` take `Eco_AnyValue` for the element (kind carried by
  operand MLIR type, same convention as `eco.array.set`).
- `slice` and `append_n` take only `Eco_Int` and `Eco_Value` operands; element
  kind is recovered from the input ElmArray's tag at runtime.

### Step 7 — Lower the new array ops in `EcoToLLVMHeap.cpp`

Add OpConversionPatterns parallel to `eco.array.set` (which already knows how
to write Int/Float/Char elements unboxed and wrap boxed pointers). For each:
- `array.empty` → call existing `Elm_Kernel_JsArray_empty()` and pass result
  through. The result has no element-kind binding yet — that's set on first
  store, mirroring the existing kernel behaviour. (Confirmed: no new attribute
  on the op.)
- `array.singleton` → call the typed `elm_array_singleton_<kind>` helper
  selected by the operand's MLIR type (Step 8).
- `array.push` → call `elm_array_push_<kind>` similarly.
- `array.slice` / `array.append_n` → call `elm_array_slice` /
  `elm_array_append_n` with unboxed indices.

Register patterns in the heap lowering's `populate*` function.

### Step 8 — Add unboxed‑accepting runtime helpers (Path B)

Decision: **Path B** — small C++ helpers that take unboxed primitives, reusing
existing ElmArray code. Easier to land first; we can inline in EcoToLLVM later
if profiling justifies it.

The existing `Elm_Kernel_JsArray_singleton/push` take `HPtr` for the element,
which forces boxing on the way in. Add typed exports in
`elm-kernel-cpp/src/core/JsArrayExports.cpp` (declared in `KernelExports.h`):

```
HPtr elm_array_singleton_int(int64_t v);
HPtr elm_array_singleton_float(double v);
HPtr elm_array_singleton_char(uint16_t v);
HPtr elm_array_singleton_box(HPtr v);

HPtr elm_array_push_int(int64_t v, HPtr arr);
HPtr elm_array_push_float(double v, HPtr arr);
HPtr elm_array_push_char(uint16_t v, HPtr arr);
HPtr elm_array_push_box(HPtr v, HPtr arr);
```

For `slice` and `append_n` the existing kernels already take `HPtr` for
indices — re-declare unboxed variants:
```
HPtr elm_array_slice(int64_t start, int64_t end, HPtr arr);
HPtr elm_array_append_n(int64_t n, HPtr lhs, HPtr rhs);
```

Each helper internally delegates to the existing implementation; this is just
an unboxed-arg trampoline. Register all symbols in `RuntimeSymbols.cpp`.

Note: the LLVM lowering in Step 7 picks which `singleton_*` / `push_*` helper
to call by inspecting the element-typed operand's MLIR type, the same way
`eco.array.set` already dispatches on element kind.

### Step 9 — Extend the `Intrinsic` ADT in `Intrinsics.elm`

Add variants:
```
| CharComparison { op : String }
| CharToInt
| CharFromInt
| StringFromInt
| StringFromFloat
| ArrayEmpty { elementMlirType : MlirType }
| ArraySingleton { elementMlirType : MlirType }
| ArrayPush { elementMlirType : MlirType }
| ArraySlice
| ArrayAppendN
```

Update `intrinsicResultMlirType` and `intrinsicOperandTypes` for each.
Operand types for `CharComparison`: `[ecoChar, ecoChar]`. For `CharToInt`:
`[ecoChar]` → `ecoInt`. For `CharFromInt`: `[ecoInt]` → `ecoChar`.
For `StringFromInt`: `[ecoInt]` → `ecoValue`. For `StringFromFloat`:
`[ecoFloat]` → `ecoValue`. For `ArrayEmpty`: `[]`. For `ArraySingleton`:
`[elementMlirType]`. For `ArrayPush`: `[ecoValue, elementMlirType]` (note Elm
arg order: `push value array`, but we will pass them in the order the call site
provides). For `ArraySlice`: `[ecoInt, ecoInt, ecoValue]`. For `ArrayAppendN`:
`[ecoInt, ecoValue, ecoValue]`.

Note on arg order: confirm exact Elm signature order against
`elm-kernel-cpp/src/core/JsArrayExports.cpp` (e.g., `push value array` vs
`push array value`) when wiring `argTypes` patterns in Step 11. The existing
`unsafeSet` intrinsic uses `[MInt, elt, _]` matching `unsafeSet index value
array`.

### Step 10 — Wire `kernelIntrinsic` for new homes

Extend the dispatch in `kernelIntrinsic`:
```
"Char"   -> charIntrinsic name argTypes resultType
"String" -> stringIntrinsic name argTypes resultType
```
Both home strings are confirmed against `kernelBackendAbiPolicy`. Also extend
`utilsIntrinsic` (Char comparisons) and `jsArrayIntrinsic` (new array ops).

### Step 11 — Implement helper matchers

- `charIntrinsic`: `("toCode", [MChar], MInt)` → `CharToInt`;
  `("fromCode", [MInt], MChar)` → `CharFromInt`.
- `stringIntrinsic`: `("fromNumber", [MInt], MString)` → `StringFromInt`;
  `("fromNumber", [MFloat], MString)` → `StringFromFloat`.
- `utilsIntrinsic`: append six `(name, [MChar, MChar])` → `CharComparison`
  cases mirroring the existing Int/Float ones.
- `jsArrayIntrinsic`: append cases for `empty/singleton/push/slice/appendN`
  using the `MCustom _ "Array" [elt]` extraction pattern (confirmed canonical
  name; there is no `Mono.MArray`).

For the array intrinsics, write a small helper:
```
arrayElementType : MonoType -> Maybe MonoType
arrayElementType (MCustom _ "Array" [elt]) = Just elt
arrayElementType _                         = Nothing
```
Use it to extract `elt`, then `Types.monoTypeToAbi elt` gives `elementMlirType`.

### Step 12 — Extend `generateIntrinsicOp`

Add cases for each new variant. New ops emitter:
- `CharComparison { op }` → `Ops.ecoBinaryOp ctx op resultVar (lhs, ecoChar) (rhs, ecoChar) I1`.
- `CharToInt` → `Ops.ecoUnaryOp ctx "eco.char.toInt" resultVar (operand, ecoChar) ecoInt`.
- `CharFromInt` → `Ops.ecoUnaryOp ctx "eco.char.fromInt" resultVar (operand, ecoInt) ecoChar`.
- `StringFromInt` / `StringFromFloat` → `Ops.ecoUnaryOp` to the new op names.
- `ArrayEmpty` → new `ecoNullaryOp` helper or use `mlirOp` builder directly.
- `ArraySingleton` / `ArrayPush` → element-typed ops. May need a small helper.
- `ArraySlice` / `ArrayAppendN` → ternary builders.

Add helper combinators in `Ops.elm` if they do not yet exist:
- `ecoNullaryOp`,
- `ecoTernaryOp`,
- `ecoBinaryOpHetero` (operands of differing types — `singleton`/`push` need
  this only if our existing `ecoBinaryOp` is homogeneous; check before adding).

### Step 13 — Tests

Add cases under `compiler/tests/SourceIR/KernelIntrinsicCases.elm` (already
exists) for:
- `Char.toCode`, `Char.fromCode`, six Char comparisons.
- `String.fromInt`, `String.fromFloat` (the public `String` API that internally
  routes to `String.fromNumber`).
- `Array.empty`, `Array.singleton`, `Array.push`, `Array.slice`, `Array.append`
  over `Array Int` and `Array Float`.

Each test should assert that the generated MLIR contains the expected
`eco.char.*` / `eco.string.*` / `eco.array.*` op and **does not** contain
`eco.call @Elm_Kernel_*` for that operation.

For the boxing‑census regression check, add a manual run of the same `box`
counter the design author measured. (Capture the baseline numbers in the PR
description; we don't need to gate on them in CI.)

### Step 14 — Build + run E2E tests

Per CLAUDE.md / memory:
```
cmake --build build --target full 2>&1 | tee /tmp/test_output.txt
```
Expected: full pass set (1143/1143 according to recent BBoP-era memory). If any
regression appears, check that the new op lowerings emit correct LLVM
(specifically that we did not pass an `i64` where a `ptr addrspace(1)` is
expected, or vice versa).

## Files To Touch

- `runtime/src/codegen/Ops.td` — add Char comparison, string-from-int/float,
  and array empty/singleton/push/slice/append_n ops.
- `runtime/src/codegen/Passes/EcoToLLVMArith.cpp` — Char comparison lowerings.
- `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` — array op lowerings.
- `runtime/src/codegen/Passes/EcoToLLVM.cpp` (or `EcoToLLVMRuntime.cpp`) —
  string‑from‑number lowerings.
- `runtime/src/codegen/RuntimeSymbols.cpp` — register new runtime helpers.
- `elm-kernel-cpp/src/core/StringExports.cpp` + `String.cpp` /  `String.hpp`
  + `KernelExports.h` — `elm_string_from_int` / `elm_string_from_double`.
- (Possibly) `elm-kernel-cpp/src/core/JsArrayExports.cpp` — typed singleton/push
  helpers if Path B chosen in Step 8.
- `compiler/src/Compiler/Generate/MLIR/Intrinsics.elm` — new `Intrinsic`
  variants, lookups, and emitters.
- `compiler/src/Compiler/Generate/MLIR/Ops.elm` — small helper combinators if
  needed.
- `compiler/tests/SourceIR/KernelIntrinsicCases.elm` — new cases.

## Risk / Invariants

- All new ops obey the existing representation rules: only `i64`/`f64`/`i16`
  unboxed; `Bool` stays `!eco.value` at ABI/heap (we don't touch Bool).
- `[Pure]` is correct for Char comparisons but **not** for string/array
  allocators (they alloc → may trigger GC, statepoints inserted by RS4GC at
  the LLVM call sites).
- New allocating ops do not need `GCRootCarrier`: they only consume primitive
  operands plus already-rooted `!eco.value` arguments. RS4GC sees the LLVM
  call and handles roots normally.
- `eco.safepoint` ops emitted today by `Expr.generateSaturatedCall` for kernel
  calls disappear automatically when the intrinsic path is taken — that's the
  whole point. No other pass should need updating.

## Remaining Implementation-Time Checks

These are minor things I'll verify at implementation time; none should block
the design:

1. **`String::fromNumber(void*)` formatting.** The existing kernel handles both
   Int and Float through one entry point. When we split into
   `elm_string_from_int(int64_t)` / `elm_string_from_double(double)`, preserve
   identical output formatting by routing each to the existing branch in
   `String::fromNumber` rather than reimplementing.

2. **`Array.push` arg order.** Elm signature is `push : a -> Array a -> Array a`.
   The intrinsic's `argTypes` pattern should be `[elt, MCustom _ "Array" [_]]`,
   matching Elm-source order at the kernel-call site. Confirm by inspecting
   how `unsafeSet` (which has 3 args) currently matches in `jsArrayIntrinsic`.

3. **MemoryEffects on allocating ops.** The new `eco.string.from_int/float`
   and `eco.array.empty/singleton/push/slice/append_n` ops should NOT be
   marked `[Pure]`. Check whether existing allocating ops (e.g.
   `eco.array.set`) declare a `MemoryEffects` trait; if so, copy it.
   Otherwise omit `[Pure]` and let LLVM's RS4GC handle statepoint insertion
   at the lowered call sites as usual.

---

All design questions are resolved. Plan is ready to implement on request.
