# Invariants Summary

This memory contains essential invariants from `design_docs/invariants.csv`. Read this at startup.

## Four Representation Models (REP_001)

The compiler defines **four distinct data representation models**:
1. **ABI representation** - for function calls
2. **SSA representation** - for MLIR operands
3. **Heap representation** - for runtime objects
4. **Logical representation** - for Elm semantics

**Critical rule**: Rules in one model do not imply rules in another unless explicitly stated.

## ABI Rules

**REP_ABI_001**: Only Int, Float, and Char are passed/returned as pass-by-value MLIR types. **All other values including Bool** cross the ABI as `!eco.value`.

## SSA Rules

**REP_SSA_001**: SSA operands use immediate MLIR types (i64, f64, i16, i1) only for Int, Float, Char. All other values are `!eco.value`.

## Heap Rules

**REP_HEAP_001**: Heap field representation is determined solely by layout metadata (RecordLayout, TupleLayout, CtorLayout).

**REP_HEAP_002**: Unboxed fields only when layout bitmap marks them unboxed. GC relies on bitmap.

## Closure Rules

**REP_CLOSURE_001**: Closures capture using SSA rules. Only immediate operands stored unboxed. **Bool stored as !eco.value**.

**FORBID_CLOSURE_001**: Bool must NOT be captured/stored as immediate operand outside SSA control-flow contexts.

## Type Mapping (CGEN_012)

| MonoType | MLIR Type |
|----------|-----------|
| MInt | i64 |
| MFloat | f64 |
| MChar | i16 |
| MBool | **!eco.value** (NOT i1 at boundaries) |
| MString, MList, MTuple, MRecord, MCustom, MFunction | !eco.value |

## Embedded Constants (HEAP_010, REP_CONSTANT_001)

Unit, True, False, Nil, Nothing, EmptyString, EmptyRec are **HPointer values with nonzero constant bits** - never heap allocated.

## Unboxed Bitmap Rules

**CGEN_026**: For eco.construct.*, unboxed_bitmap derived from SSA operand MLIR types: bit set iff operand is i64, f64, or i16.

**CGEN_003**: Closure unboxed bitmaps match SSA operand types after closure-boundary normalization.

## Control Flow (CGEN_010, CGEN_028, CGEN_042-CGEN_054)

**CGEN_010**: eco.case has explicit MLIR result types; every alternative terminates with eco.yield matching those types.

**CGEN_028**: Every eco.case alternative terminates with eco.yield. eco.return forbidden inside alternatives.

**CGEN_042**: Every block must end with a terminator (eco.return, eco.jump, eco.yield, etc.).

## Monomorphization

**MONO_002**: No MVar with CNumber at codegen time - must resolve to MInt or MFloat.

**MONO_006**: RecordLayout/TupleLayout store fieldCount, indices, unboxedBitmap.

**MONO_010**: MonoGraph contains all types including all constructors in ctorLayouts.

**GOPT_018**: All MonoCase branches must have same MonoType as resultType (enforced by GlobalOpt, formerly MONO_018).

## Forbidden Patterns (FORBID_*)

- **FORBID_REP_001**: Don't assume SSA immediate type means unboxed heap field without consulting bitmap
- **FORBID_REP_002**: Don't assume pass-by-value ABI means unboxed heap/closure storage
- **FORBID_HEAP_001**: Don't use address range checks for pointer/constant distinction - use HPointer constant bits
- **FORBID_CF_001**: No implicit fallthrough - all region exits must be explicit terminators
