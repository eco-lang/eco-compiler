module Compiler.Generate.CodeGen.JumpTarget exposing
    ( expectJumpTarget
    , checkJumpTargets
    )

{-| Test logic for CGEN_030: Jump Target Validity invariant.

`eco.jump` target must refer to a lexically enclosing `eco.joinpoint` with
matching id, and argument types must match.

@docs expectJumpTarget, checkJumpTargets

-}

import Compiler.AST.Source as Src
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getIntAttr
        , violationsToExpectation
        )
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict


{-| Verify that jump target invariants hold for a source module.
-}
expectJumpTarget : Src.Module -> Expectation
expectJumpTarget srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkJumpTargets mlirModule)


{-| Check jump target validity invariants.
-}
checkJumpTargets : MlirModule -> List Violation
checkJumpTargets mlirModule =
    let
        funcOps =
            findFuncOps mlirModule

        violations =
            List.concatMap checkFunctionJumps funcOps
    in
    violations


checkFunctionJumps : MlirOp -> List Violation
checkFunctionJumps funcOp =
    let
        -- Collect all joinpoints in this function
        joinpointMap =
            collectJoinpoints funcOp Dict.empty

        -- Find all jumps and verify targets
        jumps =
            findJumpsInOp funcOp
    in
    List.filterMap (checkJumpTarget joinpointMap) jumps


collectJoinpoints : MlirOp -> Dict Int ( MlirOp, List ( String, Mlir.Mlir.MlirType ) ) -> Dict Int ( MlirOp, List ( String, Mlir.Mlir.MlirType ) )
collectJoinpoints op map =
    let
        updatedMap =
            if op.name == "eco.joinpoint" then
                case getIntAttr "id" op of
                    Just id ->
                        let
                            argTypes =
                                case List.head op.regions of
                                    Just (MlirRegion { entry }) ->
                                        entry.args

                                    Nothing ->
                                        []
                        in
                        Dict.insert id ( op, argTypes ) map

                    Nothing ->
                        map

            else
                map
    in
    List.foldl collectJoinpointsInRegion updatedMap op.regions


collectJoinpointsInRegion : MlirRegion -> Dict Int ( MlirOp, List ( String, Mlir.Mlir.MlirType ) ) -> Dict Int ( MlirOp, List ( String, Mlir.Mlir.MlirType ) )
collectJoinpointsInRegion (MlirRegion { entry, blocks }) map =
    let
        entryMap =
            collectJoinpointsInBlock entry map

        allBlocks =
            OrderedDict.values blocks
    in
    List.foldl collectJoinpointsInBlock entryMap allBlocks


collectJoinpointsInBlock : MlirBlock -> Dict Int ( MlirOp, List ( String, Mlir.Mlir.MlirType ) ) -> Dict Int ( MlirOp, List ( String, Mlir.Mlir.MlirType ) )
collectJoinpointsInBlock block map =
    let
        bodyMap =
            List.foldl collectJoinpoints map block.body
    in
    collectJoinpoints block.terminator bodyMap


findJumpsInOp : MlirOp -> List MlirOp
findJumpsInOp op =
    let
        selfJumps =
            if op.name == "eco.jump" then
                [ op ]

            else
                []

        regionJumps =
            List.concatMap findJumpsInRegion op.regions
    in
    selfJumps ++ regionJumps


findJumpsInRegion : MlirRegion -> List MlirOp
findJumpsInRegion (MlirRegion { entry, blocks }) =
    let
        entryJumps =
            findJumpsInBlock entry

        allBlocks =
            OrderedDict.values blocks

        blockJumps =
            List.concatMap findJumpsInBlock allBlocks
    in
    entryJumps ++ blockJumps


findJumpsInBlock : MlirBlock -> List MlirOp
findJumpsInBlock block =
    let
        bodyJumps =
            List.concatMap findJumpsInOp block.body

        terminatorJumps =
            findJumpsInOp block.terminator
    in
    bodyJumps ++ terminatorJumps


checkJumpTarget : Dict Int ( MlirOp, List ( String, Mlir.Mlir.MlirType ) ) -> MlirOp -> Maybe Violation
checkJumpTarget joinpointMap jumpOp =
    let
        maybeTargetId =
            getIntAttr "target" jumpOp
    in
    case maybeTargetId of
        Nothing ->
            Just
                { opId = jumpOp.id
                , opName = jumpOp.name
                , message = "eco.jump missing target attribute"
                }

        Just targetId ->
            case Dict.get targetId joinpointMap of
                Nothing ->
                    Just
                        { opId = jumpOp.id
                        , opName = jumpOp.name
                        , message = "eco.jump target " ++ String.fromInt targetId ++ " not found in enclosing joinpoints"
                        }

                Just ( _, expectedArgs ) ->
                    let
                        jumpArgCount =
                            List.length jumpOp.operands

                        expectedArgCount =
                            List.length expectedArgs
                    in
                    if jumpArgCount /= expectedArgCount then
                        Just
                            { opId = jumpOp.id
                            , opName = jumpOp.name
                            , message =
                                "eco.jump has "
                                    ++ String.fromInt jumpArgCount
                                    ++ " args but joinpoint "
                                    ++ String.fromInt targetId
                                    ++ " expects "
                                    ++ String.fromInt expectedArgCount
                            }

                    else
                        Nothing
