# Plan: Ensure All SourceIR Test Cases Have Concrete testValue

## Problem

The MONO_021 invariant test (`NoCEcoValueInUserFunctionsTest`) runs all StandardTestSuites
through a check that no user-defined function retains `MVar` with `CEcoValue` after
monomorphization. Many test cases fail because:

1. **No `testValue` def**: `wrapWithMain` picks the first def as entry point. If it's
   polymorphic and never called at a concrete type, the monomorphizer produces CEcoValue MVars.
2. **`testValue` is polymorphic**: testValue IS a lambda/accessor that's never applied,
   so it retains CEcoValue.

**New standard**: Every SourceIR test module MUST have a `testValue` definition that is a
concrete, fully-applied expression. This is now the standard format for all SourceIR tests.

## Decisions (all resolved)

1. **Stubs**: Don't need real implementations. We just need to compile against them.
   CGEN_044 regressions from calling through stubs are acceptable failures for now.
2. **Group E (cycle/phantom)**: Leave broken for now, come back later.
3. **Monomorphic tests**: Add testValue to EVERY test for consistency — this is the standard.
4. **Custom type patterns**: Construct values using `ctorExpr`.
5. **Regressions**: Other tests may regress due to `wrapWithMain` now picking testValue.
   Let them fail — we will fix later.
6. **Batch**: Do them ALL in one pass.
7. **wrapWithMain**: Remove the "first def" fallback. Only wrap `testValue`. If no
   `testValue` exists, crash. This enforces the new standard at the pipeline level.
8. **Concrete arg types**: Vary types across type variables for stronger coverage.
   Use `a=Int, b=String, c=Float` (or similar) rather than all-Int.
9. **Multi-def testValue scope**: testValue should ensure ALL defs in the module are
   reachable. If `f` calls `g` calls `h`, then `testValue = f 1` suffices. If defs
   are independent, testValue should reference all of them (e.g., via a tuple or let).

## Implementation Steps

### Step 0: Harden wrapWithMain in TestPipeline.elm

Change `wrapWithMain` to ONLY look for `testValue`:
- Remove the fallback that picks the first def when `testValue` is absent.
- If no `testValue` def exists in the module, crash with a clear error message
  like `"Test module must define 'testValue' — see SourceIR test standard"`.
- Remove the `entryName` logic that tries `testValue` then falls back to
  `List.head valueNames`.
- The new logic: find `testValue` in `valueNames`. If absent, crash. If present,
  bind `_tv = testValue`.

Current code (TestPipeline.elm ~460-477):
```elm
entryName =
    if List.member "testValue" valueNames then
        Just "testValue"
    else
        List.head valueNames

defs =
    case entryName of
        Just name -> [ Src.Define ... (varRef name) ... ]
        Nothing -> []
```

New code:
```elm
defs =
    if List.member "testValue" valueNames then
        [ Src.Define ... (varRef "testValue") ... ]
    else
        Debug.todo "Test module must define 'testValue' — see SourceIR test standard"
```

### Step 1: PatternArgCases.elm — 28 cases

All use `makeModuleWithDefs` or `makeModuleWithTypedDefsUnionsAliases`.
Add `testValue` as last def calling the polymorphic function(s) at concrete types.
Vary types across type variables: `a=Int, b=String`.

| Case | Defs | testValue |
|------|------|-----------|
| twoVariablePatterns | `first x y = x` | `testValue = first 1 "a"` |
| threeVariablePatterns | `pick x y z = y` | `testValue = pick 1 "a" 2.0` |
| variablePatternReturningTuple | `pair x y = (x,y)` | `testValue = pair 1 "a"` |
| variablePatternReturningList | `wrap x = [x]` | `testValue = wrap 1` |
| singleWildcardPattern | `f _ = 42` | `testValue = f 1` |
| wildcardWithVariable | `f _ x = x` | `testValue = f 1 "a"` |
| multipleWildcards | `f _ _ = 42` | `testValue = f 1 "a"` |
| tuple2Pattern | `f (x,y) = x` | `testValue = f (1, "a")` |
| tuple3Pattern | `f (x,y,z) = y` | `testValue = f (1, "a", 2.0)` |
| tuplePatternWithWildcard | `f (x,_) = x` | `testValue = f (1, "a")` |
| nestedTuplePattern | `f ((a,b),c) = a` | `testValue = f ((1, "a"), 2.0)` |
| multipleTuplePatternArgs | two tuple-pattern args | `testValue = f (1, "a") (2, "b")` |
| singleFieldRecordPattern | `f {x} = x` | `testValue = f {x=1}` |
| multiFieldRecordPattern | `f {x,y} = x` | `testValue = f {x=1, y="a"}` |
| recordPatternWithManyFields | `f {a,b,c,d} = a` | `testValue = f {a=1, b="a", c=2.0, d=3}` |
| multipleRecordPatternArgs | two record-pattern args | `testValue = f {x=1} {y="a"}` |
| recordPatternWithVariable | record + var arg | `testValue = f {x=1} "a"` |
| consPattern | `head (x::_) = x` | `testValue = head [1]` |
| fixedListPattern | `f [a,b] = a` | `testValue = f [1, 2]` |
| nestedConsPattern | `f (x::y::_) = x` | `testValue = f [1, 2, 3]` |
| intLiteralPattern | `f 0 = True` | `testValue = f 0` |
| stringLiteralPattern | `f "hello" = True` | `testValue = f "hello"` |
| unitPattern | `f () = 42` | `testValue = f ()` |
| multipleLiteralPatterns | `f 0 "x" = True` | `testValue = f 0 "x"` |
| deeplyNestedTuplePattern | deep nested tuples | match shape, vary types |
| mixedNestedPatterns | mixed patterns | match shape, vary types |
| tripleNestedPatterns | triple nesting | match shape, vary types |
| nestedWithWildcards | nested with wildcards | match shape, vary types |
| fiveArgsWithMixedPatterns | 5 args | provide 5 concrete args, varied types |
| allSamePatternType | all same pattern | match shape, vary types |
| alternatingPatterns | alternating | match shape, vary types |
| customTypePatternInFunctionArg | custom type | `testValue = f (Ctor arg)` using `ctorExpr` |
| customTypePatternMultipleExtractors | custom type | `testValue = f (Ctor args)` using `ctorExpr` |

### Step 2: AsPatternCases.elm — 16 cases

All use `makeModuleWithDefs`. Add `testValue` calling the as-pattern function.
Vary types: `a=Int, b=String`.

| Case | Def | testValue |
|------|-----|-----------|
| aliasOnWildcard | `f (_ as y) = y` | `testValue = f 1` |
| multipleAliases | `f (x as a) (y as b) = (a,b)` | `testValue = f 1 "a"` |
| aliasOn2Tuple | `f ((a,b) as t) = t` | `testValue = f (1, "a")` |
| aliasOn3Tuple | `f ((a,b,c) as t) = t` | `testValue = f (1, "a", 2.0)` |
| nestedAliasInTuple | nested alias in tuple | match shape, vary types |
| aliasOnNestedTuple | nested tuple alias | match shape, vary types |
| aliasOnRecordPattern | `f ({x} as r) = ...` | `testValue = f {x=1}` |
| multipleRecordAliases | multiple record aliases | match shape, vary types |
| aliasOnRecordWithManyFields | many-field record alias | match shape, vary types |
| aliasOnConsPattern | `f ((x::xs) as l) = ...` | `testValue = f [1, 2]` |
| aliasOnFixedListPattern | `f ([a,b] as l) = ...` | `testValue = f [1, 2]` |
| nestedAliasInList | nested alias in list | match shape, vary types |
| aliasOnNestedCons | nested cons alias | match shape, vary types |
| multipleLevelsOfAlias | multiple levels | match shape, vary types |
| aliasInDeeplyNestedStructure | deep nesting | match shape, vary types |
| mixedNestedAliases | mixed | match shape, vary types |

### Step 3: AnnotatedCases.elm — 11 cases

All use `makeModuleWithTypedDefs`. Need typed testValue def with `tipe` field.
Vary types: `a=Int, b=String, c=Float`.

| Case | Function | testValue type | testValue body |
|------|----------|---------------|----------------|
| boolIdentity | `boolId : Bool -> Bool` | `tType "Bool" []` | `boolId True` |
| constAnnotated | `const : a -> b -> a` | `tType "Int" []` | `const 1 "a"` |
| applyWithUsage | `apply : (a->b) -> a -> b` | verify existing | may already have concrete usage |
| flipAnnotated | `flip : (a->b->c) -> b -> a -> c` | needs fn arg | see implementation |
| composeWithUsage | `compose` | verify existing | may already have concrete usage |
| onAnnotated | `on` | needs fn args | see implementation |
| pairAnnotated | `pair : a -> b -> (a,b)` | `tTuple [tInt, tStr]` | `pair 1 "a"` |
| wrapInTupleAnnotated | `wrapInTuple : a -> (a,a)` | `tTuple [tInt, tInt]` | `wrapInTuple 1` |
| constTupleAnnotated | `constTuple : a -> b -> (a,a)` | `tTuple [tInt, tInt]` | `constTuple 1 "a"` |
| makeRecordAnnotated | `makeRecord : a -> {x:a}` | `tRecord` | `makeRecord 1` |
| makeRecordSameTypeAnnotated | similar | similar | similar |
| nestTupleAnnotated | nested tuple | match shape | match shape |

### Step 4: MultiDefCases.elm — 15 cases

All use `makeModuleWithDefs`. Add `testValue` as last def.
For multi-def modules: testValue must ensure ALL defs are reachable.
If defs call each other, calling the root suffices.
If defs are independent, use a tuple: `testValue = (f 1, g 2, h 3 4)`.

| Case | Defs | testValue |
|------|------|-----------|
| twoIdenticalStructureDefinitions | `a = 1+2; b = 1+2` | `testValue = (a, b)` |
| threeSimpleValueDefinitions | `a=1; b=True; c="x"` | `testValue = (a, b, c)` |
| multipleFunctionsSameArity | `f x=x; g x=x+1` | `testValue = (f 1, g 2)` |
| multipleFunctionsDifferentArities | `f x=x; g x y=x+y` | `testValue = (f 1, g 2 3)` |
| functionsCallEachOther | `f x=g x; g x=x+1` | `testValue = f 1` (g reachable via f) |
| multipleDefsWithLet | let-bound defs | `testValue` refs all top-level defs |
| multipleDefsWithCase | case defs | `testValue` refs all top-level defs |
| multipleDefsWithIf | `a=if..; b=if..; c=if..` | `testValue = (a, b, c)` |
| multipleDefsWithRecords | `a={x=1}; b=...; c=...` | `testValue = (a, b, c)` |
| multipleDefsWithBinops | `a=1+2; b=3*4; c=5-6` | `testValue = (a, b, c)` |
| largeModuleManyDefs | 5 defs | `testValue = (a, b, c, d, e)` |
| nestedLetsMultipleDefs | nested let defs | `testValue` refs all top-level defs |
| tuplePatternMultipleDefs | `f (a,b)=a; g (x,y,z)=x+y+z` | `testValue = (f (1,"a"), g (1,2,3))` |
| listPatternMultipleDefs | `f [a]=a; g [x,y]=x+y` | `testValue = (f [1], g [2, 3])` |
| recordPatternMultipleDefs | `f {x}=x; g {a,b}=a+b` | `testValue = (f {x=1}, g {a=2, b=3})` |
| mixedExpressionsAndPatterns | mixed | `testValue` refs all top-level defs |

### Step 5: FunctionCases.elm — 9 cases (1 Group A + 8 Group C)

Group A (no testValue):
- `topLevelFunctionWithPatterns` — add testValue

Group C (polymorphic testValue → rename to testFn):
Switch from `makeModule "testValue"` to `makeModuleWithDefs "Test"`.
Vary types: `a=Int, b=String`.

| Case | testFn | testValue |
|------|--------|-----------|
| twoArgumentLambda | `testFn = \x y -> x` | `testValue = testFn 1 "a"` |
| lambdaReturningTuple | `testFn = \x y -> (x,y)` | `testValue = testFn 1 "a"` |
| lambdaWithWildcard | `testFn = \_ -> 42` | `testValue = testFn 1` |
| lambdaReturningLambda | `testFn = \x -> \y -> x` | `testValue = testFn 1 "a"` |
| lambdaInsideLetInsideLambda | rename + apply | match shape, vary types |
| lambdaWithTuplePattern | `testFn = \(x,y) -> x` | `testValue = testFn (1, "a")` |
| lambdaWithRecordPattern | `testFn = \{x} -> x` | `testValue = testFn {x=1}` |
| lambdaWithMixedPatterns | rename + apply | match shape, vary types |

### Step 6: RecordCases.elm — 1 case (Group C)

- `multipleAccessorFunctions` — already changed to `testFn`/`testValue` in earlier work.
  Verify the existing change uses varied types.

### Step 7: CaseCases.elm — 3 cases (2 Group A + 1 Group C)

Group A:
- `caseOnCustomTypeMultipleConstructors` — add testValue with concrete custom type value
- `caseOnCustomTypePayloadExtraction` — add testValue with concrete custom type value

Group C:
- `stringChainWithStringEquality` — rename to testFn, `testValue = testFn "hello"`

### Step 8: EdgeCaseCases.elm — 1 case

- `multipleDefinitionsWithVariousPatterns` — add testValue referencing all defs

### Step 9: ListCases.elm — 3 cases

- `testIndexedMap` — add testValue calling `indexedMap` concretely
- `testFilter` — add testValue calling `filter` concretely
- `testFilterMap` — add testValue calling `filterMap` concretely

These call through stubs. Accept CGEN_044 failures for now.

### Step 10: ArrayCases.elm — 5 cases

- `pushTest` — add testValue calling `push` concretely
- `sliceTest` — add testValue calling `slice` concretely
- `fromListHelpTest` — add testValue
- `appendTest` — add testValue
- `sliceLeftTest` — add testValue

These call through stubs. Accept CGEN_044 failures for now.

### Step 11: TypeCheckFailsCases.elm — 1 case

- `aliasEverywhere` — add testValue

### Step 12: Import fixes

For each modified file, add any missing SourceBuilder imports:
- `callExpr`, `intExpr`, `strExpr`, `boolExpr`, `floatExpr`
- `varExpr`, `recordExpr`, `tupleExpr`, `tuple3Expr`, `ctorExpr`
- `makeModuleWithDefs` (when switching from `makeModule`)
- `unitExpr` (for unit args)

### Step 13: Run full test suite

```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

Report results. Expect:
- MONO_021 failures only for Group E (cycle + phantom type var)
- Possible CGEN_044 failures from stub-calling testValues
- Possible other regressions from wrapWithMain entry point change
- All are acceptable to leave broken for now

## Assumptions

1. **`applyWithUsage` / `composeWithUsage`**: Will verify during implementation whether
   these already have concrete usage or need testValue added.

2. **SourceBuilder helpers**: `callExpr`, `intExpr`, `strExpr`, `floatExpr`, `boolExpr`,
   `tupleExpr`, `tuple3Expr`, `recordExpr`, `ctorExpr`, `unitExpr`, `varExpr`,
   `listExpr`, `makeModuleWithDefs` all exist in SourceBuilder. Will verify any
   missing ones during implementation.

3. **List element types**: List patterns like `f [a] = a` constrain all elements to the
   same type — `testValue = f [1]` is sufficient (can't vary types within a list).

4. **Higher-order function args**: For functions like `flip : (a->b->c) -> b -> a -> c`,
   the testValue needs to pass a concrete function. Will use simple lambdas like
   `\x y -> x + y` or built-in operators.
