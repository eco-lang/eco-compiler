# Error 1: Missing `predicate` on `arith.cmpi` for i16 (12 errors)

## Root Cause

**File:** `compiler/src/Compiler/Generate/MLIR/Patterns.elm:205`

The pattern compiler's `IsChr` branch calls `Ops.ecoBinaryOp` to emit `arith.cmpi` for Char equality tests. `ecoBinaryOp` (`Ops.elm:646-656`) is a generic binary op builder that only sets `_operand_types` — it does **not** set the required `predicate` attribute. The correct function is `Ops.arithCmpI` (`Ops.elm:540-588`) which sets both `_operand_types` and `predicate`.

For comparison, `IsInt` (line 186) correctly uses `eco.int.eq` (an Eco dialect op that doesn't need `predicate`).

## MLIR Evidence

Correct emission (i32 comparison):
```mlir
%8 = "arith.cmpi"(%6, %7) {_operand_types = [i32, i32], predicate = 0 : i64} : (i32, i32) -> i1
```

Incorrect emission (i16 comparison — missing predicate):
```mlir
%250 = "arith.cmpi"(%248, %249) {_operand_types = [i16, i16]} : (i16, i16) -> i1
```

## Affected Locations (12)

All 12 errors follow the same pattern: an `i16` value is projected from a tuple or custom type, compared against an `i16` constant (character literal), and the `arith.cmpi` is emitted without `predicate`. Characters involved: `,` (44), `\` (92), `{` (123), `-` (45), `(` (40), `5` (53), `}` (125).

## Failing Tests

- **Elm-test:** `compiler/tests/TestLogic/Generate/CodeGen/CmpiPredicateAttrTest.elm` — **FAILS** with: `arith.cmpi is missing required 'predicate' attribute`
- **E2E:** `test/elm/src/CharCasePredicateTest.elm` — passes in JIT (bug only manifests in Stage 6 `eco-boot-native` parser)

## Fix Direction

Replace the `ecoBinaryOp` call on line 205 of `Patterns.elm` with a call to `Ops.arithCmpI` with predicate `"eq"`.
