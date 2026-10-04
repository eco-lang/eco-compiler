module TestLogic.Generate.CodeGen.JumpTarget exposing (expectJumpTarget)

{-| A jump in generated MLIR that names no joinpoint, or passes it the wrong
arguments, is a broken program that no type in `Mlir.Mlir` rules out. This
module checks the jumps in the MLIR generated for one source module.

A _joinpoint_ is an `eco.joinpoint` op, identified by its integer `id`
attribute. Its parameters are the arguments of the entry block of its first
region. A _jump_ is an `eco.jump` op. Its `target` attribute names a joinpoint
by `id`, and its operands are the arguments it passes to that joinpoint's
parameters.

`expectJumpTarget` compiles the module with `runToMlir` and checks each
top-level `func.func` on its own. It collects the joinpoints at any depth in the
function by `id`, and then reports each jump in the function that:

  - has no integer `target` attribute;
  - has a `target` that no joinpoint in the same function has as its `id`;
  - has a different number of operands from the joinpoint's parameters;
  - records in its `_operand_types` attribute a type that differs from the
    joinpoint's parameter type at the same position.

The joinpoint need not enclose the jump: one with a matching `id` anywhere in
the same function is accepted. When two joinpoints in a function share an `id`,
a jump is checked against the one found last in a depth-first walk of the
function. A jump without `_operand_types` has its argument types left
unchecked.

Among what is not checked: jumps and joinpoints outside a top-level
`func.func`, whether a joinpoint id is unique, and whether a jump's operands
really have the types its `_operand_types` attribute records.

@docs expectJumpTarget

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , findFuncOps
        , getIntAttr
        , typesMatch
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR and passes when
no jump in it breaks the rules in the module docstring. It fails with the
compiler's message if compilation fails, and otherwise with the first violation
found, as `violationsToExpectation` reports it.
-}
expectJumpTarget : Src.Module -> Expectation
expectJumpTarget srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkJumpTargets mlirModule)


{-| Returns the violations found in each top-level `func.func` of the module,
each function checked against its own joinpoints only.
-}
checkJumpTargets : MlirModule -> List Violation
checkJumpTargets mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunctionJumps funcOps


{-| Returns a violation for each jump at any depth in `funcOp` that does not fit
the joinpoint it targets, looked up among the joinpoints of `funcOp`.
-}
checkFunctionJumps : MlirOp -> List Violation
checkFunctionJumps funcOp =
    let
        joinpointMap =
            collectJoinpoints funcOp Dict.empty

        jumps =
            findJumpsInOp funcOp
    in
    List.filterMap (checkJumpTarget joinpointMap) jumps


{-| Adds `op`, if it is a joinpoint, and every joinpoint nested in its regions
to `map`, keyed by `id`. Each is stored with its parameters, the arguments of
its first region's entry block, or none if it has no region.

A joinpoint without an integer `id` is left out. A joinpoint replaces one
already in `map` with the same `id`, so the last one found wins.

-}
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


{-| Adds every joinpoint in the region to `map`, from the entry block first and
then from the labelled blocks in order.
-}
collectJoinpointsInRegion : MlirRegion -> Dict Int ( MlirOp, List ( String, Mlir.Mlir.MlirType ) ) -> Dict Int ( MlirOp, List ( String, Mlir.Mlir.MlirType ) )
collectJoinpointsInRegion (MlirRegion { entry, blocks }) map =
    let
        entryMap =
            collectJoinpointsInBlock entry map

        allBlocks =
            OrderedDict.values blocks
    in
    List.foldl collectJoinpointsInBlock entryMap allBlocks


{-| Adds every joinpoint in the block to `map`, from its body ops first and then
from its terminator.
-}
collectJoinpointsInBlock : MlirBlock -> Dict Int ( MlirOp, List ( String, Mlir.Mlir.MlirType ) ) -> Dict Int ( MlirOp, List ( String, Mlir.Mlir.MlirType ) )
collectJoinpointsInBlock block map =
    let
        bodyMap =
            List.foldl collectJoinpoints map block.body
    in
    collectJoinpoints block.terminator bodyMap


{-| Returns `op`, if it is an `eco.jump`, followed by every `eco.jump` nested in
its regions.
-}
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


{-| Returns every `eco.jump` in the region, from the entry block first and then
from the labelled blocks in order.
-}
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


{-| Returns every `eco.jump` in the block's body ops and then in its terminator.
A jump that the block holds both in its body and as its terminator is listed
twice.
-}
findJumpsInBlock : MlirBlock -> List MlirOp
findJumpsInBlock block =
    let
        bodyJumps =
            List.concatMap findJumpsInOp block.body

        terminatorJumps =
            findJumpsInOp block.terminator
    in
    bodyJumps ++ terminatorJumps


{-| Returns the violation, if any, of `jumpOp` against the joinpoints in
`joinpointMap`. In order, it reports a missing `target`, a `target` not in the
map, or an operand count different from the joinpoint's parameter count, and
otherwise the first type mismatch `checkJumpArgTypes` finds.
-}
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
                        checkJumpArgTypes jumpOp targetId expectedArgs


{-| Returns a violation for the first position at which the type recorded in
`jumpOp`'s `_operand_types` attribute differs from the type of the parameter in
`expectedArgs` at that position, or `Nothing` if none differs. `targetId` is
used only in the message.

A jump without `_operand_types` gets `Nothing`, since it has no recorded types
to compare; nothing in this module reports the missing attribute. Positions
past the end of the shorter of the two lists are not compared.

-}
checkJumpArgTypes : MlirOp -> Int -> List ( String, Mlir.Mlir.MlirType ) -> Maybe Violation
checkJumpArgTypes jumpOp targetId expectedArgs =
    case extractOperandTypes jumpOp of
        Nothing ->
            Nothing

        Just jumpArgTypes ->
            let
                expectedTypes =
                    List.map Tuple.second expectedArgs

                mismatches =
                    List.indexedMap
                        (\i ( jumpType, expectedType ) ->
                            if typesMatch jumpType expectedType then
                                Nothing

                            else
                                Just
                                    { index = i
                                    , jumpType = jumpType
                                    , expectedType = expectedType
                                    }
                        )
                        (List.map2 Tuple.pair jumpArgTypes expectedTypes)
                        |> List.filterMap identity
            in
            case mismatches of
                [] ->
                    Nothing

                first :: _ ->
                    Just
                        { opId = jumpOp.id
                        , opName = jumpOp.name
                        , message =
                            "eco.jump arg "
                                ++ String.fromInt first.index
                                ++ " has type "
                                ++ typeToString first.jumpType
                                ++ " but joinpoint "
                                ++ String.fromInt targetId
                                ++ " expects "
                                ++ typeToString first.expectedType
                        }


{-| Returns a short spelling of a type for a failure message: `i1` to `i64`
and `f64` as MLIR writes them, a named struct by its stored name (`eco.value`,
without the `!`), and `function` for any function type.
-}
typeToString : Mlir.Mlir.MlirType -> String
typeToString t =
    case t of
        Mlir.Mlir.I1 ->
            "i1"

        Mlir.Mlir.I8 ->
            "i8"

        Mlir.Mlir.I16 ->
            "i16"

        Mlir.Mlir.I32 ->
            "i32"

        Mlir.Mlir.I64 ->
            "i64"

        Mlir.Mlir.F64 ->
            "f64"

        Mlir.Mlir.NamedStruct name ->
            name

        Mlir.Mlir.FunctionType _ ->
            "function"
