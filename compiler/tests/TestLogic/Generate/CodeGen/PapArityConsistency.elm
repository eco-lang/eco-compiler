module TestLogic.Generate.CodeGen.PapArityConsistency exposing
    ( expectPapArityConsistency
    , checkPapArityConsistency
    )

{-| Test logic for CGEN_051: papCreate arity matches function parameter count.

`eco.papCreate` arity must equal the number of arguments its referenced
function symbol accepts.

This test builds a map of function symbols to their parameter counts,
then verifies each `eco.papCreate` has an arity that matches.

@docs expectPapArityConsistency, checkPapArityConsistency

-}

import Compiler.AST.Source as Src
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , findOpsNamed
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        )
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirRegion(..))


{-| Verify that papCreate arity matches function parameter count.
-}
expectPapArityConsistency : Src.Module -> Expectation
expectPapArityConsistency srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkPapArityConsistency mlirModule)


{-| Check papCreate arity consistency with function definitions.
-}
checkPapArityConsistency : MlirModule -> List Violation
checkPapArityConsistency mlirModule =
    let
        -- Build a map from function symbol names to their parameter counts
        funcParamCountMap =
            buildFuncParamCountMap mlirModule

        -- Find all papCreate ops
        papCreateOps =
            findOpsNamed "eco.papCreate" mlirModule

        -- Check each papCreate
        violations =
            List.filterMap (checkPapCreateOp funcParamCountMap) papCreateOps
    in
    violations


{-| Build a map from function symbol names to their parameter counts.
-}
buildFuncParamCountMap : MlirModule -> Dict String Int
buildFuncParamCountMap mlirModule =
    let
        funcOps =
            findFuncOps mlirModule

        -- Extract symbol name and parameter count from a func.func op
        extractFuncInfo : MlirOp -> Maybe ( String, Int )
        extractFuncInfo op =
            case getStringAttr "sym_name" op of
                Nothing ->
                    Nothing

                Just symName ->
                    -- Get parameter count from the entry block arguments
                    let
                        paramCount =
                            case List.head op.regions of
                                Just (MlirRegion { entry }) ->
                                    List.length entry.args

                                Nothing ->
                                    0
                    in
                    Just ( symName, paramCount )
    in
    funcOps
        |> List.filterMap extractFuncInfo
        |> Dict.fromList


{-| Check a single papCreate op for arity consistency with its function.
-}
checkPapCreateOp : Dict String Int -> MlirOp -> Maybe Violation
checkPapCreateOp funcParamCountMap op =
    let
        maybeArity =
            getIntAttr "arity" op

        maybeFuncName =
            getStringAttr "function" op
    in
    case ( maybeArity, maybeFuncName ) of
        ( Nothing, _ ) ->
            -- Missing arity already caught by PapCreateArity test
            Nothing

        ( _, Nothing ) ->
            -- Missing function already caught by PapCreateArity test
            Nothing

        ( Just arity, Just funcName ) ->
            case Dict.get funcName funcParamCountMap of
                Nothing ->
                    -- Function not found - could be an external kernel function
                    -- that we don't have the definition for. Skip this check.
                    Nothing

                Just paramCount ->
                    if arity /= paramCount then
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message =
                                "eco.papCreate arity="
                                    ++ String.fromInt arity
                                    ++ " but function "
                                    ++ funcName
                                    ++ " has "
                                    ++ String.fromInt paramCount
                                    ++ " parameters"
                            }

                    else
                        Nothing
