module TestLogic.Generate.CodeGen.SsaTypeConsistency exposing
    ( expectSsaTypeConsistency
    , checkSsaTypeConsistency
    )

{-| Test logic for CGEN_0B1: SSA Type Consistency invariant.

Within each function, an SSA name must never be assigned different types.
This catches the "use of value '%X' expects different type than prior uses"
runtime error.

Note: SSA names like %0 are routinely reused across functions, so checking
must be per-function, not module-wide.

@docs expectSsaTypeConsistency, checkSsaTypeConsistency

-}

import Compiler.AST.Source as Src
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getStringAttr
        , violationsToExpectation
        )
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict


{-| Verify that SSA type consistency invariants hold for a source module.
-}
expectSsaTypeConsistency : Src.Module -> Expectation
expectSsaTypeConsistency srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkSsaTypeConsistency mlirModule)


{-| Result of building a type environment - either success or a conflict.
-}
type alias TypeEnvResult =
    Result Violation (Dict String MlirType)


{-| Check that all SSA values have consistent types within each function.

This processes each function separately since SSA names are function-scoped.

-}
checkSsaTypeConsistency : MlirModule -> List Violation
checkSsaTypeConsistency mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.filterMap checkFunction funcOps


{-| Check a single function for SSA type consistency.
Returns Just violation if a type conflict is found.
-}
checkFunction : MlirOp -> Maybe Violation
checkFunction funcOp =
    let
        funcName =
            getStringAttr "sym_name" funcOp
                |> Maybe.withDefault "<unknown>"

        result =
            buildTypeEnvWithConflictCheck funcName funcOp
    in
    case result of
        Ok _ ->
            Nothing

        Err violation ->
            Just violation


{-| Build a type environment while checking for conflicts.
Returns Err with violation if the same SSA name is assigned different types.
-}
buildTypeEnvWithConflictCheck : String -> MlirOp -> TypeEnvResult
buildTypeEnvWithConflictCheck funcName op =
    let
        initial =
            Ok Dict.empty

        withRegions =
            List.foldl (collectFromRegionChecked funcName) initial op.regions
    in
    withRegions


{-| Record an SSA name and type, checking for conflicts.
-}
recordSsa : String -> String -> MlirType -> TypeEnvResult -> TypeEnvResult
recordSsa funcName name newType result =
    case result of
        Err v ->
            Err v

        Ok env ->
            case Dict.get name env of
                Nothing ->
                    Ok (Dict.insert name newType env)

                Just existingType ->
                    if existingType == newType then
                        Ok env

                    else
                        Err
                            { opId = name
                            , opName = "SSA definition"
                            , message =
                                "SSA value '"
                                    ++ name
                                    ++ "' in function '"
                                    ++ funcName
                                    ++ "' has conflicting types: "
                                    ++ typeToString existingType
                                    ++ " vs "
                                    ++ typeToString newType
                            }


collectFromRegionChecked : String -> MlirRegion -> TypeEnvResult -> TypeEnvResult
collectFromRegionChecked funcName (MlirRegion { entry, blocks }) result =
    let
        withEntryArgs =
            List.foldl
                (\( name, t ) acc -> recordSsa funcName name t acc)
                result
                entry.args

        withEntryBody =
            List.foldl (collectFromOpChecked funcName) withEntryArgs entry.body

        withEntryTerm =
            collectFromOpChecked funcName entry.terminator withEntryBody

        withBlocks =
            List.foldl (collectFromBlockChecked funcName) withEntryTerm (OrderedDict.values blocks)
    in
    withBlocks


collectFromBlockChecked : String -> MlirBlock -> TypeEnvResult -> TypeEnvResult
collectFromBlockChecked funcName block result =
    let
        withArgs =
            List.foldl
                (\( name, t ) acc -> recordSsa funcName name t acc)
                result
                block.args

        withBody =
            List.foldl (collectFromOpChecked funcName) withArgs block.body

        withTerm =
            collectFromOpChecked funcName block.terminator withBody
    in
    withTerm


collectFromOpChecked : String -> MlirOp -> TypeEnvResult -> TypeEnvResult
collectFromOpChecked funcName op result =
    let
        withResults =
            List.foldl
                (\( name, t ) acc -> recordSsa funcName name t acc)
                result
                op.results

        withRegions =
            List.foldl (collectFromRegionChecked funcName) withResults op.regions
    in
    withRegions


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
