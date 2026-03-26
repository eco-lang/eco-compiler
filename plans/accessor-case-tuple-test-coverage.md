# Plan: Expand Test Coverage for Accessor-via-Case and Projection Bitmap Invariants

## Motivation

The `LetDestructFuncTupleTest` E2E failure exposed two gaps in test coverage:

1. **REP_BOUNDARY_001 test (`ProjectionLayoutBitmap.elm`)** only checks `eco.project.custom` — it does not
   verify `eco.project.record`, `eco.project.tuple2`, or `eco.project.tuple3`.

2. **MONO_015 test (`SpecializeAccessorCases.elm`)** only covers accessors passed directly to higher-order
   functions like `List.map`. It does not cover accessors selected dynamically via `case` expressions or
   stored in intermediate data structures like tuples.

The goal is to expand both test suites so that the underlying monomorphization bug (accessor `.a` getting
return type `!eco.value` instead of `i64` when selected via case and stored in a tuple) is caught by
existing invariant checking infrastructure.

## Step 1: Extend ProjectionLayoutBitmap to cover record and tuple projections

**File:** `compiler/tests/TestLogic/Generate/CodeGen/ProjectionLayoutBitmap.elm`

Currently line 62 only searches for `"eco.project.custom"`. Extend `checkProjectionLayoutBitmap` to also
check:
- `eco.project.record` — look up `RecordLayout` from `monoGraph.recordLayouts` and verify field result
  types match the record's `unboxed_bitmap`.
- `eco.project.tuple2` — look up `TupleLayout` and verify field result types match tuple `unboxed_bitmap`.
- `eco.project.tuple3` — same as tuple2.

For each projection op:
- Extract the `index` attribute (field index being projected).
- Look up the layout's `unboxed_bitmap`.
- If bit `index` is set in the bitmap, result type must be a primitive (i64, f64, i16).
- If bit `index` is clear, result type must be `!eco.value`.

**Challenge:** Record and tuple projections don't carry a `tag` attribute like custom projections. The
layout must be inferred from the operand's defining op or from the MonoGraph. This may require:
- Walking the use-def chain to find the `eco.construct.record`/`eco.construct.tuple2` that produced the
  operand, and reading its `unboxed_bitmap` attribute directly.
- Or checking ALL record layouts in the MonoGraph that have the matching field count, similar to how the
  custom projection checker tries all layouts for a given tag.

The simpler approach: for `eco.project.record`, trace the source operand to its `eco.construct.record` (if
visible in the same function) and read the `unboxed_bitmap` from the construct op. This catches the common
case. For cross-function operands (function arguments), we can't easily determine the bitmap, so skip those.

An even simpler first pass: just check that `eco.project.record` ops whose enclosing function has a
corresponding `eco.construct.record` with a known bitmap are consistent. This would catch the accessor bug
because the record is constructed in the caller and the accessor projects from it.

## Step 2: Add case-selected accessor test cases to SpecializeAccessorCases.elm

**File:** `compiler/tests/SourceIR/SpecializeAccessorCases.elm`

Add a new section `accessorViaCaseCases` and wire it into `testCases`. Each case uses SourceBuilder to
construct an AST.

### Case 2a: Accessor selected via case, stored in tuple (direct reproduction)

Derived from `LetDestructFuncTupleTest.elm`:

```elm
type Loc = First | Second

choose loc rec =
    let
        ( getter, setter ) =
            case loc of
                First -> ( .a, \x m -> { m | a = x } )
                Second -> ( .b, \x m -> { m | b = x } )
    in
    ( getter rec, setter 99 rec )

testValue = choose First { a = 10, b = 20 }
```

Build this with SourceBuilder using `caseExpr`, `tupleExpr`, `accessorExpr`, `lambdaExpr`, `updateExpr`.
The record has `{ a : Int, b : Int }` — both Int fields. This is the exact pattern that triggers
MONO_015 violation: the accessor `.a` must be specialized knowing that `a : Int`.

### Case 2b: Accessor selected via case, applied immediately (no tuple)

```elm
type Which = UseA | UseB

getField which rec =
    case which of
        UseA -> .a rec
        UseB -> .b rec

testValue = getField UseA { a = 42, b = 0 }
```

This tests whether an accessor inside a case branch (but not stored in a tuple) gets correct type
resolution. Simpler variant — may or may not trigger the same bug.

### Case 2c: Accessor selected via case, passed to higher-order function

```elm
type SortBy = ByName | ByAge

sortKey sortBy =
    case sortBy of
        ByName -> .name
        ByAge -> .age

testValue = List.map (sortKey ByName) [ { name = "Alice", age = 30 } ]
```

This tests whether an accessor returned from a case expression and then passed to `List.map` gets the
correct specialization. The accessor goes through: case branch -> function return -> HOF argument.

### Case 2d: Accessor in case with mixed field types (Int and String)

```elm
type Field = IntField | StrField

pickAccessor field =
    case field of
        IntField -> .count
        StrField -> .label

testValue =
    let
        rec = { count = 5, label = "hello" }
        f = pickAccessor IntField
    in
    f rec
```

This specifically tests the mismatch scenario: `.count` returns Int (should be i64) while `.label`
returns String (should be !eco.value). The case branches return accessors with different concrete return
types.

### Case 2e: Accessor stored in a record field (not just tuple)

```elm
type alias Ops =
    { getter : { a : Int, b : Int } -> Int
    , setter : Int -> { a : Int, b : Int } -> { a : Int, b : Int }
    }

makeOps =
    { getter = .a
    , setter = \x m -> { m | a = x }
    }

testValue = makeOps.getter { a = 10, b = 20 }
```

This checks whether storing an accessor in a record field (rather than a tuple) also gets correct
specialization.

### Case 2f: Accessor selected via nested case

```elm
type Outer = OutA | OutB
type Inner = InX | InY

pickAccessor outer inner =
    case outer of
        OutA ->
            case inner of
                InX -> .x
                InY -> .y
        OutB -> .z

testValue = pickAccessor OutA InX { x = 1, y = 2, z = 3 }
```

Nested case selection of accessors.

## Step 3: Wire new test cases into existing test suites

- Add `accessorViaCaseCases` to the `testCases` function in `SpecializeAccessorCases.elm`.
- The existing `ProjectionLayoutBitmapTest.elm` uses `StandardTestSuites.expectSuite` which runs against
  all standard source IR modules. The new accessor cases in Step 2 will automatically be picked up if
  they are added to the standard suite. If not, add them explicitly.
- Verify that the new test cases FAIL with the current monomorphization bug (they should report violations
  from the projection bitmap check or from the monomorphization expectation).

## Step 4: Verify

Run:
```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

Expect:
- The new MONO_015 cases (2a-2f) should fail because the accessor gets the wrong type.
- The extended REP_BOUNDARY_001 check should catch projection/bitmap mismatches on record projections.
- All previously passing tests should still pass.

## Files to modify

| File | Change |
|------|--------|
| `compiler/tests/TestLogic/Generate/CodeGen/ProjectionLayoutBitmap.elm` | Add record/tuple projection checking |
| `compiler/tests/SourceIR/SpecializeAccessorCases.elm` | Add case-selected accessor test cases (2a-2f) |
| `compiler/tests/TestLogic/Generate/CodeGen/ProjectionLayoutBitmapTest.elm` | May need to add explicit test cases if not auto-picked-up |

## Notes

- This plan is test-coverage-only. It does not fix the monomorphization bug.
- The new tests should expose the bug so that the fix can be validated against them.
- Cases 2b and 2e may pass even with the current bug (they don't go through the same code path). Include
  them anyway for coverage.
