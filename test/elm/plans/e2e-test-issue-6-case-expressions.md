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

The `if` expression generator (lines 1977-1996) is also a stub - it ignores conditions and evaluates branches sequentially.

---

## Design Reference

**Primary design document:** `/work/design_docs/mlir-case-codegen.md`

This plan follows that design exactly.

---

## Key Design Decisions

### 1. Tail Position Assumption

Case expressions are treated as appearing in **tail position**. Each branch ends with `eco.return` or `eco.jump`. The control flow exits the function; we don't need to "return a value" from the case itself.

**Non-tail cases are a future extension** - they would require wrapping the case in `eco.joinpoint` to carry results to a continuation.

### 2. Dummy Result Pattern

After control flow ops (`eco.case`, `eco.jump`), return a **dummy `Ctor0`** for the `ExprResult`. The real control exits via `eco.return`/`eco.jump` inside the case branches. This matches the existing `generateTailCall` pattern.

### 3. Result Type Threading

Compute `resultMonoType` from the case expression, convert to `resultMlirType` via `monoTypeToMlir`, and thread through all codegen. The `ecoCase` and `ecoJoinpoint` builders take `resultTypes` as a parameter.

### 4. Only Eco Dialect Ops

Use **only eco dialect ops** for control flow:
- `eco.case` - pattern matching control flow
- `eco.joinpoint` - shared branch targets
- `eco.jump` - jump to joinpoint
- `eco.return` - function return

Do **NOT** use `scf` dialect operations directly.

### 5. IsCtor Tests via eco.case

For constructor tests (`IsCtor`), rely on `eco.case` for dispatch. Don't emit standalone comparisons. Only use `generateTest` for boolean/primitive tests in Chain nodes.

### 6. Context/Type Consistency

- If the eco dialect already enforces `result_types` for `eco.case`/`eco.joinpoint`:
  - Fill `resultTypes` in `ecoCase` and `ecoJoinpoint` using `monoTypeToMlir`
- Otherwise, you can omit `result_types` (pass `[]`) and add them later via an eco→eco inference pass

---

## Eco Dialect Control Flow Operations

### 1. `eco.case` - Pattern Match on Constructor Tag

```mlir
eco.case %scrutinee [tag0, tag1, tag2] {
  // Tag 0 alternative - must end with eco.return or eco.jump
  %val0 = arith.constant 0 : i64
  eco.return
}, {
  // Tag 1 alternative
  %val1 = arith.constant 1 : i64
  eco.return
}, {
  // Tag 2 alternative
  %val2 = arith.constant 2 : i64
  eco.return
}
```

### 2. `eco.joinpoint` - Shared Branch Target

```mlir
eco.joinpoint 0(%arg1: i64, %arg2: i64) {
  // Body executes when jumped to
  %sum = eco.int.add %arg1, %arg2 : i64
  eco.return
} continuation {
  // Continuation - code that may jump to the joinpoint
  eco.jump 0(%val1, %val2 : i64, i64)
}
```

### 3. `eco.jump` - Jump to Joinpoint

```mlir
eco.jump 0(%arg1, %arg2 : i64, i64)
```

### 4. `eco.project` - Extract Field from Constructor

```mlir
%field = eco.project %constructor[0] : !eco.value -> !eco.value
```

### 5. `eco.return` - Terminate Branch

```mlir
eco.return
```

---

## Implementation Plan

### Step 1: Add New Helper Functions

#### 1.1 `ecoCase` Builder

```elm
ecoCase :
    Context
    -> String           -- scrutinee SSA name (e.g. "%root")
    -> List Int         -- tags or branch discriminator values
    -> List MlirRegion  -- one region per alternative
    -> List MlirType    -- result types (may be [])
    -> ( Context, MlirOp )
ecoCase ctx scrutinee tags regions resultTypes =
    let
        attrsBase =
            Dict.fromList
                [ ( "tags", I64ArrayAttr (List.map IntAttr tags) ) ]

        attrs =
            if List.isEmpty resultTypes then
                attrsBase
            else
                Dict.insert "result_types"
                    (ArrayAttr (List.map TypeAttr resultTypes))
                    attrsBase
    in
    mlirOp ctx "eco.case"
        |> opBuilder.withOperands [ scrutinee ]
        |> opBuilder.withRegions regions
        |> opBuilder.withAttrs attrs
        |> opBuilder.build
```

#### 1.2 `ecoJoinpoint` Builder

```elm
ecoJoinpoint :
    Context
    -> Int                        -- joinpoint id (from jump index)
    -> List ( String, MlirType )  -- parameter types, usually []
    -> MlirRegion                 -- jpRegion: body
    -> MlirRegion                 -- continuation region
    -> List MlirType              -- result types
    -> ( Context, MlirOp )
ecoJoinpoint ctx id params jpRegion contRegion resultTypes =
    let
        attrsBase =
            Dict.fromList [ ( "id", IntAttr id ) ]

        attrs =
            if List.isEmpty resultTypes then
                attrsBase
            else
                Dict.insert "result_types"
                    (ArrayAttr (List.map TypeAttr resultTypes))
                    attrsBase
    in
    mlirOp ctx "eco.joinpoint"
        |> opBuilder.withRegions [ mkRegion params [] jpRegion, contRegion ]
        |> opBuilder.withAttrs attrs
        |> opBuilder.build
```

#### 1.3 Factor Out `ecoJump` Helper

Extract the `eco.jump` building code from `generateTailCall` into a reusable helper:

```elm
ecoJump :
    Context
    -> List String              -- operand SSA names
    -> Int                      -- joinpoint id
    -> List MlirType            -- operand types
    -> ( Context, MlirOp )
ecoJump ctx operands id operandTypes =
    let
        jumpAttrs =
            Dict.fromList
                [ ( "target", IntAttr id )
                , ( "_operand_types", ArrayAttr (List.map TypeAttr operandTypes) )
                ]
    in
    mlirOp ctx "eco.jump"
        |> opBuilder.withOperands operands
        |> opBuilder.withAttrs jumpAttrs
        |> opBuilder.isTerminator True
        |> opBuilder.build
```

Then update `generateTailCall` to use this helper.

#### 1.4 `lastOpMustBeReturn` Helper

Ensure regions end with `eco.return`:

```elm
lastOpMustBeReturn : ExprResult -> MlirOp
lastOpMustBeReturn result =
    -- Verify or extract the last op which should be eco.return
    -- Used when building regions for eco.case
    case List.reverse result.ops of
        lastOp :: _ ->
            lastOp  -- Should be eco.return
        [] ->
            -- Should not happen; generate a default return
            ...
```

#### 1.5 `dummyReturnOp` Helper

Generate a dummy return for continuation regions:

```elm
dummyReturnOp : MlirType -> MlirOp
dummyReturnOp resultTy =
    -- Create an eco.return op for continuation regions
    ...
```

#### 1.6 `generateDTPath` - Decision Tree Path Navigation

**Note:** `generateMonoPath` already exists for `Mono.MonoPath`. This is a separate helper for `DT.Path`:

```elm
generateDTPath : Context -> Name.Name -> DT.Path -> ( List MlirOp, String, Context )
generateDTPath ctx root dtPath =
    case dtPath of
        DT.Empty ->
            ( [], "%" ++ Name.toString root, ctx )

        DT.Index index sub ->
            let
                ( opsSub, varSub, ctx1 ) =
                    generateDTPath ctx root sub

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, projOp ) =
                    ecoProject ctx2 resultVar (Index.toInt index) False varSub ecoValue
            in
            ( opsSub ++ [ projOp ], resultVar, ctx3 )

        DT.Unbox sub ->
            let
                ( opsSub, varSub, ctx1 ) =
                    generateDTPath ctx root sub

                ( resultVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, projOp ) =
                    ecoProject ctx2 resultVar 0 True varSub ecoValue
            in
            ( opsSub ++ [ projOp ], resultVar, ctx3 )
```

#### 1.7 `generateTest` - Test to Boolean

For Chain nodes, generate boolean SSA values for tests:

```elm
generateTest : Context -> Name.Name -> ( DT.Path, DT.Test ) -> ( List MlirOp, String, Context )
generateTest ctx root ( path, test ) =
    let
        ( pathOps, valVar, ctx1 ) =
            generateDTPath ctx root path
    in
    case test of
        DT.IsCtor _home _name index _ ctorOpts ->
            -- We'll rely on eco.case for ctor dispatch; we do *not* emit a compare here.
            -- For Chain test chains, we will only use IsBool / primitives.
            ( pathOps, valVar, ctx1 )

        DT.IsBool expected ->
            -- valVar is already a Bool; maybe invert it.
            if expected then
                ( pathOps, valVar, ctx1 )
            else
                let
                    ( resVar, ctx2 ) =
                        freshVar ctx1

                    ( ctx3, notOp ) =
                        ecoBoolNot ctx2 resVar valVar
                in
                ( pathOps ++ [ notOp ], resVar, ctx3 )

        DT.IsInt i ->
            let
                ( constVar, ctx2 ) =
                    freshVar ctx1

                ( ctx3, constOp ) =
                    arithConstantInt ctx2 constVar i

                ( resVar, ctx4 ) =
                    freshVar ctx3

                ( ctx5, cmpOp ) =
                    ecoIntEq ctx4 resVar valVar constVar
            in
            ( pathOps ++ [ constOp, cmpOp ], resVar, ctx5 )

        DT.IsCons ->
            -- Cons/nil tests will typically be done via eco.case on tags; for
            -- Chain, you can treat this as Bool: isNonEmptyList(valVar).
            ...

        DT.IsNil ->
            ...

        -- Similarly define for IsChr, IsStr using eco.char.eq / eco.string.eq if present.
```

#### 1.8 `testToTagInt` - Extract Tag from Test

```elm
testToTagInt : DT.Test -> ( DT.Test, Mono.Decider Mono.MonoChoice ) -> Int
testToTagInt exampleTest ( test, _ ) =
    case test of
        DT.IsCtor _ _ index _ _ ->
            Index.toInt index

        DT.IsInt i ->
            i

        DT.IsBool b ->
            if b then 1 else 0

        -- For other tests, assign sequential integers per decision site
        ...
```

#### 1.9 `extractPathAndTest` - Get Path from FanOut Edge

```elm
extractPathAndTest : ( DT.Test, Mono.Decider Mono.MonoChoice ) -> ( DT.Path, DT.Test )
extractPathAndTest ( test, _ ) =
    -- Extract the path from the test
    -- Note: You may need to extend FanOut to carry DT.Path as in Optimized.Decider,
    -- or recover it via separate data.
    case test of
        DT.IsCtor _ _ _ _ _ ->
            ( DT.Empty, test )  -- Path may be implicit or need extension

        ...
```

### Step 2: Implement `generateCase`

Replace the stub with:

```elm
generateCase :
    Context
    -> Name.Name                        -- label (for jumps; may be unused in MLIR)
    -> Name.Name                        -- root variable name
    -> Mono.Decider Mono.MonoChoice
    -> List ( Int, Mono.MonoExpr )      -- shared branch bodies
    -> ExprResult
generateCase ctx _label root decider jumps =
    let
        -- 1. Compute result type of case expression
        resultMonoType : Mono.MonoType
        resultMonoType =
            Mono.typeOf (Mono.MonoCase root root decider jumps Mono.MUnit)  -- or a helper

        resultMlirType : MlirType
        resultMlirType =
            monoTypeToMlir resultMonoType

        -- 2. Emit joinpoints for shared branches
        ( ctx1, joinpointOps ) =
            generateSharedJoinpoints ctx jumps resultMlirType

        -- 3. Generate decision tree control flow starting from decider
        decisionResult : ExprResult
        decisionResult =
            generateDecider ctx1 root decider resultMlirType

        -- 4. ExprResult contract: even though control ends in return/jump,
        --    the caller expects a "resultVar"; we can return a dummy.
        ( dummyVar, ctx2 ) =
            freshVar decisionResult.ctx

        ( ctx3, dummyOp ) =
            ecoConstruct ctx2 dummyVar 0 0 0 []
    in
    { ops = joinpointOps ++ decisionResult.ops ++ [ dummyOp ]
    , resultVar = dummyVar
    , ctx = ctx3
    }
```

### Step 3: Implement `generateDecider`

Traverse the `Mono.Decider MonoChoice`:

```elm
generateDecider :
    Context
    -> Name.Name                      -- root variable
    -> Mono.Decider Mono.MonoChoice
    -> MlirType                       -- result type of the whole case
    -> ExprResult
generateDecider ctx root decider resultTy =
    case decider of
        Mono.Leaf choice ->
            generateLeaf ctx root choice resultTy

        Mono.Chain success failure ->
            generateChain ctx root success failure resultTy

        Mono.FanOut edges fallback ->
            generateFanOut ctx root edges fallback resultTy
```

#### 3.1 Leaf Nodes

```elm
generateLeaf :
    Context
    -> Name.Name
    -> Mono.MonoChoice
    -> MlirType
    -> ExprResult
generateLeaf ctx _root choice resultTy =
    case choice of
        Mono.Inline branchExpr ->
            let
                branchRes =
                    generateExpr ctx branchExpr

                ( ctx1, retOp ) =
                    ecoReturn branchRes.ctx branchRes.resultVar resultTy
            in
            { ops = branchRes.ops ++ [ retOp ]
            , resultVar = branchRes.resultVar
            , ctx = ctx1
            }

        Mono.Jump ->
            -- For a leaf Jump, we just jump to the appropriate joinpoint.
            -- We assume generateFanOut/Chain already know which jump id to use
            -- and have emitted the eco.jump there; here, we only need a
            -- placeholder if Mono.Decider carries the jump index.
            crash "Mono.Jump leaf should be handled in generateFanOut/Chain with label index"
```

**Note:** In `Mono.Decider`, `Jump` does *not* carry the index; the index is encoded via the decision tree structure and `jumps` list. We therefore handle jumps in `generateFanOut` (where we see the target index from DT.Test context) or extend `MonoChoice.Jump` to carry that index. If you extend `MonoChoice` to `Jump Int`, adjust the code:

```elm
-- Assuming MonoChoice carries the index; if it does not, extend it.
generateLeaf ctx _root (Mono.Jump index) resultTy =
    let
        -- No intermediate ops; just jump
        ( ctx1, jumpOp ) =
            ecoJump ctx [] index []  -- or with state params if needed

        -- Dummy result
        ( dummyVar, ctx2 ) =
            freshVar ctx1

        ( ctx3, dummyOp ) =
            ecoConstruct ctx2 dummyVar 0 0 0 []
    in
    { ops = [ jumpOp, dummyOp ]
    , resultVar = dummyVar
    , ctx = ctx3
    }
```

#### 3.2 Chain Nodes (Test Chains)

`Mono.Chain` corresponds to an `if` whose condition is an AND of multiple tests.

**Note:** You may want to refactor `Mono.Decider` to preserve the `(DT.Path, DT.Test)` list as `Optimized.Decider` does. For this design, assume you've extended `Mono.Decider` to:
```elm
Chain (List (DT.Path, DT.Test)) (Decider a) (Decider a)
```

```elm
generateChain :
    Context
    -> Name.Name
    -> Mono.Decider Mono.MonoChoice  -- success
    -> Mono.Decider Mono.MonoChoice  -- failure
    -> MlirType
    -> ExprResult
generateChain ctx root success failure resultTy =
    let
        -- For Chain, Mono.Decider has already absorbed the test list;
        -- you may want to refactor your Decider type to preserve the
        -- (DT.Path, DT.Test) list as Optimized.Decider does.
        ( tests, successTree, failureTree ) =
            extractChainComponents (Mono.Chain success failure)

        -- Compute condVar as AND of all test booleans
        ( condOps, condVar, ctx1 ) =
            generateChainCondition ctx root tests

        -- Now use eco.case on Bool: tags [1] for True; default = False.
        thenRes =
            generateDecider ctx1 root successTree resultTy

        elseRes =
            generateDecider thenRes.ctx root failureTree resultTy

        -- Build regions that *end in eco.return*, so they don't fall through
        thenRegion =
            mkRegion [] thenRes.ops (lastOpMustBeReturn thenRes)

        elseRegion =
            mkRegion [] elseRes.ops (lastOpMustBeReturn elseRes)

        ( ctx2, caseOp ) =
            ecoCase elseRes.ctx condVar [ 1 ] [ thenRegion, elseRegion ] [ resultTy ]

        ( dummyVar, ctx3 ) =
            freshVar ctx2

        ( ctx4, dummyOp ) =
            ecoConstruct ctx3 dummyVar 0 0 0 []
    in
    { ops = condOps ++ [ caseOp, dummyOp ]
    , resultVar = dummyVar
    , ctx = ctx4
    }
```

**Implementation details:**

- `generateChainCondition`:
  - Calls `generateTest` for each `(DT.Path, DT.Test)`.
  - ANDs the resulting booleans using `eco.int.and` or equivalent.
- This keeps **all control flow in eco** (`eco.case` on Bool), and relies on EcoToLLVM to lower `eco.case` on `i1` scrutinees to `if`/`switch`.

#### 3.3 FanOut Nodes (Multi-way Branch)

`Mono.FanOut edges fallback` corresponds to multi-way branching (switch-like).

```elm
generateFanOut :
    Context
    -> Name.Name
    -> List ( DT.Test, Mono.Decider Mono.MonoChoice )
    -> Mono.Decider Mono.MonoChoice    -- fallback
    -> MlirType
    -> ExprResult
generateFanOut ctx root edges fallback resultTy =
    let
        -- Assume tests are all of a compatible kind for a single scrutinee,
        -- as guaranteed by DecisionTree compilation (same path, same type of test).
        ( firstTest, _ ) =
            List.head edges
                |> Maybe.withDefault ( DT.IsNil, Mono.Leaf (Mono.Inline ...) )

        ( path, exampleTest ) =
            -- You'll need to remember the path for FanOut; either extend
            -- Mono.FanOut to carry DT.Path as in Optimized.Decider, or
            -- recover it via separate data.
            extractPathAndTest firstTest

        ( pathOps, scrutineeVar, ctx1 ) =
            generateDTPath ctx root path

        -- Map tests to discrete tags
        tags : List Int
        tags =
            List.map (testToTagInt exampleTest) edges

        -- Generate regions
        ( regions, ctx2 ) =
            List.foldl
                (\( test, subTree ) ( accRegions, accCtx ) ->
                    let
                        subRes =
                            generateDecider accCtx root subTree resultTy

                        region =
                            mkRegion [] subRes.ops (lastOpMustBeReturn subRes)
                    in
                    ( region :: accRegions, subRes.ctx )
                )
                ( [], ctx1 )
                edges
                |> (\( regs, c ) -> ( List.reverse regs, c ))

        -- Fallback region
        fallbackRes =
            generateDecider ctx2 root fallback resultTy

        fallbackRegion =
            mkRegion [] fallbackRes.ops (lastOpMustBeReturn fallbackRes)

        ( ctx3, caseOp ) =
            ecoCase ctx2 scrutineeVar tags (regions ++ [ fallbackRegion ]) [ resultTy ]

        ( dummyVar, ctx4 ) =
            freshVar ctx3

        ( ctx5, dummyOp ) =
            ecoConstruct ctx4 dummyVar 0 0 0 []
    in
    { ops = pathOps ++ [ caseOp, dummyOp ]
    , resultVar = dummyVar
    , ctx = ctx5
    }
```

**Explanation:**

- We assume all `DT.Test` values in `edges` are coherent (same test kind), which is what `DecisionTree` guarantees for a given node.
- For ctor tests (`IsCtor`), `testToTagInt` maps each test to its constructor index; `eco.case` will switch on constructor tag, which EcoToLLVM already knows how to lower.
- For integer/char/string tests, `testToTagInt` can assign small integers 0..N-1 *per decision site*; EcoToLLVM then implements comparisons to distinguish them.

### Step 4: Implement Shared Branch Joinpoints

The `jumps : List (Int, MonoExpr)` list holds branches that are reachable from multiple Decider leaves (sharing).

```elm
generateSharedJoinpoints :
    Context
    -> List ( Int, Mono.MonoExpr )
    -> MlirType
    -> ( Context, List MlirOp )
generateSharedJoinpoints ctx jumps resultTy =
    List.foldl
        (\( index, branchExpr ) ( accCtx, accOps ) ->
            let
                -- Body: generateExpr for branch, then eco.return
                branchRes =
                    generateExpr accCtx branchExpr

                ( ctx1, retOp ) =
                    ecoReturn branchRes.ctx branchRes.resultVar resultTy

                jpRegion =
                    mkRegion [] (branchRes.ops ++ [ retOp ])  -- body

                -- Continuation: may be empty or hold post-joinpoint straight-line code
                contRegion =
                    mkRegion [] [] (dummyReturnOp resultTy)  -- or empty; depends on eco semantics

                ( ctx2, jpOp ) =
                    ecoJoinpoint ctx1 index [] jpRegion contRegion [ resultTy ]
            in
            ( ctx2, jpOp :: accOps )
        )
        ( ctx, [] )
        jumps
        |> (\( c, ops ) -> ( c, List.reverse ops ))
```

**Key points:**

- **eco.joinpoint/eco.jump MUST be used for shared branches**: every `(index, branchExpr)` in `jumps` becomes a joinpoint definition; every `Mono.Jump index` leaf becomes an `eco.jump` to that joinpoint.
- We do **not** introduce new eco ops; we're only using `eco.joinpoint`, `eco.jump`, `eco.return`, all of which already exist and are tested in the eco dialect.
- The exact shape of `eco.joinpoint` continuation and result types is defined in the eco dialect; you may need to adjust `contRegion` to fit that shape.

### Step 5: Implement `generateIf`

Replace the stub with eco.case on Bool:

```elm
generateIf :
    Context
    -> List ( Mono.MonoExpr, Mono.MonoExpr )
    -> Mono.MonoExpr
    -> ExprResult
generateIf ctx branches final =
    case branches of
        [] ->
            generateExpr ctx final

        ( condExpr, thenExpr ) :: rest ->
            -- Build one conditional and embed the rest as else-case
            let
                condRes =
                    generateExpr ctx condExpr  -- produces Bool SSA

                condVar =
                    condRes.resultVar

                -- else branch: either another if or final expression
                elseRes =
                    generateIf condRes.ctx rest final

                -- Build regions that end in eco.return
                thenRes =
                    generateExpr condRes.ctx thenExpr

                resultTy =
                    monoTypeToMlir (Mono.typeOf thenExpr)

                ( ctx1, thenRet ) =
                    ecoReturn thenRes.ctx thenRes.resultVar resultTy

                thenRegion =
                    mkRegion [] (thenRes.ops ++ [ thenRet ])

                ( ctx2, elseRet ) =
                    ecoReturn elseRes.ctx elseRes.resultVar resultTy

                elseRegion =
                    mkRegion [] (elseRes.ops ++ [ elseRet ])

                -- eco.case on Bool: tag 1 for True
                ( ctx3, caseOp ) =
                    ecoCase ctx2 condVar [ 1 ] [ thenRegion, elseRegion ] [ resultTy ]

                ( dummyVar, ctx4 ) =
                    freshVar ctx3

                ( ctx5, dummyOp ) =
                    ecoConstruct ctx4 dummyVar 0 0 0 []
            in
            { ops = condRes.ops ++ [ caseOp, dummyOp ]
            , resultVar = dummyVar
            , ctx = ctx5
            }
```

**Explanation:**

- This compiles `if c1 then t1 else if c2 then t2 else ... final` to a nested sequence of `<compute cond> + eco.case` ops, where each branch's regions end in `eco.return`.
- It uses only **eco dialect** ops for control flow (`eco.case`, `eco.return`) plus your existing expression generators and arithmetic/boolean operations.
- There is no shared-branch scenario in vanilla `if`, so we don't use joinpoints here.

---

## Optional AST Changes

To simplify implementation, consider these changes to `Compiler/AST/Monomorphized.elm`:

### 1. Extend `MonoChoice.Jump` to Carry Index

```elm
type MonoChoice
    = Inline MonoExpr
    | Jump Int          -- Was just: Jump
```

This allows `Leaf (Jump index)` to directly emit `eco.jump` to the correct joinpoint. Right now `MonoChoice.Jump` is bare; the target index is only present indirectly via `jumps`.

### 2. Extend `Mono.Chain` to Carry Test Chain

```elm
type Decider a
    = Leaf a
    | Chain (List (DT.Path, DT.Test)) (Decider a) (Decider a)  -- Added test list
    | FanOut (List (DT.Test, Decider a)) (Decider a)
```

This mirrors `Optimized.Decider` and makes `generateChainCondition` trivial and aligns with JS's `generateIfTest`.

These are internal AST changes, not dialect changes, and they follow the patterns used in the Optimized / JS backend.

---

## Files to Modify

1. **`/work/compiler/src/Compiler/Generate/CodeGen/MLIR.elm`**:
   - Add helpers: `ecoCase`, `ecoJoinpoint`, `ecoJump` (factored from `generateTailCall`)
   - Add helpers: `lastOpMustBeReturn`, `dummyReturnOp`
   - Add helpers: `generateDTPath`, `generateTest`, `testToTagInt`, `extractPathAndTest`
   - Add: `generateDecider`, `generateLeaf`, `generateChain`, `generateFanOut`
   - Add: `generateSharedJoinpoints`, `generateChainCondition`
   - Replace stub: `generateCase`
   - Replace stub: `generateIf`
   - Refactor: `generateTailCall` to use `ecoJump` helper
   - Keep: `generateMonoPath` unchanged (separate from `generateDTPath`)

2. **(Optional) `/work/compiler/src/Compiler/AST/Monomorphized.elm`**:
   - Extend `MonoChoice.Jump` to `Jump Int`
   - Extend `Mono.Chain` to carry test list

---

## Non-Goals (Future Extensions)

1. **Non-tail cases**: This design assumes `MonoCase` is used where the control is allowed to exit the current function (tail position). Handling non-tail cases will require threading the case result back via joinpoints or additional SSA constructs (e.g., encoding case results as extra state in `eco.joinpoint`).

2. **Full primitive test coverage**: The design outlines how to handle `IsCtor` via `eco.case` tags and proposes using Bool `eco.case` plus eco comparison ops for `IsInt` / `IsChr` / `IsStr` / `IsBool`. EcoToLLVM may need small extensions to lower `eco.case` over non-ADT scrutinees correctly; this is C++ work, but it requires no new eco ops.

---

## Estimated Complexity

**High** - ~300-500 lines of new Elm code:
- New helpers (~150 lines)
- `generateDecider` and variants (~150 lines)
- `generateSharedJoinpoints` (~50 lines)
- `generateIf` replacement (~50 lines)
- Refactoring `generateTailCall` (~20 lines)

## Priority

**Critical** - Case expressions are fundamental. Most Elm programs won't work without them.

---

## Questions Resolved

| Question | Answer |
|----------|--------|
| Where is the bug? | `MLIR.elm:2097-2109`, `generateCase` is a stub |
| What IR is used? | `Mono.Decider Mono.MonoChoice` with `DT.Test` and `DT.Path` |
| Is this missing or broken? | **Missing** - stub placeholder, never implemented |
| What eco ops exist? | `eco.case`, `eco.joinpoint`, `eco.jump`, `eco.project`, `eco.return` |
| What dialect to use? | **eco dialect only** - NOT scf dialect |
| Is downstream lowering done? | **Yes** - EcoToLLVM handles eco.case → cf.switch |
| Result handling? | **Tail position** - branches end with eco.return/eco.jump, return dummy |
| Shared branches? | **Always use eco.joinpoint/eco.jump** |
| Existing path helper? | `generateMonoPath` exists for `Mono.MonoPath`; add `generateDTPath` for `DT.Path` |
| result_types attribute? | Fill if dialect enforces; otherwise pass `[]` and infer later |

## Reference Files

- **Design doc**: `/work/design_docs/mlir-case-codegen.md`
- **Test files**: `/work/test/codegen/case_*.mlir`, `/work/test/codegen/joinpoint_*.mlir`
- **JS reference**: `/work/compiler/src/Compiler/Generate/JavaScript/Expression.elm` lines 1201-1429
