module TestLogic.Generate.CodeGen.JoinpointUniqueId exposing (expectJoinpointUniqueId)

{-| An `eco.jump` names the joinpoint it transfers control to by an integer,
so two joinpoints with the same integer in one function would make a jump
ambiguous. This module checks that no generated function has such a pair.

A _joinpoint_ is an `eco.joinpoint` op, identified within its function by its
integer `id` attribute. An `eco.jump` names its destination by that integer, in
its `target` attribute.

`expectJoinpointUniqueId` compiles a source module to MLIR and walks each
top-level `func.func` of the result, including every op nested in its regions,
in both the entry block and the other blocks, and in both block bodies and
terminators. Within one function it reports:

  - a joinpoint with no integer `id` attribute;
  - a joinpoint whose `id` an earlier joinpoint of the same function already
    has, with the op id of that earlier joinpoint in the message.

Ids are compared only within one top-level `func.func`, so the same `id` in two
different functions is not a violation.

The code generator under `src/` builds no op named `eco.joinpoint`, so on
generated MLIR this check finds no joinpoint and passes whenever compilation
succeeds.

Among what is not tested: that each `eco.jump` names a joinpoint that exists.

@docs expectJoinpointUniqueId

-}

import Compiler.AST.Source as Src
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR and passes when no
top-level `func.func` contains an `eco.joinpoint` without an integer `id` or two
`eco.joinpoint` ops with the same `id`.

It fails when compilation fails. When there are violations, it fails with the
message of one of them only. For a repeated `id` that message names the function
and the op id of the joinpoint that first had the `id`.

-}
expectJoinpointUniqueId : Src.Module -> Expectation
expectJoinpointUniqueId srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkJoinpointUniqueness mlirModule)


{-| Returns the joinpoint violations found in the top-level `func.func` ops of
`mlirModule`, each function checked on its own.
-}
checkJoinpointUniqueness : MlirModule -> List Violation
checkJoinpointUniqueness mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunctionJoinpoints funcOps


{-| Returns the violations among the joinpoints nested anywhere in `funcOp`: one
for each joinpoint with no integer `id`, and one for each joinpoint whose `id`
an earlier joinpoint, in walk order, already has.

The function is named by its `sym_name`, or `unknown` when it has none. The
violations come out in the reverse of walk order.

-}
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


{-| Returns `op` itself if it is an `eco.joinpoint`, followed by every
`eco.joinpoint` nested in its regions, in walk order.
-}
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


{-| Returns every `eco.joinpoint` in a region, those in the entry block first
and then those in the other blocks in their stored order.
-}
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


{-| Returns every `eco.joinpoint` in a block, at any depth, those in the body
ops first and then those in the terminator.
-}
findJoinpointsInBlock : MlirBlock -> List MlirOp
findJoinpointsInBlock block =
    let
        bodyJoinpoints =
            List.concatMap findJoinpointsInOp block.body

        terminatorJoinpoints =
            findJoinpointsInOp block.terminator
    in
    bodyJoinpoints ++ terminatorJoinpoints
