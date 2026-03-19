module Compiler.GlobalOpt.Staging.Types exposing
    ( ProducerId(..), SlotId(..), NodeId, ClassId
    , Node(..), StagingGraph, Uf, StagingSolution
    , ProducerInfo, Segmentation
    , emptyStagingGraph, emptyProducerInfo
    )

{-| Core data types for the global staging algorithm.

This module defines:

  - `ProducerId` - Identifies function producers (closures, tail-funcs, kernels)
  - `SlotId` - Identifies slots that can hold function values
  - `Node` - Union-find graph node (either producer or slot)
  - `StagingGraph` - Union-find graph for computing equivalence classes
  - `StagingSolution` - Output mapping classes to canonical segmentations


# IDs

@docs ProducerId, SlotId, NodeId, ClassId


# Graph Types

@docs Node, StagingGraph, Uf, StagingSolution


# Producer Info

@docs ProducerInfo, Segmentation


# Constructors

@docs emptyStagingGraph, emptyProducerInfo

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Dict exposing (Dict)
import Set exposing (Set)


{-| Segmentation is already defined in Monomorphized.elm as List Int.
We re-export it here for convenience.
-}
type alias Segmentation =
    List Int



-- ============================================================================
-- PRODUCER AND SLOT IDS
-- ============================================================================


{-| Function producers: closures, tail-funcs, externs/kernels.
-}
type ProducerId
    = ProducerClosure Mono.LambdaId
    | ProducerTailFunc Int
    | ProducerKernel String


{-| Slots: semantic places that can hold a function value.
-}
type SlotId
    = SlotParam Int Int
    | SlotRecord String String
    | SlotTuple String Int
    | SlotList String Int
    | SlotCapture Mono.LambdaId Int
    | SlotIfResult Int
    | SlotCaseResult Int



-- ============================================================================
-- UNION-FIND GRAPH
-- ============================================================================


{-| Node identifier in the union-find graph.
-}
type alias NodeId =
    Int


{-| Equivalence class identifier.
-}
type alias ClassId =
    Int


{-| A node in the staging graph - either a producer or a slot.
-}
type Node
    = NodeProducer ProducerId
    | NodeSlot SlotId


{-| Union-find data structure for tracking equivalence classes.
-}
type alias Uf =
    { parent : Array Int
    }


{-| The staging graph containing nodes and union-find structure.
-}
type alias StagingGraph =
    { nextNodeId : NodeId
    , nodeIndex : Dict String NodeId
    , nodeById : Array Node
    , uf : Uf
    }


{-| An empty union-find structure.
-}
emptyUf : Uf
emptyUf =
    { parent = Array.empty
    }


{-| An empty staging graph.
-}
emptyStagingGraph : StagingGraph
emptyStagingGraph =
    { nextNodeId = 0
    , nodeIndex = Dict.empty
    , nodeById = Array.empty
    , uf = emptyUf
    }



-- ============================================================================
-- PRODUCER INFO
-- ============================================================================


{-| Information about producers gathered during the first pass.
Keys are producer ID strings (from producerIdToKey).
-}
type alias ProducerInfo =
    { naturalSeg : Dict String Segmentation
    , totalArity : Dict String Int
    }


{-| An empty producer info collection.
-}
emptyProducerInfo : ProducerInfo
emptyProducerInfo =
    { naturalSeg = Dict.empty
    , totalArity = Dict.empty
    }



-- ============================================================================
-- STAGING SOLUTION
-- ============================================================================


{-| The solution produced by the staging algorithm.

  - `classSeg` maps each equivalence class to its canonical segmentation
  - `producerClass` maps each producer to its equivalence class
  - `slotClass` maps each slot to its equivalence class
  - `dynamicSlots` contains slot keys that must use generic apply at runtime
    (the solver could not assign a reliable segmentation for their class)

-}
type alias StagingSolution =
    { classSeg : Array (Maybe Segmentation)
    , producerClass : Dict String ClassId
    , slotClass : Dict String ClassId
    , dynamicSlots : Set String
    }
