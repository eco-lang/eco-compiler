module TestLogic.Generate.MonoTypeShape exposing (expectMonoTypesFullyElaborated)

{-| Code generation cannot lay out a number whose type is still undecided, so
the program handed to it must hold no number variable: an `MVar` with the
`CNumber` constraint, which stands for an `Int` or a `Float` not yet chosen
(MONO\_001 allows a variable only with a constraint that needs no further
inference; MONO\_002 rules out `CNumber` at code generation). Any other
variable is an `MVar _ CEcoValue`, always boxed, and may remain.

`expectMonoTypesFullyElaborated` runs a program through the pipeline of a
default build, `TestLogic.TestPipeline.runToGlobalOptLssOn`: the solver
monomorphization engine with lambda-set specialization, then the
post-monomorphization inliner and the global optimizer. It fails if any type
stored in the optimized graph, at any position `MonoTraverse.anyNodeType`
reaches (node, expression, parameter, capture and call-metadata types, and the
branches a case holds inline) and at any depth (inside lists, tuples, records,
custom type arguments and functions), is a number variable. The solver
engine's final prune closes number variables, but the inliner and the global
optimizer run after it and nothing else checks their output.

Among what is not checked: the substitution engine's graph, which
`TestLogic.Generate.MonoNumericResolution` checks the same way.

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| Returns an expectation that passes when no type in the globally optimized
graph of `srcModule`, built with the solver engine, holds a number variable.
It fails with the pipeline's message when the pipeline fails, and otherwise
with one line per node holding one, labelled with the node's `SpecId`.
-}
expectMonoTypesFullyElaborated : Src.Module -> Expect.Expectation
expectMonoTypesFullyElaborated srcModule =
    case Pipeline.runToGlobalOptLssOn srcModule of
        Err msg ->
            Expect.fail ("solver+LSS pipeline failed: " ++ msg)

        Ok { optimizedMonoGraph } ->
            let
                issues =
                    collectMonoTypeIssues optimizedMonoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)


{-| One line per node of the graph holding a number variable in some type.
-}
collectMonoTypeIssues : Mono.MonoGraph -> List String
collectMonoTypeIssues (Mono.MonoGraph data) =
    Array.toIndexedList data.nodes
        |> List.filterMap
            (\( specId, maybeNode ) ->
                case maybeNode of
                    Just node ->
                        if MonoTraverse.anyNodeType hasNumberVar node then
                            Just ("SpecId " ++ String.fromInt specId ++ ": a type holds an MVar with CNumber constraint (MONO_001/MONO_002)")

                        else
                            Nothing

                    Nothing ->
                        Nothing
            )


{-| Returns whether `monoType` holds an `MVar _ CNumber` at any depth.
-}
hasNumberVar : Mono.MonoType -> Bool
hasNumberVar monoType =
    case monoType of
        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MList _ elemType ->
            hasNumberVar elemType

        Mono.MTuple _ elemTypes ->
            List.any hasNumberVar elemTypes

        Mono.MRecord _ fields ->
            List.any hasNumberVar (Dict.values fields)

        Mono.MCustom _ _ _ typeArgs ->
            List.any hasNumberVar typeArgs

        Mono.MFunction _ _ paramTypes returnType ->
            List.any hasNumberVar paramTypes || hasNumberVar returnType

        _ ->
            False
