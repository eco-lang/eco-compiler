# Fix Record Update MLIR Code Generation

## Problem Statement

The `generateRecordUpdate` function in `Compiler/Generate/MLIR/Expr.elm` is a **stub implementation** that ignores the update parameters and wraps the original record as a single field instead of performing a proper record update.

### Current Behavior (Buggy)

For `{ original | x = 10 }` where `original = { x = 1, y = 2 }`:

```mlir
%2 = "eco.construct.record"(%0, %1) {field_count = 2, ...}  // original = {x=1, y=2}
%3 = "eco.construct.record"(%2) {field_count = 1, ...}       // WRONG: wraps original
```

Output: `{ x = { f0 = 1, f1 = 2 } }` instead of `{ x = 10, y = 2 }`

### Expected Behavior

```mlir
%2 = "eco.construct.record"(%0, %1) ...  // original = {x=1, y=2}
%3 = "arith.constant"() {value = 10 : i64} ...  // new x value
%4 = "eco.project.record"(%2) {index = 1} ...   // project y from original
%5 = "eco.construct.record"(%3, %4) {field_count = 2, ...}  // new record {x=10, y=2}
```

---

## Root Cause

The current implementation at lines 3587-3605:

```elm
generateRecordUpdate ctx record _ _ _ =
    let
        recordResult = generateExpr ctx record
        ( resultVar, ctx1 ) = Ctx.freshVar recordResult.ctx
        ( ctx2, constructOp ) =
            Ops.ecoConstructRecord ctx1 resultVar [ ( recordResult.resultVar, Types.ecoValue ) ] 1 0
    in
    { ops = recordResult.ops ++ [ constructOp ], ... }
```

**Issues:**
1. Ignores `updates` parameter (uses `_`)
2. Ignores `layout` parameter (uses `_`)
3. Ignores `monoType` parameter (uses `_`)
4. Creates a 1-field record containing the original record instead of updating fields

---

## Implementation

### Step 1: Replace stub in `Compiler/Generate/MLIR/Expr.elm`

Replace the `generateRecordUpdate` function (lines ~3585-3605) with the proper implementation that:

1. **Evaluates the original record once** - store in `recordResult`
2. **Handles empty record edge case** - return original (CGEN_018 invariant)
3. **Builds update dictionary** - map field index to update expression
4. **Iterates layout.fields in order** - for each field:
   - If field index is in updates dict: evaluate update expression, coerce to storage type
   - Otherwise: project field from original record at that index
5. **Constructs new record** - with all field values (updated + projected)

### Key Implementation Details

**Storage type determination:**
```elm
storageType =
    if fieldInfo.isUnboxed then
        Types.monoTypeToAbi fieldInfo.monoType
    else
        Types.ecoValue
```

**For updated fields:**
- Generate the update expression
- Coerce result to storage type via `coerceResultToType`

**For unchanged fields:**
- Use `Ops.ecoProjectRecord` to extract field from original record
- Project directly to storage type

**Final construction:**
- Use `Ops.ecoConstructRecord` with all field vars
- Pass `layout.fieldCount` and `layout.unboxedBitmap`

---

## Invariants Preserved

| Invariant | How Preserved |
|-----------|---------------|
| **Immutability** | Original record evaluated once; only used for projections, never stored as a field |
| **CGEN_018** | Empty records return original value; never construct empty record |
| **Layout correctness** | Iterate `layout.fields` in storage order; use field's `index`, `monoType`, `isUnboxed` |
| **Boxing/unboxing** | Use `coerceResultToType` for SSA type mismatches |
| **eco.construct.record** | Pass correct field_count and unboxed_bitmap from layout |

---

## Testing

### Primary Test
- `RecordUpdateTest.elm` should output:
  ```
  updated: { x = 10, y = 2 }
  original: { x = 1, y = 2 }
  ```

### Additional Test Cases to Verify
1. **Multiple field updates**: `{ r | x = 1, y = 2 }`
2. **Nested record updates**: `{ r | inner = { a = 1 } }`
3. **Update with unboxed fields**: Record with Int/Float fields
4. **Update preserving boxed fields**: Record with String/List fields
5. **Single field record update**: `{ r | only = newValue }`
6. **No actual changes**: `{ r | x = r.x }` (should still work)

### Verification Commands
```bash
# Run specific test
TEST_FILTER=RecordUpdateTest cmake --build build --target check

# Run all elm-core tests
TEST_FILTER=elm-core cmake --build build --target check

# Run compiler unit tests
cd compiler && npx elm-test-rs --fuzz 1
```

---

## Files to Modify

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Replace `generateRecordUpdate` stub with proper implementation |

---

## Dependencies

The implementation relies on existing functions:
- `Ctx.getOrCreateTypeIdForMonoType` - type table registration
- `generateExpr` - evaluate expressions
- `Ctx.freshVar` - SSA variable allocation
- `Ops.ecoProjectRecord` - field projection
- `Ops.ecoConstructRecord` - record construction
- `coerceResultToType` - boxing/unboxing coercion
- `Types.monoTypeToAbi` - type conversion

All dependencies already exist and are used elsewhere in the codebase.

---

## Success Criteria

1. `RecordUpdateTest` passes with correct output
2. All existing elm-core tests continue to pass (no regressions)
3. Compiler unit tests pass (6892 tests)
4. Generated MLIR shows proper field projections and construction
