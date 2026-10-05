module TestLogic.Generate.CodeGen.JoinpointUniqueId exposing (expectJoinpointUniqueId)

{-| Checks how tail recursion appears in generated MLIR. The `eco` dialect has
an `eco.joinpoint` op (a loop head, identified within its function by an
integer `id`) and an `eco.jump` that re-enters one by `id`; two joinpoints with
the same `id` would make a jump ambiguous. The code generator does not use that
pair for tail recursion: `Compiler.Generate.MLIR.TailRec` lowers every
self-tail-recursive function (a `MonoTailFunc`) to an `scf.while` loop. So a
check of joinpoint ids alone finds nothing to check on generated MLIR; this
module checks the lowering that is generated, and keeps the id check for any
joinpoint that does appear.

`expectJoinpointUniqueId` compiles a source module to MLIR with
`TestLogic.TestPipeline.runToMlir` and reports:

  - for each `MonoTailFunc` node of the monomorphized graph whose body holds a
    `MonoTailCall`, when the module has a top-level `func.func` named for it
    (`sym_name` ending in `_$_<SpecId>`): that function holds no `scf.while`
    (the tail call was not lowered to a loop), or holds an `eco.jump` (the
    fallback `Compiler.Generate.MLIR.Expr.generateTailCall` was reached; it
    jumps to a joinpoint 0 that nothing defines);
  - within any top-level `func.func`, an `eco.joinpoint` with no integer `id`,
    or one whose `id` an earlier joinpoint of the same function already has.

Not checked: tail calls of let-bound tail functions (`MonoTailDef`), and
whether the loop computes the right thing. `TestLogic.Generate.CodeGen.JumpTarget`
checks every `eco.jump` against its enclosing joinpoints.

@docs expectJoinpointUniqueId

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        , walkOpAndChildren
        )
import TestLogic.TestPipeline exposing (runToMlir)


{-| Returns an expectation that compiles `srcModule` to MLIR and passes when
every tail-recursive function is lowered to an `scf.while` with no `eco.jump`,
and no top-level `func.func` contains an `eco.joinpoint` without an integer
`id` or two `eco.joinpoint` ops with the same `id`. It fails when compilation
fails, and otherwise with the violations.
-}
expectJoinpointUniqueId : Src.Module -> Expectation
expectJoinpointUniqueId srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule, monoGraph } ->
            violationsToExpectation
                (checkTailLoops monoGraph mlirModule ++ checkJoinpointUniqueness mlirModule)


{-| Returns a violation for each function generated for a tail-recursive
`MonoTailFunc` that holds no `scf.while` or holds an `eco.jump`.
-}
checkTailLoops : Mono.MonoGraph -> MlirModule -> List Violation
checkTailLoops (Mono.MonoGraph data) mlirModule =
    let
        funcsBySpec =
            findFuncOps mlirModule
                |> List.filterMap
                    (\op ->
                        getStringAttr "sym_name" op
                            |> Maybe.andThen specIdOf
                            |> Maybe.map (\specId -> ( specId, op ))
                    )
                |> Dict.fromList

        isTailRecursive body =
            MonoTraverse.foldExpr
                (\e found ->
                    case e of
                        Mono.MonoTailCall _ _ _ ->
                            True

                        _ ->
                            found
                )
                False
                body
    in
    Array.toIndexedList data.nodes
        |> List.filterMap
            (\( specId, maybeNode ) ->
                case ( maybeNode, Dict.get specId funcsBySpec ) of
                    ( Just (Mono.MonoTailFunc _ body _), Just funcOp ) ->
                        if isTailRecursive body then
                            let
                                opNames =
                                    List.map .name (walkOpAndChildren funcOp)

                                violation message =
                                    Just { opId = funcOp.id, opName = funcOp.name, message = message }
                            in
                            if List.member "eco.jump" opNames then
                                violation "tail-recursive function holds an eco.jump (Expr.generateTailCall fallback) instead of an scf.while loop"

                            else if not (List.member "scf.while" opNames) then
                                violation "tail-recursive function was not lowered to an scf.while loop"

                            else
                                Nothing

                        else
                            Nothing

                    _ ->
                        Nothing
            )


{-| The SpecId after the last `_$_` of a symbol, if it is a number.
-}
specIdOf : String -> Maybe Int
specIdOf name =
    case List.reverse (String.split "_$_" name) of
        last :: _ :: _ ->
            String.toInt last

        _ ->
            Nothing


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
    List.filter (\o -> o.name == "eco.joinpoint") (walkOpAndChildren op)
