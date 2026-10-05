module TestLogic.Type.PostSolve.GroupBTypes exposing
    ( checkGroupBLiterals
    , expectGroupBTypesValid
    )

{-| Checks that PostSolve types every string, character and float literal and
every unit with the type its form implies, in agreement with the solver
(POST\_001).

Constraint generation types some expressions, its _Group B_, through a
_synthetic placeholder_: a fresh type variable tied to the type its context
expects (`Compiler.Type.Constrain.Typed.Expression` makes the split).
`Compiler.Type.PostSolve` then writes the structural type of the literals among
them, `String`, `Char`, `Float` or `()`, over whatever the solver recorded.

`checkGroupBLiterals` finds every `Str`, `Chr`, `Float` and `Unit` expression
in the module and reports one whose type after PostSolve is missing or not
exactly its form's type, and one whose type before PostSolve, when it has one,
is a different type. The second catches a placeholder that the solver left
unconstrained or tied to a contradicting type, which PostSolve's overwrite
would otherwise hide.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.Data.Name exposing (Name)
import Expect
import TestLogic.TestPipeline as Pipeline
import TestLogic.Type.PostSolve.PostSolveInvariantHelpers as Helpers


{-| Passes when `srcModule` compiles through PostSolve, holds at least one
string, character or float literal or unit, and `checkGroupBLiterals` reports
nothing for it. A program with no such expression fails, since the check would
look at nothing.

A canonicalization or type error fails with the pipeline's message.

-}
expectGroupBTypesValid : Src.Module -> Expect.Expectation
expectGroupBTypesValid srcModule =
    case Pipeline.runToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok result ->
            let
                literalCount =
                    Helpers.walkExprs result.canonical
                        |> List.filter (\n -> Helpers.groupBLiteralType n.node /= Nothing)
                        |> List.length
            in
            if literalCount == 0 then
                Expect.fail "The program has no string, character or float literal or unit to check"

            else
                case checkGroupBLiterals result.canonical result.nodeTypesPre result.nodeTypesPost of
                    [] ->
                        Expect.pass

                    issues ->
                        Expect.fail (String.join "\n" issues)


{-| Returns one line for each string, character or float literal or unit in
`canonical` whose type in `nodeTypesPost` is not exactly its form's type, or
whose type in `nodeTypesPre`, when present, differs from it.
-}
checkGroupBLiterals : Can.Module -> Array.Array (Maybe (Can.Type Name)) -> Array.Array (Maybe (Can.Type Name)) -> List String
checkGroupBLiterals canonical nodeTypesPre nodeTypesPost =
    Helpers.walkExprs canonical
        |> List.filterMap
            (\exprNode ->
                Helpers.groupBLiteralType exprNode.node
                    |> Maybe.andThen
                        (\expected ->
                            let
                                label =
                                    "NodeId " ++ String.fromInt exprNode.id ++ ": "

                                pre =
                                    Array.get exprNode.id nodeTypesPre |> Maybe.andThen identity

                                post =
                                    Array.get exprNode.id nodeTypesPost |> Maybe.andThen identity
                            in
                            if post /= Just expected then
                                Just (label ++ "type after PostSolve is " ++ Debug.toString post ++ ", expected " ++ Debug.toString expected)

                            else
                                case pre of
                                    Just preType ->
                                        if preType /= expected then
                                            Just (label ++ "the solver typed it " ++ Debug.toString preType ++ ", not " ++ Debug.toString expected)

                                        else
                                            Nothing

                                    Nothing ->
                                        Nothing
                        )
            )
