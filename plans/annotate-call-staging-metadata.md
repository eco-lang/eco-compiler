# Plan: Annotate MonoCall with Staging Metadata

## Overview

This plan moves **all curried staging / call-site logic** into GlobalOpt. After `MonoGlobalOptimize.globalOptimize` runs, every `MonoCall` carries a compact "call plan" (`CallInfo`) that MLIR executes mechanically.

### Current State

- MLIR `Expr.elm` computes staging at call sites via `callModelForCallee`, `collectStageArities`, and inline arity calculations
- `Context.elm` defines its own `CallModel` type (`FlattenedExternal | StageCurried`)
- `generateCall` recomputes `firstStageArity`, `totalArity` from signatures and types on every call
- `generateClosureApplication` recomputes `initialRemaining` and `remainingStageArities` via `Ctx.lookupVarArity`, `Mono.stageReturnType`, etc.
- Staging logic is duplicated between GlobalOpt (for ABI wrappers) and MLIR codegen

### Target State

- `MonoCall` carries `CallInfo` with all precomputed staging metadata
- MLIR codegen consumes metadata directly without re-deriving staging from types
- `CallModel` is defined in `Monomorphized.elm` (AST-side, independent of MLIR)
- GlobalOpt is the single source of truth for staging decisions
- Intrinsics and kernel signatures remain in MLIR (backend concern)

---

## Target Invariants

1. **Call model is encoded on the IR**
   - Every `MonoCall` has `callInfo.callModel : Mono.CallModel`
   - `FlattenedExternal` for extern/kernel/ctor and aliases around them
   - `StageCurried` for closures/user functions

2. **Stage arities are precomputed**
   - `callInfo.stageArities : List Int` equals `collectStageArities (Mono.typeOf callee)` after canonicalization

3. **Single-stage saturated is pre-classified**
   - `callInfo.isSingleStageSaturated : Bool` decides `generateSaturatedCall` vs `generateClosureApplication`

4. **applyByStages inputs are precomputed**
   - `callInfo.initialRemaining : Int` is the stage arity at this call site (sourceRemaining)
   - `callInfo.remainingStageArities : List Int` is the stage list for subsequent stages

5. **No staging helpers in MLIR**
   - `Expr.elm` does not call `collectStageArities`, `Mono.stageReturnType`, or `callModelForCallee`
   - All such logic moves to GlobalOpt

6. **Phase ordering**
   - All transformations that create `MonoCall` run *before* `annotateCallStaging`
   - If inlining runs after, it must preserve `CallInfo` or trigger re-annotation

---

## Phase 1: IR Changes — Add CallModel and CallInfo to Monomorphized.elm

### Step 1.1: Add CallModel type

**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

**Add near the staging helpers (Segmentation, etc.):**
```elm
{-| Call model of a function, independent of backend.
    This is the AST-side version; MLIR Context.CallModel can be removed.
-}
type CallModel
    = FlattenedExternal
    | StageCurried
```

### Step 1.2: Add CallInfo type alias

**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

**Add after CallModel:**
```elm
{-| Staging / call-site metadata for MonoCall.

  - callModel: FlattenedExternal vs StageCurried
  - stageArities: Full list of stage arities [a1, a2, ...] for the callee.
  - isSingleStageSaturated: True if this call consumes all arguments and
                            fits entirely in the first stage.
  - initialRemaining: Stage arity of the current closure value at this call site
                      (used as sourceRemaining in applyByStages).
  - remainingStageArities: Stage arities for subsequent stages after saturating
                           the current closure (used in applyByStages).
-}
type alias CallInfo =
    { callModel : CallModel
    , stageArities : List Int
    , isSingleStageSaturated : Bool
    , initialRemaining : Int
    , remainingStageArities : List Int
    }
```

### Step 1.3: Add default CallInfo helper

**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

**Add after CallInfo:**
```elm
{-| Default/placeholder CallInfo for newly constructed calls.
    Will be overwritten by annotateCallStaging pass in GlobalOpt.
-}
defaultCallInfo : CallInfo
defaultCallInfo =
    { callModel = StageCurried
    , stageArities = []
    , isSingleStageSaturated = False
    , initialRemaining = 0
    , remainingStageArities = []
    }
```

### Step 1.4: Extend MonoExpr.MonoCall

**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

**Current (around line 165):**
```elm
| MonoCall Region MonoExpr (List MonoExpr) MonoType
```

**Change to:**
```elm
| MonoCall Region MonoExpr (List MonoExpr) MonoType CallInfo
```

### Step 1.5: Update module exports

**File:** `compiler/src/Compiler/AST/Monomorphized.elm`

**Add to exports:**
```elm
, CallModel(..), CallInfo, defaultCallInfo
```

---

## Phase 2: Monomorphize — Emit Calls with Placeholder Metadata

### Step 2.1: Update Specialize.elm

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

Monomorphize stays staging-agnostic. Attach `defaultCallInfo` to all `MonoCall` constructions:

**Before:**
```elm
( Mono.MonoCall region monoFunc monoArgs resultMonoType, state3 )
```

**After:**
```elm
( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, state3 )
```

Search for all `Mono.MonoCall` construction sites and apply the same change.

### Step 2.2: Update Closure.elm (if applicable)

**File:** `compiler/src/Compiler/Generate/Monomorphize/Closure.elm`

Check for any `Mono.MonoCall` construction and add `Mono.defaultCallInfo`.

---

## Phase 3: Mechanical Updates — Thread CallInfo Through Existing Code

All modules that pattern-match `Mono.MonoCall` must gain/forward the new `CallInfo` parameter.

### Step 3.1: Update MonoGlobalOptimize.elm traversals

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

Update all `MonoCall` patterns to include `callInfo`:

**In `canonicalizeExpr`, `rewriteExprForAbi`, `validateExprClosures`, etc.:**
```elm
-- Before:
Mono.MonoCall region fn args resultType ->
    Mono.MonoCall region
        (canonicalizeExpr fn)
        (List.map canonicalizeExpr args)
        resultType

-- After:
Mono.MonoCall region fn args resultType callInfo ->
    Mono.MonoCall region
        (canonicalizeExpr fn)
        (List.map canonicalizeExpr args)
        resultType
        callInfo
```

**In `buildNestedCallsGO` (constructs calls):**
```elm
callExpr =
    Mono.MonoCall region currentCallee nowArgs resultType Mono.defaultCallInfo
```

### Step 3.2: Update MonoInlineSimplify.elm

**File:** `compiler/src/Compiler/GlobalOpt/MonoInlineSimplify.elm`

Update all `MonoCall` patterns in `rewriteExpr`, `simplifyLets`, `dce`, `remapLambdaIds`, etc.:

**Pattern matching:**
```elm
-- Before:
Mono.MonoCall region func args resultType ->
    ...
    ( Mono.MonoCall region rewrittenFunc rewrittenArgs resultType, ctx2 )

-- After:
Mono.MonoCall region func args resultType callInfo ->
    ...
    ( Mono.MonoCall region rewrittenFunc rewrittenArgs resultType callInfo, ctx2 )
```

**Beta-reduction special case:**
```elm
-- Before:
Mono.MonoCall region (Mono.MonoClosure info closureBody closureType) args resultType ->
    ...

-- After:
Mono.MonoCall region (Mono.MonoClosure info closureBody closureType) args resultType callInfo ->
    ...
```

**When constructing new MonoCall (beta reduction, inlining):**
```elm
Mono.MonoCall region newFunc newArgs resultType Mono.defaultCallInfo
```

### Step 3.3: Search for all MonoCall sites

Use grep to find all remaining sites:
```bash
grep -rn "MonoCall" compiler/src/
```

Ensure every pattern match includes `callInfo` and every construction includes `Mono.defaultCallInfo`.

---

## Phase 4: New GlobalOpt Phase — annotateCallStaging

### Step 4.1: Add CallEnv type for local call model propagation

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

**Add near top of file:**
```elm
{-| Environment for tracking call models of local variables.
    This replaces MLIR's Ctx.lookupVarCallModel logic.
-}
type alias CallEnv =
    { varCallModel : Dict Name Mono.CallModel
    }


emptyCallEnv : CallEnv
emptyCallEnv =
    { varCallModel = Dict.empty }
```

### Step 4.2: Wire phase into globalOptimize

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

**Current:**
```elm
globalOptimize typeEnv graph0 =
    let
        graph1 = canonicalizeClosureStaging graph0
        graph2 = normalizeCaseIfAbi graph1
        graph3 = validateClosureStaging graph2
        graph4 = annotateReturnedClosureArity graph3
    in
    graph4
```

**Change to:**
```elm
globalOptimize typeEnv graph0 =
    let
        graph1 = canonicalizeClosureStaging graph0
        graph2 = normalizeCaseIfAbi graph1
        graph3 = validateClosureStaging graph2
        graph4 = annotateCallStaging graph3
        graph5 = annotateReturnedClosureArity graph4
    in
    graph5
```

### Step 4.3: Implement callModelForExpr

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

```elm
{-| Determine call model for an expression.
    Mirrors MLIR's Expr.callModelForExpr but operates on MonoGraph.
-}
callModelForExpr : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Maybe Mono.CallModel
callModelForExpr (Mono.MonoGraph { nodes }) env expr =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            case Dict.get specId nodes of
                Just (Mono.MonoExtern _) ->
                    Just Mono.FlattenedExternal

                Just (Mono.MonoCtor _ _) ->
                    Just Mono.FlattenedExternal

                Just (Mono.MonoEnum _ _) ->
                    Just Mono.FlattenedExternal

                _ ->
                    Just Mono.StageCurried

        Mono.MonoVarKernel _ _ _ _ ->
            Just Mono.FlattenedExternal

        Mono.MonoVarLocal name _ ->
            Dict.get name env.varCallModel

        Mono.MonoClosure _ _ _ ->
            Just Mono.StageCurried

        _ ->
            Nothing


{-| Get call model for a callee, defaulting to StageCurried. -}
callModelForCallee : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Mono.CallModel
callModelForCallee graph env funcExpr =
    case callModelForExpr graph env funcExpr of
        Just model ->
            model

        Nothing ->
            -- Default: user closures / expressions use StageCurried model
            Mono.StageCurried
```

### Step 4.4: Implement computeCallInfo

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

**Add import:**
```elm
import Compiler.GlobalOpt.MonoReturnArity as MonoReturnArity
```

**Add function:**
```elm
{-| Compute CallInfo for a MonoCall based on callee and arguments.
    This is the core logic that moves staging decisions into GlobalOpt.
-}
computeCallInfo :
    Mono.MonoGraph
    -> CallEnv
    -> Mono.MonoExpr
    -> List Mono.MonoExpr
    -> Mono.MonoType
    -> Mono.CallInfo
computeCallInfo graph env func args resultType =
    let
        callModel =
            callModelForCallee graph env func
    in
    case callModel of
        Mono.FlattenedExternal ->
            -- No staged-curried logic needed; existing MLIR code treats
            -- extern partial vs saturated based on resultType alone.
            { Mono.defaultCallInfo
                | callModel = Mono.FlattenedExternal
            }

        Mono.StageCurried ->
            let
                funcType : Mono.MonoType
                funcType =
                    Mono.typeOf func

                -- Full stage segmentation for the function type
                stageAritiesFull : List Int
                stageAritiesFull =
                    MonoReturnArity.collectStageArities funcType

                totalArity : Int
                totalArity =
                    List.sum stageAritiesFull

                firstStageArity : Int
                firstStageArity =
                    case stageAritiesFull of
                        n :: _ ->
                            n

                        [] ->
                            0

                argCount : Int
                argCount =
                    List.length args

                isSingleStageSaturated : Bool
                isSingleStageSaturated =
                    argCount == totalArity
                        && argCount <= firstStageArity
                        && totalArity > 0

                -- Stage arity at this call site (for applyByStages sourceRemaining)
                initialRemaining : Int
                initialRemaining =
                    firstStageArity

                -- Stage arities for subsequent stages (for applyByStages)
                remainingStageArities : List Int
                remainingStageArities =
                    case funcType of
                        Mono.MFunction _ retType ->
                            MonoReturnArity.collectStageArities retType

                        _ ->
                            []
            in
            { callModel = Mono.StageCurried
            , stageArities = stageAritiesFull
            , isSingleStageSaturated = isSingleStageSaturated
            , initialRemaining = initialRemaining
            , remainingStageArities = remainingStageArities
            }
```

### Step 4.5: Implement annotateCallStaging

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

```elm
{-| Phase: Annotate all MonoCall nodes with precomputed staging metadata.
    After this phase, MLIR codegen can use CallInfo directly without
    recomputing call models or stage arities.
-}
annotateCallStaging : Mono.MonoGraph -> Mono.MonoGraph
annotateCallStaging graph =
    let
        (Mono.MonoGraph record) =
            graph

        ( newNodes, _ ) =
            Dict.foldl
                (\specId node ( accNodes, _ ) ->
                    let
                        newNode =
                            annotateNodeCalls graph emptyCallEnv node
                    in
                    ( Dict.insert specId newNode accNodes, () )
                )
                ( Dict.empty, () )
                record.nodes
    in
    Mono.MonoGraph { record | nodes = newNodes }
```

### Step 4.6: Implement annotateNodeCalls

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

```elm
annotateNodeCalls : Mono.MonoGraph -> CallEnv -> Mono.MonoNode -> Mono.MonoNode
annotateNodeCalls graph env node =
    case node of
        Mono.MonoDefine expr tipe ->
            Mono.MonoDefine (annotateExprCalls graph env expr) tipe

        Mono.MonoTailFunc params body tipe ->
            Mono.MonoTailFunc params (annotateExprCalls graph env body) tipe

        Mono.MonoPortIncoming expr tipe ->
            Mono.MonoPortIncoming (annotateExprCalls graph env expr) tipe

        Mono.MonoPortOutgoing expr tipe ->
            Mono.MonoPortOutgoing (annotateExprCalls graph env expr) tipe

        Mono.MonoCycle defs tipe ->
            let
                newDefs =
                    List.map
                        (\( name, e ) -> ( name, annotateExprCalls graph env e ))
                        defs
            in
            Mono.MonoCycle newDefs tipe

        -- Constructors, enums, externs contain no expressions
        _ ->
            node
```

### Step 4.7: Implement annotateExprCalls

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

```elm
annotateExprCalls : Mono.MonoGraph -> CallEnv -> Mono.MonoExpr -> Mono.MonoExpr
annotateExprCalls graph env expr =
    case expr of
        Mono.MonoCall region func args resultType _ ->
            let
                func1 =
                    annotateExprCalls graph env func

                args1 =
                    List.map (annotateExprCalls graph env) args

                callInfo =
                    computeCallInfo graph env func1 args1 resultType
            in
            Mono.MonoCall region func1 args1 resultType callInfo

        Mono.MonoLet def body tipe ->
            let
                ( def1, env1 ) =
                    annotateDefCalls graph env def

                body1 =
                    annotateExprCalls graph env1 body
            in
            Mono.MonoLet def1 body1 tipe

        Mono.MonoClosure info body tipe ->
            let
                newCaptures =
                    List.map
                        (\( n, e, flag ) -> ( n, annotateExprCalls graph env e, flag ))
                        info.captures

                body1 =
                    annotateExprCalls graph env body
            in
            Mono.MonoClosure { info | captures = newCaptures } body1 tipe

        Mono.MonoIf branches final tipe ->
            let
                branches1 =
                    List.map
                        (\( c, t ) ->
                            ( annotateExprCalls graph env c
                            , annotateExprCalls graph env t
                            )
                        )
                        branches

                final1 =
                    annotateExprCalls graph env final
            in
            Mono.MonoIf branches1 final1 tipe

        Mono.MonoDestruct d inner tipe ->
            Mono.MonoDestruct d (annotateExprCalls graph env inner) tipe

        Mono.MonoCase s1 s2 decider branches tipe ->
            let
                decider1 =
                    annotateDeciderCalls graph env decider

                branches1 =
                    List.map
                        (\( p, e ) -> ( p, annotateExprCalls graph env e ))
                        branches
            in
            Mono.MonoCase s1 s2 decider1 branches1 tipe

        Mono.MonoList region items tipe ->
            Mono.MonoList region (List.map (annotateExprCalls graph env) items) tipe

        Mono.MonoRecordCreate fields tipe ->
            Mono.MonoRecordCreate
                (List.map (\( n, e ) -> ( n, annotateExprCalls graph env e )) fields)
                tipe

        Mono.MonoRecordAccess inner name tipe ->
            Mono.MonoRecordAccess (annotateExprCalls graph env inner) name tipe

        Mono.MonoRecordUpdate record updates tipe ->
            Mono.MonoRecordUpdate
                (annotateExprCalls graph env record)
                (List.map (\( n, e ) -> ( n, annotateExprCalls graph env e )) updates)
                tipe

        Mono.MonoTupleCreate region items tipe ->
            Mono.MonoTupleCreate region (List.map (annotateExprCalls graph env) items) tipe

        Mono.MonoTailCall name args tipe ->
            -- Tail calls use their own representation, no CallInfo needed
            Mono.MonoTailCall name
                (List.map (\( n, e ) -> ( n, annotateExprCalls graph env e )) args)
                tipe

        -- Leaves: literals, vars (no subexpressions)
        _ ->
            expr
```

### Step 4.8: Implement annotateDefCalls (with CallEnv propagation)

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

```elm
{-| Annotate calls in a definition and propagate call model to CallEnv.
    This replaces MLIR's Ctx.lookupVarCallModel logic for local aliases.
-}
annotateDefCalls :
    Mono.MonoGraph
    -> CallEnv
    -> Mono.MonoDef
    -> ( Mono.MonoDef, CallEnv )
annotateDefCalls graph env def =
    case def of
        Mono.MonoDef name bound ->
            let
                bound1 =
                    annotateExprCalls graph env bound

                maybeModel =
                    callModelForExpr graph env bound1

                env1 =
                    case maybeModel of
                        Just model ->
                            { env
                                | varCallModel =
                                    Dict.insert name model env.varCallModel
                            }

                        Nothing ->
                            env
            in
            ( Mono.MonoDef name bound1, env1 )

        Mono.MonoTailDef name params bound ->
            -- Tail defs are only referenced by MonoTailCall (string name),
            -- not VarLocal, so no callModel mapping is needed.
            ( Mono.MonoTailDef name params (annotateExprCalls graph env bound), env )
```

### Step 4.9: Implement annotateDeciderCalls and annotateChoiceCalls

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

```elm
annotateDeciderCalls : Mono.MonoGraph -> CallEnv -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
annotateDeciderCalls graph env decider =
    case decider of
        Mono.Leaf choice ->
            Mono.Leaf (annotateChoiceCalls graph env choice)

        Mono.Chain edges success failure ->
            Mono.Chain edges
                (annotateDeciderCalls graph env success)
                (annotateDeciderCalls graph env failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut path
                (List.map (\( test, d ) -> ( test, annotateDeciderCalls graph env d )) edges)
                (annotateDeciderCalls graph env fallback)


annotateChoiceCalls : Mono.MonoGraph -> CallEnv -> Mono.MonoChoice -> Mono.MonoChoice
annotateChoiceCalls graph env choice =
    case choice of
        Mono.Inline expr ->
            Mono.Inline (annotateExprCalls graph env expr)

        Mono.Jump i ->
            Mono.Jump i
```

---

## Phase 5: MLIR Context Changes — Use Mono.CallModel

### Step 5.1: Update imports in Context.elm

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

**Ensure import:**
```elm
import Compiler.AST.Monomorphized as Mono
```

### Step 5.2: Remove CallModel type from Context.elm

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

**Delete:**
```elm
type CallModel
    = FlattenedExternal
    | StageCurried
```

### Step 5.3: Update FuncSignature and VarInfo

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

**Change references from `CallModel` to `Mono.CallModel`:**
```elm
type alias FuncSignature =
    { paramTypes : List Mono.MonoType
    , returnType : Mono.MonoType
    , callModel : Mono.CallModel  -- Was: CallModel
    , returnedClosureParamCount : Maybe Int
    }

type alias VarInfo =
    { ssaVar : String
    , mlirType : MlirType
    , callModel : Maybe Mono.CallModel  -- Was: Maybe CallModel
    , sourceArity : Maybe Int
    }
```

### Step 5.4: Update all CallModel references

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

Change all occurrences:
- `FlattenedExternal` → `Mono.FlattenedExternal`
- `StageCurried` → `Mono.StageCurried`

**In `isFlattenedExternalSpec`:**
```elm
isFlattenedExternalSpec : Int -> Context -> Bool
isFlattenedExternalSpec specId ctx =
    case Dict.get specId ctx.signatures of
        Just sig ->
            sig.callModel == Mono.FlattenedExternal

        Nothing ->
            False
```

**In `extractNodeSignature`:**
Update pattern matches to use `Mono.FlattenedExternal` / `Mono.StageCurried`.

### Step 5.5: Update module exports

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

**Remove `CallModel(..)` from exports.**

---

## Phase 6: MLIR Expr Changes — Consume CallInfo

### Step 6.1: Update generateExpr pattern

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Change:**
```elm
-- Before:
Mono.MonoCall _ func args resultType ->
    generateCall ctx func args resultType

-- After:
Mono.MonoCall _ func args resultType callInfo ->
    generateCall ctx func args resultType callInfo
```

### Step 6.2: Update generateCall signature and implementation

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**New signature:**
```elm
generateCall :
    Ctx.Context
    -> Mono.MonoExpr
    -> List Mono.MonoExpr
    -> Mono.MonoType
    -> Mono.CallInfo
    -> ExprResult
```

**New implementation:**
```elm
generateCall ctx func args resultType callInfo =
    case callInfo.callModel of
        Mono.FlattenedExternal ->
            -- Kernels / externs: use ABI-flattened model.
            if Types.isFunctionType resultType then
                -- Partial application of an extern (rare but possible)
                generateClosureApplication ctx func args resultType callInfo
            else
                -- Fully-saturated external call
                generateSaturatedCall ctx func args resultType

        Mono.StageCurried ->
            if callInfo.isSingleStageSaturated then
                -- Single-stage saturated call: use saturated path (has intrinsic logic)
                generateSaturatedCall ctx func args resultType
            else
                -- Multi-stage call or partial application: use closure path
                generateClosureApplication ctx func args resultType callInfo
```

### Step 6.3: Update generateClosureApplication

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**New signature:**
```elm
generateClosureApplication :
    Ctx.Context
    -> Mono.MonoExpr
    -> List Mono.MonoExpr
    -> Mono.MonoType
    -> Mono.CallInfo
    -> ExprResult
```

**Key changes in implementation:**

Replace the entire block that computes `(initialRemaining, remainingStageArities)` with direct use of `CallInfo`:

**Before (delete this logic):**
```elm
( initialRemaining, remainingStageArities ) =
    case func of
        Mono.MonoVarLocal name _ ->
            case Ctx.lookupVarArity ctx1b name of
                Just arity ->
                    ( arity, collectStageArities (Mono.stageReturnType funcType) )
                Nothing ->
                    ...
        Mono.MonoVarGlobal _ specId _ ->
            case Dict.get specId ctx.signatures of
                Just sig ->
                    ...
        Mono.MonoClosure closureInfo _ _ ->
            ...
        _ ->
            ...
```

**After (use CallInfo directly):**
```elm
let
    initialRemaining =
        callInfo.initialRemaining

    remainingStageArities =
        callInfo.remainingStageArities

    papResult =
        applyByStages
            ctx1b
            funcResult.resultVar
            funcResult.resultType
            initialRemaining
            remainingStageArities
            expectedType
            boxedArgsWithTypes
            []
in
...
```

### Step 6.4: Delete staging helpers from Expr.elm

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Delete:**
- `callModelForExpr` function
- `callModelForCallee` function
- Local `collectStageArities` function (use `MonoReturnArity.collectStageArities` in GlobalOpt only)

**Remove uses of:**
- `Mono.stageReturnType` in codegen
- `Mono.stageParamTypes` in codegen
- `Mono.stageArity` in codegen

### Step 6.5: Update Ctx references in Expr.elm

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Change all occurrences:**
- `Ctx.FlattenedExternal` → `Mono.FlattenedExternal`
- `Ctx.StageCurried` → `Mono.StageCurried`

### Step 6.6: Keep applyByStages unchanged

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

`applyByStages` signature stays the same:
```elm
applyByStages :
    Ctx.Context
    -> String          -- funcVar
    -> MlirType        -- funcMlirType
    -> Int             -- sourceRemaining (now from callInfo.initialRemaining)
    -> List Int        -- remainingStageArities (now from callInfo.remainingStageArities)
    -> MlirType        -- saturatedReturnType
    -> List ( String, MlirType )
    -> List MlirOp
    -> ApplyByStagesResult
```

It is now purely metadata-driven; no call site passes `Mono.stageReturnType` or `collectStageArities` anymore.

---

## Phase 7: Intrinsics & Kernel Signatures — Keep in MLIR

### 7.1: Intrinsic detection stays in MLIR

**Files:** `Compiler/Generate/MLIR/Intrinsics.elm`, `Compiler/Generate/MLIR/Expr.elm`

**Rationale:**
- Intrinsics are a backend concern; they don't affect staging invariants
- Keeping them in MLIR avoids coupling GlobalOpt to MLIR-specific ops
- `generateSaturatedCall` continues to use `Intrinsics.kernelIntrinsic` as-is

**No changes needed** for intrinsics in this refactor.

### 7.2: kernelFuncSignatureFromType stays in Context.elm

**File:** `compiler/src/Compiler/Generate/MLIR/Context.elm`

**Rationale:**
- This refactor focuses on curried staging, not kernel ABI
- Kernels are not entangled with stage-curried closure logic
- Optional future work: move kernel signatures to GlobalOpt

**No changes needed** for kernel signatures in this refactor.

---

## Phase 8: Update Tests

### Step 8.1: Update test utilities

Any test code that constructs `MonoCall` expressions needs the additional `CallInfo` parameter.

### Step 8.2: Run test suite

```bash
cd compiler && npx elm-test-rs --fuzz 1
cmake --build build --target check
```

---

## File-by-File Checklist

| File | Changes |
|------|---------|
| `Compiler/AST/Monomorphized.elm` | Add `CallModel`, `CallInfo`, `defaultCallInfo`; extend `MonoCall` |
| `Compiler/Generate/Monomorphize/Specialize.elm` | Add `Mono.defaultCallInfo` to all `MonoCall` constructions |
| `Compiler/Generate/Monomorphize/Closure.elm` | Check for `MonoCall` construction, add `defaultCallInfo` |
| `Compiler/GlobalOpt/MonoGlobalOptimize.elm` | Add `CallEnv`, `callModelForExpr`, `computeCallInfo`, `annotateCallStaging` phase; thread `callInfo` through traversals |
| `Compiler/GlobalOpt/MonoInlineSimplify.elm` | Thread `callInfo` through all `MonoCall` patterns |
| `Compiler/Generate/MLIR/Context.elm` | Remove `CallModel` type; use `Mono.CallModel` |
| `Compiler/Generate/MLIR/Expr.elm` | Consume `CallInfo`; delete `callModelForCallee`, `callModelForExpr`, local `collectStageArities`; remove `Mono.stageReturnType` usage |

---

## Grep Patterns for Implementation

**Find all MonoCall pattern matches:**
```bash
grep -rn "MonoCall" compiler/src/ | grep -v "\.elm~"
```

**Find all MonoCall constructions:**
```bash
grep -rn "Mono\.MonoCall" compiler/src/
```

**Find staging helper usages to remove from Expr.elm:**
```bash
grep -n "collectStageArities\|stageReturnType\|stageParamTypes\|stageArity" compiler/src/Compiler/Generate/MLIR/Expr.elm
```

**Find CallModel references to update:**
```bash
grep -rn "Ctx\.FlattenedExternal\|Ctx\.StageCurried\|CallModel" compiler/src/Compiler/Generate/MLIR/
```

---

## Summary of CallInfo Fields

For each `MonoCall`, GlobalOpt computes:

| Field | Type | Purpose |
|-------|------|---------|
| `callModel` | `Mono.CallModel` | `FlattenedExternal` for externs/kernels; `StageCurried` for user closures |
| `stageArities` | `List Int` | Full segmentation of callee type, e.g. `[2,1]` |
| `isSingleStageSaturated` | `Bool` | Decides `generateSaturatedCall` vs `generateClosureApplication` |
| `initialRemaining` | `Int` | Stage arity at call site (applyByStages `sourceRemaining`) |
| `remainingStageArities` | `List Int` | Subsequent stage arities (applyByStages input) |

These five fields eliminate the need for:
- `callModelForCallee` in MLIR
- `Mono.stageReturnType`, `Mono.stageParamTypes`, `Mono.stageArity` in MLIR codegen
- Local `collectStageArities` in MLIR

All staging / curried-call decisions are made **once** in GlobalOpt, and MLIR codegen becomes a simple, metadata-driven emitter.
