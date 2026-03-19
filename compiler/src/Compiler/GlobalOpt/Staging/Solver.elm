module Compiler.GlobalOpt.Staging.Solver exposing (solveStagingGraph)

{-| Solves the staging graph to produce a StagingSolution.

This module:

1.  Builds equivalence classes from the union-find structure
2.  Chooses canonical segmentation for each class (majority voting)
3.  Maps producers and slots to their classes


# API

@docs solveStagingGraph

-}

import Array exposing (Array)
import Compiler.GlobalOpt.Staging.Types exposing (ClassId, Node(..), NodeId, ProducerId(..), ProducerInfo, Segmentation, StagingGraph, StagingSolution, Uf)
import Compiler.GlobalOpt.Staging.UnionFind exposing (producerIdToKey, slotIdToKey, ufFind)
import Dict exposing (Dict)
import Set exposing (Set)



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

        -- 4) Identify dynamic slots: slots in classes with no producer
        -- segmentation information (the solver has no basis for choosing
        -- a canonical staging). These must use generic apply at runtime.
        dynamicSlots =
            identifyDynamicSlots producerInfo sg classMembers slotClass
    in
    { classSeg = classSeg
    , producerClass = producerClass
    , slotClass = slotClass
    , dynamicSlots = dynamicSlots
    }



-- ============================================================================
-- BUILD CLASSES
-- ============================================================================


{-| Build equivalence classes from the union-find structure.
Returns (nodeToClass, classMembers).
-}
type alias BuildState =
    { nextClass : Int
    , nodeToClass : Dict Int ClassId
    , classMembers : Dict Int (List NodeId)
    , uf : Uf
    }


buildClasses :
    StagingGraph
    -> ( Dict Int ClassId, Dict Int (List NodeId) )
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
                    Dict.get rootId state.nodeToClass

                ( classId, nextClass2, nodeToClass2 ) =
                    case maybeClassId of
                        Just cid ->
                            ( cid, state.nextClass, state.nodeToClass )

                        Nothing ->
                            -- Assign new class to root
                            ( state.nextClass
                            , state.nextClass + 1
                            , Dict.insert rootId state.nextClass state.nodeToClass
                            )

                -- Also assign this node to the class
                nodeToClass3 =
                    if nid /= rootId then
                        Dict.insert nid classId nodeToClass2

                    else
                        nodeToClass2

                -- Add node to class members
                classMembers2 =
                    Dict.update
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
            Dict.foldl
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
    -> Dict Int ClassId
    -> Dict Int (List NodeId)
    -> Array (Maybe Segmentation)
chooseCanonicalSegs producerInfo sg _ classMembers =
    let
        maxClassId =
            Dict.foldl (\classId _ acc -> max classId acc) -1 classMembers

        base =
            Array.repeat (maxClassId + 1) Nothing
    in
    Dict.foldl
        (\classId nodeIds acc ->
            let
                canonical =
                    chooseForClass producerInfo sg nodeIds
            in
            Array.set classId (Just canonical) acc
        )
        base
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
    case Array.get nid sg.nodeById of
        Just (NodeProducer pid) ->
            Dict.get (producerIdToKey pid) producerInfo.naturalSeg

        Just (NodeSlot _) ->
            -- Slots don't contribute segmentations
            Nothing

        Nothing ->
            Nothing


{-| Get kernel segmentation for a node if it's a kernel.
-}
kernelSegForNode : ProducerInfo -> StagingGraph -> NodeId -> Maybe Segmentation
kernelSegForNode producerInfo sg nid =
    case Array.get nid sg.nodeById of
        Just (NodeProducer (ProducerKernel name)) ->
            let
                key =
                    producerIdToKey (ProducerKernel name)
            in
            Dict.get key producerInfo.naturalSeg

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
                            Dict.get key acc |> Maybe.withDefault ( seg, 0 )
                    in
                    Dict.insert key ( seg, Tuple.second current + 1 ) acc
                )
                Dict.empty
                segmentations

        -- Find max count
        maxCount =
            Dict.foldl
                (\_ ( _, count ) acc -> max count acc)
                0
                counts

        -- All segmentations with max count
        bestSegs =
            Dict.foldl
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
    -> Dict Int ClassId
    -> ( Dict String ClassId, Dict String ClassId )
mapProducersAndSlotsToClasses sg nodeToClass =
    Dict.foldl
        (\_ nid ( prodMap, slotMap ) ->
            case Dict.get nid nodeToClass of
                Nothing ->
                    ( prodMap, slotMap )

                Just classId ->
                    case Array.get nid sg.nodeById of
                        Just (NodeProducer pid) ->
                            let
                                key =
                                    producerIdToKey pid
                            in
                            ( Dict.insert key classId prodMap, slotMap )

                        Just (NodeSlot sid) ->
                            let
                                key =
                                    slotIdToKey sid
                            in
                            ( prodMap, Dict.insert key classId slotMap )

                        Nothing ->
                            ( prodMap, slotMap )
        )
        ( Dict.empty, Dict.empty )
        sg.nodeIndex



-- ============================================================================
-- DYNAMIC SLOTS
-- ============================================================================


{-| Identify slots that must use generic apply at runtime.

A slot is dynamic if its equivalence class has no producer nodes with
segmentation information — the solver had no basis for choosing a canonical
staging. Currently this is conservative: classes where majority voting
succeeded are not marked dynamic even if producers disagreed, because the
rewriter will eta-wrap non-conforming producers to match.

This can be extended later to also mark slots whose classes contain producers
with fundamentally incompatible call models (e.g. mixed kernel + user closure).
-}
identifyDynamicSlots :
    ProducerInfo
    -> StagingGraph
    -> Dict Int (List NodeId)
    -> Dict String ClassId
    -> Set String
identifyDynamicSlots producerInfo sg classMembers slotClass =
    let
        -- Find classes with no producer segmentations
        classesWithNoProducers : Set Int
        classesWithNoProducers =
            Dict.foldl
                (\classId nodeIds acc ->
                    let
                        hasProducerSeg =
                            List.any
                                (\nid -> stagingForNode producerInfo sg nid /= Nothing)
                                nodeIds
                    in
                    if hasProducerSeg then
                        acc

                    else
                        Set.insert classId acc
                )
                Set.empty
                classMembers
    in
    -- Mark all slots in those classes as dynamic
    Dict.foldl
        (\slotKey classId acc ->
            if Set.member classId classesWithNoProducers then
                Set.insert slotKey acc

            else
                acc
        )
        Set.empty
        slotClass
