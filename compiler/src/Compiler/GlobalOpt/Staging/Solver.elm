module Compiler.GlobalOpt.Staging.Solver exposing (solveStagingGraph)

{-| Solves the staging graph to produce a StagingSolution.

This module:

1.  Builds equivalence classes from the union-find structure
2.  Chooses canonical segmentation for each class (majority voting)
3.  Maps producers and slots to their classes


# API

@docs solveStagingGraph

-}

import Compiler.GlobalOpt.Staging.Types exposing (ClassId, Node(..), NodeId, ProducerId(..), ProducerInfo, Segmentation, StagingGraph, StagingSolution, Uf)
import Compiler.GlobalOpt.Staging.UnionFind exposing (producerIdToKey, slotIdToKey, ufFind)
import Data.Map as Dict exposing (Dict)



-- ============================================================================
-- SOLVE STAGING GRAPH
-- ============================================================================


{-| Solve the staging graph to produce a StagingSolution.
-}
solveStagingGraph :
    ProducerInfo
    -> StagingGraph
    -> StagingSolution
solveStagingGraph producerInfo sg =
    let
        -- 1) Build mapping NodeId -> ClassId from union-find
        ( nodeToClass, classMembers ) =
            buildClasses sg

        -- 2) For each class, choose canonical segmentation
        classSeg =
            chooseCanonicalSegs producerInfo sg nodeToClass classMembers

        -- 3) Build producerClass / slotClass maps
        ( producerClass, slotClass ) =
            mapProducersAndSlotsToClasses sg nodeToClass
    in
    { classSeg = classSeg
    , producerClass = producerClass
    , slotClass = slotClass
    }



-- ============================================================================
-- BUILD CLASSES
-- ============================================================================


{-| Build equivalence classes from the union-find structure.
Returns (nodeToClass, classMembers).
-}
type alias BuildState =
    { nextClass : Int
    , nodeToClass : Dict Int Int ClassId
    , classMembers : Dict Int Int (List NodeId)
    , uf : Uf
    }


buildClasses :
    StagingGraph
    -> ( Dict Int Int ClassId, Dict Int Int (List NodeId) )
buildClasses sg =
    let
        -- Process each node in the graph
        assignClass :
            String
            -> NodeId
            -> BuildState
            -> BuildState
        assignClass _ nid state =
            let
                -- Find root with path compression
                ( rootId, uf1 ) =
                    ufFind nid state.uf

                -- Check if root already has a class
                maybeClassId =
                    Dict.get identity rootId state.nodeToClass

                ( classId, nextClass2, nodeToClass2 ) =
                    case maybeClassId of
                        Just cid ->
                            ( cid, state.nextClass, state.nodeToClass )

                        Nothing ->
                            -- Assign new class to root
                            ( state.nextClass
                            , state.nextClass + 1
                            , Dict.insert identity rootId state.nextClass state.nodeToClass
                            )

                -- Also assign this node to the class
                nodeToClass3 =
                    if nid /= rootId then
                        Dict.insert identity nid classId nodeToClass2

                    else
                        nodeToClass2

                -- Add node to class members
                classMembers2 =
                    Dict.update identity
                        classId
                        (\maybeList ->
                            Just (nid :: Maybe.withDefault [] maybeList)
                        )
                        state.classMembers
            in
            { nextClass = nextClass2
            , nodeToClass = nodeToClass3
            , classMembers = classMembers2
            , uf = uf1
            }

        initialState =
            { nextClass = 0
            , nodeToClass = Dict.empty
            , classMembers = Dict.empty
            , uf = sg.uf
            }

        finalState =
            Dict.foldl compare
                assignClass
                initialState
                sg.nodeIndex
    in
    ( finalState.nodeToClass, finalState.classMembers )



-- ============================================================================
-- CHOOSE CANONICAL SEGMENTATIONS
-- ============================================================================


{-| Choose canonical segmentation for each class using majority voting.
If a kernel is in the class, use the kernel's segmentation.
-}
chooseCanonicalSegs :
    ProducerInfo
    -> StagingGraph
    -> Dict Int Int ClassId
    -> Dict Int Int (List NodeId)
    -> Dict Int Int Segmentation
chooseCanonicalSegs producerInfo sg _ classMembers =
    Dict.foldl compare
        (\classId nodeIds acc ->
            let
                canonical =
                    chooseForClass producerInfo sg nodeIds
            in
            Dict.insert identity classId canonical acc
        )
        Dict.empty
        classMembers


chooseForClass :
    ProducerInfo
    -> StagingGraph
    -> List NodeId
    -> Segmentation
chooseForClass producerInfo sg nodeIds =
    let
        -- Collect all segmentations for nodes in this class
        segmentations =
            List.filterMap (stagingForNode producerInfo sg) nodeIds

        -- Check if any node is a kernel (kernels have fixed ABI)
        maybeKernelSeg =
            List.filterMap (kernelSegForNode producerInfo sg) nodeIds
                |> List.head
    in
    case maybeKernelSeg of
        Just kernelSeg ->
            -- Kernel in class - use kernel's segmentation
            kernelSeg

        Nothing ->
            -- No kernel - use majority voting
            if List.isEmpty segmentations then
                []

            else
                majorityVote segmentations


{-| Get the natural segmentation for a node.
-}
stagingForNode : ProducerInfo -> StagingGraph -> NodeId -> Maybe Segmentation
stagingForNode producerInfo sg nid =
    case Dict.get identity nid sg.nodeById of
        Just (NodeProducer pid) ->
            Dict.get identity (producerIdToKey pid) producerInfo.naturalSeg

        Just (NodeSlot _) ->
            -- Slots don't contribute segmentations
            Nothing

        Nothing ->
            Nothing


{-| Get kernel segmentation for a node if it's a kernel.
-}
kernelSegForNode : ProducerInfo -> StagingGraph -> NodeId -> Maybe Segmentation
kernelSegForNode producerInfo sg nid =
    case Dict.get identity nid sg.nodeById of
        Just (NodeProducer (ProducerKernel name)) ->
            let
                key =
                    producerIdToKey (ProducerKernel name)
            in
            Dict.get identity key producerInfo.naturalSeg

        _ ->
            Nothing


{-| Choose segmentation by majority voting.
Ties are broken by preferring fewer stages (more flat).
-}
majorityVote : List Segmentation -> Segmentation
majorityVote segmentations =
    let
        -- Count occurrences of each segmentation
        counts =
            List.foldl
                (\seg acc ->
                    let
                        key =
                            segToKey seg

                        current =
                            Dict.get identity key acc |> Maybe.withDefault ( seg, 0 )
                    in
                    Dict.insert identity key ( seg, Tuple.second current + 1 ) acc
                )
                Dict.empty
                segmentations

        -- Find max count
        maxCount =
            Dict.foldl compare
                (\_ ( _, count ) acc -> max count acc)
                0
                counts

        -- All segmentations with max count
        bestSegs =
            Dict.foldl compare
                (\_ ( seg, count ) acc ->
                    if count == maxCount then
                        seg :: acc

                    else
                        acc
                )
                []
                counts

        -- Among ties, prefer fewer stages (more flat)
        sorted =
            List.sortBy List.length bestSegs
    in
    case sorted of
        first :: _ ->
            first

        [] ->
            -- Fallback (shouldn't happen)
            []


{-| Convert segmentation to a string key for counting.
-}
segToKey : Segmentation -> String
segToKey seg =
    List.map String.fromInt seg |> String.join ","



-- ============================================================================
-- MAP PRODUCERS AND SLOTS TO CLASSES
-- ============================================================================


{-| Build maps from ProducerId/SlotId to ClassId.
-}
mapProducersAndSlotsToClasses :
    StagingGraph
    -> Dict Int Int ClassId
    -> ( Dict String String ClassId, Dict String String ClassId )
mapProducersAndSlotsToClasses sg nodeToClass =
    Dict.foldl compare
        (\_ nid ( prodMap, slotMap ) ->
            case Dict.get identity nid nodeToClass of
                Nothing ->
                    ( prodMap, slotMap )

                Just classId ->
                    case Dict.get identity nid sg.nodeById of
                        Just (NodeProducer pid) ->
                            let
                                key =
                                    producerIdToKey pid
                            in
                            ( Dict.insert identity key classId prodMap, slotMap )

                        Just (NodeSlot sid) ->
                            let
                                key =
                                    slotIdToKey sid
                            in
                            ( prodMap, Dict.insert identity key classId slotMap )

                        Nothing ->
                            ( prodMap, slotMap )
        )
        ( Dict.empty, Dict.empty )
        sg.nodeIndex
