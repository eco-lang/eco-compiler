module TestLogic.Type.PostSolve.NoSyntheticVars exposing (expectNoSyntheticVars)

{-| Gives tests a check that no synthetic placeholder variable is left
unconstrained, and so survives into the node types after PostSolve.

Constraint generation types some expressions through a _synthetic
placeholder_: a fresh type variable recorded as the expression's type and tied
to the type its context expects. Variable references, constructors, and
string, character and float literals and unit are such expressions. A
placeholder that no constraint reaches stays a variable of its own: it occurs
at its node and nowhere else in the solved node types.
`TestLogic.Type.PostSolve.PostSolveInvariantHelpers.orphanPlaceholderVars`
finds those, and its docstring says why nothing else can look like one.

`expectNoSyntheticVars` compiles the module through PostSolve with
`TestLogic.Type.PostSolve.CompileThroughPostSolve.compileToPostSolveDetailed`
and fails for each such orphan variable still present in the node's type
after PostSolve, which replaces only the types of literals and unit. A module
that fails to canonicalize or type check fails with the pipeline's message.

-}

import Array
import Compiler.AST.Source as Src
import Data.Set as EverySet
import Expect
import TestLogic.Type.PostSolve.CompileThroughPostSolve as Compile
import TestLogic.Type.PostSolve.PostSolveInvariantHelpers as Helpers


{-| Runs `srcModule` through PostSolve and passes when no node typed through a
synthetic placeholder keeps an orphan placeholder variable in its type after
PostSolve.

It fails with one line per such node, or with the pipeline's message when
canonicalization or type checking fails.

-}
expectNoSyntheticVars : Src.Module -> Expect.Expectation
expectNoSyntheticVars srcModule =
    case Compile.compileToPostSolveDetailed srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                issues =
                    Helpers.orphanPlaceholderVars artifacts.canonical artifacts.syntheticExprIds artifacts.nodeTypesPre
                        |> List.filterMap
                            (\( nodeId, name ) ->
                                case Array.get nodeId artifacts.nodeTypesPost |> Maybe.andThen identity of
                                    Just postType ->
                                        if EverySet.member identity name (Helpers.freeTypeVars postType) then
                                            Just
                                                ("NodeId "
                                                    ++ String.fromInt nodeId
                                                    ++ ": placeholder variable '"
                                                    ++ name
                                                    ++ "' is constrained by nothing"
                                                )

                                        else
                                            Nothing

                                    Nothing ->
                                        Nothing
                            )
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)
