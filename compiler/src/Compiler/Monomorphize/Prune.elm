module Compiler.Monomorphize.Prune exposing (pruneUnreachableSpecs)

{-| Prune unreachable specializations from MonoGraph.

After monomorphization, this pass removes all specializations that are not
reachable from the main entry point via callEdges. This ensures the graph
handed to GlobalOpt and MLIR contains only concrete specializations that
matter for code generation.

@docs pruneUnreachableSpecs

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.BitSet as BitSet exposing (BitSet)
import Compiler.Monomorphize.Analysis as Analysis
import Data.Map
import Dict exposing (Dict)


{-| Compute the BitSet of SpecIds reachable from the main specialization
by DFS over the precomputed callEdges adjacency.
-}
reachableFromMain : Mono.MonoGraph -> BitSet
reachableFromMain (Mono.MonoGraph record) =
    let
        size =
            record.registry.nextId
    in
    case record.main of
        Nothing ->
            -- Library / non-executable: conservatively keep everything.
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Just _ ->
                            ( specId + 1, BitSet.insert specId acc )

                        Nothing ->
                            ( specId + 1, acc )
                )
                ( 0, BitSet.fromSize size )
                record.nodes
                |> Tuple.second

        Just (Mono.StaticMain mainSpecId) ->
            markReachable record.callEdges [ mainSpecId ] (BitSet.fromSize size)


{-| DFS over callEdges using an explicit stack. Returns BitSet of all reachable specIds.
-}
markReachable : Array (Maybe (List Int)) -> List Int -> BitSet -> BitSet
markReachable callEdges stack visited =
    case stack of
        [] ->
            visited

        specId :: rest ->
            if BitSet.member specId visited then
                markReachable callEdges rest visited

            else
                let
                    visited1 =
                        BitSet.insert specId visited

                    neighbors =
                        case Array.get specId callEdges |> Maybe.andThen identity of
                            Nothing ->
                                []

                            Just edges ->
                                edges
                in
                markReachable callEdges (neighbors ++ rest) visited1


{-| Prune MonoGraph and SpecializationRegistry to keep only
specializations reachable from mainSpecId via callEdges.
Also recomputes ctorShapes from the pruned nodes.
-}
pruneUnreachableSpecs : TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> Mono.MonoGraph
pruneUnreachableSpecs globalTypeEnv (Mono.MonoGraph record) =
    let
        live : BitSet
        live =
            reachableFromMain (Mono.MonoGraph record)

        -- 1. Filter nodes (leave Nothing gaps for dead entries)
        nodes1 : Array (Maybe Mono.MonoNode)
        nodes1 =
            Array.indexedMap
                (\specId entry ->
                    if BitSet.member specId live then
                        entry

                    else
                        Nothing
                )
                record.nodes

        -- 2. Filter callEdges (leave Nothing gaps for dead entries)
        callEdges1 : Array (Maybe (List Int))
        callEdges1 =
            Array.indexedMap
                (\specId entry ->
                    if BitSet.member specId live then
                        entry

                    else
                        Nothing
                )
                record.callEdges

        -- 3. Rebuild registry
        oldReg =
            record.registry

        -- Null out dead entries in reverseMapping
        reverseMapping1 : Array (Maybe ( Mono.Global, Mono.MonoType, Maybe Mono.LambdaId ))
        reverseMapping1 =
            Array.indexedMap
                (\i entry ->
                    if BitSet.member i live then
                        entry

                    else
                        Nothing
                )
                oldReg.reverseMapping

        -- Rebuild mapping from live reverseMapping entries
        mapping1 : Dict String Mono.SpecId
        mapping1 =
            List.foldl
                (\( specId, maybeEntry ) acc ->
                    case maybeEntry of
                        Just ( global, monoType, maybeLambda ) ->
                            let
                                key =
                                    Mono.toComparableSpecKey (Mono.SpecKey global monoType maybeLambda)
                            in
                            Dict.insert key specId acc

                        Nothing ->
                            acc
                )
                Dict.empty
                (Array.toIndexedList reverseMapping1)

        registry1 : Mono.SpecializationRegistry
        registry1 =
            { nextId = oldReg.nextId
            , mapping = mapping1
            , reverseMapping = reverseMapping1
            }

        -- 4. Recompute ctorShapes from pruned nodes
        ctorShapes1 : Dict String (List Mono.CtorShape)
        ctorShapes1 =
            Dict.fromList (Data.Map.toList compare (Analysis.computeCtorShapesForGraph globalTypeEnv nodes1))
    in
    Mono.MonoGraph
        { nodes = nodes1
        , main = record.main
        , registry = registry1
        , ctorShapes = ctorShapes1
        , nextLambdaIndex = record.nextLambdaIndex
        , callEdges = callEdges1

        -- Stale bits for pruned specIds are harmless — no node exists to reference them.
        , specHasEffects = record.specHasEffects
        , specValueUsed = record.specValueUsed
        }
