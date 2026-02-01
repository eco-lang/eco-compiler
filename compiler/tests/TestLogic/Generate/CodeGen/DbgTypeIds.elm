module TestLogic.Generate.CodeGen.DbgTypeIds exposing
    ( expectDbgTypeIds
    , checkDbgTypeIds
    )

{-| Test logic for CGEN_036: Dbg Type IDs Valid invariant.

When `eco.dbg` has `arg_type_ids`, each ID must reference a valid type table entry.

@docs expectDbgTypeIds, checkDbgTypeIds

-}

import Compiler.AST.Source as Src
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getArrayAttr
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirAttr(..), MlirModule, MlirOp)


{-| Verify that dbg type IDs invariants hold for a source module.
-}
expectDbgTypeIds : Src.Module -> Expectation
expectDbgTypeIds srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkDbgTypeIds mlirModule)


{-| Check dbg type IDs invariants.
-}
checkDbgTypeIds : MlirModule -> List Violation
checkDbgTypeIds mlirModule =
    let
        typeTableOps =
            List.filter (\op -> op.name == "eco.type_table") mlirModule.body

        maxTypeId =
            case List.head typeTableOps of
                Just typeTable ->
                    case getArrayAttr "types" typeTable of
                        Just types ->
                            List.length types - 1

                        Nothing ->
                            -1

                Nothing ->
                    -1

        dbgOps =
            findOpsNamed "eco.dbg" mlirModule

        violations =
            List.concatMap (checkDbgOp maxTypeId) dbgOps
    in
    violations


checkDbgOp : Int -> MlirOp -> List Violation
checkDbgOp maxTypeId op =
    let
        maybeTypeIds =
            getArrayAttr "arg_type_ids" op
    in
    case maybeTypeIds of
        Nothing ->
            []

        Just typeIds ->
            if maxTypeId < 0 then
                [ { opId = op.id
                  , opName = op.name
                  , message = "eco.dbg has arg_type_ids but no eco.type_table in module"
                  }
                ]

            else
                List.indexedMap (checkTypeId op maxTypeId) typeIds
                    |> List.filterMap identity


checkTypeId : MlirOp -> Int -> Int -> MlirAttr -> Maybe Violation
checkTypeId op maxTypeId index attr =
    case attr of
        IntAttr _ typeId ->
            if typeId < 0 || typeId > maxTypeId then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.dbg arg_type_ids["
                            ++ String.fromInt index
                            ++ "]="
                            ++ String.fromInt typeId
                            ++ " out of range [0,"
                            ++ String.fromInt maxTypeId
                            ++ "]"
                    }

            else
                Nothing

        _ ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.dbg arg_type_ids[" ++ String.fromInt index ++ "] is not an integer"
                }
