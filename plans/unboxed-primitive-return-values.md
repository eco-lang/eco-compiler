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
