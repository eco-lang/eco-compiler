# Unboxed Primitive Return Values — Direct Kernels and Closures

## Goal

Make `Int` / `Float` / `Char` results of compiled function calls flow as MLIR
primitives (`i64` / `f64` / `i16`) end-to-end, both for:

- **A. Direct kernel calls** — the C kernel symbol returns the primitive
  directly; the call-site MLIR result is the primitive type; we only box at
  the use site if the caller demands `!eco.value`.

- **B. Closures / generic apply / segmentation_unknown** — closure calls whose
  Mono result type is primitive return the primitive without ever allocating
  an `ElmInt` / `ElmFloat` / `ElmChar` heap object. Boxed fallback remains
  available where types are imprecise.

## Status of the codebase (what is already done)

A surprising amount of the design doc is already implemented. Concretely:

- `KernelInstanceAbi` already carries `abiResultType` and
  `deriveKernelInstanceAbi` already sets it from
  `MlirTypes.monoTypeToAbi key.resultType` under `ElmDerived`
  (`compiler/src/Compiler/Monomorphize/KernelAbi.elm:544-587`).
- `ensurePrimitiveAbi` already validates both args and result against
  `MInt → ecoInt` / `MFloat → ecoFloat` / `MChar → ecoChar`
  (`KernelAbi.elm:830-900`).
- `REP_ABI_001` already covers both parameters and results
  (`design_docs/invariants.csv:9`).
- Direct kernel call codegen already uses `instanceAbi.abiResultType` as the
  MLIR call result type (`Compiler/Generate/MLIR/Expr.elm:3038-3046`).
- Many primitive-return kernels already return primitives in C++ today
  (`Basics_add_Int`, `Basics_idiv`, `Bitwise_*`, `Char_fromCode`,
  `Char_toCode`, `String_length`, etc. — see `KernelExports.h`).
- `Eco_AnyValue` is already `AnyTypeOf<[Eco_Value, Eco_Int, Eco_Float, Eco_Char, Eco_Bool]>`
  and `Eco_PapExtendOp` already declares its result as `Eco_AnyValue`
  (`runtime/src/codegen/Ops.td:134, 1187`). The dialect already permits
  primitive results — no TableGen changes needed.
- `ParamKind { PK_Boxed, PK_Int, PK_Float, PK_Char }` and `EvalParamLayout`
  already exist (`runtime/src/allocator/Heap.hpp:367-384`).
- `eco_apply_closure_typed` already accepts a typed `int64_t* typed_args`
  buffer with an `EvalParamLayout` for arg-side typing
  (`runtime/src/allocator/RuntimeExports.h:289-299`,
   `RuntimeExports.cpp:1092+`).
- `mlirTypeToParamKind` already exists
  (`runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:1132-1136`).

What is **not** yet done is the result-side: closures always return `HPtr`,
and a handful of kernels still box their primitive result in C++.

## Proposed approach

The plan splits along the same A/B axis as the design doc. Phase A is small
mop-up (audit + a few kernel C++ signatures). Phase B is the structural work
on the closure header and the runtime apply helper.

The chosen B-side ABI follows the design doc verbatim: keep the boxed
`EvalFunction` evaluator unchanged, add an optional `TypedEvalFunction`
out-param entrypoint, and add a new `eco_apply_closure_eval` helper that
selects between them.

---

## Phase A — Direct kernel primitive results

The Elm-side and MLIR-side machinery is already in place. The remaining
work is auditing and migrating the few kernels that still box primitive
results in C++.

### A1. Audit

Cross-reference monomorphized kernel result types against the C++
declarations in `elm-kernel-cpp/src/KernelExports.h`. Mechanical procedure:

1. Grep `KernelExports.h` for every `Elm_Kernel_*` declaration whose
   return type is `HPtr` and whose Elm signature names a primitive
   result. The match is small in practice: `Json/Time/Bytes/Url/Parser/
   Regex` overwhelmingly return containers, Records, Tasks, Maybe, etc.,
   not raw primitives.
2. For each candidate, check the matching C declaration. Any kernel
   whose Mono result is `MInt` / `MFloat` / `MChar` while the C symbol
   returns `HPtr` is a discrepancy.

Expected outcome: **`JsArray.length` is the only real discrepancy.**
`Elm_Kernel_JsArray_length` (`KernelExports.h:218`) returns `HPtr`
despite the Elm signature `JsArray a -> Int`. The MLIR call already
expects `i64` after `instanceAbi.abiResultType` derives from
`monoTypeToAbi MInt`, so this is currently a latent semantic mismatch
that survives because `HPtr` and `i64` are the same LLVM-level width.

Sanity-check pass: when migrating each kernel, also grep for `int64_t
Elm_Kernel_*`, `double Elm_Kernel_*`, `uint16_t Elm_Kernel_*` to confirm
the migrated signature is the only one of its kind for that name. No
hidden suffix variants.

### A2. Migrate kernel C++ signatures

For each discrepancy in A1:

1. Change the declaration in `KernelExports.h` to return the primitive
   (`int64_t` / `double` / `uint16_t`).
2. Change the implementation in the matching `*Exports.cpp` to return the
   raw primitive instead of allocating a boxed value.
3. If the Elm side also needs a per-instance suffix (e.g. element-typed
   variants), follow the existing `kernelInstanceSymbol` pattern in
   `KernelAbi.elm:597+`. Most candidates are not element-typed and need no
   suffix.

### A3. Tests for A

- **`compiler/tests/Compiler/Monomorphize/KernelAbiTest.elm`**: extend with
  cases asserting `abiResultType == ecoInt/ecoFloat/ecoChar` for the
  migrated kernels (e.g. `JsArray.length`).
- **MLIR shape test**: in `compiler/tests/TestLogic/Generate/CodeGen/`,
  add a fixture that calls a primitive-return kernel in a primitive
  consuming context and assert no `eco.box` follows the call. Also add a
  fixture in a polymorphic consuming context (e.g. result flows into
  `List.foldl` over `a`) and assert exactly one box op appears at the use
  site.
- **C++ unit tests**: extend `elm-kernel-cpp/tests/JsArrayExportsTest.cpp`
  (or equivalent) to call the migrated kernel directly and check the
  primitive result. No HPtr orchestration needed.

### A4. Boxing on use

Verify that downstream MLIR codegen correctly inserts `eco.box` (or
equivalent) when a primitive call result flows into an `!eco.value`-typed
context. The existing `boxToMatchSignatureTyped` and `coerceResultToType`
machinery should already cover this; A4 is verification, not new code.

---

## Phase B — Closure results

This is the structural piece. We extend `EvalParamLayout` (the only
header that needs to grow), keep the existing single `evaluator`
function pointer in `Closure` but compile it to its real result-type C
ABI, add a runtime helper that supports typed-result out-params, and
migrate generic-apply / segmentation_unknown lowerings.

**Closure does not grow.** Adding a second function pointer
(`typed_eval`) was rejected: ABI always returns primitives unboxed, so
there's no need for a "boxed-result entrypoint" sitting alongside an
"unboxed-result entrypoint". A single evaluator is enough; its real C
ABI matches the closure's Mono result type, and the runtime dispatches
based on `result_kind` read from the layout.

### B1. Extend `EvalParamLayout`

**File:** `runtime/src/allocator/Heap.hpp`

This is the **only** header whose size changes — it grows by 1 byte.

```cpp
struct EvalParamLayout {
    uint8_t num_params;
    uint8_t result_kind;  // NEW: 0=PK_Boxed, 1=PK_Int, 2=PK_Float, 3=PK_Char
    uint8_t kinds[];      // unchanged
};
```

Memory layout becomes `{ num_params: u8, result_kind: u8, kinds[num_params]: u8[] }`.
This struct is allocated as a tiny global per evaluator-shape and is
not on hot data paths. The `Closure` struct is **unchanged**.

The result kind is a per-closure-shape property (matches the evaluator's
real return type). All call-site layouts that target the same evaluator
must agree on `result_kind`. The frontend always knows the Mono result
type at the call site, so populating `result_kind` consistently is
straightforward.

### B2. Update layout builders / cache

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

`getOrCreateEvalLayout` (the helper that emits the layout global) gets
an additional `uint8_t resultKind` parameter. The function:

1. Includes `resultKind` in its cache key.
2. Emits the global with the `result_kind` byte at offset 1, followed
   by `num_params` and `kinds[]`.

Every existing caller of `getOrCreateEvalLayout` must be updated to
pass the call-site's known result kind. For sites that don't yet plumb
through a Mono result type, default to `PK_Boxed` — this preserves
current behaviour byte-for-byte (existing callers all expect a boxed
result).

There are **no new fields on the `Closure` struct**, so no allocator
changes and no stack-map / GC tracing changes are needed.

### B3. Evaluator wrapper has its real C ABI

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

The single evaluator wrapper (`getOrCreateWrapper` and its variants)
has its return type compiled to match the closure's Mono result type:

- `PK_Int`   → wrapper returns `i64`.
- `PK_Float` → wrapper returns `double`.
- `PK_Char`  → wrapper returns `i16`.
- `PK_Boxed` → wrapper returns `HPtr` (status quo).

Args still arrive via the typed `int64_t* typed_args` buffer (existing
convention). The wrapper unpacks each arg slot per its kind, calls the
underlying target function, and returns the result in the natural
register for its C ABI.

Implementation sketch:

1. Look up (or create) the wrapper for `(target, captureKinds,
   resultKind)`. Cache by tuple including `resultKind` — the same
   target compiled for two different result kinds is two distinct
   wrappers (this should not happen in practice, since a target's
   Mono result type is fixed, but the cache discipline keeps things
   consistent if it ever does).
2. Wrapper signature in MLIR:
   ```
   func.func @__closure_eval_<target>_<kindSuffix>(%args: !llvm.ptr) -> <T>
   ```
   where `<T> ∈ {i64, f64, i16, ptr addrspace(1)}` chosen by `resultKind`.
3. Body unpacks args (unchanged from today) and calls the underlying
   target function whose signature already matches `<T>` for its
   real-return Mono result.

No second function pointer; no separate "typed eval" wrapper. The
wrapper *is* the typed-result evaluator.

**Rationale.** Today the existing wrapper signature is uniformly
`void*(*)(void**)` (boxed-return). For primitive-result functions,
codegen currently emits a wrapper that boxes the primitive into an
`ElmInt`/`ElmFloat`/`ElmChar`. We are removing that boxing step from
the wrapper itself: the wrapper now returns the primitive natively.
The single-call-site that today consumes a boxed `HPtr` from the
wrapper (i.e. `eco_apply_closure_typed`) must move to the new helper
or read the primitive and box on the way out (see B5/B5b).

### B4. Plumb result kind from frontend to wrapper + layout

**Files:** `runtime/src/codegen/Ops.td`,
`compiler/src/Compiler/Generate/MLIR/Expr.elm`,
`runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

The Elm frontend knows the Mono function type at the point it emits
`papCreate` and at every call site. We surface that as an op attribute
that flows into both:
- The wrapper choice (B3) — the wrapper compiled for a given closure
  has its return ABI matching the result kind.
- The `EvalParamLayout` global (B2) — its `result_kind` byte equals
  the same value.

1. **Op attribute (TableGen).** Add an optional `_result_kind`
   attribute (`I8Attr`) to the closure-emitting and closure-applying
   op family — concretely `Eco_PapCreateOp`, `Eco_PapCreateGroupOp`,
   and `Eco_PapExtendOp`. Values: `0=PK_Boxed`, `1=PK_Int`,
   `2=PK_Float`, `3=PK_Char`. Absence ≡ `PK_Boxed`.

2. **Frontend (Expr.elm).** When emitting any of these ops, populate
   `_result_kind` from the Mono function-result type:
   - `MInt` → 1, `MFloat` → 2, `MChar` → 3
   - `MBool`, `MVar _ _`, container, custom, function → 0 (PK_Boxed).

3. **Lowering (papCreate / papCreateGroup).** Read `_result_kind` and:
   - Pass it to `getOrCreateWrapper(rt, target, resultKind)` (B3) so
     the emitted wrapper's return ABI matches.
   - Pass it to `getOrCreateEvalLayout(..., resultKind)` (B2) so the
     emitted layout global carries the same `result_kind`.
   - Store the wrapper pointer into `closure->evaluator` (existing
     field — no change to the Closure struct).

For polymorphic / boxed-only closures (e.g. closures whose result is a
type variable), the attribute is absent and the wrapper + layout are
emitted with `PK_Boxed`, matching today's behaviour byte-for-byte.

### B5. New runtime helper `eco_apply_closure_eval`

**File:** `runtime/src/allocator/RuntimeExports.{h,cpp}`

Add:

```cpp
void eco_apply_closure_eval(HPtr closure_hptr,
                            int64_t* typed_args,
                            uint32_t num_args,
                            const EvalParamLayout* args_layout,
                            void* result_slot,
                            uint8_t desired_kind);
```

The helper reads the closure's intrinsic result kind from
`args_layout->result_kind` (set by the frontend at this call site —
see B4). The closure header is unchanged; the kind lives in the layout.

Behaviour, where `K = args_layout->result_kind`:

1. **Saturated dispatch (matches K).** Call `closure->evaluator` with
   the typed-args buffer. The evaluator's real C ABI is determined by
   `K` (B3), so we cast its function pointer accordingly:
   - `K == PK_Int`:   `auto fn = reinterpret_cast<int64_t (*)(int64_t*)>(eval); int64_t r = fn(typed_args);`
   - `K == PK_Float`: `auto fn = reinterpret_cast<double (*)(int64_t*)>(eval); double r = fn(typed_args);`
   - `K == PK_Char`:  `auto fn = reinterpret_cast<uint16_t (*)(int64_t*)>(eval); uint16_t r = fn(typed_args);`
   - `K == PK_Boxed`: `auto fn = reinterpret_cast<HPtr (*)(int64_t*)>(eval); HPtr r = fn(typed_args);`

2. **Result delivery.**
   - If `desired_kind == K`: store `r` directly into `*result_slot`. No
     allocation.
   - If `K` is primitive and `desired_kind == PK_Boxed`: allocate the
     matching `ElmInt`/`ElmFloat`/`ElmChar`, store its `HPtr` into
     `*(HPtr*)result_slot`. (This is the only allocation site, and it
     only fires when a primitive-result closure is consumed by a boxed
     caller — exactly the case where boxing is unavoidable.)
   - If `K == PK_Boxed` and `desired_kind` is primitive: extract the
     primitive payload from the boxed result via
     `readElmIntPayload`/`readElmFloatPayload`/`readElmCharPayload`,
     store into the typed slot. No allocation.

3. **Under-saturated branch (generic apply).** If the closure is
   under-saturated, the helper extends the closure (returns a closure
   `HPtr`) and writes it into `*result_slot` as `HPtr`. By construction
   `desired_kind == PK_Boxed` here (see B7); assert otherwise.

The single function pointer in `Closure` (`evaluator`) is reinterpreted
based on `K`. There is no `typed_eval` second pointer.

### B5a. Extract `buildBoxedArgsFromTyped`

The existing arg-translation logic in `eco_apply_closure_typed` (which
builds a `void**` boxed-args buffer when needed) is **no longer
needed for primitive-result evaluators**: the new wrappers (B3) take
the typed-args buffer directly. However, fully-boxed closures still
exist (`K == PK_Boxed`), and their wrappers may legitimately want
boxed args.

Audit `eco_apply_closure_typed`'s body and decide:
- If the existing wrappers all already accept typed args (the typed-args
  refactor is complete), there is nothing to extract — both helpers
  pass `typed_args` directly to the evaluator.
- If some legacy wrappers still take `void**`, factor the arg
  re-boxing logic into a helper used by both code paths.

This step is bookkeeping; behaviour-preserving.

### B5b. `eco_apply_closure_typed` becomes a shim

Re-implement as a shim around the new helper:

```cpp
HPtr eco_apply_closure_typed(HPtr c, int64_t* a, uint32_t n,
                             const EvalParamLayout* layout) {
    HPtr out;
    eco_apply_closure_eval(c, a, n, layout, &out, PK_Boxed);
    return out;
}
```

This keeps every existing caller working unchanged. For primitive-result
closures the inner helper allocates an `ElmInt`/`ElmFloat`/`ElmChar` to
satisfy the boxed return — i.e. legacy callers still get the same
boxed value, just allocated by the helper instead of by the wrapper.

### B6. EcoToLLVM helper `emitClosureEvalCall`

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

Add an LLVM-emitting helper used by every closure-call lowering that
wants to honour primitive results:

```cpp
Value emitClosureEvalCall(Location loc,
                          Value closureHPtr,
                          ArrayRef<Value> typedArgs,
                          Value layoutPtr,
                          Type resultLLVMType,    // i64 / f64 / i16 / ptr
                          uint8_t desiredKind,
                          OpBuilder &builder);
```

Body:

1. `alloca` typed args buffer (`alloca [N x i64]`), store args.
2. `alloca` a result slot of the appropriate LLVM type.
3. Emit a call to `@eco_apply_closure_eval` with all six args.
4. `load` from the result slot at `resultLLVMType` and return.

### B7. Migrate `lowerGenericApply` and saturated `segmentation_unknown`

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

Both already build a typed args buffer + `EvalParamLayout`. Change them to:

1. Compute `desiredKind` from the op's MLIR result type (via
   `mlirTypeToParamKind`).
2. Replace the call to `getOrCreateApplyClosureTyped(...)` with a call to
   `emitClosureEvalCall(...)`.
3. Replace the op with the loaded primitive (or HPtr) value.

**Under-saturated generic apply is always boxed.** An under-saturated
generic apply produces a closure `HPtr`, never a primitive — well-typed
IR cannot have `Int`/`Float`/`Char` as the result type of an
under-saturated apply. So a call site that statically wants a primitive
result (`desired_kind != PK_Boxed`) only ever reaches the saturated
branch. Add an assert in the runtime helper: if the runtime takes the
under-saturated branch and `desired_kind != PK_Boxed`, that is a
compiler bug. Equivalently, the lowering can refuse to ask for a
primitive result on a generic-apply op whose IR result type is
`!eco.value` — the two should always agree.

### B8. Frontend op result type selection

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

When emitting `eco.papExtend` / segmentation_unknown / generic-apply ops,
choose the result MLIR type from the Mono result type via
`Types.monoTypeToAbi`. The dialect already accepts `Eco_AnyValue`, so no
verifier work is needed — only the Elm-side type-selection logic.

For polymorphic call sites (Mono result still a `MVar _ CEcoValue`), keep
`!eco.value` and `desired_kind = PK_Boxed`. For Bool, also keep
`!eco.value`: Bool is treated as boxed everywhere (no `PK_Bool`),
matching REP_ABI_001 / REP_HEAP_002.

### B9. Tests for B

- **IR shape test** (`compiler/tests/TestLogic/Generate/CodeGen/`):
  fixture like `List.map (\x -> x + 1) xs : List Int` and assert:
  - The wrapper emitted for `(\x -> x + 1)` has return type `i64` (not
    `!eco.value`).
  - The `EvalParamLayout` global emitted at the call site has
    `result_kind = 1` (PK_Int).
  - Generic-apply or segmentation_unknown ops at the call site have
    result type `i64`, not `!eco.value`.
  - After EcoToLLVM, the call lowers to `@eco_apply_closure_eval` with
    no `eco_alloc_int` between the apply and the result use.
- **Runtime alloc-count test** (new
  `runtime/test/allocator/EcoApplyClosureEvalTest.cpp`): construct a
  closure manually with an `int64_t (int64_t*)` evaluator and a layout
  whose `result_kind == PK_Int`. Call `eco_apply_closure_eval` with
  `desired_kind == PK_Int` and assert `Allocator::getCombinedStats()`
  unchanged. Then call again with `desired_kind == PK_Boxed` and assert
  exactly one `ElmInt` allocation occurred (the unavoidable boxing for
  a boxed caller). Verifies both the no-alloc primitive path and the
  on-demand boxing fallback.
- **Boxed-fallback test**: construct a `result_kind == PK_Boxed` closure
  whose evaluator allocates and returns an `ElmInt`. Call
  `eco_apply_closure_eval` with `desired_kind == PK_Int`; assert no
  *additional* allocation on the result-extraction side (the payload
  is read directly from the closure-allocated `ElmInt`).
- **Typed-args regression**: confirm existing `eco_apply_closure_typed`
  tests still pass after it becomes a shim around `eco_apply_closure_eval`.

---

## Cross-cutting concerns

### Invariants

- `REP_ABI_001` already covers results; no change required.
- `REP_BOUNDARY_001/002/003` apply unchanged: a primitive crossing into
  `!eco.value` still requires explicit boxing.
- **Layout-wrapper consistency.** For any closure, the wrapper stored
  in `closure->evaluator` must have a return-type C ABI matching
  `args_layout->result_kind` of every layout used to apply it. Since
  the wrapper and the layout are both populated from the same
  `_result_kind` op attribute, the frontend should never produce a
  mismatch; add a runtime debug assertion in `eco_apply_closure_eval`
  that checks the layout's `result_kind` is in `{0,1,2,3}`.
- **No "wrapper-internal allocation purely for args/results" rule.**
  User functions may legitimately allocate. The codegen invariant is
  that the *wrapper* generated by `getOrCreateWrapper` must not
  allocate solely to box a primitive return or to box typed args —
  for primitive-result closures, the wrapper returns the primitive
  natively. Enforce with IR tests (`CHECK-NOT` for `eco_alloc_int` /
  `_float` / `_char` inside primitive-result wrappers).

### Staging

The migration is staged so each step compiles and passes existing tests:

- B1 alone (`EvalParamLayout` grows by 1 byte, default `result_kind = 0`)
  is byte-for-byte equivalent to the old layout for all current callers.
- B2 alone (`getOrCreateEvalLayout` accepts a result-kind parameter,
  defaulting to 0) is a NOP — every caller still passes 0.
- B5+B5a+B5b alone (new helper + refactor `eco_apply_closure_typed` as
  a shim around it, all closures still `PK_Boxed`) is a pure NOP for
  callers — same observable behaviour, same wrapper signatures.
- B3+B4 are the bite: wrappers for primitive-result closures change
  return ABI from `HPtr` to `i64`/`f64`/`i16`. At this point
  `eco_apply_closure_eval` must already be in place (B5) so the legacy
  shim can box on the way out for any boxed caller that hasn't migrated
  yet. Land B5 before B3+B4.
- B6+B7+B8 consume the new ABI from MLIR call sites, eliminating the
  alloc on primitive consumers.

### Forbidden things

- No "fake HPtr that is actually an i64" anywhere. Every typed slot must
  be a real `i64*` / `f64*` / `i16*` of correct LLVM type.
- The boxed fallback in B5 must not allocate when `desired_kind ==
  PK_Boxed` and the closure is inherently boxed (`K == PK_Boxed`).
  Boxed result is just a pass-through.
- No second function pointer on `Closure`. The single `evaluator` slot
  is reinterpreted by the runtime according to `args_layout->result_kind`.

---

## Summary of files touched

### Compiler (Elm)

- `compiler/src/Compiler/Generate/MLIR/Expr.elm` — choose Eco op result
  type from Mono result for generic-apply / segmentation_unknown sites
  (B8). Verify Phase A4 boxing-on-use.
- `compiler/src/Compiler/Monomorphize/KernelAbi.elm` — already done. No
  edits expected unless the audit (A1) reveals missing `kernelInstanceSymbol`
  arms.

### Runtime / codegen passes

- `runtime/src/allocator/Heap.hpp` — extend `EvalParamLayout` with a
  `result_kind` byte (B1). **No `Closure` struct changes.**
- `runtime/src/allocator/RuntimeExports.{h,cpp}` — add
  `eco_apply_closure_eval` (B5), audit/factor `buildBoxedArgsFromTyped`
  if still needed (B5a), retarget `eco_apply_closure_typed` as a shim
  (B5b). **No new closure-field initialisation needed in
  `eco_alloc_closure*`.**
- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` —
  parameterise `getOrCreateWrapper` on `resultKind` so wrappers have
  the matching return ABI (B3); update `getOrCreateEvalLayout` to
  emit `result_kind` (B2); plumb `_result_kind` op attribute through
  `papCreate`/`papCreateGroup`/`papExtend` lowering (B4);
  `emitClosureEvalCall` (B6); migrate `lowerGenericApply` + saturated
  `segmentation_unknown` (B7).
- `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` — register
  `eco_apply_closure_eval` symbol declaration alongside
  `eco_apply_closure_typed`.
- `runtime/src/codegen/RuntimeSymbols.cpp` — JIT symbol map entry.
- `runtime/src/codegen/Ops.td` — add `_result_kind` optional `I8Attr`
  on `Eco_PapCreateOp`, `Eco_PapCreateGroupOp`, `Eco_PapExtendOp` (B4).

### Eco kernel C++

- `elm-kernel-cpp/src/KernelExports.h` and matching `*Exports.cpp` —
  migrate any remaining primitive-return kernels found in audit A1
  (e.g. `JsArray.length`).

### Tests

- `compiler/tests/Compiler/Monomorphize/KernelAbiTest.elm` — extend (A3).
- `compiler/tests/TestLogic/Generate/CodeGen/` — add primitive-result
  shape tests for direct kernels (A3) and closures (B9).
- `runtime/test/allocator/EcoApplyClosureEvalTest.cpp` — new (B9).
- `elm-kernel-cpp/tests/JsArrayExportsTest.cpp` — extend with
  primitive-return assertions for migrated kernels (A3).

---

## Resolutions (previously open questions)

All eight open questions were resolved before implementation. The
decisions are folded into the body above; this section preserves the
rationale for future reference.

1. **Mono result type at `papCreate` time** — pass via a dedicated
   `_result_kind` attribute on the op (`PK_*`). The Elm frontend has the
   Mono function type in hand, so reading from the target's MLIR/LLVM
   signature would be brittle once types are erased or the target is a
   kernel. See B4.

2. **Header growth** — `Closure` does **not** grow at all. Only
   `EvalParamLayout` grows, by 1 byte, to carry `result_kind`. We
   reject the earlier "+16 bytes on Closure" plan: there is no need for
   a second function pointer (`typed_eval`) when ABI always returns
   primitives unboxed. A single `evaluator` whose real C ABI matches
   the closure's result kind, plus a `result_kind` byte on the layout,
   is enough. See B1.

3. **Under-saturated generic apply with primitive result** — impossible
   in well-typed IR. Under-saturated apply produces a closure `HPtr`,
   not a primitive. Lowering only asks for a primitive result on an op
   whose result type is primitive, which is by construction saturated.
   Add an assert in the runtime helper. See B7.

4. **Phase A audit scope** — likely only `JsArray.length`. Mechanical
   grep over `KernelExports.h` for primitive-Elm-result kernels declared
   as `HPtr`. `Json/Time/Bytes/Url/Parser/Regex` overwhelmingly return
   containers, Records, Tasks, etc. See A1.

5. **Wrapper allocation-freeness** — not a global runtime invariant
   (user evaluators may legitimately allocate). Instead, a codegen-only
   invariant: the wrapper produced by `getOrCreateWrapper` and the
   apply-helper plumbing do not allocate purely to convert args or
   results. The only allocation site on the apply path is the
   on-demand "primitive-result closure called by boxed caller" boxing
   inside `eco_apply_closure_eval`. Enforced via IR tests, not runtime
   contracts. See "Invariants" above.

6. **Other callers of `eco_apply_closure_typed`** — current grep shows
   only `RuntimeSymbols.cpp` and `EcoToLLVMRuntime.cpp`. Re-grep before
   B5b. If surprise callers exist, either migrate them to the new API or
   leave them on the boxed shim with a comment. See B5b.

7. **GC / stack-map impact** — none. The `Closure` struct doesn't
   change, so GC tracing, stack maps, `offsetof(Closure, values)`, and
   hard-coded closure-header offsets are all unaffected. The only
   header that changes is `EvalParamLayout`, which is a tiny global
   not touched by GC. See B1.

8. **Bool result kind** — Bool stays always boxed; no `PK_Bool`. Bool
   results are `!eco.value` everywhere, matching REP_ABI_001 /
   REP_HEAP_002. See B8.

---

## Phase C — C++ kernel callers honour the typed-result ABI

### Why this phase exists

Phases A + B cover MLIR-emitted call sites end-to-end, but a large
population of closure invocations live on the **C++ side**: Elm-core
kernels (`List`, `JsArray`, `String`, `Bytes`), effect managers (`Http`,
`Time`, `Json`, `Regex`, `Parser`), and the platform runtime
(`Scheduler`, `PlatformRuntime`). They all reach the closure's
`evaluator` field through one of two legacy entries:

- `eco_apply_closure(closure, uint64_t* args, n)` — boxed-args legacy
  shim. Forwards to `eco_apply_closure_typed` with an all-`PK_Boxed`
  layout pulled from the static `kAllBoxedLayoutsHolder` cache. The
  layout's `result_kind` byte is **always 0** in that cache.
- `eco_closure_call_saturated(closure, uint64_t* args, n, layout)` —
  saturated path used directly by core `*_arity_N` shims. The kernels
  in `core/ListExports.cpp`, `JsArrayExports.cpp`, `StringExports.cpp`,
  and `BytesExports.cpp` pass `layout=nullptr`, which the helper treats
  as all-`PK_Boxed` with `result_kind = 0`.

Both entries route into `eco_apply_closure_eval`, which dispatches the
saturated branch by reinterpreting `closure->evaluator` per
`layout->result_kind`. **If the wrapper actually returns `i64` / `f64`
/ `i16` (because the closure has primitive K) but the kernel's layout
claims `result_kind = 0`, the runtime mis-casts the return word.** On
x86-64 a `void*` and an `int64_t` happen to share the same return
register, so the bits flow through, but they are interpreted as an
HPointer encoding (heap address bits 0..39 + tag) rather than the
intended primitive value. A test like `List.foldl (\\x acc -> x + acc)
0 [1..5]` then computes `0` instead of `15`, because `eco_alloc_int`'s
HPtr encoding is read back as if it were the integer.

The C++-kernel callers are precisely the population that needs to honour
the new ABI. Phase C migrates them; Phase D removes the K=0 gate
introduced in the first implementation cut.

### C0. Audit — every C++ → Elm closure-invocation site

Source-of-truth listing. Update this list before implementation if any
new sites have appeared.

#### `eco_apply_closure(...)` callers (boxed-args legacy)

| Path | Line | Closure called | Closure return type |
|------|-----:|----------------|---------------------|
| `elm-kernel-cpp/src/parser/ParserExports.cpp` | 132 | user parser body callback | parser-result record (boxed) |
| `elm-kernel-cpp/src/regex/RegexExports.cpp` | 354 | `Regex.replace` user transformer | `String` (boxed) |
| `elm-kernel-cpp/src/http/HttpEffectManager.cpp` | 74, 145 | `Cmd` mapper, subscription tagger | `msg` (boxed) |
| `elm-kernel-cpp/src/http/HttpExports.cpp` | 258, 346, 373, 468, 487 | resume continuations, `expect` handlers, mappers | `Task` / `msg` (boxed) |
| `elm-kernel-cpp/src/time/TimeExports.cpp` | 196 | posix → user-domain conversion | user `posix` value (boxed) |
| `elm-kernel-cpp/src/time/TimeEffectManager.cpp` | 186, 352, 359 | subscription mapper / tagger | `msg` (boxed) |
| `elm-kernel-cpp/src/json/JsonExports.cpp` | 1056, 1103, 1134, 1194, 1691 | `Decoder.map` / `Decoder.andThen` body, `Encode.encode` callback | decoder result / encoded value (boxed) |
| `runtime/src/platform/Scheduler.cpp` | 159, 169, 182 | `callClosure1/2/4` for scheduler-internal callbacks | `Task` (boxed) |
| `runtime/src/platform/PlatformRuntime.cpp` | 156 | `main` function thunk | `Cmd` / `Program` (boxed) |

Today every closure on this list returns a boxed type (`Task`, `Cmd`,
`msg`, `String`, decoder result, etc.), so naively migrating to
`eco_apply_closure_eval` with `desired_kind = PK_Boxed` and
`layout->result_kind = 0` is correct *for these specific call sites*.
The migration's value here is **uniformity** and **future-proofing**:
once the wrapper return ABI is allowed to be primitive (Phase D), an
audit of "which callers might one day target a primitive-result
closure?" must be a no-op because every site already routes through
`eco_apply_closure_eval` with a layout whose `result_kind` was read
from the closure header.

#### `eco_closure_call_saturated(...)` callers (saturated path)

| Path | Line | Closure called | Closure return type |
|------|-----:|----------------|---------------------|
| `elm-kernel-cpp/src/core/ListExports.cpp` | 26, 31, 36, 42, 48 | user fn passed to `List.foldl/foldr/map/indexedMap/...` (arity 1..5) | **arbitrary** (`b` in `foldl : (a -> b -> b) -> b -> List a -> b`) |
| `elm-kernel-cpp/src/core/JsArrayExports.cpp` | 42, 49, 86, 93 | `JsArray.foldl/foldr/map/indexedMap` callback | **arbitrary** |
| `elm-kernel-cpp/src/core/StringExports.cpp` | 187, 202, 215 | `String.foldl/foldr/map` callback | **arbitrary** for `foldl/foldr`; `Char` for `map` (primitive) |
| `elm-kernel-cpp/src/bytes/BytesExports.cpp` | 400 | `Decode.succeed`/`Decode.map` decoder body | decoder result (boxed) |

These are the **risky** ones. `List.foldl`, `JsArray.foldl`, etc. are
polymorphic in their accumulator type. A user invocation like
`List.foldl (\\x acc -> x + acc) 0 [1..5]` produces a closure whose
wrapper return is `i64`. After Phase D the kernel's
`eco_closure_call_saturated(... , layout=nullptr)` mis-casts that
return — reproducing exactly the bug the gate currently hides.

`String.map` is interesting: its callback returns `Char` (`i16`), so
*every* call site is K = `PK_Char`. The kernel must propagate this
into the layout it builds.

#### Direct C++-implemented evaluators (closure body is C++ code)

Not closure *invocations*, but C++ functions that are stored *as* a
closure's `evaluator` pointer. They implement the wrapper protocol
(`void *(void *[])`) themselves. Their return ABI must agree with the
closure header's `result_kind`.

| Path | Line | Function | Return type |
|------|-----:|----------|-------------|
| `elm-kernel-cpp/src/core/ProcessExports.cpp` | 56 | `sleepBindingEvaluator` | `Task ()` (boxed) |
| `elm-kernel-cpp/src/time/TimeExports.cpp` | 231 | `timeNowBindingEvaluator` | `Task posix` (boxed) |
| `elm-kernel-cpp/src/http/HttpExports.cpp` | 594 | `bindingEval` | `Task` (boxed) |
| `eco-kernel-cpp/src/eco/MVar.cpp` | 242, 264, 286 | `readBindingEvaluator`, `takeBindingEvaluator`, `putBindingEvaluator` | `Task` (boxed) |

All of these return boxed `Task` HPointers. They stay K = `PK_Boxed`
forever. Phase C registers them with the new closure-K convention by
calling `eco_alloc_closure` (or its successor) with `PK_Boxed`
explicitly, so the closure header's `result_kind` byte is set
correctly.

### C1. Decide where K lives so kernels can read it

To make the C++ kernels K-aware without duplicating per-arity / per-K
trampolines, we need a way for the kernel to **discover the closure's
K at invocation time**. There are three viable options:

1. **Closure header carries K (chosen).** Steal 2 bits from the
   existing `unboxed:52` field, leaving 50 bits = 25 typed slots
   (down from 26). Re-pack the header as
   `n_values:6 | max_values:6 | result_kind:2 | unboxed:50`. The
   total bit-packed payload stays at 64 bits; `Closure` does not
   grow, GC tracing offsets are unchanged.
2. Per-instance kernel variants — `Elm_Kernel_List_foldl_acc_Int`,
   `_acc_Float`, `_acc_Char`, `_acc_Boxed`. Cleanest typing but
   exponential blowup against arity × accumulator-kind matrices.
3. Side table mapping closure HPtr → K. GC-fragile and requires
   per-allocation bookkeeping.

The plan adopts option (1). This **revises** the original Phase B
"Closure does not grow" decision: the field count and struct size are
unchanged, but two bits of `unboxed` are reassigned. The frontend's
2-bit-per-slot capacity drops from 26 to 25 captures; this is well
inside today's typical capture counts (the `Compiler/Generate/MLIR/
Functions.elm` tests assert ≤ 16 captures everywhere).

### C2. Update `Closure` struct + allocator

**File:** `runtime/src/allocator/Heap.hpp`

Change the bit-packed payload:

```cpp
typedef struct {
    Header header;
    u64 n_values   : 6;     // 0-63
    u64 max_values : 6;     // 0-63
    u64 result_kind: 2;     // ParamKind: 0=Boxed, 1=Int, 2=Float, 3=Char
    u64 unboxed    : 50;    // 25 typed slots × 2 bits each
    EvalFunction evaluator;
    Unboxable values[];
} Closure;
```

**File:** `runtime/src/allocator/RuntimeExports.{h,cpp}`

`eco_alloc_closure(void* func_ptr, uint32_t num_captures)` gains an
overload (or a new entry) that also takes `uint8_t result_kind`:

```cpp
HPtr eco_alloc_closure_k(void* func_ptr, uint32_t num_captures,
                         uint8_t result_kind);
```

The legacy `eco_alloc_closure` forwards with `result_kind = 0` so
existing C++ kernel sites (Process, Time, MVar, Http binding evaluators)
that all return boxed Tasks keep working byte-for-byte.

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

`PapCreateOpLowering` and `PapCreateGroupOpLowering` switch from
`eco_alloc_closure(funcPtr, arity)` to `eco_alloc_closure_k(funcPtr,
arity, op._result_kind)`. The op attribute is already populated by
Phase B4.

**File:** `runtime/src/allocator/RuntimeExports.cpp`

`eco_pap_extend` already copies the metadata from `old_closure` into
`new_closure`. Add `new_closure->result_kind = old_closure->result_kind`
to that copy block. Same for `eco_alloc_closure_group_slow`.

**Bitmap derivation.** `unboxed` is now 50 bits = 25 slots. Audit:

- `compiler/src/Compiler/Generate/MLIR/Functions.elm` — capture count
  cap; bump tests if any approach 25.
- `runtime/src/allocator/RuntimeExports.cpp` — re-validate the
  `pointerMaskFromKindBitmap` helper against 50-bit input. The mask
  derivation is independent of bitmap width so should be unaffected.
- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` —
  `deriveAllParamKindsBitmap` uses `arity * 2` shifts; cap the loop
  at 25 instead of 26.

### C3. Migrate `eco_closure_call_saturated`

**File:** `runtime/src/allocator/RuntimeExports.cpp`

The `K = layout ? layout->result_kind : 0` hack added in the first
implementation cut becomes:

```cpp
uint8_t K = closure->result_kind;
```

The function reads K **from the closure header**, not the layout. The
caller no longer needs to construct a typed-result layout — the legacy
`layout=nullptr` path is sufficient because the result-kind information
now lives on the closure itself.

Once K comes from the closure, every C++ kernel that calls
`eco_closure_call_saturated(..., /*layout=*/nullptr)` automatically
dispatches the right cast on the wrapper. This eliminates the
mis-cast risk for **all** of the Section C0 saturated-path callers
without touching their source.

### C4. Migrate `eco_apply_closure` (legacy boxed-args entry)

**File:** `runtime/src/allocator/RuntimeExports.cpp`

The legacy `eco_apply_closure` shim builds an all-`PK_Boxed` layout
from `kAllBoxedLayoutsHolder` and forwards to
`eco_apply_closure_typed`. Today the cache's `result_kind` byte is
always 0; flip this to **read K from the closure** before forwarding:

```cpp
extern "C" HPtr eco_apply_closure(HPtr closure_hptr, uint64_t* args,
                                  uint32_t num_args) {
    void* closure_ptr = hpointerToPtr(closure_hptr.toBits());
    uint8_t K = closure_ptr ? static_cast<Closure*>(closure_ptr)->result_kind : 0;
    const EvalParamLayout* layout =
        (num_args == 0) ? nullptr : getAllBoxedLayoutForK(num_args, K);
    return eco_apply_closure_typed(closure_hptr,
                                   reinterpret_cast<int64_t*>(args),
                                   num_args, layout);
}
```

`getAllBoxedLayoutForK` indexes a 4-row × 64-column compile-time table
of layouts. Each row sets `result_kind` to the row's K; each column
has the matching `num_params`. All kinds bytes are zero (boxed args).

After this change, every C++ caller of `eco_apply_closure` — Parser,
Regex, Http, Time, Json, Scheduler, PlatformRuntime — automatically
dispatches the correct wrapper cast based on the closure's actual K.
None of those source files need editing.

### C5. Migrate `eco_apply_segmentation_unknown`

**File:** `runtime/src/allocator/RuntimeExports.cpp`

`eco_apply_segmentation_unknown` already takes a typed `EvalParamLayout*`
from the caller. The frontend (B7) passes K = 0 today. Once K is
available on the closure header we can stop relying on the caller and
read it directly:

```cpp
uint8_t K = closure->result_kind;
// override args_layout->result_kind with K when forwarding
```

Effect: the saturated-branch forwarding to `eco_apply_closure_typed`
inside this helper now sees the right K regardless of what the call
site emitted.

### C6. Update direct C++-evaluator allocation sites

For each of the C++-implemented evaluators in C0's third table:

- `elm-kernel-cpp/src/core/ProcessExports.cpp:56` (`sleepBindingEvaluator`)
- `elm-kernel-cpp/src/time/TimeExports.cpp:231` (`timeNowBindingEvaluator`)
- `elm-kernel-cpp/src/http/HttpExports.cpp:594` (`bindingEval`)
- `eco-kernel-cpp/src/eco/MVar.cpp:242, 264, 286` (`{read,take,put}BindingEvaluator`)

Replace `eco_alloc_closure(reinterpret_cast<EvalFunction>(eval), arity)`
with `eco_alloc_closure_k(reinterpret_cast<EvalFunction>(eval), arity,
PK_Boxed)`. All of these return `Task` HPointers and keep K = 0.

This step is bookkeeping; without it the legacy path in C2's allocator
forwarder still gives the right K=0, so behaviour is preserved. But
making the intent explicit at the call site avoids future drift if
one of these C++ evaluators is ever changed to return a primitive.

### C7. Tests for Phase C

- **Allocation regression test** (`runtime/test/allocator/EcoApplyClosureEvalTest.cpp`,
  shared with B9): construct a closure with `result_kind = PK_Int`
  and a fast-path evaluator that returns `int64_t`. Invoke via the
  legacy `eco_apply_closure(c, args, n)` entry; assert the helper
  returns the boxed value (allocates exactly one `ElmInt`) AND that
  the boxed value's payload reads back as the original int.
- **`eco_closure_call_saturated` typed test**: same closure, invoke via
  `eco_closure_call_saturated(c, args, n, /*layout=*/nullptr)`;
  assert the returned HPtr is a freshly allocated `ElmInt` with the
  right payload.
- **End-to-end Elm tests**: `List.foldl (\\x acc -> x + acc) 0 [1..5]
  == 15`, `List.map (\\x -> x * 2) [1,2,3] == [2,4,6]`, `String.map
  Char.toUpper "abc" == "ABC"`. These exist already and will fail
  loudly if Phase C/D is wrong.
- **Capture-count regression**: `compiler/tests/TestLogic/Generate/CodeGen/`
  add a fixture with 25 captures (the new ceiling) and one with 26
  captures (now must overflow into boxed slot kinds). The latter is
  expected to either fail compilation with a clear error or fall
  back to PK_Boxed for the overflow slots — pick one and document.

### C8. Staging within Phase C

C2 + C3 + C4 + C5 must land together. The closure header `result_kind`
field is read by all four entry points, and any one of them reading
`closure->result_kind` while the field is uninitialised is undefined
behaviour. The struct change (C2) must initialise the field on every
`eco_alloc_closure*` path before any reader (C3/C4/C5) runs. Order:

1. C2 first — change the struct, change the allocator. All allocation
   paths now initialise `result_kind = 0` (default).
2. C3, C4, C5 in any order — readers come online. With every closure
   carrying `result_kind = 0` they all behave identically to today.
3. C6 — explicit-K allocation sites updated. Still a NOP because they
   pass K = 0 anyway.

At the end of Phase C the system is **functionally identical** to
today (every closure has K = 0), but every closure-invocation path is
now K-aware. Phase D then flips the lever.

---

## Phase D — Turn on the optimization

Phase D is intentionally minimal: revert each of the K = 0 forcings
introduced in the first implementation cut.

### D1. Restore `getOrCreateWrapper` resultKind handling

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

Delete the `uint8_t resultKind = 0;` override at the top of the
function. The wrapper now returns `i64` / `f64` / `i16` / `ptr` per
the caller's `resultKind` argument (set from the op's `_result_kind`
attribute in B3 / B4).

Restore the wrapper-result handling that was added in B3 (the
`if (resultKind != 0) { /* primitive return */ } else { /* legacy
boxing path */ }` switch is already in place; it was simply
unreachable because `resultKind` was forced to 0).

### D2. Restore layout `result_kind` propagation in MLIR-emitted call sites

**File:** `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

In `lowerSegmentationUnknown`, `lowerGenericApply`, and the
`emitInlineClosureCall` helper, replace the `uint8_t layoutResultKind
= 0;` overrides with reads of the op's `_result_kind` attribute
(which Phase B4 already populates):

```cpp
uint8_t layoutResultKind = static_cast<uint8_t>(op.get_resultKind());
```

In `emitInlineClosureCall`, restore the read of
`safeOp->getAttrOfType<IntegerAttr>("_result_kind")` that was deleted
during the gating.

### D3. Stop populating layout `result_kind` from the op attribute (optional cleanup)

After Phase C, `args_layout->result_kind` is **redundant** with
`closure->result_kind`. The runtime helper now reads K from the closure
header, so the layout's byte is not consulted on the saturated path
(though the under-saturated and over-saturated paths still trust it
for sub-layout construction).

**Decision point:** keep the layout byte for future flexibility, or
remove it.

- **Keep**: matches the Phase B design exactly; layout K is a hint
  for sub-layout chains in over-saturated apply. No code change.
- **Remove**: shrink `EvalParamLayout` back to `{ num_params, kinds[] }`,
  rewrite the global emitter, simplify the runtime helper. Saves
  one byte per layout global (negligible) but removes a redundant
  source of truth.

The plan recommends **keep** for now: removing the layout byte is a
follow-up cleanup that doesn't affect correctness. The runtime debug
assertion `assert(layout->result_kind == closure->result_kind)`
guards against drift.

### D4. Tests for Phase D

The existing tests from B9 + C7 are sufficient. Run:

- E2E suite (`cmake --build build --target full`).
- Stress suite.
- IR shape tests assert `eco_alloc_int` / `_float` / `_char` does
  **not** appear inside the wrapper bodies for primitive-result
  closures.
- Allocation-count tests confirm the boxing site has moved off the
  hot path.

Pre-Phase-D baseline (gate engaged): a fold over `[1..N]` allocates
one `ElmInt` per iteration inside the wrapper. Post-Phase-D: zero
allocations on the wrapper path; the only allocation is the
caller-side `eco.box` if the result flows into an `!eco.value`
context. IR-level `CHECK-NOT` patterns capture this exactly.

### D5. Undo the K = 0 documentation in `project_unboxed_primitive_returns.md`

Update the memory file's "What is gated off" section to "what's
delivered". The gating is gone.

---

## Revised summary of files touched (Phases C + D)

### Runtime / allocator

- `runtime/src/allocator/Heap.hpp` — `Closure` bit-packing changed:
  add `result_kind:2`, shrink `unboxed` to `:50` (25 typed slots).
  `EvalParamLayout`'s `result_kind` byte stays.
- `runtime/src/allocator/RuntimeExports.{h,cpp}` — add
  `eco_alloc_closure_k`; `eco_alloc_closure` legacy keeps K=0.
  `eco_pap_extend` + `eco_alloc_closure_group_slow` propagate
  `result_kind` from source to result. `eco_apply_closure`,
  `eco_closure_call_saturated`, `eco_apply_segmentation_unknown`
  read K from the closure header.
- `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` —
  `PapCreateOpLowering` / `PapCreateGroupOpLowering` call
  `eco_alloc_closure_k` with op's `_result_kind`. Remove the
  `resultKind = 0;` overrides in `getOrCreateWrapper` and the
  lowerings.

### C++ kernels (explicit-K allocation sites)

- `elm-kernel-cpp/src/core/ProcessExports.cpp` — `eco_alloc_closure_k(.., PK_Boxed)`.
- `elm-kernel-cpp/src/time/TimeExports.cpp` — same.
- `elm-kernel-cpp/src/http/HttpExports.cpp` — same.
- `eco-kernel-cpp/src/eco/MVar.cpp` — same for all three binding evaluators.

### Compiler

- `compiler/src/Compiler/Generate/MLIR/Functions.elm` — capture-count
  cap audit (drop ceiling from 26 to 25 if any test approaches it).
- No other Elm-side changes; B4's `_result_kind` plumbing already
  populates the attribute.

### Tests

- `runtime/test/allocator/EcoApplyClosureEvalTest.cpp` — extended
  with the C7 cases.
- `compiler/tests/TestLogic/Generate/CodeGen/CaptureCountLimit.elm`
  (new) — assert 25-capture closures compile and 26-capture trigger
  the documented overflow path.

---

## Resolutions for Phases C + D

C+D revise two earlier decisions:

A. **"Closure does not grow"** (Resolutions §2). The struct size still
   does not grow (the bit-packed field is unchanged at 64 bits), but
   we re-allocate two bits inside it. The maximum typed-capture count
   drops from 26 to 25.

B. **K lives in the layout** (Resolutions §2, B5). Layout-K becomes a
   redundant hint; the **closure header's `result_kind` is the
   authoritative source of truth** for every dispatch path. The
   layout byte is kept to ease over-saturated sub-layout chaining
   and as a debug-asserting cross-check, but the runtime no longer
   *requires* the caller to populate it correctly.

These revisions are necessary because the alternative — every
closure-invocation site (including ~30 C++ kernel call sites)
reading the closure's K from elsewhere — does not have a workable
implementation. Storing K on the closure is the smallest change that
preserves the plan's headline guarantee: **primitive return values
flow as primitives end-to-end, with no boxing overhead on the apply
path.**
