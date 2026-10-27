module Compiler.Generate.MLIR.Lambdas exposing (processLambdas)

{-| MLIR has no nested functions, so every anonymous or let-bound local
function in a program must become a top-level `func.func` of its own. This
module generates those functions.

While generating an enclosing function, expression generation does not emit a
local function's body in place. It builds the closure value and queues the
function as a _pending lambda_ (`Ctx.PendingLambda`) in the context. Once the
enclosing nodes are generated, `processLambdas` turns the queue into
functions. Generating one lambda's body can queue further lambdas, so this is
repeated, round by round, until a round queues nothing.

A lambda's arguments are its _captures_, the free variables it closes over,
followed by its parameters, each at its ABI type (`Types.monoTypeToAbi`), so a
primitive arrives unboxed. A lambda without captures is generated under its
own name. A lambda with captures is generated as its _fast clone_, named with a
`$cap` suffix.

A lambda's body may also refer to _sibling mappings_: names bound by the
enclosing let chain, as they were mapped to SSA values when the lambda was
queued. Captures and parameters shadow a sibling of the same name.

@docs processLambdas

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Generate.MLIR.Context as Ctx
import Compiler.Generate.MLIR.Expr as Expr
import Compiler.Generate.MLIR.LogicalTypes as LogicalTypes
import Compiler.Generate.MLIR.Ops as Ops
import Compiler.Generate.MLIR.TailRec as TailRec
import Compiler.Generate.MLIR.Types as Types
import Dict
import Mlir.Mlir exposing (MlirAttr(..), MlirOp, MlirRegion, MlirType(..))
import Set
import Utils.Crash exposing (crash)



-- ====== LAMBDA PROCESSING ======


{-| Returns the function definitions for every lambda pending in `ctx`,
including those queued while generating them, together with the context
emptied of pending lambdas and pending function ops.

Function ops already in `ctx.pendingFuncOps` are returned ahead of each
round's lambdas. Within one round, two pending lambdas with the same name and
the same contents are generated once, while two with the same name and
different contents are a crash. A name queued again in a later round is
generated again.

-}
processLambdas : Ctx.Context -> ( List MlirOp, Ctx.Context )
processLambdas ctx =
    case ctx.pendingLambdas of
        [] ->
            -- Also drain any pre-generated func ops (e.g. from local tail-rec functions)
            ( ctx.pendingFuncOps, { ctx | pendingFuncOps = [] } )

        lambdas ->
            let
                ctxCleared =
                    { ctx | pendingLambdas = [], pendingFuncOps = [] }

                -- Pre-generated func ops accumulated before this round
                priorFuncOps =
                    ctx.pendingFuncOps

                -- Deduplicate lambdas by name to avoid duplicate function definitions.
                -- The same lambda can legitimately be queued twice in one round:
                -- BytesFusion compiles a decoder binding AND the fused path
                -- references the same lambda, so `generateClosure` runs twice on one
                -- `MonoClosure` and queues two identical entries. Those are dropped.
                -- Two entries that share a name but differ are two different lambdas
                -- under one lambdaId, which MONO_019 forbids; dropping one would
                -- silently miscompile every call to it, so that crashes instead.
                dedupedLambdas =
                    let
                        ( _, revResult ) =
                            List.foldl
                                (\lambda ( seen, acc ) ->
                                    case Dict.get lambda.name seen of
                                        Just kept ->
                                            if sameLambda kept lambda then
                                                ( seen, acc )

                                            else
                                                crash
                                                    ("MONO_019 violation: two different lambdas are both named '"
                                                        ++ lambda.name
                                                        ++ "' (in "
                                                        ++ ctx.currentFuncName
                                                        ++ "); a lambdaId must identify one logical lambda"
                                                    )

                                        Nothing ->
                                            ( Dict.insert lambda.name lambda seen, lambda :: acc )
                                )
                                ( Dict.empty, [] )
                                lambdas
                    in
                    List.reverse revResult

                ( revLambdaOps, ctxAfter ) =
                    List.foldl
                        (\lambda ( accOps, accCtx ) ->
                            let
                                ( ops, newCtx ) =
                                    generateLambdaFunc accCtx lambda

                                -- Reset varMappings/definedSsaVars after each lambda func
                                -- to prevent stale entries leaking to the next lambda.
                                cleanCtx =
                                    { newCtx | varMappings = Dict.empty, definedSsaVars = Set.empty }
                            in
                            ( List.reverse ops ++ accOps, cleanCtx )
                        )
                        ( [], ctxCleared )
                        dedupedLambdas

                ( moreOps, finalCtx ) =
                    processLambdas ctxAfter
            in
            ( priorFuncOps ++ List.reverse revLambdaOps ++ moreOps, finalCtx )


{-| Returns whether two pending lambdas queued under one name are the same lambda queued
twice: the same captures, parameters, body, return type and tail-recursion
role. `siblingMappings` is not compared, since it records SSA names of the
enclosing function at the point each copy was queued, which differ between two
queuings of one lambda without changing the lambda.
-}
sameLambda : Ctx.PendingLambda -> Ctx.PendingLambda -> Bool
sameLambda a b =
    a.captures
        == b.captures
        && a.params
        == b.params
        && a.returnType
        == b.returnType
        && a.isTailRecursive
        == b.isTailRecursive
        && a.selfBindingName
        == b.selfBindingName
        && a.body
        == b.body


{-| Builds the function definition of `lambda`, with the context's current
function name set to the lambda's name.
-}
generateLambdaFunc : Ctx.Context -> Ctx.PendingLambda -> ( List MlirOp, Ctx.Context )
generateLambdaFunc ctxIn lambda =
    generateLambdaFuncNamed { ctxIn | currentFuncName = lambda.name } lambda


{-| Builds the function definition of `lambda`: one `func.func`, carrying
logical-type attributes, named after the lambda, with `$cap` appended when it
has captures.

The body is generated in a fresh scope: captures, parameters and sibling
mappings are in it, and nothing else of the enclosing function's state.
`nextVar` starts no lower than the enclosing context's, the argument count, and
one past every numeric SSA name among the siblings, so a fresh name cannot
collide with one of them.

A tail-recursive lambda's body becomes a loop through
`TailRec.compileTailFuncToWhile`, over its parameters only. When it refers to
itself by name, the body first builds a closure of the lambda itself with
`eco.papCreate` over its captures, and that closure is what the name means
inside the body; a sibling of the same name is not imported. Any other lambda's
body is generated with `Expr.generateExpr`; unless the body ends in its own
terminator, the result is coerced to the ABI return type and returned.

-}
generateLambdaFuncNamed : Ctx.Context -> Ctx.PendingLambda -> ( List MlirOp, Ctx.Context )
generateLambdaFuncNamed ctx lambda =
    let
        hasCaptures =
            not (List.isEmpty lambda.captures)

        captureArgPairs : List ( String, MlirType )
        captureArgPairs =
            List.map (\( name, monoTy ) -> ( "%" ++ name, Types.monoTypeToAbi monoTy )) lambda.captures

        paramArgPairs : List ( String, MlirType )
        paramArgPairs =
            List.map (\( name, monoTy ) -> ( "%" ++ name, Types.monoTypeToAbi monoTy )) lambda.params

        allArgPairs : List ( String, MlirType )
        allArgPairs =
            captureArgPairs ++ paramArgPairs

        varMappingsWithArgs : Dict.Dict String Ctx.VarInfo
        varMappingsWithArgs =
            List.foldl
                (\( name, monoTy ) acc ->
                    let
                        mlirType =
                            Types.monoTypeToAbi monoTy

                        varName =
                            "%" ++ name
                    in
                    Dict.insert name
                        { ssaVar = varName
                        , mlirType = mlirType
                        }
                        acc
                )
                Dict.empty
                (lambda.captures ++ lambda.params)

        -- Nothing for a non-numeric name such as "%decider".
        parseNumericIndex : String -> Maybe Int
        parseNumericIndex ssaName =
            if String.startsWith "%" ssaName then
                String.dropLeft 1 ssaName |> String.toInt

            else
                Nothing

        maxSiblingIndex : Int
        maxSiblingIndex =
            lambda.siblingMappings
                |> Dict.values
                |> List.filterMap (\info -> parseNumericIndex info.ssaVar)
                |> List.maximum
                |> Maybe.withDefault -1

        -- Never below the enclosing context's counter, nor at a sibling's %N.
        nextVarBase : Int
        nextVarBase =
            List.maximum [ ctx.nextVar, List.length allArgPairs, maxSiblingIndex + 1 ]
                |> Maybe.withDefault 0

        -- The self name is bound to a local closure instead (see below).
        filteredSiblingMappings : Dict.Dict String Ctx.VarInfo
        filteredSiblingMappings =
            case lambda.selfBindingName of
                Just selfName ->
                    Dict.remove selfName lambda.siblingMappings

                Nothing ->
                    lambda.siblingMappings

        varMappingsWithSiblings : Dict.Dict String Ctx.VarInfo
        varMappingsWithSiblings =
            Dict.union varMappingsWithArgs filteredSiblingMappings

        -- Sibling SSA names are mapped but not registered as defined here.
        lambdaSsaVars : List String
        lambdaSsaVars =
            List.map Tuple.first allArgPairs

        ctxWithArgs : Ctx.Context
        ctxWithArgs =
            -- A new function: the enclosing function's split parameters and sret layout do not apply.
            { ctx | varMappings = varMappingsWithSiblings, nextVar = nextVarBase, splitAggParams = Dict.empty, sretTailLayout = Nothing }
                |> Ctx.resetDefinedSsaVars lambdaSsaVars

        actualResultType : MlirType
        actualResultType =
            Types.monoTypeToAbi lambda.returnType
    in
    if lambda.isTailRecursive then
        -- Captures stay function arguments outside the loop state; scf.while is not isolated from above.
        let
            ( selfPrefixOps, ctxForTailRec ) =
                case lambda.selfBindingName of
                    Just selfName ->
                        let
                            selfFunctionName =
                                if hasCaptures then
                                    lambda.name ++ "$cap"

                                else
                                    lambda.name

                            selfArity =
                                List.length lambda.captures + List.length lambda.params

                            selfNumCaptured =
                                List.length lambda.captures

                            captureMlirTypes =
                                List.map (\( _, monoTy ) -> Types.monoTypeToAbi monoTy) lambda.captures

                            selfOperandTypesAttr =
                                if List.isEmpty captureMlirTypes then
                                    Dict.empty

                                else
                                    Dict.singleton "_operand_types"
                                        (ArrayAttr Nothing (List.map TypeAttr captureMlirTypes))

                            selfFastEvaluatorAttr =
                                if hasCaptures then
                                    Dict.singleton "_fast_evaluator" (SymbolRefAttr (lambda.name ++ "$cap"))

                                else
                                    Dict.empty

                            -- The kind of the unboxed ABI return type; the attribute is omitted for kind 0 (boxed).
                            selfResultKind =
                                Types.mlirTypeToKind (Types.monoTypeToAbi lambda.returnType)

                            selfResultKindAttr =
                                if selfResultKind == 0 then
                                    Dict.empty

                                else
                                    Dict.singleton "_result_kind" (IntAttr (Just I8) selfResultKind)

                            selfPapAttrs =
                                Dict.union selfResultKindAttr
                                    (Dict.union selfFastEvaluatorAttr
                                        (Dict.union selfOperandTypesAttr
                                            (Dict.fromList
                                                [ ( "function", SymbolRefAttr selfFunctionName )
                                                , ( "arity", IntAttr Nothing (Ops.assertStageArity selfArity) )
                                                , ( "num_captured", IntAttr Nothing selfNumCaptured )
                                                ]
                                                |> Ops.withSlotKinds captureMlirTypes
                                            )
                                        )
                                    )

                            captureVarNames =
                                List.map (\( capName, _ ) -> "%" ++ capName) lambda.captures

                            ( selfVar, ctxAfterFresh ) =
                                Ctx.freshVar ctxWithArgs

                            ( ctxAfterPap, selfPapOp ) =
                                Ops.mlirOp ctxAfterFresh "eco.papCreate"
                                    |> Ops.opBuilder.withOperands captureVarNames
                                    |> Ops.opBuilder.withResults [ ( selfVar, Types.ecoValue ) ]
                                    |> Ops.opBuilder.withAttrs selfPapAttrs
                                    |> Ops.opBuilder.build

                            ctxWithSelf =
                                Ctx.addVarMapping selfName
                                    selfVar
                                    Types.ecoValue
                                    ctxAfterPap
                        in
                        ( [ selfPapOp ], ctxWithSelf )

                    Nothing ->
                        ( [], ctxWithArgs )

            ( tailRecOps, ctx1 ) =
                TailRec.compileTailFuncToWhile ctxForTailRec lambda.name paramArgPairs (List.map Tuple.second lambda.params) lambda.body actualResultType Nothing

            bodyOps =
                selfPrefixOps ++ tailRecOps

            ( bodyNonTermOps, bodyTerminator ) =
                case List.reverse bodyOps of
                    term :: rest ->
                        ( List.reverse rest, term )

                    [] ->
                        let
                            ( dummyOps, dummyVar, ctxDummy ) =
                                Expr.createDummyValue ctx1 actualResultType

                            ( _, dummyRetOp ) =
                                Ops.ecoReturn ctxDummy dummyVar actualResultType
                        in
                        ( dummyOps, dummyRetOp )

            funcBodyRegion : MlirRegion
            funcBodyRegion =
                Ops.mkRegion allArgPairs bodyNonTermOps bodyTerminator

            funcName =
                if hasCaptures then
                    lambda.name ++ "$cap"

                else
                    lambda.name

            ( ctx2, fastCloneOpRaw ) =
                Ops.funcFunc ctx1 funcName allArgPairs actualResultType funcBodyRegion

            captureMonoTypes : List Mono.MonoType
            captureMonoTypes =
                List.map Tuple.second lambda.captures

            paramMonoTypes : List Mono.MonoType
            paramMonoTypes =
                List.map Tuple.second lambda.params

            fastCloneOp =
                LogicalTypes.addLogicalTypesAttr
                    ctx2.ecoConfig.logicalTypes.customMaxFields
                    ctx2.typeRegistry.ctorShapes
                    (captureMonoTypes ++ paramMonoTypes)
                    lambda.returnType
                    fastCloneOpRaw
        in
        ( [ fastCloneOp ], ctx2 )

    else
        let
            exprResult : Expr.ExprResult
            exprResult =
                Expr.generateExpr ctxWithArgs lambda.body

            region : MlirRegion
            region =
                if exprResult.isTerminated then
                    Ops.mkRegionTerminatedByOps allArgPairs exprResult.ops

                else
                    let
                        ( coerceOps, finalVar, coerceCtx ) =
                            Expr.coerceResultToType exprResult.ctx exprResult.resultVar exprResult.resultType actualResultType

                        ( _, returnOp ) =
                            Ops.ecoReturn coerceCtx finalVar actualResultType
                    in
                    Ops.mkRegion allArgPairs (exprResult.ops ++ coerceOps) returnOp

            funcName =
                if hasCaptures then
                    lambda.name ++ "$cap"

                else
                    lambda.name

            ( ctx2, fastCloneOpRaw ) =
                Ops.funcFunc exprResult.ctx funcName allArgPairs actualResultType region

            captureMonoTypes : List Mono.MonoType
            captureMonoTypes =
                List.map Tuple.second lambda.captures

            paramMonoTypes : List Mono.MonoType
            paramMonoTypes =
                List.map Tuple.second lambda.params

            fastCloneOp =
                LogicalTypes.addLogicalTypesAttr
                    ctx2.ecoConfig.logicalTypes.customMaxFields
                    ctx2.typeRegistry.ctorShapes
                    (captureMonoTypes ++ paramMonoTypes)
                    lambda.returnType
                    fastCloneOpRaw
        in
        ( [ fastCloneOp ], ctx2 )
