# Error 4: `eco.papCreate` unboxed_bitmap missing i1 bit (4 errors)

## Root Cause

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`, `generateClosure` (~line 881)

Bool values are `i1` in SSA representation but must be `!eco.value` in closures (per `REP_CLOSURE_001`, `FORBID_CLOSURE_001`). The `generateClosure` function:

1. Evaluates capture expressions via `generateExpr`, which produces `i1` for Bool values
2. Passes `i1` captures directly to `eco.papCreate` **without boxing**
3. Computes `unboxed_bitmap` using `Types.isUnboxable`, which correctly returns `False` for `I1` (Bool is not unboxable)
4. Result: bitmap says "boxed `!eco.value`" (bit=0) but the actual operand is `i1`

### Relevant Invariants

- **REP_CLOSURE_001**: Closure objects capture values using SSA representation rules: only immediate operands are stored in unboxed fields and **all other values (including Bool) are stored as `!eco.value`**
- **FORBID_CLOSURE_001**: No phase may assume that Bool values are captured, stored, or passed as immediate operands outside SSA control-flow contexts; **Bool must be represented as `!eco.value` in heap and closures**
- **CGEN_012**: `monoTypeToMlir` maps MBool to `eco.value` (not i1) at ABI/closure boundaries

## MLIR Evidence

Location 1 (line 203125 — bit 0):
```mlir
%5 = "arith.constant"() {value = true} : () -> i1
%7 = "eco.papCreate"(%5) {
    _operand_types = [i1],
    arity = 2,
    function = @Terminal_Main_lambda_30632$clo,
    num_captured = 1,
    unboxed_bitmap = 0        // ERROR: bit 0 should be set for i1, OR i1 should be boxed first
} : (i1) -> !eco.value
```

Locations 2-4 (lines 294768, 528555, 533309 — bit 2):
```mlir
%31 = "eco.papCreate"(%root, %8, %10, %7, %15, %5) {
    _operand_types = [!eco.value, !eco.value, i1, !eco.value, !eco.value, !eco.value],
    arity = 7,
    num_captured = 6,
    unboxed_bitmap = 0        // ERROR: bit 2 should be set (operand %10 is i1)
} : (!eco.value, !eco.value, i1, !eco.value, !eco.value, !eco.value) -> !eco.value
```

## Failing Test

`test/elm/src/ClosureCaptureBoolTest.elm` — **FAILS** with: `'eco.papCreate' op unboxed_bitmap bit 0 doesn't match operand type: bit is unset but operand type is 'i1'`

## Fix Direction

Box Bool captures (`i1` -> `!eco.value` via `eco.box`) before passing to `papCreate`, analogous to `boxArgsForClosureBoundary` which already does this for `papExtend` arguments. The bitmap is already correct (bit=0 = boxed). The missing step is a boxing pass on captures in `generateClosure`.

Two sites need fixing:
1. `generateClosure` (~line 881): capture processing — no boxing of Bool captures before `papCreate`
2. `MonoTailDef` handler (~line 3315): capture types from `varMappings` flow through to `papCreate` without boxing
