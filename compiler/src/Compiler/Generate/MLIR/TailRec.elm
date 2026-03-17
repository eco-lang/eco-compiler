module Compiler.Generate.MLIR.TailRec exposing (compileTailFuncToWhile)

{-| SCF-based tail-recursion compilation.

This module compiles self-tail-recursive functions to scf.while loops.
It replaces the joinpoint+eco.jump pattern with direct loop emission.

The key insight is that a tail-recursive function can be compiled to:

    scf.while (%params..., %done, %result) : (...) -> (...) {
        // before-region: check if done
        %continue = arith.xori %done, true
        scf.condition(%continue) %params..., %done, %result
    } do {
        // after-region: compute next state via eco.case
        %next_params..., %next_done, %next_result = eco.case ... { eco.yield ... }
        scf.yield %next_params..., %next_done, %next_result
    }

@docs compileTailFuncToWhile

-}

import Array exposing (Array)
import Compiler.AST.DecisionTree.Test as Test
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name as Name
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Expr as Expr
import Compiler.Generate.MLIR.Intrinsics as Intrinsics
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.Patterns as Patterns
import Compiler.Generate.MLIR.Types as Types
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Mlir.Mlir exposing (MlirOp, MlirRegion(..), MlirType(..))
import Dict
import OrderedDict
import Utils.Crash exposing (crash)



-- ============================================================================
-- ====== TYPES ======
-- ============================================================================


{-| Specification of the loop being compiled.
Contains information needed to compile step expressions.
-}
type alias LoopSpec =
    { funcName : String
    , paramVars : List ( String, MlirType ) -- SSA vars for params (scf.while after-region block args)
    , retType : MlirType
    }


{-| Result of compiling a single step of the loop body.

Invariant: resultType must always equal loopSpec.retType for the enclosing
compileStep/LoopSpec. All step forms (tail calls, base returns, cases, ifs)
are responsible for producing a resultVar of this type.

-}
type alias StepResult =
    { ops : List MlirOp
    , nextParams : List ( String, MlirType ) -- SSA vars for next iteration
    , doneVar : String -- i1: true = done, false = continue
    , resultVar : String -- result when done
    , resultType : MlirType -- type of resultVar (== loopSpec.retType)
    , ctx : Ctx.Context
    }



-- ============================================================================
-- ====== MAIN ENTRY POINT ======
-- ============================================================================


{-| Compile a tail-recursive function body to an scf.while loop.

Returns the ops for the function body (init-ops + scf.while + eco.return).

-}
compileTailFuncToWhile :
    Ctx.Context
    -> String -- func name
    -> List ( String, MlirType ) -- function args (already in context)
    -> Mono.MonoExpr -- body expression
    -> MlirType -- return type
    -> ( List MlirOp, Ctx.Context )
compileTailFuncToWhile ctx funcName paramPairs body retTy =
    let
        -- Step 1: Define initial state
        -- Loop state = (p1..pn, done, result) where done starts as false
        -- and result starts as a dummy value
        ( doneInitVar, ctx1 ) =
            Ctx.freshVar ctx

        ( ctx2, doneInitOp ) =
            Ops.arithConstantBool ctx1 doneInitVar False

        ( resInitOps, resInitVar, ctx3 ) =
            Expr.createDummyValue ctx2 retTy

        initOps =
            doneInitOp :: resInitOps

        -- Step 2: Collect initial values for loop state
        -- Order: params..., done, result
        paramInitVars =
            List.map Tuple.first paramPairs

        paramTypes =
            List.map Tuple.second paramPairs

        -- State types: (paramTypes..., i1, retTy)
        stateTypes =
            paramTypes ++ [ I1, retTy ]

        initVars =
            paramInitVars ++ [ doneInitVar, resInitVar ]

        -- Step 3: Allocate fresh SSA names for scf.while results
        ( resultVars, ctx4 ) =
            allocateFreshVars ctx3 (List.length stateTypes)

        -- Build triples for scf.while: (resultVar, initVar, type)
        triples =
            List.map3 (\r i t -> ( r, i, t )) resultVars initVars stateTypes

        -- Step 4: Build before-region (condition check)
        ( beforeRegion, beforeArgs, ctx5 ) =
            buildBeforeRegion ctx4 stateTypes

        -- Step 5: Build after-region (loop body)
        loopSpec =
            { funcName = funcName
            , paramVars =
                -- The after-region block args for params (first n args)
                List.take (List.length paramPairs) (zip beforeArgs stateTypes)
            , retType = retTy
            }

        -- Original parameter pairs (e.g., [("%acc", I64), ("%n", I64)])
        -- These are needed to set up variable mappings in the after-region
        originalParamPairs =
            paramPairs

        ( afterRegion, ctx6 ) =
            buildAfterRegion ctx5 stateTypes loopSpec body originalParamPairs

        -- Step 6: Emit scf.while
        ( ctx7, whileOp ) =
            Ops.scfWhile ctx6 triples beforeRegion afterRegion

        -- Step 7: Return the result (last element of scf.while results)
        resFinalVar =
            List.drop (List.length stateTypes - 1) resultVars
                |> List.head
                |> Maybe.withDefault "%error_no_result"

        ( ctx8, returnOp ) =
            Ops.ecoReturn ctx7 resFinalVar retTy
    in
    ( initOps ++ [ whileOp, returnOp ], ctx8 )



-- ============================================================================
-- ====== BEFORE REGION (CONDITION) ======
-- ============================================================================


{-| Build the before-region for scf.while.

The before-region checks if we should continue looping:
%continue = arith.xori %done, true : i1
scf.condition(%continue) %params..., %done, %result

-}
buildBeforeRegion :
    Ctx.Context
    -> List MlirType
    -> ( MlirRegion, List String, Ctx.Context )
buildBeforeRegion ctx stateTypes =
    let
        numParams =
            List.length stateTypes - 2

        -- Allocate block args
        ( blockArgs, ctx1 ) =
            allocateFreshVars ctx (List.length stateTypes)

        blockArgPairs =
            zip blockArgs stateTypes

        -- done is at index numParams (second-to-last)
        doneArg =
            List.drop numParams blockArgs
                |> List.head
                |> Maybe.withDefault "%error_no_done"

        -- Compute continue = xor(done, true)
        ( continueVar, ctx2 ) =
            Ctx.freshVar ctx1

        ( trueVar, ctx3 ) =
            Ctx.freshVar ctx2

        ( ctx4, trueOp ) =
            Ops.arithConstantBool ctx3 trueVar True

        ( ctx5, xorOp ) =
            Ops.ecoBinaryOp ctx4 "arith.xori" continueVar ( doneArg, I1 ) ( trueVar, I1 ) I1

        -- scf.condition
        ( ctx6, conditionOp ) =
            Ops.scfCondition ctx5 continueVar blockArgPairs

        region =
            mkSingleBlockRegion blockArgPairs [ trueOp, xorOp ] conditionOp
    in
    ( region, blockArgs, ctx6 )



-- ============================================================================
-- ====== AFTER REGION (LOOP BODY) ======
-- ============================================================================


{-| Build the after-region for scf.while.

The after-region computes the next loop state by compiling the body expression.

-}
buildAfterRegion :
    Ctx.Context
    -> List MlirType
    -> LoopSpec
    -> Mono.MonoExpr
    -> List ( String, MlirType ) -- original parameter pairs (e.g., [("%acc", I64)])
    -> ( MlirRegion, Ctx.Context )
buildAfterRegion ctx stateTypes loopSpec body originalParamPairs =
    let
        -- Allocate block args
        ( blockArgs, ctx1 ) =
            allocateFreshVars ctx (List.length stateTypes)

        blockArgPairs =
            zip blockArgs stateTypes

        -- Set up context with block args as variables
        numParams =
            List.length loopSpec.paramVars

        -- The new block args for parameters (first numParams items)
        newParamBlockArgs =
            List.take numParams blockArgPairs

        -- Update loopSpec to use actual after-region block args
        updatedLoopSpec =
            { loopSpec | paramVars = newParamBlockArgs }

        -- Set up variable mappings for the block args
        -- Map original Elm names to new block argument SSA names
        ctxWithArgs =
            setupVarMappings ctx1 originalParamPairs newParamBlockArgs

        -- Compile the step
        stepResult =
            compileStep ctxWithArgs updatedLoopSpec body

        -- Build scf.yield with (nextParams..., done, result)
        -- Use actual types from stepResult
        yieldOperands =
            stepResult.nextParams ++ [ ( stepResult.doneVar, I1 ), ( stepResult.resultVar, stepResult.resultType ) ]

        ( ctx2, yieldOp ) =
            Ops.scfYieldMany stepResult.ctx yieldOperands

        region =
            mkSingleBlockRegion blockArgPairs stepResult.ops yieldOp
    in
    ( region, ctx2 )


{-| Set up variable mappings so that parameter names in the body can be resolved.

Takes the original parameter pairs (with SSA names like "%acc") and the new block
argument pairs (with fresh SSA names like "%v5"), and updates the context's
varMappings so that references to the original names resolve to the new block args.

-}
setupVarMappings : Ctx.Context -> List ( String, MlirType ) -> List ( String, MlirType ) -> Ctx.Context
setupVarMappings ctx originalParamPairs newBlockArgPairs =
    -- Zip the original and new pairs together, then update varMappings
    List.foldl
        (\( ( origSsaName, _ ), ( newSsaName, newType ) ) accCtx ->
            -- Extract the Elm name by stripping the "%" prefix from the original SSA name
            let
                elmName =
                    String.dropLeft 1 origSsaName
            in
            -- Update the mapping: elmName -> newSsaName with the new type
            Ctx.addVarMapping elmName newSsaName newType accCtx
        )
        ctx
        (zip originalParamPairs newBlockArgPairs)



-- ============================================================================
-- ====== STEP COMPILATION ======
-- ============================================================================


{-| Compile a single step of the loop body.

This is the main dispatcher that handles different expression types:

  - MonoTailCall -> continue looping with new args
  - MonoCase -> multi-result eco.case for step computation
  - MonoIf -> treat as 2-way case
  - Other -> base case return (done=true)

-}
compileStep : Ctx.Context -> LoopSpec -> Mono.MonoExpr -> StepResult
compileStep ctx loopSpec expr =
    case expr of
        Mono.MonoTailCall _ args _ ->
            -- Inside a MonoTailFunc, MonoTailCall is always a self-recursive call
            -- (the IR structure guarantees this - MonoTailCall only appears in
            -- MonoTailFunc bodies and always refers back to the enclosing function)
            compileTailCallStep ctx loopSpec args

        Mono.MonoCase scrutinee1 scrutinee2 decider jumps resultType ->
            -- Case expression -> multi-result eco.case
            compileCaseStep ctx loopSpec scrutinee1 scrutinee2 decider jumps resultType

        Mono.MonoIf branches final _ ->
            -- If expression -> treat as multi-way case
            compileIfStep ctx loopSpec branches final

        Mono.MonoLet def body _ ->
            -- Let expression -> compile def, then recurse on body
            compileLetStep ctx loopSpec def body

        Mono.MonoDestruct destructor body _ ->
            -- Destruct expression -> generate path + binding, then recurse on body
            compileDestructStep ctx loopSpec destructor body

        _ ->
            -- All other expressions -> base return (done=true)
            compileBaseReturnStep ctx loopSpec expr



-- ============================================================================
-- ====== TAIL CALL STEP ======
-- ============================================================================


{-| Compile a MonoTailCall as a "continue" step.

Sets done=false and evaluates new argument values.

-}
compileTailCallStep :
    Ctx.Context
    -> LoopSpec
    -> List ( Name.Name, Mono.MonoExpr )
    -> StepResult
compileTailCallStep ctx loopSpec args =
    let
        -- Loop parameters and their ABI MLIR types (e.g. Bool -> !eco.value)
        paramTypes : Array MlirType
        paramTypes =
            loopSpec.paramVars
                |> List.map Tuple.second
                |> Array.fromList

        -- Evaluate each argument expression and coerce to the loop's ABI param types.
        ( argOpsRev, argVarsRev, ctx1 ) =
            List.foldl
                (\( index, ( _, argExpr ) ) ( opsAcc, varsAcc, ctxAcc ) ->
                    let
                        argResult =
                            Expr.generateExpr ctxAcc argExpr

                        expectedTy : MlirType
                        expectedTy =
                            case Array.get index paramTypes of
                                Just ty ->
                                    ty

                                Nothing ->
                                    crash
                                        ("TailRec.compileTailCallStep: arity mismatch for tail call in "
                                            ++ loopSpec.funcName
                                        )

                        ( coerceOps, finalVar, ctxCoerced ) =
                            Expr.coerceResultToType
                                argResult.ctx
                                argResult.resultVar
                                argResult.resultType
                                expectedTy

                        chunkOps =
                            argResult.ops ++ coerceOps
                    in
                    ( List.reverse chunkOps ++ opsAcc
                    , ( finalVar, expectedTy ) :: varsAcc
                    , ctxCoerced
                    )
                )
                ( [], [], ctx )
                (List.indexedMap Tuple.pair args)

        argOps =
            List.reverse argOpsRev

        argVars =
            List.reverse argVarsRev

        -- done = false (continue looping)
        ( doneVar, ctx2 ) =
            Ctx.freshVar ctx1

        ( ctx3, doneOp ) =
            Ops.arithConstantBool ctx2 doneVar False

        -- result = dummy (not used when continuing)
        ( dummyOps, dummyVar, ctx4 ) =
            Expr.createDummyValue ctx3 loopSpec.retType
    in
    { ops = argOps ++ [ doneOp ] ++ dummyOps
    , nextParams = argVars
    , doneVar = doneVar
    , resultVar = dummyVar
    , resultType = loopSpec.retType
    , ctx = ctx4
    }



-- ============================================================================
-- ====== BASE RETURN STEP ======
-- ============================================================================


{-| Compile a non-tail expression as a "done" step.

Sets done=true and evaluates the expression as the result.

-}
compileBaseReturnStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoExpr
    -> StepResult
compileBaseReturnStep ctx loopSpec expr =
    let
        exprResult =
            Expr.generateExpr ctx expr
    in
    if exprResult.isTerminated then
        crash
            "TailRec.compileBaseReturnStep: encountered terminated ExprResult; extend compileStep to handle this expression shape directly."

    else
        let
            -- Coerce the expression result to the loop's result MLIR type.
            -- This mirrors generateDefine/generateClosureFunc, which coerce to
            -- the function's ABI return type before emitting eco.return.
            ( coerceOps, finalVar, ctx1 ) =
                Expr.coerceResultToType
                    exprResult.ctx
                    exprResult.resultVar
                    exprResult.resultType
                    loopSpec.retType

            -- done = true (base case)
            ( doneVar, ctx2 ) =
                Ctx.freshVar ctx1

            ( ctx3, doneOp ) =
                Ops.arithConstantBool ctx2 doneVar True

            nextParams =
                loopSpec.paramVars
        in
        { ops = exprResult.ops ++ coerceOps ++ [ doneOp ]
        , nextParams = nextParams
        , doneVar = doneVar
        , resultVar = finalVar
        , resultType = loopSpec.retType
        , ctx = ctx3
        }



-- ============================================================================
-- ====== CASE STEP ======
-- ============================================================================


{-| Compile a MonoCase as a multi-result eco.case step.

Each case alternative recursively calls compileStep, and the results
are yielded via eco.yieldMany. This mirrors Expr.generateCase but produces
StepResult instead of ExprResult.

-}
compileCaseStep :
    Ctx.Context
    -> LoopSpec
    -> Name.Name
    -> Name.Name
    -> Mono.Decider Mono.MonoChoice
    -> List ( Int, Mono.MonoExpr )
    -> Mono.MonoType
    -> StepResult
compileCaseStep ctx loopSpec _ _ decider jumps _ =
    let
        jumpLookup : Array (Maybe Mono.MonoExpr)
        jumpLookup =
            pairsToSparseArray jumps
    in
    compileCaseDeciderStep ctx loopSpec decider jumpLookup


{-| Compile a decision tree for a case expression as a single loop step.

This mirrors Expr.generateDeciderWithJumps, but instead of producing
an ExprResult for the case _value_, it produces a StepResult for the
loop state (nextParams..., done, result).

-}
compileCaseDeciderStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.Decider Mono.MonoChoice
    -> Array (Maybe Mono.MonoExpr)
    -> StepResult
compileCaseDeciderStep ctx loopSpec decider jumpLookup =
    case decider of
        Mono.Leaf choice ->
            compileCaseLeafStep ctx loopSpec choice jumpLookup

        Mono.Chain testChain success failure ->
            compileCaseChainStep ctx loopSpec testChain success failure jumpLookup

        Mono.FanOut path edges fallback ->
            compileCaseFanOutStep ctx loopSpec path edges fallback jumpLookup


{-| Leaf node in the decision tree.

Inline the branch expression and treat it as the step body.
This lets compileStep see any MonoTailCall and compile it into a continue
state, instead of going through Expr.generateTailCall/eco.jump.

-}
compileCaseLeafStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoChoice
    -> Array (Maybe Mono.MonoExpr)
    -> StepResult
compileCaseLeafStep ctx loopSpec choice jumpLookup =
    case choice of
        Mono.Inline branchExpr ->
            compileStep ctx loopSpec branchExpr

        Mono.Jump index ->
            case Array.get index jumpLookup |> Maybe.andThen identity of
                Just branchExpr ->
                    compileStep ctx loopSpec branchExpr

                Nothing ->
                    crash
                        ("compileCaseLeafStep: Jump index "
                            ++ String.fromInt index
                            ++ " not found in jumpLookup"
                        )


{-| Chain node: sequence of tests culminating in success/failure subtrees.

We compile the chain condition to an i1, then build a 2-way eco.caseMany
on that condition where each alternative yields the full step tuple.

-}
compileCaseChainStep :
    Ctx.Context
    -> LoopSpec
    -> List ( Mono.MonoDtPath, DT.Test )
    -> Mono.Decider Mono.MonoChoice
    -> Mono.Decider Mono.MonoChoice
    -> Array (Maybe Mono.MonoExpr)
    -> StepResult
compileCaseChainStep ctx loopSpec testChain success failure jumpLookup =
    let
        -- Compute the boolean condition (i1)
        ( condOps, condVar, condCtx ) =
            Patterns.generateMonoChainCondition ctx testChain

        -- Then branch
        thenStep =
            compileCaseDeciderStep condCtx loopSpec success jumpLookup

        thenYieldOperands =
            thenStep.nextParams
                ++ [ ( thenStep.doneVar, I1 )
                   , ( thenStep.resultVar, thenStep.resultType )
                   ]

        ( thenYieldCtx, thenYieldOp ) =
            Ops.ecoYieldMany thenStep.ctx thenYieldOperands

        thenRegion =
            mkSingleBlockRegion [] thenStep.ops thenYieldOp

        -- Else branch: reuse condCtx bindings but propagate accumulated state
        -- from the then branch (nextVar to avoid SSA conflicts, plus pendingLambdas,
        -- pendingFuncOps, and kernelDecls which accumulate across branches).
        ctxForElse =
            { condCtx
                | nextVar = thenYieldCtx.nextVar
                , pendingLambdas = thenYieldCtx.pendingLambdas
                , pendingFuncOps = thenYieldCtx.pendingFuncOps
                , kernelDecls = thenYieldCtx.kernelDecls
            }

        elseStep =
            compileCaseDeciderStep ctxForElse loopSpec failure jumpLookup

        elseYieldOperands =
            elseStep.nextParams
                ++ [ ( elseStep.doneVar, I1 )
                   , ( elseStep.resultVar, elseStep.resultType )
                   ]

        ( elseYieldCtx, elseYieldOp ) =
            Ops.ecoYieldMany elseStep.ctx elseYieldOperands

        elseRegion =
            mkSingleBlockRegion [] elseStep.ops elseYieldOp

        -- Step tuple types: (paramTypes..., i1, retTy)
        numParams =
            List.length loopSpec.paramVars

        paramTypes =
            List.map Tuple.second loopSpec.paramVars

        -- Allocate result names for the step tuple
        ( caseResultNames, ctxWithResults ) =
            allocateFreshVars elseYieldCtx (numParams + 2)

        caseResultPairs =
            zip caseResultNames (paramTypes ++ [ I1, loopSpec.retType ])

        -- eco.case on i1: tag 1 for True (then), tag 0 for False (else)
        ( ctxAfterCase, caseOp ) =
            Ops.ecoCaseMany
                ctxWithResults
                condVar
                I1
                "bool"
                [ 1, 0 ]
                [ thenRegion, elseRegion ]
                caseResultPairs

        nextParamVars =
            List.take numParams caseResultPairs

        doneResultVar =
            List.drop numParams caseResultNames
                |> List.head
                |> Maybe.withDefault "%error_no_done"

        resultResultVar =
            List.drop (numParams + 1) caseResultNames
                |> List.head
                |> Maybe.withDefault "%error_no_result"
    in
    { ops = condOps ++ [ caseOp ]
    , nextParams = nextParamVars
    , doneVar = doneResultVar
    , resultVar = resultResultVar
    , resultType = loopSpec.retType
    , ctx = ctxAfterCase
    }


{-| FanOut node: multi-way branching on constructor tags, ints, chars, or strings.

We generate an eco.case/eco.case\_string whose result tuple is
(nextParams..., done, result). Each alternative region yields this tuple
via eco.yieldMany.

-}
compileCaseFanOutStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoDtPath
    -> List ( DT.Test, Mono.Decider Mono.MonoChoice )
    -> Mono.Decider Mono.MonoChoice
    -> Array (Maybe Mono.MonoExpr)
    -> StepResult
compileCaseFanOutStep ctx loopSpec path edges fallback jumpLookup =
    let
        edgeTests =
            List.map Tuple.first edges

        caseKind =
            case edgeTests of
                firstTest :: _ ->
                    Patterns.caseKindFromTest firstTest

                [] ->
                    "ctor"

        scrutineeType =
            Patterns.scrutineeTypeFromCaseKind caseKind

        ( pathOps, scrutineeVar, ctx1 ) =
            Patterns.generateMonoDtPath ctx path scrutineeType

        -- Tags and (optional) string patterns
        ( tags, stringPatterns ) =
            if caseKind == "str" then
                let
                    edgeCount =
                        List.length edges

                    altCount =
                        edgeCount + 1

                    patterns =
                        edges
                            |> List.map Tuple.first
                            |> List.map extractStringPatternForStep

                    sequentialTags =
                        List.range 0 (altCount - 1)
                in
                ( sequentialTags, Just patterns )

            else
                let
                    edgeTags =
                        List.map (\( test, _ ) -> Patterns.testToTagInt test) edges

                    fallbackTag =
                        Patterns.computeFallbackTag edgeTests
                in
                ( edgeTags ++ [ fallbackTag ], Nothing )

        -- Compile edge regions
        ( edgeRegionsRev, ctx2 ) =
            List.foldl
                (\( _, subTree ) ( accRegions, accCtx ) ->
                    let
                        subStep =
                            compileCaseDeciderStep accCtx loopSpec subTree jumpLookup

                        yieldOperands =
                            subStep.nextParams
                                ++ [ ( subStep.doneVar, I1 )
                                   , ( subStep.resultVar, subStep.resultType )
                                   ]

                        ( yieldCtx, yieldOp ) =
                            Ops.ecoYieldMany subStep.ctx yieldOperands

                        region =
                            mkSingleBlockRegion [] subStep.ops yieldOp
                    in
                    ( region :: accRegions, yieldCtx )
                )
                ( [], ctx1 )
                edges

        edgeRegions =
            List.reverse edgeRegionsRev

        -- Fallback region
        fallbackStep =
            compileCaseDeciderStep ctx2 loopSpec fallback jumpLookup

        fallbackYieldOperands =
            fallbackStep.nextParams
                ++ [ ( fallbackStep.doneVar, I1 )
                   , ( fallbackStep.resultVar, fallbackStep.resultType )
                   ]

        ( fallbackYieldCtx, fallbackYieldOp ) =
            Ops.ecoYieldMany fallbackStep.ctx fallbackYieldOperands

        fallbackRegion =
            mkSingleBlockRegion [] fallbackStep.ops fallbackYieldOp

        allRegions =
            edgeRegions ++ [ fallbackRegion ]

        -- Step tuple result types
        numParams =
            List.length loopSpec.paramVars

        paramTypes =
            List.map Tuple.second loopSpec.paramVars

        ( caseResultNames, ctxWithResults ) =
            allocateFreshVars fallbackYieldCtx (numParams + 2)

        caseResultPairs =
            zip caseResultNames (paramTypes ++ [ I1, loopSpec.retType ])

        -- Build eco.case / eco.case_string
        ( ctx3, caseOp ) =
            case stringPatterns of
                Just patterns ->
                    Ops.ecoCaseStringMany
                        ctxWithResults
                        scrutineeVar
                        scrutineeType
                        tags
                        patterns
                        allRegions
                        caseResultPairs

                Nothing ->
                    Ops.ecoCaseMany
                        ctxWithResults
                        scrutineeVar
                        scrutineeType
                        caseKind
                        tags
                        allRegions
                        caseResultPairs

        nextParamVars =
            List.take numParams caseResultPairs

        doneResultVar =
            List.drop numParams caseResultNames
                |> List.head
                |> Maybe.withDefault "%error_no_done"

        resultResultVar =
            List.drop (numParams + 1) caseResultNames
                |> List.head
                |> Maybe.withDefault "%error_no_result"
    in
    { ops = pathOps ++ [ caseOp ]
    , nextParams = nextParamVars
    , doneVar = doneResultVar
    , resultVar = resultResultVar
    , resultType = loopSpec.retType
    , ctx = ctx3
    }


{-| Extract string pattern from a DT.Test, crash if not a string test.
-}
extractStringPatternForStep : DT.Test -> String
extractStringPatternForStep test =
    case test of
        Test.IsStr s ->
            s

        _ ->
            crash "extractStringPatternForStep: expected Test.IsStr but got non-string test"



-- ============================================================================
-- ====== IF STEP ======
-- ============================================================================


{-| Compile a MonoIf as a step.

Generates a multi-result eco.case where each branch recursively calls compileStep.
The result is the step tuple (nextParams..., done, result).

-}
compileIfStep :
    Ctx.Context
    -> LoopSpec
    -> List ( Mono.MonoExpr, Mono.MonoExpr )
    -> Mono.MonoExpr
    -> StepResult
compileIfStep ctx loopSpec branches final =
    case branches of
        [] ->
            -- No more branches, compile the final expression
            compileStep ctx loopSpec final

        ( condExpr, thenExpr ) :: restBranches ->
            -- Compile the condition
            let
                condRes =
                    Expr.generateExpr ctx condExpr

                -- Ensure condition is i1 for eco.case
                ( condUnboxOps, condVar, condCtx ) =
                    if Types.isEcoValueType condRes.resultType then
                        -- Unbox Bool to i1 using eco.unbox
                        Intrinsics.unboxToType condRes.ctx condRes.resultVar I1

                    else
                        ( [], condRes.resultVar, condRes.ctx )

                -- Compile then branch with compileStep
                thenStep =
                    compileStep condCtx loopSpec thenExpr

                -- Build then region that yields the step tuple
                thenYieldOperands =
                    thenStep.nextParams ++ [ ( thenStep.doneVar, I1 ), ( thenStep.resultVar, thenStep.resultType ) ]

                ( thenYieldCtx, thenYieldOp ) =
                    Ops.ecoYieldMany thenStep.ctx thenYieldOperands

                thenRegion =
                    mkSingleBlockRegion [] thenStep.ops thenYieldOp

                -- Compile else branch recursively (handles nested if-else chains)
                elseStep =
                    compileIfStep thenYieldCtx loopSpec restBranches final

                -- Build else region that yields the step tuple
                elseYieldOperands =
                    elseStep.nextParams ++ [ ( elseStep.doneVar, I1 ), ( elseStep.resultVar, elseStep.resultType ) ]

                ( elseYieldCtx, elseYieldOp ) =
                    Ops.ecoYieldMany elseStep.ctx elseYieldOperands

                elseRegion =
                    mkSingleBlockRegion [] elseStep.ops elseYieldOp

                -- Build multi-result eco.case
                -- Step tuple types: (paramTypes..., i1, retTy)
                numParams =
                    List.length loopSpec.paramVars

                paramTypes =
                    List.map Tuple.second loopSpec.paramVars

                -- Allocate fresh names for the case results
                ( caseResultNames, ctxWithResults ) =
                    allocateFreshVars elseYieldCtx (numParams + 2)

                caseResultPairs =
                    zip caseResultNames (paramTypes ++ [ I1, loopSpec.retType ])

                -- eco.case on i1: tag 1 for True (then), tag 0 for False (else)
                ( ctxAfterCase, caseOp ) =
                    Ops.ecoCaseMany ctxWithResults condVar I1 "bool" [ 1, 0 ] [ thenRegion, elseRegion ] caseResultPairs

                -- Extract the step results from the case
                nextParamVars =
                    List.take numParams caseResultPairs

                doneResultVar =
                    List.drop numParams caseResultNames
                        |> List.head
                        |> Maybe.withDefault "%error_no_done"

                resultResultVar =
                    List.drop (numParams + 1) caseResultNames
                        |> List.head
                        |> Maybe.withDefault "%error_no_result"
            in
            { ops = condRes.ops ++ condUnboxOps ++ [ caseOp ]
            , nextParams = nextParamVars
            , doneVar = doneResultVar
            , resultVar = resultResultVar
            , resultType = loopSpec.retType
            , ctx = ctxAfterCase
            }



-- ============================================================================
-- ====== LET STEP ======
-- ============================================================================


{-| Compile a MonoLet step.

Delegates to Expr.generateLet (via a synthetic MonoLet wrapping) for each
definition, so that the full let-chain sibling context (placeholder
mappings, currentLetSiblings) is properly set up. This is critical for
self-recursive closures defined in let bindings — without sibling context
their PendingLambda gets empty siblingMappings and lookupVar fails for
the self-reference.

For MonoTailDef, we also delegate to Expr.generateExpr (which routes to
generateLet) for the definition setup, then use compileStep for the body
so that MonoTailCall for the outer function still generates correct loop
continuation.

-}
compileLetStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoDef
    -> Mono.MonoExpr
    -> StepResult
compileLetStep ctx loopSpec def body =
    let
        -- Collect ALL let-bound names from this point in the chain, including
        -- the current def and any subsequent MonoLet nodes in body. This mirrors
        -- Expr.collectLetBoundNames so that sibling closures can see each other.
        boundNames =
            Expr.collectLetBoundNames (Mono.MonoLet def body Mono.MUnit)

        -- Save outer siblings for restoration on exit (lexical scoping)
        outerSiblings =
            ctx.currentLetSiblings

        -- Build placeholder mappings for the whole let-group
        ctxWithPlaceholders =
            Expr.addPlaceholderMappings boundNames ctx

        -- Only include the let-bound names in currentLetSiblings (not all varMappings).
        -- This prevents outer-scope variables from leaking into lambda siblingMappings,
        -- which would cause cross-function SSA references (CGEN_CLOSURE_003).
        letBoundSiblings =
            List.foldl
                (\name acc ->
                    case Dict.get name ctxWithPlaceholders.varMappings of
                        Just info ->
                            Dict.insert name info acc

                        Nothing ->
                            acc
                )
                Dict.empty
                boundNames

        ctxReady =
            { ctxWithPlaceholders | currentLetSiblings = letBoundSiblings }
    in
    case def of
        Mono.MonoDef _ _ ->
            let
                defSetupExpr =
                    Mono.MonoLet def Mono.MonoUnit Mono.MUnit

                defSetupResult =
                    Expr.generateExpr ctxReady defSetupExpr

                ctxAfterDef =
                    defSetupResult.ctx

                ctxForBody =
                    { ctxAfterDef | currentLetSiblings = outerSiblings }

                bodyStep =
                    compileStep ctxForBody loopSpec body
            in
            { ops = defSetupResult.ops ++ bodyStep.ops
            , nextParams = bodyStep.nextParams
            , doneVar = bodyStep.doneVar
            , resultVar = bodyStep.resultVar
            , resultType = bodyStep.resultType
            , ctx = bodyStep.ctx
            }

        Mono.MonoTailDef _ _ _ ->
            -- Compile the MonoTailDef binding (pending lambda, papCreate) using
            -- Expr.generateExpr with a dummy body. This sets up the var mapping
            -- for the defined name without compiling the actual body.
            -- Then compile the actual body via compileStep to maintain the
            -- TailRec context (so MonoTailCall for the outer function generates
            -- correct loop continuation instead of crashing in mkCaseRegionFromDecider).
            let
                -- Compile just the def setup: pending lambda + papCreate + var mapping.
                -- Use MonoUnit as a dummy body since we only need the side effects
                -- on the context (var mappings, pending lambdas).
                defSetupExpr =
                    Mono.MonoLet def Mono.MonoUnit Mono.MUnit

                defSetupResult =
                    Expr.generateExpr ctxReady defSetupExpr

                -- Restore outer siblings before compiling the body
                ctxAfterDef =
                    defSetupResult.ctx

                ctxForBody =
                    { ctxAfterDef | currentLetSiblings = outerSiblings }

                -- Now compile the actual body with compileStep (maintains TailRec context)
                bodyStep =
                    compileStep ctxForBody loopSpec body
            in
            { ops = defSetupResult.ops ++ bodyStep.ops
            , nextParams = bodyStep.nextParams
            , doneVar = bodyStep.doneVar
            , resultVar = bodyStep.resultVar
            , resultType = bodyStep.resultType
            , ctx = bodyStep.ctx
            }


{-| Compile a MonoDestruct step.

This mirrors Expr.generateDestruct but returns a StepResult instead of ExprResult:

  - Generate path ops to navigate the MonoPath and extract the value.
  - Bind the destructured name to the extracted SSA value in the context.
  - Recursively compile the body as a step.

This ensures that any MonoTailCall inside the body is still seen by compileStep
and treated as a "continue" step, instead of going through Expr.generateTailCall.

-}
compileDestructStep :
    Ctx.Context
    -> LoopSpec
    -> Mono.MonoDestructor
    -> Mono.MonoExpr
    -> StepResult
compileDestructStep ctx loopSpec (Mono.MonoDestructor name path _) body =
    let
        -- Use the path's actual result type, as in Expr.generateDestruct.
        -- The destructor's monoType may still contain unsubstituted vars;
        -- the path carries the correctly-specialized concrete type.
        pathResultType : Mono.MonoType
        pathResultType =
            Mono.getMonoPathType path

        destructorMlirType : MlirType
        destructorMlirType =
            Types.monoTypeToAbi pathResultType

        -- Navigate the path to produce the destructured value.
        ( pathOps, pathVar, ctx1 ) =
            Patterns.generateMonoPath ctx path destructorMlirType

        -- Bind the destructured name to the extracted SSA value.
        ctx2 : Ctx.Context
        ctx2 =
            Ctx.addVarMapping name pathVar destructorMlirType ctx1

        -- Recursively compile the body as a loop step.
        bodyStep : StepResult
        bodyStep =
            compileStep ctx2 loopSpec body
    in
    { ops = pathOps ++ bodyStep.ops
    , nextParams = bodyStep.nextParams
    , doneVar = bodyStep.doneVar
    , resultVar = bodyStep.resultVar
    , resultType = bodyStep.resultType
    , ctx = bodyStep.ctx
    }



-- ============================================================================
-- ====== HELPERS ======
-- ============================================================================


{-| Create a single-block region with the given args, body ops, and terminator.
-}
mkSingleBlockRegion :
    List ( String, MlirType )
    -> List MlirOp
    -> MlirOp
    -> MlirRegion
mkSingleBlockRegion args body terminator =
    MlirRegion
        { entry =
            { args = args
            , body = body
            , terminator = terminator
            }
        , blocks = OrderedDict.empty
        }


{-| Allocate N fresh variable names.
-}
allocateFreshVars : Ctx.Context -> Int -> ( List String, Ctx.Context )
allocateFreshVars ctx n =
    let
        ( varsRev, ctxFinal ) =
            List.foldl
                (\_ ( vars, ctxAcc ) ->
                    let
                        ( v, ctxNew ) =
                            Ctx.freshVar ctxAcc
                    in
                    ( v :: vars, ctxNew )
                )
                ( [], ctx )
                (List.range 1 n)
    in
    ( List.reverse varsRev, ctxFinal )


pairsToSparseArray : List ( Int, a ) -> Array (Maybe a)
pairsToSparseArray pairs =
    let
        maxIdx =
            List.foldl (\( i, _ ) acc -> max i acc) -1 pairs
    in
    List.foldl (\( i, v ) arr -> Array.set i (Just v) arr) (Array.repeat (maxIdx + 1) Nothing) pairs


{-| Zip two lists together.
-}
zip : List a -> List b -> List ( a, b )
zip xs ys =
    List.map2 Tuple.pair xs ys
