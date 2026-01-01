# E2E Test Issue 6: Case Expressions Not Compiled Correctly

## Affected Tests (~20)

- CaseIntTest.elm, CaseDefaultTest.elm, CaseDeeplyNestedTest.elm
- CaseManyBranchesTest.elm, CaseNestedTest.elm, CaseListTest.elm
- CaseStringTest.elm, CaseBoolTest.elm, CaseMaybeTest.elm
- CaseCustomTypeTest.elm, CustomTypeBasicTest.elm
- AnonymousFunctionTest.elm, RecursiveFactorialTest.elm, RecursiveFibonacciTest.elm
- And others...

---

## Root Cause Analysis

### The Bug Location

**File:** `/work/compiler/src/Compiler/Generate/CodeGen/MLIR.elm`
**Lines:** 2097-2109

```elm
-- CASE GENERATION (stub)

generateCase : Context -> Name.Name -> Name.Name -> Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> ExprResult
generateCase ctx _ _ _ _ =
    let
        ( resultVar, ctx1 ) =
            freshVar ctx

        ( ctx2, constructOp ) =
            ecoConstruct ctx1 resultVar 0 0 0 []
    in
    { ops = [ constructOp ]
    , resultVar = resultVar
    , ctx = ctx2
    }
```

### What's Wrong

The function is a **stub that ignores all inputs**:
- `_` for `label` (Name.Name) - the case expression's identifier
- `_` for `root` (Name.Name) - the variable being matched against
- `_` for `decider` (Mono.Decider Mono.MonoChoice) - the compiled decision tree
- `_` for `jumps` (List (Int, Mono.MonoExpr)) - shared branch targets

It always returns an empty `eco.construct` with tag=0, size=0, producing `Ctor0`.

### Related Stub: `generateIf`

The `if` expression generator (lines 1977-1996) is also a stub - it ignores conditions and evaluates branches sequentially:

```elm
generateIf ctx branches final =
    case branches of
        [] ->
            generateExpr ctx final

        ( _, thenBranch ) :: restBranches ->  -- Ignores condition (_)
            let
                thenResult = generateExpr ctx thenBranch
                elseResult = generateIf thenResult.ctx restBranches final
            in
            { ops = thenResult.ops ++ elseResult.ops
            , resultVar = elseResult.resultVar
            , ctx = elseResult.ctx
            }
```

---

## Architecture Understanding

### Decision Tree Compilation (Already Working)

The compiler has a complete pattern matching pipeline:

1. **DecisionTree.elm** - Compiles patterns into decision trees using Scott & Ramsey algorithm
2. **Decider type** - Represents compiled decision trees:
   ```elm
   type Decider a
       = Leaf a                                    -- Match found
       | Chain (Decider a) (Decider a)            -- if-then-else chain
       | FanOut (List (Test, Decider a)) (Decider a)  -- switch on tag
   ```
3. **MonoChoice type**:
   ```elm
   type MonoChoice
       = Inline MonoExpr   -- Evaluate expression directly
       | Jump              -- Jump to shared branch target
   ```
4. **DT.Test type** - Tests to perform:
   ```elm
   type Test
       = IsCtor IO.Canonical Name Index Int CtorOpts
       | IsCons | IsNil | IsTuple
       | IsInt Int | IsChr String | IsStr String | IsBool Bool
   ```
5. **DT.Path type** - Navigation into data structures:
   ```elm
   type Path
       = Index ZeroBased Path  -- Navigate to tuple/ctor field
       | Unbox Path            -- Unbox a single-field wrapper
       | Empty                 -- The root value
   ```

### JavaScript Implementation (Working Reference)

`/work/compiler/src/Compiler/Generate/JavaScript/Expression.elm` lines 1201-1429:

```elm
generateDecider mode parentModule label root decisionTree =
    case decisionTree of
        Opt.Leaf (Opt.Inline branch) ->
            codeToStmtList (generate mode parentModule branch)

        Opt.Leaf (Opt.Jump index) ->
            [ JS.Break (Just (JsName.makeLabel label index)) ]

        Opt.Chain testChain success failure ->
            [ JS.IfStmt
                (foldl1 (JS.ExprInfix JS.OpAnd) (List.map (generateIfTest mode root) testChain))
                (JS.Block (generateDecider mode parentModule label root success))
                (JS.Block (generateDecider mode parentModule label root failure))
            ]

        Opt.FanOut path edges fallback ->
            [ JS.Switch
                (generateCaseTest mode root path (first (head edges)))
                (foldr (\edge cases -> generateCaseBranch ... edge :: cases)
                    [ JS.Default (generateDecider ... fallback) ]
                    edges)
            ]
```

### Available MLIR Infrastructure

The MLIR backend has:
- `eco.project` - Extract fields from objects (lines 2375-2398)
- `eco.construct` - Create heap objects
- `eco.int.eq`, `eco.int.ne`, `eco.int.lt`, etc. - Integer comparisons
- `mkRegion` - Create MLIR regions with blocks
- Uses `the-sett/elm-mlir` package for MLIR AST types

**Missing:** Control flow operations like `scf.if` or `cf.cond_br`

---

## Proposed Solution

### Step 1: Add MLIR Control Flow Operations

The `the-sett/elm-mlir` package likely provides `scf.if` or similar. If not, we can use:
- `scf.if` - Structured control flow if/else
- `scf.yield` - Return values from regions

```elm
-- New helper function
scfIf : Context -> String -> String -> MlirRegion -> MlirRegion -> MlirType -> (Context, MlirOp)
scfIf ctx resultVar condition thenRegion elseRegion resultType =
    mlirOp ctx "scf.if"
        |> opBuilder.withOperands [ condition ]
        |> opBuilder.withRegions [ thenRegion, elseRegion ]
        |> opBuilder.withResults [ ( resultVar, resultType ) ]
        |> opBuilder.build
```

### Step 2: Implement Path Navigation

Translate `DT.Path` to MLIR operations:

```elm
pathToMlir : Context -> Name.Name -> DT.Path -> (List MlirOp, String, Context)
pathToMlir ctx root path =
    case path of
        DT.Empty ->
            ( [], "%" ++ Name.toString root, ctx )

        DT.Index index subPath ->
            let
                ( subOps, subVar, ctx1 ) = pathToMlir ctx root subPath
                ( resultVar, ctx2 ) = freshVar ctx1
                ( ctx3, projectOp ) = ecoProject ctx2 resultVar (Index.toInt index) False subVar ecoValue
            in
            ( subOps ++ [ projectOp ], resultVar, ctx3 )

        DT.Unbox subPath ->
            let
                ( subOps, subVar, ctx1 ) = pathToMlir ctx root subPath
                ( resultVar, ctx2 ) = freshVar ctx1
                ( ctx3, projectOp ) = ecoProject ctx2 resultVar 0 True subVar ecoValue
            in
            ( subOps ++ [ projectOp ], resultVar, ctx3 )
```

### Step 3: Implement Test Generation

Generate comparison operations for each test type:

```elm
generateTest : Context -> Name.Name -> DT.Path -> DT.Test -> (List MlirOp, String, Context)
generateTest ctx root path test =
    let
        ( pathOps, valueVar, ctx1 ) = pathToMlir ctx root path
    in
    case test of
        DT.IsCtor _ _ index _ _ ->
            -- Extract tag and compare to constructor index
            let
                ( tagVar, ctx2 ) = freshVar ctx1
                ( ctx3, getTagOp ) = ecoGetTag ctx2 tagVar valueVar
                ( resultVar, ctx4 ) = freshVar ctx3
                ( ctx5, cmpOp ) = intEq ctx4 resultVar tagVar (Index.toInt index)
            in
            ( pathOps ++ [ getTagOp, cmpOp ], resultVar, ctx5 )

        DT.IsInt expected ->
            let
                ( resultVar, ctx2 ) = freshVar ctx1
                ( ctx3, cmpOp ) = intEq ctx2 resultVar valueVar expected
            in
            ( pathOps ++ [ cmpOp ], resultVar, ctx3 )

        DT.IsBool expected ->
            if expected then
                ( pathOps, valueVar, ctx1 )  -- Value itself is the condition
            else
                -- Negate the value
                let
                    ( resultVar, ctx2 ) = freshVar ctx1
                    ( ctx3, notOp ) = intNot ctx2 resultVar valueVar
                in
                ( pathOps ++ [ notOp ], resultVar, ctx3 )

        -- ... other cases
```

### Step 4: Implement Decider Traversal

```elm
generateDecider : Context -> Name.Name -> Name.Name -> Mono.Decider Mono.MonoChoice -> MonoType -> ExprResult
generateDecider ctx label root decider resultType =
    case decider of
        Mono.Leaf (Mono.Inline expr) ->
            generateExpr ctx expr

        Mono.Leaf Mono.Jump ->
            -- Generate jump to labeled block (needs special handling)
            generateJump ctx label

        Mono.Chain success failure ->
            -- Chain has implicit test in success branch
            -- Generate if-then-else
            let
                successResult = generateDecider ctx label root success resultType
                failureResult = generateDecider successResult.ctx label root failure resultType
                ( resultVar, ctx1 ) = freshVar failureResult.ctx

                thenRegion = mkRegion [] successResult.ops (scfYield successResult.resultVar)
                elseRegion = mkRegion [] failureResult.ops (scfYield failureResult.resultVar)

                ( ctx2, ifOp ) = scfIf ctx1 resultVar ??? thenRegion elseRegion (monoTypeToMlir resultType)
            in
            { ops = [ ifOp ], resultVar = resultVar, ctx = ctx2 }

        Mono.FanOut edges fallback ->
            -- Generate switch-like dispatch
            generateFanOut ctx label root edges fallback resultType
```

### Step 5: Handle Jump Targets

The `jumps` parameter contains shared branch expressions. These need to be:
1. Generated as separate labeled blocks
2. Accessed via `eco.jump` or similar for the `Jump` choice

---

## Questions Resolved

| Question | Answer |
|----------|--------|
| Where is the bug? | `MLIR.elm:2097-2109`, `generateCase` is a stub |
| What IR is used? | `Mono.Decider Mono.MonoChoice` with `DT.Test` and `DT.Path` |
| Is this missing or broken? | **Missing** - stub placeholder, never implemented |
| What eco ops exist? | `eco.project` for field access, but no tag extraction or control flow |
| How are ctors represented? | Tag field (integer), accessed via `eco.project` or needs `eco.getTag` |

## Questions Still Open

1. **Does `the-sett/elm-mlir` support `scf.if` or `cf.cond_br`?**
   - Need to check the package API
   - May need to add new ops to the MLIR builder

2. **How to extract constructor tags?**
   - Need `eco.getTag` operation, or use `eco.project` with special index
   - Check how runtime represents tags

3. **How to handle jumps (shared branches)?**
   - MLIR doesn't have `goto`
   - Options: duplicate code, use functions, or use `scf.while` with state

4. **What's the result type for case expressions?**
   - The signature has no return type info
   - May need to thread through from caller

---

## Implementation Steps

1. **Examine `the-sett/elm-mlir`** to understand available ops
2. **Add `eco.getTag`** operation (or use existing mechanism)
3. **Implement `pathToMlir`** for path navigation
4. **Implement `generateTest`** for each test type
5. **Implement `generateDecider`** for tree traversal
6. **Handle jump targets** in `generateCase`
7. **Also fix `generateIf`** which has the same issue

## Files to Modify

- `/work/compiler/src/Compiler/Generate/CodeGen/MLIR.elm` - Main implementation
- Possibly eco dialect in runtime if `eco.getTag` doesn't exist

## Estimated Complexity

**High** - This is a substantial implementation:
- ~200-400 lines of new Elm code
- Need to understand MLIR control flow semantics
- Need to handle all test types and path navigation
- Jump targets add complexity

## Priority

**Critical** - Case expressions are fundamental. Most Elm programs won't work without them.
