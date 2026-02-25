module TestLogic.Generate.CodeGen.PapExtendSaturatedResultType exposing (expectPapExtendSaturatedResultType)

{-| Test logic for CGEN\_056: Saturated PapExtend Result Type invariant.

For every `eco.papExtend` that represents a fully saturated closure application
of some `func.func @f`, the `eco.papExtend` result MLIR type must equal the
result type of `@f`'s `func.func` signature.

The test works by:

1.  Building a map from function `sym_name` → return type (from `function_type`
    attribute on `func.func` ops).
2.  For each function scope, tracking PAP provenance through `eco.papCreate` and
    chained `eco.papExtend` ops to determine which function each PAP ultimately
    targets and how many arguments remain.
3.  Identifying saturated `eco.papExtend` ops (where remaining args ≤ 0) and
    asserting their result type matches the target function's return type.

@docs expectPapExtendSaturatedResultType

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getIntAttr
        , getStringAttr
        , getTypeAttr
        , walkOpAndChildren
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Tracks provenance of a PAP value: which function it targets and how many
args remain before saturation.
-}
type alias PapInfo =
    { targetFunc : String
    , remaining : Int
    }


{-| Verify that saturated papExtend result type invariants hold for a source module.
-}
expectPapExtendSaturatedResultType : Src.Module -> Expectation
expectPapExtendSaturatedResultType srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule, mlirOutput } ->
            let
                violations =
                    checkPapExtendSaturatedResultType mlirModule
            in
            if List.isEmpty violations then
                Expect.pass

            else
                let
                    funcReturnTypeMap =
                        buildFuncReturnTypeMap mlirModule

                    funcMapStr =
                        Dict.toList funcReturnTypeMap
                            |> List.map (\( name, ty ) -> "  @" ++ name ++ " -> " ++ typeToString ty)
                            |> String.join "\n"

                    violationStrs =
                        List.map (\v -> v.message) violations
                            |> String.join "\n"
                in
                Expect.fail
                    (violationStrs
                        ++ "\n\nfuncReturnTypeMap:\n"
                        ++ funcMapStr
                        ++ "\n\nMLIR:\n"
                        ++ mlirOutput
                    )


{-| Check saturated papExtend result type invariants across the module.
-}
checkPapExtendSaturatedResultType : MlirModule -> List Violation
checkPapExtendSaturatedResultType mlirModule =
    let
        funcReturnTypeMap =
            buildFuncReturnTypeMap mlirModule
    in
    List.concatMap (checkFunction funcReturnTypeMap) mlirModule.body


{-| Build a map from function sym\_name to its return type.

Extracts the return type from the `function_type` attribute on each `func.func` op.

-}
buildFuncReturnTypeMap : MlirModule -> Dict String MlirType
buildFuncReturnTypeMap mlirModule =
    let
        extractFuncReturnType : MlirOp -> Maybe ( String, MlirType )
        extractFuncReturnType op =
            case ( getStringAttr "sym_name" op, getTypeAttr "function_type" op ) of
                ( Just symName, Just (FunctionType { results }) ) ->
                    case results of
                        returnType :: _ ->
                            Just ( symName, returnType )

                        [] ->
                            Nothing

                _ ->
                    Nothing
    in
    findFuncOps mlirModule
        |> List.filterMap extractFuncReturnType
        |> Dict.fromList


{-| Check PAP saturated result types within a single function.

Processes each function independently to avoid SSA name collisions
(SSA names are only unique within each function).

-}
checkFunction : Dict String MlirType -> MlirOp -> List Violation
checkFunction funcReturnTypeMap funcOp =
    let
        allOpsInFunc =
            walkOpAndChildren funcOp

        papInfoMap =
            buildPapInfoMap allOpsInFunc

        papExtendOps =
            List.filter (\op -> op.name == "eco.papExtend") allOpsInFunc
    in
    List.filterMap (checkSaturatedPapExtend funcReturnTypeMap papInfoMap) papExtendOps


{-| Build a map from SSA value names to their PAP provenance info.

Tracks provenance from:

1.  `eco.papCreate` → records target function and remaining = arity - num\_captured
2.  `eco.papExtend` → propagates target function, updates remaining

For the two-clone model, uses `_fast_evaluator` attribute when present to resolve
the target function (pointing to the `$cap` clone).

-}
buildPapInfoMap : List MlirOp -> Dict String PapInfo
buildPapInfoMap ops =
    List.foldl processOp Dict.empty ops


processOp : MlirOp -> Dict String PapInfo -> Dict String PapInfo
processOp op map =
    if op.name == "eco.papCreate" then
        case ( List.head op.results, getIntAttr "arity" op, getIntAttr "num_captured" op ) of
            ( Just ( resultName, _ ), Just arity, Just numCaptured ) ->
                let
                    -- Use _fast_evaluator if present (two-clone model), otherwise use function attr
                    targetFunc =
                        case getStringAttr "_fast_evaluator" op of
                            Just fastEvalName ->
                                fastEvalName

                            Nothing ->
                                getStringAttr "function" op
                                    |> Maybe.withDefault ""
                in
                if targetFunc == "" then
                    map

                else
                    Dict.insert resultName
                        { targetFunc = targetFunc
                        , remaining = arity - numCaptured
                        }
                        map

            _ ->
                map

    else if op.name == "eco.papExtend" then
        case ( List.head op.results, List.head op.operands, getIntAttr "remaining_arity" op ) of
            ( Just ( resultName, _ ), Just sourcePapName, Just remainingArity ) ->
                case Dict.get sourcePapName map of
                    Just sourceInfo ->
                        let
                            numNewArgs =
                                List.length op.operands - 1

                            newRemaining =
                                remainingArity - numNewArgs
                        in
                        if newRemaining > 0 then
                            Dict.insert resultName
                                { targetFunc = sourceInfo.targetFunc
                                , remaining = newRemaining
                                }
                                map

                        else
                            map

                    Nothing ->
                        map

            _ ->
                map

    else
        map


{-| Check a single papExtend op: if it represents a saturated call, verify its
result type matches the target function's return type.
-}
checkSaturatedPapExtend : Dict String MlirType -> Dict String PapInfo -> MlirOp -> Maybe Violation
checkSaturatedPapExtend funcReturnTypeMap papInfoMap op =
    case List.head op.operands of
        Nothing ->
            Nothing

        Just sourcePapName ->
            case Dict.get sourcePapName papInfoMap of
                Nothing ->
                    -- Source PAP not tracked (block arg, cross-function, etc.) - skip
                    Nothing

                Just sourceInfo ->
                    let
                        numNewArgs =
                            List.length op.operands - 1

                        resultRemaining =
                            sourceInfo.remaining - numNewArgs
                    in
                    if resultRemaining > 0 then
                        -- Not saturated - skip
                        Nothing

                    else
                        -- Saturated call - verify result type matches func return type
                        case List.head op.results of
                            Nothing ->
                                Nothing

                            Just ( _, papExtendResultType ) ->
                                case Dict.get sourceInfo.targetFunc funcReturnTypeMap of
                                    Nothing ->
                                        -- Target function not found (external/kernel) - skip
                                        Nothing

                                    Just funcReturnType ->
                                        if papExtendResultType == funcReturnType then
                                            Nothing

                                        else
                                            Just
                                                { opId = op.id
                                                , opName = op.name
                                                , message =
                                                    "Saturated eco.papExtend result type "
                                                        ++ typeToString papExtendResultType
                                                        ++ " does not match func.func @"
                                                        ++ sourceInfo.targetFunc
                                                        ++ " return type "
                                                        ++ typeToString funcReturnType
                                                }


typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct name ->
            "!" ++ name

        FunctionType _ ->
            "function"
