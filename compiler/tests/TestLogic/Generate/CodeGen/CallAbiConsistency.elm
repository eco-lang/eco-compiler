module TestLogic.Generate.CodeGen.CallAbiConsistency exposing (expectCallAbiConsistency, checkCallAbiConsistency)

{-| Test logic for Call ABI Consistency invariant.

For every `eco.call`, the operand types must match the target function's
declared parameter types. This catches cases where a value is passed as
a different type than the function expects (e.g., i1 passed to a function
expecting !eco.value).

This invariant is derived from REP\_ABI\_001 which requires consistent
representation at function call boundaries.

@docs expectCallAbiConsistency, checkCallAbiConsistency

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , findFuncOps
        , findOpsNamed
        , getStringAttr
        , getTypeAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that call ABI consistency invariants hold for a source module.
-}
expectCallAbiConsistency : Src.Module -> Expectation
expectCallAbiConsistency srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCallAbiConsistency mlirModule)


{-| Check that all eco.call operand types match target function parameter types.
-}
checkCallAbiConsistency : MlirModule -> List Violation
checkCallAbiConsistency mlirModule =
    let
        -- Build a map of function names to their parameter types
        funcParamTypes =
            buildFuncParamTypesMap mlirModule

        -- Find all eco.call ops
        callOps =
            findOpsNamed "eco.call" mlirModule

        -- Check each call
        violations =
            List.filterMap (checkCallOp funcParamTypes) callOps
    in
    violations


{-| Build a map from function symbol names to their parameter types.
-}
buildFuncParamTypesMap : MlirModule -> Dict String (List MlirType)
buildFuncParamTypesMap mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.foldl addFuncToMap Dict.empty funcOps


addFuncToMap : MlirOp -> Dict String (List MlirType) -> Dict String (List MlirType)
addFuncToMap funcOp dict =
    case getStringAttr "sym_name" funcOp of
        Nothing ->
            dict

        Just name ->
            case getTypeAttr "function_type" funcOp of
                Nothing ->
                    dict

                Just funcType ->
                    case extractParamTypes funcType of
                        Nothing ->
                            dict

                        Just paramTypes ->
                            Dict.insert name paramTypes dict


{-| Extract parameter types from a function type.
-}
extractParamTypes : MlirType -> Maybe (List MlirType)
extractParamTypes mlirType =
    case mlirType of
        FunctionType { inputs } ->
            Just inputs

        _ ->
            Nothing


{-| Check a single eco.call for ABI consistency.
-}
checkCallOp : Dict String (List MlirType) -> MlirOp -> Maybe Violation
checkCallOp funcParamTypes op =
    case getStringAttr "callee" op of
        Nothing ->
            Nothing

        Just callee ->
            let
                -- Remove leading @ if present
                calleeName =
                    if String.startsWith "@" callee then
                        String.dropLeft 1 callee

                    else
                        callee
            in
            case Dict.get calleeName funcParamTypes of
                Nothing ->
                    -- Function not found in module (might be external)
                    Nothing

                Just expectedParamTypes ->
                    case extractOperandTypes op of
                        Nothing ->
                            Nothing

                        Just actualOperandTypes ->
                            checkTypesMatch op calleeName expectedParamTypes actualOperandTypes


{-| Check if operand types match parameter types.
-}
checkTypesMatch : MlirOp -> String -> List MlirType -> List MlirType -> Maybe Violation
checkTypesMatch op calleeName expectedTypes actualTypes =
    let
        expectedCount =
            List.length expectedTypes

        actualCount =
            List.length actualTypes
    in
    if expectedCount /= actualCount then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "Call to '"
                    ++ calleeName
                    ++ "' has "
                    ++ String.fromInt actualCount
                    ++ " operands but function expects "
                    ++ String.fromInt expectedCount
                    ++ " parameters"
            }

    else
        -- Check each operand against expected parameter type
        List.map2 Tuple.pair expectedTypes actualTypes
            |> List.indexedMap (checkSingleType op calleeName)
            |> List.filterMap identity
            |> List.head


checkSingleType : MlirOp -> String -> Int -> ( MlirType, MlirType ) -> Maybe Violation
checkSingleType op calleeName index ( expected, actual ) =
    if typesMatch expected actual then
        Nothing

    else
        Just
            { opId = op.id
            , opName = op.name
            , message =
                "Call to '"
                    ++ calleeName
                    ++ "' operand "
                    ++ String.fromInt index
                    ++ " has type "
                    ++ typeToString actual
                    ++ " but function parameter expects "
                    ++ typeToString expected
            }


{-| Check if two types match.
-}
typesMatch : MlirType -> MlirType -> Bool
typesMatch t1 t2 =
    t1 == t2


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
