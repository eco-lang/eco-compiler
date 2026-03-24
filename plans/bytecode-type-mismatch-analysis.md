# Bytecode E2E Failure Analysis

## Summary

142 E2E tests fail only with bytecode encoding, not with text format. The root cause
is **incorrect SSA value numbering in the bytecode IR section encoder**, combined with
a minor **FloatAttr encoding bug**. These are NOT codegen bugs — the Elm MLIR codegen
produces correct MLIR. The bytecode encoder corrupts the IR during serialization.

## Evidence

### Test case: `AnonymousFunctionTest.elm`, function `List_foldrHelper_$_12`

**Text format** (correct):
```mlir
^bb0(%fn: !eco.value, %acc: !eco.value, %ctr: i64, %ls: !eco.value):
    ...
    %30 = "eco.case"(%32) ({
        // True branch
        %33 = "eco.call"(%29) {callee = @List_reverse_$_14} : ...
        %34 = "eco.call"(%fn, %acc, %33) {callee = @List_foldl_$_15} : ...
        "eco.yield"(%34) : ...
    }, {
        // False branch
        %35 = "arith.constant"() {value = 1 : i64} : () -> i64
        %36 = "eco.int.add"(%ctr, %35) : (i64, i64) -> i64    ← CORRECT: %ctr=i64, %35=i64
        %37 = "eco.call"(%fn, %acc, %36, %29) {callee = @List_foldrHelper_$_12} : ...
        "eco.yield"(%37) : ...
    }) : (i1) -> !eco.value
    %39 = "eco.papExtend"(%fn, %28, %30) : ... -> !eco.value
    ...
```

**Bytecode round-trip** (incorrect):
```mlir
    %21 = "eco.case"(%20) ({
        // True branch
        %26 = "eco.call"(%19) {callee = @List_reverse_$_14} : ...
        %27 = "eco.call"(%arg0, %arg1, %22) {callee = @List_foldl_$_15} : ...   ← %22 forward ref!
        "eco.yield"(%23) : ...                                                     ← %23 forward ref!
    }, {
        // False branch
        %c1_i64 = arith.constant 1 : i64
        %26 = "eco.int.add"(%arg2, %22) : (i64, !eco.value) -> i64   ← %22 is !eco.value, not i64!
        %27 = "eco.call"(%arg0, %arg1, %23, %19) : ...
        "eco.yield"(%24) : ...
    }) : (i1) -> !eco.value
    %22 = "eco.papExtend"(%arg0, %18, %21) : ... -> !eco.value   ← %22 defined HERE (after use!)
    %23 = "eco.papExtend"(...) : ... -> !eco.value
    %24 = "eco.papExtend"(...) : ... -> !eco.value
```

### Analysis

The bytecode encoder assigns sequential value indices (0, 1, 2...) as it walks ops.
In MLIR bytecode, the value index for an operand is the sequential position of that
value's definition within the closest enclosing isolated region.

**Problem 1: Value numbering inside non-isolated regions**

When encoding an `eco.case` op with multiple region alternatives, the encoder
walks Alternative 1, registering all its results into the value env, then walks
Alternative 2 using the SAME value env. This means:

- Alternative 2 sees values defined in Alternative 1
- The sequential indices for Alternative 2's values are offset by Alternative 1's value count
- References to values AFTER the eco.case (like `%39` = `eco.papExtend`) get wrong indices

MLIR expects: within a non-isolated region, values are numbered relative to the parent
scope. But case alternatives are separate regions — values defined in one alternative
should NOT be visible in another.

**Problem 2: Forward references with wrong types**

When the encoder encounters an operand name that hasn't been registered yet (forward
reference), `lookupValue` returns -1. In the bytecode, -1 as an unsigned value index
is interpreted as a very large index, which wraps around or maps to a completely
different value. The result is that operands reference wrong values with wrong types.

In text format, forward references work because the type signature on each op
independently specifies operand types. In bytecode, operand types come from the
referenced value's definition — so wrong references produce wrong types.

### Bug Categories

| Category | Count | Root cause |
|----------|-------|------------|
| Type mismatches (i64 vs !eco.value) | ~50 | Wrong value indices → references !eco.value-typed values instead of primitive-typed ones |
| eco.yield parent mismatch | ~8 | Value numbering desync causes ops to appear at wrong nesting |
| Dominance violations | ~7 | Forward references to values defined after the use point |
| construct.custom unboxed_bitmap | ~15 | Same value numbering issue → wrong field values |
| Structural errors | ~3 | Region/block structure corruption from numbering desync |
| Float encoding | ~8 | encodeAPFloat has wrong format (extra varint prefix) |
| Runtime wrong output | ~8 | Parse OK but wrong value connections produce wrong results |

### Bug: `encodeAPFloat` extra prefix byte

```elm
encodeAPFloat : Float -> BE.Encoder
encodeAPFloat f =
    BE.sequence [ encodeVarInt 1, BE.float64 Bytes.LE f ]
```

MLIR's `readAPFloatWithKnownSemantics(IEEEdouble)` calls `readAPIntWithKnownWidth(64)`
which for width=64 reads a single signed varint. But `encodeAPFloat` writes
`encodeVarInt 1` (a "numActiveWords" prefix) PLUS the raw float bytes. The reader
interprets the prefix + first bytes of the float as a zigzag-decoded integer, producing
a garbage value.

**Fix:** `encodeAPFloat f = encodeSignedVarInt (floatBitsToInt f)` — encode the raw
bits of the float as a signed varint, matching how `readAPIntWithKnownWidth(64)` reads.

### Proposed Fix for Value Numbering

The core fix is to handle non-isolated regions (like eco.case alternatives) correctly.
MLIR's bytecode format numbers values relative to the nearest enclosing isolated region.
Non-isolated regions (case alternatives) don't create new value scopes.

**Approach:**
1. Values defined inside case alternatives ARE numbered in the parent scope
2. BUT alternative regions are encoded independently — ops in alternative A can't
   reference values from alternative B
3. After encoding ALL alternatives, the values after the eco.case are numbered
   continuing from where the last alternative left off

The current encoder already threads `valueEnv` through blocks and ops. The issue is
in `encodeRegion` → `encodeBlock` for non-isolated regions: each block in a region
should advance the value counter independently, and the caller should use the
final counter value.

For eco.case specifically: each alternative region's values should be numbered in
sequence (alternative 0 gets indices N..N+k, alternative 1 gets N+k+1..N+k+m, etc.),
and the eco.case result gets the next index after all alternatives.

This matches MLIR's behavior: `eco.case` result `%46` in text format is numbered
after all the values inside its regions.
