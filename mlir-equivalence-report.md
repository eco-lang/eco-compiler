# MLIR Equivalence Suite — Pattern A & C Root Cause and Fix Report

**Date:** 2026-05-13
**Suite:** `cmake --build build --target run-mlir-equivalence`

## Summary

| Pattern | Symptom | Tests Affected | Status |
|---|---|---|---|
| A | Stage 6 inverts the True/False arm in `case` over a Bool stored as a Custom-type field | 9 | **FIXED** |
| B | Stage 2's i64 literal parsing truncates `9223372036854775807` to `2048` under Node | 1 | Ignored per user (Eco has 64-bit Int; Node's JS Number doesn't) |
| C | Stage 6 emits invalid `eco.papCreateGroup` binary MLIR — `cross_edges consumer N out of range` (N ≈ 1.6 × 10⁹) | 3 | **FIXED (workaround)** |

**Final equivalence result:** 689/690 tests passing. The remaining failure is Pattern B (IntOverflowTest), which user excluded.

---

## Pattern A — Bool case inversion via boxed Custom field

### Symptom

Tests like `CaseBoolTest`:

```elm
case True of
    True ->  "yes"
    False -> "no"
```

Returned `"no"` in the True arm at Stage 6 (native) but `"yes"` in Stage 2 (JS). The arm-swap also showed up in inlined `if`/`&&`/`||` constant-folding and the single-ctor pair-Bool tests.

### Investigation

The discriminator hits `eco.case` with the i1 scrutinee coming from a Bool that was boxed into a Custom-type field (e.g. `Pair Bool x`). The MLIR text for the project step looked correct:

```mlir
%b = eco.project.custom %p field=0 : !eco.value -> i1
```

i.e. the field was stored boxed (HPointer to `Const_True` = 3<<40 or `Const_False` = 4<<40), and the projection asked for an `i1` directly. The C++ lowering `CustomProjectOpLowering` (in `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp:843`) loaded the 8-byte field as the result type:

```cpp
if (isHPtrLLVMType(resultType)) {
    Value loaded = create<LLVM::LoadOp>(loc, i64Ty, fieldPtr);
    rewriter.replaceOp(op, heapLoadI64ToValue(...));   // wraps back to HPointer
} else {
    // i1 hits this branch — loads ONLY THE LOW BIT of the slot
    Value result = create<LLVM::LoadOp>(loc, resultType, fieldPtr);
    rewriter.replaceOp(op, result);
}
```

For an `i1` target with a boxed source, the load reads the low bit of the 64-bit slot. Both `Const_True` (0x3 << 40) and `Const_False` (0x4 << 40) have a low bit of `0`. So every Bool projected this way decoded as `False` — the `True` arm of `eco.case` was dead, and dispatch fell through to `False`. The textual MLIR looked fine because the bug was at the LLVM-lowering layer.

The same code is used by Tuple2/Tuple3 field projection, but those go through the Patterns.elm wrapper that inserts an explicit `eco.unbox` step for I1 targets (REP_CONSTANT_003). The Custom branch was missing that wrapper.

### Fix

`compiler/src/Compiler/Generate/MLIR/Patterns.elm:485-579` — when the destructure target type is `I1` and the field is stored boxed (the Just-fieldInfo `else` branch and the Nothing-fieldInfo `else` branch), project as `!eco.value` first, then add `Intrinsics.unboxToType … I1`:

```elm
if targetType == I1 then
    let
        ( valVar, ctxV ) = Ctx.freshVar ctx2
        ( ctxP, projectOp ) = Ops.ecoProjectCustom ctxV valVar index Types.ecoValue subVar
        ( unboxOps, unboxedVar, ctxU ) = Intrinsics.unboxToType ctxP valVar I1
    in
    ( projectOp :: unboxOps, unboxedVar, ctxU )
else
    -- existing behavior for non-i1 targets
    ...
```

`eco.unbox … i1` lowers to a runtime helper that compares the HPointer against `Const_True` / `Const_False` rather than reading the low bit.

### Outcome

All 9 Bool tests now pass at Stage 6. No regressions in Tuple2/Tuple3 destructure (they already used the project-as-eco.value + unbox idiom) or the unrelated case lowering.

---

## Pattern C — invalid `eco.papCreateGroup.cross_edges` in mutual let-rec

### Symptom

Three mutual let-rec tests (`MutualLetRecManyCapturesTest`, `MutualLetRecClosuresTest`, `MutualLetRecNestedTest`) emitted binary MLIR that the verifier rejected:

```
error: 'eco.papCreateGroup' op cross_edges consumer 1612463081 out of range
error: 'eco.papCreateGroup' op cross_edges consumer 1614627243 out of range
```

The decimal values (~1.6 × 10⁹) hinted at uninitialised-memory contamination rather than a logic bug.

### Investigation

The Stage 6 binary parsed cleanly when printed via `ecoc --emit=mlir` for Stage 2 but failed for Stage 6. A section-by-section decode showed:

- string / dialect sections: byte-identical between Stage 2 (3210 B) and Stage 6 (3236 B)
- `attrType` section: **24 bytes larger** in Stage 6 (807 vs 783 B)
- `attrTypeOffset`: **2 bytes larger** in Stage 6 (191 vs 189 B) — i.e. **two extra attribute entries**
- IR section: same size, but indices shifted by +2 from byte ~340 onward

Extracting the attribute table revealed two **extra `IntegerAttr i64`** entries in Stage 6 at positions [75] and [76]:

```
[75] code=8 type=i64 value=1612959687   (encoded as 9-byte varint 00 8e 77 38 c0 00 00 00 00)
[76] code=8 type=i64 value=1612466329   (encoded as 9-byte varint 00 32 73 38 c0 00 00 00 00)
```

These values appeared as positions 1 and 4 (the **consumer indices**) of the flattened `cross_edges` 6-element ArrayAttr, which textually should have been `[0, 1, 4, 1, 0, 4]`. Stage 6 was producing `[0, 1612959687, 4, 1, 1612466329, 4]` — corrupting only the consumerIdx slots while leaving producerIdx and slot positions intact.

The Elm code in `Compiler/Generate/MLIR/Expr.elm`:

```elm
crossEdgesForSibling =
    List.indexedMap
        (\j ( _, captureExpr, _ ) ->
            case captureExpr of
                Mono.MonoVarLocal refName _ ->
                    case Dict.get refName memberIndex of
                        Just producerIdx ->
                            Just ( producerIdx, consumerIdx, nonSiblingCount + j )
                        Nothing -> Nothing
                _ -> Nothing
        )
        siblingCaptures
        |> List.filterMap identity
```

`consumerIdx` is captured from the surrounding `buildSiblingData (consumerIdx, member) acc`. Inside an `Eco.Console.log` trace inserted in this function, all values printed correctly (`consumerIdx=0`, `consumerIdx=1` — the small Int values they should be). So **the value being passed in was correct at the trace point**, but the i64 value being WRITTEN INTO the `IntAttr` for the `cross_edges` attribute later was garbage — meaning the inner lambda was reading garbage from its closure for `consumerIdx` on its second use (the tuple construction).

The pattern matches the open-record codegen issue from the 2026-05-11 memory note: `buildSiblingData` is on the boundary between Elm's open-record polymorphism and Eco's heap-layout codegen. The bug exposes itself **specifically when `consumerIdx` is referenced exactly once in the inner lambda** — a single read of an unboxed-Int closure slot, which the Stage 6 native compiler mishandles. Adding a second read (via a side-effecting trace log, or any other materialisation) anchors the value correctly.

Confirmed empirically:

| Inner-lambda body | Result |
|---|---|
| `Just ( producerIdx, consumerIdx, nonSiblingCount + j )` | **FAILS** — bogus 1.6e9 written |
| `let _ = Eco.Console.log ("...consumerIdx=" ++ String.fromInt consumerIdx ++ ...) () in Just (..., consumerIdx, ...)` | passes |
| `let cl = consumerIdx + 0 in Just (..., cl, ...)` *(hoisted to surrounding `let`)* | passes |

### Fix

`compiler/src/Compiler/Generate/MLIR/Expr.elm:4498-4506` — introduce a named local `consumerIdxLocal = consumerIdx + 0` in the `buildSiblingData` `let` block and reference it from the inner-lambda tuple. The `+ 0` materialises the value through an `arith.add` op the Elm front-end's simplifier does not collapse to an identity, which is enough to anchor the closure capture.

```elm
-- Force consumerIdx through an additional in-scope arithmetic
-- use before the inner lambda captures it. Without this extra
-- read, the Stage 6 native compiler's closure-capture codegen
-- mishandles the Int slot for `consumerIdx`, leaving garbage
-- (~1.6e9 HPointer-pattern bits) in the cross_edges array.
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
                        Nothing -> Nothing
                _ -> Nothing
        )
        siblingCaptures
        |> List.filterMap identity
```

This is a **workaround**, not a root-cause fix. The actual codegen bug — the inner lambda's closure-capture read of a single-use unboxed-Int slot — is still latent in `buildSiblingData`-shaped functions elsewhere. The 2026-05-11 memory note about open-record narrowing in this exact function is the deeper underlying issue and should still be tracked separately.

### Outcome

All 3 MutualLetRec tests now produce byte-identical Stage 2 / Stage 6 binary MLIR:

```
$ cmp build/test/mlir-equivalence-out/elm/MutualLetRecManyCapturesTest/stage{2,6}.bin.mlir
$ echo $?
0
```

A clean rebuild of the bootstrap chain (`cmake --build build --target run-mlir-equivalence`) reports **689/690 tests passing**, with only `IntOverflowTest` (Pattern B, deliberately excluded) remaining as a known difference.

---

## Files changed

- `compiler/src/Compiler/Generate/MLIR/Patterns.elm` — Pattern A fix (Custom-field i1 unbox)
- `compiler/src/Compiler/Generate/MLIR/Expr.elm` — Pattern C workaround (anchor `consumerIdx` through `+ 0`)

No C++ runtime changes were needed for either fix.
