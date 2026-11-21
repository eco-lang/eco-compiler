module Compiler.MonoOpt.Representation exposing (run)

{-| The node rewrite of the representation passes
(plans/constructor-representation-levels.md §13, R3): `EraseWrappers` and
`NullableMaybe` decide first (`EraseWrappers.plan`, `NullableMaybe.choose`),
and this module then rewrites the graph's nodes for both in one loop, with one
expression traversal per node, instead of a full pass for each.

@docs run

-}

import Compiler.IR.Mono as Mono
import Compiler.MonoOpt.EraseWrappers as EraseWrappers
import Compiler.MonoOpt.NullableMaybe as NullableMaybe
import Set


{-| Applies the erasure `plan` and, if given, the nullable `choice` to `graph`,
and returns the graph with what each did. The nullable choice must have been
made on the erased graph's types (`plan.ctorShapes`); its decision-tree rewrite
runs in the erasure's traversal and looks each tested type up through
`EraseWrappers.eraseType`.
-}
run : EraseWrappers.Plan -> Maybe NullableMaybe.Choice -> Mono.MonoGraph -> ( Mono.MonoGraph, EraseWrappers.EraseStats, Maybe NullableMaybe.NullStats )
run plan choice graph =
    let
        nullable =
            Maybe.map .nullable choice |> Maybe.withDefault Mono.layoutMapEmpty

        rewritten =
            if EraseWrappers.erasableIsEmpty plan.erasable && Mono.layoutMapIsEmpty nullable then
                Nothing

            else
                Just
                    (EraseWrappers.rewriteNodes plan
                        (NullableMaybe.touchesNode nullable)
                        (NullableMaybe.rewriteStep (EraseWrappers.eraseType plan.erasable) nullable)
                        0
                        graph
                    )

        ( erased, eraseStats ) =
            case rewritten of
                Just r ->
                    EraseWrappers.finish plan r graph

                Nothing ->
                    EraseWrappers.finish plan
                        { nodes = (\(Mono.MonoGraph g) -> g.nodes) graph, nextLambda = 0, counts = { calls = 0, steps = 0, lastRemoved = Nothing }, extra = 0, visited = Set.empty }
                        graph

        testsRewritten =
            Maybe.map .extra rewritten |> Maybe.withDefault 0
    in
    case choice of
        Just c ->
            let
                stats =
                    c.stats
            in
            ( NullableMaybe.recordNullable c erased, eraseStats, Just { stats | testsRewritten = testsRewritten } )

        Nothing ->
            ( erased, eraseStats, Nothing )
