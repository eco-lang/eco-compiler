module TestLogic.Generate.CodeGen.JumpTarget exposing (expectJumpTarget, checkJumpTargets)

{-| A jump in generated MLIR that names no enclosing joinpoint, or passes it
the wrong arguments, is a broken program that no type in `Mlir.Mlir` rules
out. This module checks the jumps in the MLIR generated for one source module.

A _joinpoint_ is an `eco.joinpoint` op, identified by its integer `id`
attribute. Its parameters are the arguments of the entry block of its first
(body) region. A _jump_ is an `eco.jump` op. Its `target` attribute names a
joinpoint by `id`, and its operands are the arguments it passes to that
joinpoint's parameters. A jump re-enters a joinpoint it is nested in (in its
body or its continuation region), so the target must _enclose_ the jump.

`expectJumpTarget` compiles the module with `runToMlir` and checks each
top-level `func.func` on its own, walking it with the joinpoints that enclose
the current op. It reports each jump that:

  - has no integer `target` attribute;
  - has a `target` that no enclosing joinpoint has as its `id`;
  - has a different number of operands from that joinpoint's parameters
    (the innermost enclosing one with the `id`);
  - has an operand whose defined type (from the op result or block argument
    that introduces it in the function,
    `TestLogic.Generate.CodeGen.Invariants.typeEnvOfOp`) differs from the
    joinpoint's parameter type at the same position.

The code generator lowers tail recursion to `scf.while` loops
(`Compiler.Generate.MLIR.TailRec`) and emits no `eco.joinpoint`, so on generated
MLIR every `eco.jump` is reported: the only code that emits one,
`Compiler.Generate.MLIR.Expr.generateTailCall`, is a fallback whose jump to
joinpoint 0 has no joinpoint to land on.

Among what is not checked: jumps and joinpoints outside a top-level
`func.func`, and whether a joinpoint id is unique.

@docs expectJumpTarget, checkJumpTargets

-}

import Compiler.AST.Source as Src
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirRegion(..), MlirType)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( TypeEnv
        , Violation
        , allBlocks
        , findFuncOps
        , getIntAttr
        , typeEnvOfOp
        , typesMatch
        , violationsToExpectation
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR and passes when
no jump in it breaks the rules in the module docstring. It fails with the
compiler's message if compilation fails, and otherwise with the violations
found, as `violationsToExpectation` reports them.
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
the innermost joinpoint enclosing it with its target `id`.
-}
checkFunctionJumps : MlirOp -> List Violation
checkFunctionJumps funcOp =
    checkOpJumps (typeEnvOfOp funcOp) Dict.empty funcOp


{-| Returns the jump violations of `op` and of every op nested in it, given the
type environment of the function and the joinpoints enclosing `op`, by `id`,
with their parameter types. A joinpoint encloses the ops of both its regions.
-}
checkOpJumps : TypeEnv -> Dict Int (List MlirType) -> MlirOp -> List Violation
checkOpJumps env enclosing op =
    let
        inner =
            if op.name == "eco.joinpoint" then
                case getIntAttr "id" op of
                    Just id ->
                        let
                            params =
                                case List.head op.regions of
                                    Just (MlirRegion { entry }) ->
                                        List.map Tuple.second entry.args

                                    Nothing ->
                                        []
                        in
                        Dict.insert id params enclosing

                    Nothing ->
                        enclosing

            else
                enclosing

        selfViolations =
            if op.name == "eco.jump" then
                checkJumpTarget env enclosing op |> Maybe.map List.singleton |> Maybe.withDefault []

            else
                []

        nested =
            List.concatMap
                (\region ->
                    allBlocks region
                        |> List.concatMap (\block -> block.body ++ [ block.terminator ])
                        |> List.concatMap (checkOpJumps env inner)
                )
                op.regions
    in
    selfViolations ++ nested


{-| Returns the violation, if any, of `jumpOp` against the enclosing joinpoints
in `enclosing`. In order, it reports a missing `target`, a `target` that no
enclosing joinpoint has, or an operand count different from the joinpoint's
parameter count, and otherwise the first type mismatch `checkJumpArgTypes`
finds.
-}
checkJumpTarget : TypeEnv -> Dict Int (List MlirType) -> MlirOp -> Maybe Violation
checkJumpTarget env enclosing jumpOp =
    case getIntAttr "target" jumpOp of
        Nothing ->
            Just
                { opId = jumpOp.id
                , opName = jumpOp.name
                , message = "eco.jump missing target attribute"
                }

        Just targetId ->
            case Dict.get targetId enclosing of
                Nothing ->
                    Just
                        { opId = jumpOp.id
                        , opName = jumpOp.name
                        , message = "eco.jump target " ++ String.fromInt targetId ++ " is not the id of any enclosing joinpoint"
                        }

                Just expectedTypes ->
                    let
                        jumpArgCount =
                            List.length jumpOp.operands

                        expectedArgCount =
                            List.length expectedTypes
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
                        checkJumpArgTypes env jumpOp targetId expectedTypes


{-| Returns a violation for the first operand of `jumpOp` whose defined type in
`env` differs from the joinpoint parameter type in `expectedTypes` at that
position, or that has no definition in `env`, or `Nothing` if none does.
`targetId` is used only in the message.
-}
checkJumpArgTypes : TypeEnv -> MlirOp -> Int -> List MlirType -> Maybe Violation
checkJumpArgTypes env jumpOp targetId expectedTypes =
    List.map2 Tuple.pair jumpOp.operands expectedTypes
        |> List.indexedMap
            (\i ( operand, expectedType ) ->
                case Dict.get operand env of
                    Nothing ->
                        Just ("eco.jump arg " ++ String.fromInt i ++ " (" ++ operand ++ ") has no definition in its function")

                    Just actual ->
                        if typesMatch actual expectedType then
                            Nothing

                        else
                            Just
                                ("eco.jump arg "
                                    ++ String.fromInt i
                                    ++ " has type "
                                    ++ typeToString actual
                                    ++ " but joinpoint "
                                    ++ String.fromInt targetId
                                    ++ " expects "
                                    ++ typeToString expectedType
                                )
            )
        |> List.filterMap identity
        |> List.head
        |> Maybe.map (\message -> { opId = jumpOp.id, opName = jumpOp.name, message = message })


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
