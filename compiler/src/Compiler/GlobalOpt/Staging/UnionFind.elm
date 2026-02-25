module Compiler.GlobalOpt.Staging.UnionFind exposing
    ( ufFind
    , ufUnion
    , ensureNode
    , unionNodes
    , nodeToKey
    , producerIdToKey
    , slotIdToKey
    )

{-| Union-find operations for the staging graph.

This module provides:

  - `ufFind` - Find the root of a node with path compression
  - `ufUnion` - Union two nodes into the same equivalence class
  - `ensureNode` - Add a node to the graph if not present
  - `unionNodes` - Ensure two nodes exist and union them


# Core Operations

@docs ufFind, ufUnion, ensureNode, unionNodes


# Key Generation

@docs nodeToKey, producerIdToKey, slotIdToKey

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.GlobalOpt.Staging.Types as Types exposing (..)
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO



-- ============================================================================
-- NODE KEY GENERATION
-- ============================================================================


{-| Convert a Node to a unique string key for indexing.
-}
nodeToKey : Node -> String
nodeToKey node =
    case node of
        NodeProducer pid ->
            "P:" ++ producerIdToKey pid

        NodeSlot sid ->
            "S:" ++ slotIdToKey sid


{-| Convert a ProducerId to a unique string key.
-}
producerIdToKey : ProducerId -> String
producerIdToKey pid =
    case pid of
        ProducerClosure lambdaId ->
            "C:" ++ lambdaIdToKey lambdaId

        ProducerTailFunc nodeId ->
            "T:" ++ String.fromInt nodeId

        ProducerKernel name ->
            "K:" ++ name


{-| Convert a SlotId to a unique string key.
-}
slotIdToKey : SlotId -> String
slotIdToKey sid =
    case sid of
        SlotVar name bindingId ->
            "V:" ++ name ++ ":" ++ String.fromInt bindingId

        SlotParam funcId paramIndex ->
            "P:" ++ String.fromInt funcId ++ ":" ++ String.fromInt paramIndex

        SlotRecord recordKey fieldName ->
            "R:" ++ recordKey ++ ":" ++ fieldName

        SlotTuple tupleKey elemIndex ->
            "Tu:" ++ tupleKey ++ ":" ++ String.fromInt elemIndex

        SlotCtor ctorName argIndex ->
            "Ct:" ++ ctorName ++ ":" ++ String.fromInt argIndex

        SlotList listKey elemIndex ->
            "L:" ++ listKey ++ ":" ++ String.fromInt elemIndex

        SlotCapture closureId captureIndex ->
            "Ca:" ++ lambdaIdToKey closureId ++ ":" ++ String.fromInt captureIndex

        SlotIfResult exprId ->
            "If:" ++ String.fromInt exprId

        SlotCaseResult exprId ->
            "Case:" ++ String.fromInt exprId


lambdaIdToKey : Mono.LambdaId -> String
lambdaIdToKey lambdaId =
    case lambdaId of
        Mono.AnonymousLambda (IO.Canonical ( author, pkg ) modName) idx ->
            author ++ "/" ++ pkg ++ "/" ++ modName ++ ":" ++ String.fromInt idx



-- ============================================================================
-- UNION-FIND OPERATIONS
-- ============================================================================


{-| Find the root of a node with path compression.
Returns the root NodeId and updated Uf with compressed paths.
-}
ufFind : NodeId -> Uf -> ( NodeId, Uf )
ufFind node uf =
    case Dict.get identity node uf.parent of
        Nothing ->
            -- Node is its own root
            ( node, uf )

        Just parent ->
            if parent == node then
                ( node, uf )

            else
                let
                    ( root, uf1 ) =
                        ufFind parent uf

                    -- Path compression
                    uf2 =
                        if root /= parent then
                            { uf1 | parent = Dict.insert identity node root uf1.parent }

                        else
                            uf1
                in
                ( root, uf2 )


{-| Union two nodes into the same equivalence class.
-}
ufUnion : NodeId -> NodeId -> Uf -> Uf
ufUnion a b uf0 =
    let
        ( rootA, uf1 ) =
            ufFind a uf0

        ( rootB, uf2 ) =
            ufFind b uf1
    in
    if rootA == rootB then
        uf2

    else
        -- Make rootA the parent of rootB (arbitrary choice, could use rank)
        { uf2 | parent = Dict.insert identity rootB rootA uf2.parent }


{-| Ensure a node exists in the staging graph.
Returns the NodeId and updated graph.
-}
ensureNode : Node -> StagingGraph -> ( NodeId, StagingGraph )
ensureNode node sg0 =
    let
        key =
            nodeToKey node
    in
    case Dict.get identity key sg0.nodeIndex of
        Just nid ->
            ( nid, sg0 )

        Nothing ->
            let
                nid =
                    sg0.nextNodeId

                sg1 =
                    { sg0
                        | nextNodeId = nid + 1
                        , nodeIndex = Dict.insert identity key nid sg0.nodeIndex
                        , nodeById = Dict.insert identity nid node sg0.nodeById
                    }
            in
            ( nid, sg1 )


{-| Ensure two nodes exist in the graph and union them.
-}
unionNodes : Node -> Node -> StagingGraph -> StagingGraph
unionNodes a b sg0 =
    let
        ( idA, sg1 ) =
            ensureNode a sg0

        ( idB, sg2 ) =
            ensureNode b sg1

        uf3 =
            ufUnion idA idB sg2.uf
    in
    { sg2 | uf = uf3 }
