# Remove Primitive Value Fuzzing from Compiler Tests

## Rationale

The fuzz tests outside `DeepFuzzTests.elm` fuzz **primitive values** (int, string, float, etc.) that get embedded into fixed AST structures. However, the compiler doesn't care whether an int literal is `42` or `7` - it processes them identically. The AST structure is what matters, not the concrete values.

Current fuzz tests like:
```elm
Test.fuzz Fuzz.int "Single int list" (singleIntList expectFn)
```

Create ~100 test runs that all test the same thing: "can the compiler handle a single-element int list?" The answer doesn't depend on the int's value.

**DeepFuzzTests is the exception** - it fuzzes AST structure itself using `TE.intExprFuzzer`, `S.binopChainFuzzer`, etc., which generates structurally varied expressions.

## Impact

| Metric | Before | After | Reduction |
|--------|--------|-------|-----------|
| Fuzz tests (non-Deep) | ~144 | 0 | 100% |
| Fuzz runs per invariant | ~14,400 | 0 | 100% |
| Total fuzz runs (×57 invariants) | ~820,000 | 0 | 100% |

Test nodes also decrease since `Test.fuzz` becomes `Test.test`.

## Files to Modify

All files in `/work/compiler/tests/Compiler/` that use `Test.fuzz` except `DeepFuzzTests.elm`:

1. `LiteralTests.elm` - 10 fuzz tests
2. `TupleTests.elm` - 18 fuzz tests
3. `RecordTests.elm` - 14 fuzz tests
4. `ListTests.elm` - 12 fuzz tests
5. `FunctionTests.elm` - 10 fuzz tests
6. `LetTests.elm` - 7 fuzz tests
7. `LetRecTests.elm` - 3 fuzz tests
8. `LetDestructTests.elm` - 8 fuzz tests
9. `CaseTests.elm` - 7 fuzz tests
10. `BinopTests.elm` - 14 fuzz tests
11. `OperatorTests.elm` - 5 fuzz tests
12. `HigherOrderTests.elm` - 4 fuzz tests
13. `AsPatternTests.elm` - 2 fuzz tests
14. `EdgeCaseTests.elm` - 2 fuzz tests
15. `PatternArgTests.elm` - 2 fuzz tests
16. `KernelTests.elm` - 2 fuzz tests
17. `TypeCheckFails.elm` - 1 fuzz test

## Transformation

### Before
```elm
singleIntList expectFn n =
    let
        modul =
            makeModule "testValue" (listExpr [ intExpr n ])
    in
    expectFn modul

-- In test suite:
Test.fuzz Fuzz.int ("Single int list " ++ condStr) (singleIntList expectFn)
```

### After
```elm
singleIntList expectFn () =
    let
        modul =
            makeModule "testValue" (listExpr [ intExpr 42 ])
    in
    expectFn modul

-- In test suite:
Test.test ("Single int list " ++ condStr) (singleIntList expectFn)
```

### Multi-value fuzz tests

**Before:**
```elm
pairOfInts expectFn a b =
    let
        modul =
            makeModule "testValue" (tupleExpr (intExpr a) (intExpr b))
    in
    expectFn modul

Test.fuzz2 Fuzz.int Fuzz.int ("Pair of ints " ++ condStr) (pairOfInts expectFn)
```

**After:**
```elm
pairOfInts expectFn () =
    let
        modul =
            makeModule "testValue" (tupleExpr (intExpr 1) (intExpr 2))
    in
    expectFn modul

Test.test ("Pair of ints " ++ condStr) (pairOfInts expectFn)
```

## Implementation Steps

### Step 1: Update imports in each file
Remove `Fuzz` import if it becomes unused after changes.

### Step 2: Transform each fuzz test function

For each function that takes fuzzed values:
1. Change parameter from fuzzed value to `()`
2. Replace fuzzed value usage with a representative constant
3. Use simple, readable values: `42` for int, `"hello"` for string, `3.14` for float, `'x'` for char, `True` for bool

### Step 3: Update test suite declarations

Change:
- `Test.fuzz Fuzz.int label fn` → `Test.test label fn`
- `Test.fuzz2 Fuzz.int Fuzz.int label fn` → `Test.test label fn`
- `Test.fuzz3 Fuzz.int Fuzz.int Fuzz.int label fn` → `Test.test label fn`

### Step 4: Verify no fuzz imports remain (except DeepFuzzTests)

```bash
grep -l "import Fuzz" compiler/tests/Compiler/*.elm | grep -v DeepFuzzTests
```

Should return empty.

## Representative Values to Use

| Type | Value | Rationale |
|------|-------|-----------|
| Int | `42` | Classic test value |
| Float | `3.14` | Recognizable |
| String | `"hello"` | Simple, no escapes |
| Char | `'x'` | Simple letter |
| Bool | `True` | Arbitrary choice |

For multi-value tests, use sequences:
- Two ints: `1`, `2`
- Three ints: `1`, `2`, `3`
- Mixed: `42`, `"hello"`, `3.14`

## Files to NOT Modify

- `DeepFuzzTests.elm` - Fuzzes AST structure, not just values
- `Fuzz/` directory - Contains the structural fuzzers used by DeepFuzzTests

## Verification

After changes:
1. Run `npm test` in compiler directory
2. All tests should pass
3. Test count will decrease but coverage remains equivalent
4. Test runtime should decrease significantly
