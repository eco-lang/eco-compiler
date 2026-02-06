module TestLogic.Generate.CodeGen.JoinpointUniqueId exposing (expectJoinpointUniqueId, checkJoinpointUniqueness)

{-| Test logic for CGEN\_031: Joinpoint ID Uniqueness invariant.

Within a single `func.func`, each `eco.joinpoint` id must be unique.

@docs expectJoinpointUniqueId, checkJoinpointUniqueness

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict
import TestLogic.TestPipeline exposing (runToMlir)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        )


{-| Verify that joinpoint ID uniqueness invariants hold for a source module.
-}
expectJoinpointUniqueId : Src.Module -> Expectation
expectJoinpointUniqueId srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkJoinpointUniqueness mlirModule)


{-| Check joinpoint ID uniqueness invariants.
-}
checkJoinpointUniqueness : MlirModule -> List Violation
checkJoinpointUniqueness mlirModule =
    let
        funcOps =
            findFuncOps mlirModule

        violations =
            List.concatMap checkFunctionJoinpoints funcOps
    in
    violations


checkFunctionJoinpoints : MlirOp -> List Violation
checkFunctionJoinpoints funcOp =
    let
        funcName =
            getStringAttr "sym_name" funcOp |> Maybe.withDefault "unknown"

        joinpoints =
            findJoinpointsInOp funcOp

        ( violations, _ ) =
            List.foldl
                (\jp ( accViolations, seenIds ) ->
                    let
                        maybeId =
                            getIntAttr "id" jp
                    in
                    case maybeId of
                        Nothing ->
                            ( { opId = jp.id
                              , opName = jp.name
                              , message = "eco.joinpoint missing id attribute"
                              }
                                :: accViolations
                            , seenIds
                            )

                        Just id ->
                            case Dict.get id seenIds of
                                Just firstOpId ->
                                    ( { opId = jp.id
                                      , opName = jp.name
                                      , message =
                                            "Duplicate joinpoint id "
                                                ++ String.fromInt id
                                                ++ " in function "
                                                ++ funcName
                                                ++ ", first at "
                                                ++ firstOpId
                                      }
                                        :: accViolations
                                    , seenIds
                                    )

                                Nothing ->
                                    ( accViolations
                                    , Dict.insert id jp.id seenIds
                                    )
                )
                ( [], Dict.empty )
                joinpoints
    in
    violations


findJoinpointsInOp : MlirOp -> List MlirOp
findJoinpointsInOp op =
    let
        selfJoinpoints =
            if op.name == "eco.joinpoint" then
                [ op ]

            else
                []

        regionJoinpoints =
            List.concatMap findJoinpointsInRegion op.regions
    in
    selfJoinpoints ++ regionJoinpoints


findJoinpointsInRegion : MlirRegion -> List MlirOp
findJoinpointsInRegion (MlirRegion { entry, blocks }) =
    let
        entryJoinpoints =
            findJoinpointsInBlock entry

        allBlocks =
            OrderedDict.values blocks

        blockJoinpoints =
            List.concatMap findJoinpointsInBlock allBlocks
    in
    entryJoinpoints ++ blockJoinpoints


findJoinpointsInBlock : MlirBlock -> List MlirOp
findJoinpointsInBlock block =
    let
        bodyJoinpoints =
            List.concatMap findJoinpointsInOp block.body

        terminatorJoinpoints =
            findJoinpointsInOp block.terminator
    in
    bodyJoinpoints ++ terminatorJoinpoints
