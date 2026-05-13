# Pattern C Deep Dive — Single-Use Unboxed Capture Miscompile

**Date:** 2026-05-13
**Status:** Workaround in place at `compiler/src/Compiler/Generate/MLIR/Expr.elm:4498-4506`; underlying codegen bug latent.
**Repro symptom:** `eco.papCreateGroup.cross_edges` consumer indices in `MutualLetRec*` tests come out as ~1.6×10⁹ heap-address-pattern garbage instead of the expected small sibling indices `0` and `1`.

---

## 1. What the bug is

`buildSiblingData` (Expr.elm:4449) is the body of the `List.foldl` that walks the SCC of mutually-recursive closure bindings inside `generateLetGroup`:

```elm
buildSiblingData ( consumerIdx, member ) acc =
    let
        ...
        crossEdgesForSibling =
            List.indexedMap
                (\j ( _, captureExpr, _ ) ->
                    case captureExpr of
                        Mono.MonoVarLocal refName _ ->
                            case Dict.get refName memberIndex of
                                Just producerIdx ->
                                    Just
                                        ( producerIdx
                                        , consumerIdx
                                        , nonSiblingCount + j
                                        )
                                ...
```

The inner lambda `(\j (_, captureExpr, _) -> …)` is created inside `buildSiblingData` and passed to `List.indexedMap`. From the lambda's body, the free variables — i.e. its closure captures — are:

| variable          | source                                                   | MonoType (→ MLIR ABI) |
|---|---|---|
| `memberIndex`     | outer `let` of `generateLetGroup`                         | `Dict Name Int`  → `!eco.value` |
| `consumerIdx`     | **destructured from the foldl tuple** `(consumerIdx, member)` | `Int` → **`i64`** |
| `nonSiblingCount` | local `let` inside `buildSiblingData`                     | `Int` → `i64` |

The "**single-use Int**" is **`consumerIdx`**: a primitive `i64` value, obtained by projecting field 0 of the foldl tuple via `eco.project.tuple2`, and **referenced exactly once inside the inner lambda's body** (in the `Just ( producerIdx, consumerIdx, nonSiblingCount + j )` triple). The trace logs I added earlier show that at the **call to** the inner lambda, the value being passed in via the closure capture slot is bogus (~1.6×10⁹), even though `buildSiblingData`'s outer scope sees `consumerIdx` correctly as `0` or `1`.

### Why "single use" matters

The Stage 6 native compiler's RS4GC-based safepoint pipeline (`compiler/src/Compiler/Generate/MLIR/Functions.elm`, `compiler/src/Compiler/Generate/MLIR/Lambdas.elm`, `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`, `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`) treats:

1. **multi-use** primitives the same way as primitive function-args: they get pinned in a register/stack slot whose RS4GC liveness is correctly computed across each safepoint;
2. **single-use** primitives derived directly from a heap-load (`eco.project.tuple2`, `eco.project.tuple3`, `eco.project.custom`, `eco.project.record` with `is_unboxed=true`) as transient values — and "transient" in this codebase means "let LLVM choose where to materialise the load".

The transient case is where this bug lives. In the MLIR for `buildSiblingData$cap` (extracted from a freshly built `eco-compiler.mlir`, function `@Terminal_Main_lambda_28516$cap` — the lifted form of `buildSiblingData`), the *fixed* code reads (verbatim):

```mlir
func.func private @Terminal_Main_lambda_28516$cap(
        %arg0: !eco.value,  // capture: memberNameSet (Set Name)
        %arg1: !eco.value,  // capture: memberIndex   (Dict Name Int)
        %arg2: !eco.value,  // param 1: the (consumerIdx, member) tuple
        %arg3: !eco.value   // param 2: acc accumulator
) -> !eco.value {
    %0 = eco.project.tuple2 %arg2[0] {_operand_types = [!eco.value]} : !eco.value -> i64
    %1 = eco.project.tuple2 %arg2[1] {_operand_types = [!eco.value]} : !eco.value -> !eco.value
    %c0_i64 = arith.constant 0 : i64
    %2 = eco.int.add %0, %c0_i64 {_operand_types = [i64, i64]} : i64
    ...
    // The papCreate for the inner lambda — captures memberIndex, nonSiblingCount, consumerIdxLocal
    %41 = "eco.papCreate"(%arg1, %38, %2)
            <{ _fast_evaluator = @Terminal_Main_lambda_28520$cap,
               _result_kind = 0 : i8,
               arity = 5 : i64,
               function = @Terminal_Main_lambda_28520$clo,
               num_captured = 3 : i64,
               unboxed_bitmap = 20 : i64 }>          // bitmap 20 = 0b010100 = slots 1,2 unboxed
            {_operand_types = [!eco.value, i64, i64]}
            : (!eco.value, i64, i64) -> !eco.value
    ...
}
```

The third capture operand is `%2` (the `eco.int.add %0, %c0_i64` result). **Without the `+ 0` workaround it would be `%0` directly** — the bare `eco.project.tuple2` result — which is the buggy shape.

The inner lambda's `$clo` (the generic clone that loads captures back out of the closure) is:

```mlir
func.func private @Terminal_Main_lambda_28520$clo(
        %arg0: !eco.value,  // %closure
        %arg1: i64,         // param j
        %arg2: !eco.value   // param: capture tuple
) -> !eco.value {
    %0 = "eco.project.closure"(%arg0) <{index = 0 : i64, is_unboxed = false}> : (!eco.value) -> !eco.value
    %1 = "eco.project.closure"(%arg0) <{index = 1 : i64, is_unboxed = true}> : (!eco.value) -> i64
    %2 = "eco.project.closure"(%arg0) <{index = 2 : i64, is_unboxed = true}> : (!eco.value) -> i64
    eco.safepoint %arg2, %arg0 : !eco.value, !eco.value
    %3 = "eco.call"(%0, %1, %2, %arg1, %arg2) <{callee = @Terminal_Main_lambda_28520$cap}> ...
}
```

`%2` (= `consumerIdx` via closure slot 2) is read with `is_unboxed = true`, so the closure header is consulted with the correct kind. The `$clo`/`$cap` contract is self-consistent — the read side is fine. **The bug is on the build side**, in how the *write* of `consumerIdx` into the new closure interacts with the safepoint inserted by `PapCreateOpLowering` and the subsequent allocation call.

### What goes wrong at the LLVM layer

`PapCreateOpLowering::matchAndRewrite` (`runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:600`) does, in order:

```cpp
auto [realOperands, liveRoots] = splitAdaptedRoots(op, adaptor.getOperands());
...
// Emit safepoint marker before allocation
emitSafepointMarker(op, rewriter, runtime, liveRoots);
...
auto allocCall = rewriter.create<LLVM::CallOp>(loc, allocFuncK,
    ValueRange{funcPtr, arityConst, resultKindConst});
Value closureHPtr = allocCall.getResult();
...
// Store captured values starting at offset 24.
for (size_t i = 0; i < captured.size(); ++i) {
    ...
    Value capturedValue = captured[i];
    ...
    rewriter.create<LLVM::StoreOp>(loc, capturedValue, valuePtr);
}
```

The store loop reads each `capturedValue` (= adapted operand) **after** the allocation call `eco_alloc_closure_k`. `eco_alloc_closure_k` is **not** a gc-leaf function — it can trigger a minor GC, which is a real safepoint.

`emitSafepointMarker` itself is a no-op:

```cpp
void eco::detail::emitSafepointMarker(...) {
    // RS4GC handles safepoint insertion automatically — no marker needed.
}
```

So every value that crosses `eco_alloc_closure_k` is whatever LLVM RewriteStatepointsForGC infers as live. `eco.project.tuple2 -> i64` is lowered (`EcoToLLVMHeap.cpp:534`) to:

```cpp
auto resolveCall = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{input});  // gc-leaf
Value ptr = resolveCall.getResult();
auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offsetBytes);
auto fieldPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, ptr, ValueRange{offset});
Value result = rewriter.create<LLVM::LoadOp>(loc, resultType, fieldPtr);   // i64 load
rewriter.replaceOp(op, result);
```

i.e. a non-GC `getelementptr` off of the `eco_resolve_hptr` return, followed by a plain `i64` load. The hazard: `ptr` is a derived address of the tuple HPointer `%arg2`. If LLVM **sinks** the project.tuple2 load past the allocating safepoint — or hoists the resolve/GEP/load triple as a unit through a region where `%arg2` is statepoint-relocated — it ends up reading from a *stale heap pointer* whose object has been moved/sweep-released. The post-GC contents of those bytes happen to look like heap addresses, which is exactly the symptom (top byte `0x60`, low bits arbitrary, ≈1.6 × 10⁹).

The "exactly one use" precondition matters because LLVM only considers such hazardous re-ordering when there is no other use that pins the value at an earlier point. With two uses, the load is materialised once and reused; with one use, the load can be relocated to any dominator of that use — including across the allocating safepoint.

---

## 2. Wider picture: how else could this captured-variable pattern produce incorrect code

Every site that satisfies all four properties is exposed to the same hazard:

1. an `eco.project.*` op produces an **unboxed primitive** (`i64`, `f64`, `i16`) from a heap object,
2. that primitive flows **as a capture operand** into a closure-allocating op (`eco.papCreate`, `eco.papExtend`, or `eco.papCreateGroup`),
3. between the projection and the closure allocation there is at least one **non-leaf** call or other statepoint,
4. the projection result has **exactly one use** (no other consumer to pin it).

Other call shapes that are vulnerable but happen not to trigger today:

- **Captures derived from `eco.project.record`** — e.g. extracting an `Int` field from a record and passing it as the sole `arith.cmpi` input *and* a closure capture. (Most record-field accesses today end up multi-use because they feed both the capture and a comparison.)
- **Captures derived from `eco.project.custom` with `is_unboxed=true`** for `Int`/`Float`/`Char` fields of a custom-ctor (e.g. `Just Int`, `Step Int`).
- **Captures derived from `eco.project.tuple3` field 0/1/2** when the field is an unboxed primitive (same code path as Tuple2ProjectOpLowering at `EcoToLLVMHeap.cpp:580`).
- **`papExtend` newargs**: the same code in `PapExtendOpLowering` reads `realOperands` after the allocation call; an unboxed primitive flowing into an extend is just as fragile.

The reason `MutualLetRecManyCapturesTest` is the canary is structural: `crossEdgesForSibling`'s inner lambda is the **only** place in `buildSiblingData` that uses `consumerIdx` after the destructure of the foldl tuple — and `consumerIdx` is the only `i64` capture that flows into a closure-allocating op via that "one heap load then one capture" path.

---

## 3. Which types are affected

| MLIR type | Affected? | Reason |
|---|---|---|
| `!eco.value` (HPointer / `ptr addrspace(1)` after lowering) | **No** | RS4GC tracks `addrspace(1)` pointers and relocates them automatically across statepoints. The capture path remains correct under GC moves. |
| `i64` (Int) | **Yes** | Lowers to a plain `load i64` off a derived `ptr` (non-GC addrspace). LLVM is free to sink/hoist the load. If the underlying heap object is relocated/swept across the allocating safepoint, the late re-issued load reads garbage. |
| `f64` (Float) | **Yes (same mechanism)** | `Tuple2ProjectOpLowering` falls into the same `else` branch — `load f64, ptr`. The `f64` is just bits to RS4GC; LLVM treats the load identically to the `i64` case. |
| `i16` (Char) | **Yes (same mechanism)** | `Char` projection emits `load i16, ptr`; the `closureStoreValueToI64` widen path in `PapCreateOpLowering` (line 731-734) zero-extends to `i64` for the closure slot, but only after the load. If the load is sunk past the safepoint, the i16 read is from stale memory. |
| `i1` (Bool stored unboxed) | **Not currently** | Bool is always stored boxed in heap fields and closures (REP_CLOSURE_001) — the project op for Bool goes through the boxed-then-unbox idiom that Pattern A fixed. |

So three unboxed primitive types (`Int`, `Float`, `Char`) are all candidates for the same miscompile. Boxed values (`!eco.value`) are safe because RS4GC handles them; `Bool` is forced into a boxed representation at the closure boundary so it inherits that safety.

---

## 4. Shape of code needed to trigger the bug

Concretely, an Elm-side pattern that hits the bug needs all of:

1. A **destructure or projection** that produces an unboxed primitive (`Int`, `Float`, `Char`) from a heap-resident container — i.e. one of:
   - tuple-2 / tuple-3 destructure `(a, b) = …` or `(a, b, c) = …` where one element is `Int`/`Float`/`Char`,
   - custom-type ctor destructure `Just n = …` etc. where `n` is unboxed,
   - record-field access `r.field` where `field` is unboxed.
2. That primitive is **captured by an inner lambda** (which gets lifted to a top-level `$cap`/`$clo` pair via `Compiler.Generate.MLIR.Lambdas`).
3. The capture path is **closure-allocating** — i.e. an `eco.papCreate`/`eco.papExtend`/`eco.papCreateGroup` happens before the lambda is invoked.
4. The primitive is **referenced exactly once** in the lambda body (so LLVM has no other use to pin the heap load).

`buildSiblingData` is the smallest visible example: `(consumerIdx, member) = foldl_tuple` destructures an `(Int, ClosureBinding)`; the `Int` is used once in the inner `\j (_, captureExpr, _) -> …` lambda's `Just (producerIdx, consumerIdx, nonSiblingCount + j)`; that inner lambda is a `papCreate`-built closure passed to `List.indexedMap`.

---

## 5. The `+ 0` mechanism, in MLIR

Source (Expr.elm:4498-4506, **current code**):

```elm
-- Force consumerIdx through an additional in-scope arithmetic
-- use before the inner lambda captures it.
consumerIdxLocal =
    consumerIdx + 0

crossEdgesForSibling =
    List.indexedMap
        (\j ( _, captureExpr, _ ) ->
            case captureExpr of
                Mono.MonoVarLocal refName _ ->
                    case Dict.get refName memberIndex of
                        Just producerIdx ->
                            Just ( producerIdx, consumerIdxLocal, nonSiblingCount + j )
                        ...
```

### MLIR with `+ 0` (current — buggy path avoided)

Verbatim from `Terminal_Main_lambda_28516$cap` (the lifted `buildSiblingData`):

```mlir
    %0 = eco.project.tuple2 %arg2[0] {_operand_types = [!eco.value]} : !eco.value -> i64
    %1 = eco.project.tuple2 %arg2[1] {_operand_types = [!eco.value]} : !eco.value -> !eco.value
    %c0_i64 = arith.constant 0 : i64
    %2 = eco.int.add %0, %c0_i64 {_operand_types = [i64, i64]} : i64
    ...
    %41 = "eco.papCreate"(%arg1, %38, %2) <{... unboxed_bitmap = 20 : i64 ...}> ...
```

`%0` has **two uses now**:
- one as an operand to `eco.int.add` (the `+ 0`),
- (none else — `%0` dies at line 5).

`%2` has one use (the `papCreate` capture operand), but `%2` is the result of a pure arithmetic op (`eco.int.add` → LLVM `add i64`), not a heap load. RS4GC and the LLVM register allocator have no incentive to do anything clever with `%2`.

### MLIR without `+ 0` (the buggy shape)

The exact same function, but with the workaround removed:

```mlir
    %0 = eco.project.tuple2 %arg2[0] {_operand_types = [!eco.value]} : !eco.value -> i64
    %1 = eco.project.tuple2 %arg2[1] {_operand_types = [!eco.value]} : !eco.value -> !eco.value
    ...                          (≈ 50 ops, many eco.safepoint and eco.call ops)
    %41 = "eco.papCreate"(%arg1, %38, %0) <{... unboxed_bitmap = 20 : i64 ...}> ...
```

`%0` now has exactly one use, ≈50 ops downstream. The intermediate region contains several allocating calls (`Dict.get`, `List.foldl`, `boxArgsForClosureBoundary`, …) — each of which becomes an RS4GC statepoint. The lowered `eco.project.tuple2`:

```llvm
%ptr  = call @eco_resolve_hptr(ptr addrspace(1) %arg2)  gc-leaf
%fp   = getelementptr i8, ptr %ptr, i64 8
%val0 = load i64, ptr %fp
```

is **derived data from the GC pointer `%arg2`** (the foldl tuple's HPointer). LLVM's scheduler is free to sink the `%fp`/`%val0` chain to the use site at the bottom of the function. When it does, the `getelementptr` and `load` get re-issued *after* one or more statepoints that may have relocated/swept the underlying tuple object. The re-issued load reads from heap bytes that no longer belong to the tuple — they're whatever currently lives at that address, which (because the heap is the major-GC arena) is typically an old-gen header or another object's word. Those bytes decode as small heap addresses; the test harness sees `cross_edges.consumer = 1612959687 = 0x6023cfc7` and the verifier rejects the op.

### Is `consumerIdx` corrupted in the closure, or never written correctly?

The store is the **last** write — the `LLVM::StoreOp` at `PapCreateOpLowering` line 743. The captured value `capturedValue = captured[i]` is whatever SSA value the verifier handed in. With no `+ 0`, `captured[i]` is the LLVM-IR-level value chain ending at the *sunk* `load i64, ptr` — i.e. the load reads from a stale pointer **before being stored to the new closure**. So the corruption happens **on the way in**, not after the closure has been allocated. The closure slot is written with the wrong bits to begin with; the subsequent `eco.project.closure` in `$clo` then reads back those wrong bits, faithfully.

### Why the materialisation works

`eco.int.add %0, %c0_i64` lowers to plain `%val0_anchored = add i64 %val0, 0` in LLVM IR. This op:

1. Is a side-effect-free arith op operating purely on `i64`, with no `ptr` operands → LLVM can't sink the *load* past it without also sinking the add, and the add itself is pinned by its single use as a `papCreate` operand below all of the relevant safepoints.
2. Produces a fresh SSA value (`%2`) whose definition is now this `add` instruction at the top of the function, not the `load i64`. LLVM's instcombine treats `add %x, 0` as a no-op for *value* but doesn't fold it across statepoint boundaries in a way that would dis-anchor `%val0` — the use of `%val0` by the add is enough to pin the load above the safepoints.

Effectively, the `+ 0` is a barrier between the unsafe heap-derived load and the closure-store. It costs one machine `add` of `0`, which a peephole on the eventual codegen typically eliminates anyway — but the MLIR-level op survives the passes that matter (RS4GC, LICM, instcombine over MLIR-eco ops), and that's all that's needed.

---

## What a real fix would look like

The workaround is at the wrong layer — Elm source guarding against a back-end miscompile. The real fix needs to live in one of the C++ lowering passes:

1. **`Tuple2ProjectOpLowering` / `Tuple3ProjectOpLowering` / `CustomProjectOpLowering` / `RecordProjectOpLowering`** in `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` should, when lowering a projection that yields an unboxed primitive, **emit a barrier** (e.g. an `llvm.experimental.noalias.scope.decl`, an `llvm.assume`, or an explicit gc-leaf call that takes the primitive by value) so that LLVM can't sink the underlying `load` past a statepoint. Or, equivalently, force the load to be marked as `!invariant.load` only when it provably is — and otherwise pin it.
2. **`PapCreateOpLowering` / `PapCreateGroupOpLowering` / `PapExtendOpLowering`** should pin each unboxed-primitive capture operand to a stack slot **above** the allocation call. Today they store directly out of the SSA register, which is what gives LLVM the freedom to re-materialise the load late.
3. Audit whether `emitSafepointMarker`'s reliance on RS4GC alone is correct for the closure-build path. The fact that `liveRoots` is computed but the marker is a no-op suggests the intent was always to thread root info through RS4GC; if RS4GC is missing the i64-derived-from-ptr case, that's the kernel of the bug.

Until one of those lands, the Elm-side `consumerIdxLocal = consumerIdx + 0` is the only place in the front-end where `Pattern C` is structurally avoided. If a future refactor inlines `consumerIdxLocal` back into the inner lambda, the bug will resurface on `MutualLetRec*` and any other call shape that happens to satisfy the four trigger conditions in §4.
