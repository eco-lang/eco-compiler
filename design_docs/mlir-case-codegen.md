Below is a self‑contained design for implementing `if` and `case` in the MLIR backend so that:

- The backend **only emits eco dialect ops for control flow** (no `scf` / `cf` ops).
- It uses **only ops that already exist** in the eco dialect (`eco.case`, `eco.joinpoint`, `eco.jump`, `eco.return`, `eco.construct`, `eco.project`, `eco.int.*`, etc.)   .
- **Shared branches are always implemented with `eco.joinpoint` / `eco.jump`**, mirroring how the decision tree exposes sharing.
- The **`Mono.Decider MonoChoice`** (already derived from `DecisionTree`) is the *only* driver of case control flow.

Everything described below goes into the Elm backend, primarily `Compiler/Generate/CodeGen/MLIR.elm` (the monomorphized MLIR backend)  .

---

## 0. Pre‑requisites and invariants

### 0.1. Input IR

The MLIR backend operates on `Mono.MonoExpr` and related types:

- Case expressions in the monomorphized IR:

  ```elm
  type MonoExpr
      = ...
      | MonoCase Name Name (Decider MonoChoice) (List ( Int, MonoExpr )) MonoType
      ...
  
  type Decider a
      = Leaf a
      | Chain (Decider a) (Decider a)
      | FanOut (List ( DT.Test, Decider a )) (Decider a)
  
  type MonoChoice
      = Inline MonoExpr
      | Jump
  ```

  where:

    - The two `Name` arguments to `MonoCase` are:
        - A temp name for the scrutinee.
        - The **root** variable being matched (the scrutinee’s local name).
    - `Decider MonoChoice` encodes the compiled decision tree with **sharing** (via `Jump`) already decided upstream   .
    - `jumps : List (Int, MonoExpr)` holds the bodies of shared branches.

### 0.2. Current stubs

In `MLIR.elm` today:

- `generateCase` is a stub that ignores its inputs and emits a dummy `eco.construct` .
- `generateIf` is a stub that ignores conditions and just evaluates branches sequentially .

These must be replaced.

### 0.3. Eco ops we rely on

We assume the eco dialect already has these operations (as per the dialect docs and codegen tests)  :

- Control flow (already defined and lowered to LLVM):
    - `eco.case` – pattern‑matching control flow.
    - `eco.joinpoint` – local control‑flow join with a body and continuation.
    - `eco.jump` – jump to a joinpoint (already used in `generateTailCall`) .
    - `eco.return` – function return (already used in `generateDefine` / `generateClosureFunc`) .
- Data / tests:
    - `eco.construct`, `eco.project` – ADT & record operations (already used) .
    - Primitive comparisons (e.g. `eco.int.eq` and siblings; for strings/chars/bools use whatever eco test ops are defined).

We **do not introduce any new eco ops** in this design. At most, we’ll populate already‑defined attributes like `result_types` on `eco.case`/`eco.joinpoint` if they exist; if not, we can safely omit them and let a later eco→eco pass infer them as per the SCF design docs .

---

## 1. High‑level strategy

### 1.1. Case expressions

1. `Mono.MonoCase` already carries:
    - The **scrutinee variable name** (`root`).
    - A **`Decider MonoChoice`** compiled from `DecisionTree` with sharing information.
    - A **`jumps : List (Int, MonoExpr)`** list containing shared branch bodies.

2. We will implement:

    - `generateCase : Context -> Name -> Name -> Mono.Decider Mono.MonoChoice -> List (Int, Mono.MonoExpr) -> ExprResult`

   so that:

    - It emits eco control flow that is *semantically equivalent* to the decision tree.
    - All **shared branches** in `jumps` are implemented as **`eco.joinpoint` + `eco.jump`**.
    - All leaves that `Inline` a branch body emit that body and end with `eco.return`.

3. We mirror the JavaScript backend’s structure:

    - JS backend:

      ```elm
      generateCase mode parentModule label root decider jumps =
          List.foldr (goto ...) (generateDecider ... decider) jumps
      ```

      where `generateDecider` recursively walks the `Decider` to produce `if`/`switch`/`break` statements  .

    - MLIR backend: we will add a **`generateDecider` for eco** and call it from `generateCase`, and we will add eco equivalents of `goto` via joinpoints.

4. For now, **we treat `MonoCase` as appearing in tail position** of functions when using `eco.case` (its natural use in eco is control‑only; regions typically end in `eco.return` or `eco.jump`). If you later need non‑tail cases, you will wrap the case in a `eco.joinpoint` to carry the result to a continuation, but that’s an extension of this design.

### 1.2. If expressions

1. `MonoIf` is independent of the decision tree machinery:

   ```elm
   MonoIf (List ( MonoExpr, MonoExpr )) MonoExpr MonoType
   ```

2. For `if` we will:

    - Keep it **local** – we do *not* go through `Decider`.
    - Implement it using only eco ops:
        - Evaluate each condition to a Bool.
        - For each `(cond, thenBranch)` in order, generate a conditional branch:
            - If `cond` is true, evaluate `thenBranch` and `eco.return` it.
            - Otherwise, move on to the next condition.
        - If none match, evaluate the final expression and `eco.return` it.
    - Use either:
        - A small chain of `eco.case` on Bool, or
        - A joinpoint pattern (see §4).

   For simplicity and minimal interaction with eco internals, this design uses **small `eco.case` on Bool** (scrutinee type is `i1` or whatever you already use for Bool) and no joinpoints for `if` (since there is no sharing).

---

## 2. New helpers in `MLIR.elm`

All of the following live in `Compiler/Generate/CodeGen/MLIR.elm` (you already have similar helpers for `ecoConstruct`, `ecoProject`, `ecoReturn`, etc.) .

### 2.1. Eco case builder

Add a builder for `eco.case` ops:

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

Explanation:

- This is the eco analogue of `funcFunc`, `ecoConstruct`, `ecoReturn` etc.
- The dialect docs explicitly allow `scrutinee : AnyType` and a `tags` array attribute; `result_types` is documented as an ArrayAttr of TypeAttr used by verifiers and SCF lowering .
- If you have not yet added `result_types` to the eco dialect, you can pass `resultTypes = []` and omit the attribute until the dialect is updated.

### 2.2. Eco joinpoint builder

Define a helper to build `eco.joinpoint`:

```elm
ecoJoinpoint :
    Context
    -> Int               -- joinpoint id (from jump index)
    -> List ( String, MlirType )  -- parameter (state) types, usually []
    -> MlirRegion        -- jpRegion: body
    -> MlirRegion        -- continuation region
    -> List MlirType     -- function-level result types, or [] if unknown
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

Explanation:

- Eco dialect docs show `eco.joinpoint` with `id` and (optionally) `result_types` attributes and two regions: `jpRegion` and continuation .
- For **shared branches in case**, we will use `eco.joinpoint` purely to host the shared branch body and its surrounding continuation.

### 2.3. Eco jump helper

You already have an `eco.jump` builder inside `generateTailCall` :

```elm
( ctx2, jumpOp ) =
    mlirOp ctx1 "eco.jump"
        |> opBuilder.withOperands argVarNames
        |> opBuilder.withAttrs jumpAttrs
        |> opBuilder.isTerminator True
        |> opBuilder.build
```

We will:

- Factor this out into a reusable helper `ecoJump : Context -> String -> List ( String, MlirType ) -> (Context, MlirOp)` that:
    - Takes the joinpoint name or id in attributes,
    - Takes operands and infers `_operand_types` from provided types.
- Reuse it both for tail calls and for case `Jump` leaves.

This involves:

1. Extract the common building code from `generateTailCall` into a top‑level `ecoJump` function.
2. Change `generateTailCall` to call `ecoJump`.
3. Use `ecoJump` from the new case lowering code (see §3.3.1).

### 2.4. Test generation helpers

We need to convert `DT.Path` and `DT.Test` into MLIR SSA values (bools) for chain conditions.

You *already* have `generateMonoPath : Context -> Mono.MonoPath -> ( List MlirOp, String, Context )` to project into nested structures using `eco.project` . For decision trees, you need an analogous function using `DT.Path`:

1. **Add translation from `DT.Path` to `Mono.MonoPath`** (if not already present), or
2. Implement a new helper:

```elm
generateDTPath : Context -> Name.Name -> DT.Path -> ( List MlirOp, String, Context )
generateDTPath ctx root dtPath =
    case dtPath of
        DT.Empty ->
            ( [], "%" ++ root, ctx )

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

Then:

```elm
generateTest : Context -> Name.Name -> ( DT.Path, DT.Test ) -> ( List MlirOp, String, Context )
generateTest ctx root ( path, test ) =
    let
        ( pathOps, valVar, ctx1 ) =
            generateDTPath ctx root path
    in
    case test of
        DT.IsCtor _home _name index _ ctorOpts ->
            -- We’ll rely on eco.case for ctor dispatch; we do *not* emit a compare here.
            -- For Chain test chains, we will only use IsBool / primitives, see below.
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

        -- Similarly define for IsChr, IsStr using eco.char.eq / eco.string.eq if present.

        DT.IsCons ->
            -- Cons/nil tests will typically be done via eco.case on tags; for
            -- Chain, you can again treat this as Bool: isNonEmptyList(valVar).
            ...

        DT.IsNil ->
            ...
```

Explanation:

- This gives you per‑test **boolean SSA values** that can be ANDed together for `Chain` nodes (like JS’s `foldl1_ (&&)` over `generateIfTest`) .
- For **ctor / list tests**, we will rely on `FanOut` and `eco.case` rather than building standalone comparisons; see next section.

---

## 3. Case lowering in detail

### 3.1. New `generateCase` implementation

Replace the stub in `MLIR.elm`  with:

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
            Mono.typeOf (Mono.MonoCase root root decider jumps Mono.MUnit) -- or a helper

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

Explanation:

- Step 1: we obtain the case’s result type from `MonoType`. If there’s no convenient helper, add one like `typeOfCase : Decider MonoChoice -> MonoType` or use the existing `Mono.typeOf` on some representative expression.
- Step 2: we build shared branches as joinpoints (see §3.3).
- Step 3: we walk the Decider to generate eco control flow (see §3.2).
- Step 4: we return a dummy SSA value because the real control flow exits via `eco.return` or `eco.jump` (same pattern as `generateTailCall`, which returns a dummy `Ctor0` after `eco.jump`) .

### 3.2. `generateDecider` for eco

Add a new function (similar to the JS version `generateDecider` ) that traverses `Mono.Decider MonoChoice`:

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

#### 3.2.1. Leaf nodes

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

Note: in `Mono.Decider`, Jump does *not* carry the index; the index is encoded via the decision tree structure and `jumps` list. We therefore handle jumps in `generateFanOut` (where we see the target index from DT.Test context) or extend `MonoChoice.Jump` to carry that index. If you extend `MonoChoice` to `Jump Int`, adjust the code accordingly.

#### 3.2.2. Chain nodes (test chains, like nested ifs)

`Mono.Chain` corresponds to an `if` whose condition is an AND of multiple tests:

- In JS: they compute `cond = and(generateIfTest path test)` and emit `if cond then success else failure` .

For eco:

- We will:
    - Compute the boolean condition via `generateTest` and AND them.
    - Use a small 2‑way `eco.case` on Bool to select between the `success` and `failure` subdeciders.

Sketch:

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
        --
        -- For this design, assume you’ve extended Mono.Decider to:
        --   Chain (List (DT.Path, DT.Test)) (Decider a) (Decider a)
        -- mirroring Optimized.Decider. Then:
        ( tests, successTree, failureTree ) =
            extractChainComponents (Mono.Chain success failure)

        -- Compute condVar as AND of all test booleans
        ( condOps, condVar, ctx1 ) =
            generateChainCondition ctx root tests

        -- Now use eco.case on Bool: tags [1] for True; default = False.
        ( thenRes, ctx2 ) =
            let res = generateDecider ctx1 root successTree resultTy in
            ( res, res.ctx )

        ( elseRes, ctx3 ) =
            let res = generateDecider ctx2 root failureTree resultTy in
            ( res, res.ctx )

        -- Build regions that *end in eco.return*, so they don't fall through
        thenRegion =
            mkRegion [] (thenRes.ops) (lastOpMustBeReturn thenRes)

        elseRegion =
            mkRegion [] (elseRes.ops) (lastOpMustBeReturn elseRes)

        ( ctx4, caseOp ) =
            ecoCase ctx3 condVar [ 1 ] [ thenRegion, elseRegion ] [ resultTy ]

        ( dummyVar, ctx5 ) =
            freshVar ctx4

        ( ctx6, dummyOp ) =
            ecoConstruct ctx5 dummyVar 0 0 0 []
    in
    { ops = condOps ++ [ caseOp, dummyOp ]
    , resultVar = dummyVar
    , ctx = ctx6
    }
```

Implementation details:

- `generateChainCondition`:
    - Calls `generateTest` for each `(DT.Path, DT.Test)`.
    - ANDs the resulting booleans using eco.int.and or equivalent.
- This keeps **all control flow in eco** (`eco.case` on Bool), and relies on EcoToLLVM to lower `eco.case` on `i1` scrutinees to `if`/`switch`.

#### 3.2.3. FanOut nodes (multi‑way branches)

`Mono.FanOut edges fallback` corresponds to multi‑way branching (switch‑like). In JS this becomes a `switch` statement on a test value (often the tag) .

For eco:

- We will emit a single `eco.case` over an appropriate **discriminant value** and one region per edge plus a default region.

Sketch:

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
        -- as guaranteed by DecisionTree compilation (same path, same
        -- type of test).
        ( firstTest, _ ) =
            List.head edges

        ( path, exampleTest ) =
            -- You’ll need to remember the path for FanOut; either extend
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

Explanation:

- We assume all `DT.Test` values in `edges` are coherent (same test kind), which is what `DecisionTree` guarantees for a given node .
- For ctor tests (`IsCtor`), `testToTagInt` maps each test to its constructor index; eco.case will switch on constructor tag, which EcoToLLVM already knows how to lower .
- For integer/char/string tests, `testToTagInt` can assign small integers 0..N‑1 *per decision site*; EcoToLLVM then implements comparisons to distinguish them (this requires small extensions to the case lowering, but still no new eco ops).

### 3.3. Shared branches → eco.joinpoint / eco.jump

The `jumps : List (Int, MonoExpr)` list holds branches that are reachable from multiple Decider leaves (sharing). In JS, they’re implemented with `goto` + labelled `while true` loops ; here we must use eco.joinpoint/jump.

Add:

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
                    mkRegion [] [] (dummyReturnOp resultTy)    -- or empty; depends on eco semantics

                ( ctx2, jpOp ) =
                    ecoJoinpoint ctx1 index [] jpRegion contRegion [ resultTy ]
            in
            ( ctx2, jpOp :: accOps )
        )
        ( ctx, [] )
        jumps
        |> (\( c, ops ) -> ( c, List.reverse ops ))
```

Then, in `generateDecider` (specifically in Leaf/Jump handling or FanOut), when you see a Jump target index, emit:

```elm
-- Assuming MonoChoice carries the index; if it does not, extend it.
generateLeaf ... (Mono.Jump index) resultTy =
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

Key points:

- **eco.joinpoint/eco.jump MUST be used for shared branches**: every `(index, branchExpr)` in `jumps` becomes a joinpoint definition; every `Mono.Jump index` leaf becomes an `eco.jump` to that joinpoint.
- We do **not** introduce new eco ops; we’re only using `eco.joinpoint`, `eco.jump`, `eco.return`, all of which already exist and are tested in the eco dialect .

Implementation detail:

- The exact shape of `eco.joinpoint` continuation and result types is defined in the eco dialect; you may need to adjust `contRegion` to fit that shape (for simple sharing you can treat it as an empty continuation and let `createControlFlowLoweringPass()` handle it).

---

## 4. If lowering in detail

Replace the stub `generateIf`  with a proper eco‑based implementation:

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

Explanation:

- This compiles `if c1 then t1 else if c2 then t2 else ... final` to a nested sequence of `<compute cond> + eco.case` ops, where each branch’s regions end in `eco.return`.
- It uses only **eco dialect** ops for control flow (`eco.case`, `eco.return`) plus your existing expression generators and arithmetic/boolean operations.
- There is no shared-branch scenario in vanilla `if`, so we don’t use joinpoints here.

---

## 5. Summary of code changes, by location

### 5.1. `Compiler/Generate/CodeGen/MLIR.elm`

1. **New helpers**:

    - `ecoCase` (builder for `eco.case`, §2.1).
    - `ecoJoinpoint` (builder for `eco.joinpoint`, §2.2).
    - `ecoJump` (factor out from `generateTailCall`, §2.3).
    - `generateDTPath` and `generateTest` (decision‑tree path/test to MLIR, §2.4).
    - `generateDecider` / `generateLeaf` / `generateChain` / `generateFanOut` (Decider traversal, §3.2).
    - `generateSharedJoinpoints` (shared branch → joinpoints, §3.3).
    - Optionally: small utility to get the case result type from Mono (if you don’t already have one).

2. **Replace stubs**:

    - Replace `generateCase` stub with the new implementation described in §3.1. It:
        - Calls `generateSharedJoinpoints`.
        - Then calls `generateDecider`.
        - Returns a dummy ExprResult (consistent with `generateTailCall` pattern) .
    - Replace `generateIf` stub with the eco.case‑based implementation in §4.

3. **Refactor existing code**:

    - In `generateTailCall`, replace inline `eco.jump` building with a call to the new `ecoJump` helper and keep the dummy `Ctor0` return as today .
    - Ensure `generateMonoPath` remains unchanged for destructuring; `generateDTPath` is separate for decision trees.

4. **Context / type consistency**:

    - If the eco dialect already enforces `result_types` for `eco.case`/`eco.joinpoint`:
        - Fill `resultTypes` in `ecoCase` and `ecoJoinpoint` using `monoTypeToMlir` (for function return types, or `[]` for non‑returning).
    - Otherwise, you can omit `result_types` and add them later via an eco→eco inference pass, as suggested in the SCF docs .

### 5.2. (Optional) `Compiler/AST/Monomorphized.elm` / utilities

To simplify the implementation, you may:

- Extend `Mono.Decider` to carry a test chain for `Chain`:

  ```elm
  type Decider a
      = Leaf a
      | Chain (List (DT.Path, DT.Test)) (Decider a) (Decider a)
      | FanOut (List (DT.Test, Decider a)) (Decider a)
  ```

  mirroring `Optimized.Decider` . This makes `generateChainCondition` trivial and aligns with JS’s `generateIfTest`.

- Extend `MonoChoice.Jump` to carry the target index:

  ```elm
  type MonoChoice
      = Inline MonoExpr
      | Jump Int
  ```

  so that `Leaf (Jump index)` can directly emit `eco.jump` to the correct joinpoint. Right now `MonoChoice.Jump` is bare; the target index is only present indirectly via `jumps`.

These are internal AST changes, not dialect changes, and they follow the patterns used in the Optimized / JS backend  .

---

## 6. Non‑goals and future extensions

- **Non‑tail cases**: This design assumes `MonoCase` is used where the control is allowed to exit the current function (tail position). Handling non‑tail cases will require threading the case result back via joinpoints or additional SSA constructs (e.g., encoding case results as extra state in `eco.joinpoint`).
- **Full primitive test coverage**: The design outlines how to handle `IsCtor` via `eco.case` tags and proposes using Bool `eco.case` plus eco comparison ops for `IsInt` / `IsChr` / `IsStr` / `IsBool`. EcoToLLVM may need small extensions to lower `eco.case` over non‑ADT scrutinees correctly; this is C++ work, but it requires no new eco ops.

---

With these changes, the MLIR backend:

- Uses **only eco dialect ops for control flow**.
- **Always** uses `eco.joinpoint` / `eco.jump` to implement shared branches from the decision tree.
- Uses the **compiled `Decider MonoChoice`** (derived from `DecisionTree`) as the *sole* driver for `case` control flow, mirroring the existing JavaScript backend logic but targeting eco instead of JS.

