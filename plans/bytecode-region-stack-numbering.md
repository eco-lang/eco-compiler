# Plan: Region-Stack Value Numbering for MLIR Bytecode

## Status

Two-pass numbering + APFloat fix: 819/943 E2E tests pass (baseline text: 925/943).
105 bytecode-only failures remain.

## Root Cause

MLIR's reader uses a push/pop stack for value scoping. Each region's `numValues`
extends the value vector. Non-isolated alternatives push/pop from the same base,
so their values share the same index range. After popping, subsequent parent ops
reuse those indices.

Our encoder assigns unique indices globally — sub-region values get indices
N..N+M, and the next parent op gets N+M+1. But the reader expects the next
parent op at index N (same as the sub-region base). The indices overlap in the
push/pop lifecycle because sub-region values are only alive during their push.

## Concrete Example

Parent block: [arg0, arg1, get_tag, constant, cmpi, eco.case, return]
numValues = 4 args + 4 op results = 8.

Writer: eco.case result at 7. opFirstValueID = 8. Alts at base 8.
Reader: push alt → values extends from 8 to 8+altNumValues.
        Operands at 8, 9 reference alt values. Pop. Values back to 8.
        eco.case result defined at index 7 (nextValueIDs.back).

**The writer and reader agree: alt values at [8..8+M), parent continues at 8 after pop.**

Our encoder: eco.case result at 7. Alt values at [8..8+M). Next parent op at 8+M.
But should be at 8 (same as alt base). The `numValues=8` only has slots [0..7].
Index 8+M is out of range.

## Solution

The numbering pass must NOT advance the parent's `nextValueIndex` past sub-region
values. Instead, sub-region values should be numbered relative to a PUSHED base
that's temporary. After the op with regions, the parent's counter stays where
it was before the sub-regions.

**But**: the `valueMap` must still contain correct mappings for operand lookups
within the sub-regions. An operand at index `base+2` inside alt0 references
a value defined at `base+2` in that alt.

The implementation:
1. `numberOp` for non-isolated regions: don't advance `nextValueIndex`
2. `countRegionValues`: count direct values only
3. Encoding: when encoding operands within a sub-region, the value indices
   from `valueMap` are correct (base+offset) because the reader will have
   pushed the sub-region, extending the vector to include base+offset.

## The Remaining Bug

With this approach, 819 tests pass. The remaining ~105 failures have errors
like "operand does not dominate this use" and "eco.yield expects parent eco.case".
These may require tracking the push base offset during the ENCODING pass too,
so that operand lookups adjust indices based on which region is currently being
encoded.

## Next Steps

1. Investigate the specific "operand does not dominate" errors to determine if
   they're from incorrect index mapping or actual IR structure issues.
2. Consider implementing the full push/pop simulation in the numbering pass,
   tracking both absolute and relative indices.
3. Alternatively, investigate if these remaining failures are from a different
   class of issue entirely (e.g., scf.while, successors, multiple blocks).
