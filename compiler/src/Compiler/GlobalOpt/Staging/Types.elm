module Compiler.GlobalOpt.Staging.Types exposing
    ( ProducerId(..), SlotId(..), NodeId, ClassId
    , Node(..), StagingGraph, Uf, StagingSolution
    , ProducerInfo, Segmentation
    , emptyStagingGraph, emptyUf, emptyProducerInfo
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

@docs emptyStagingGraph, emptyUf, emptyProducerInfo

-}

import Compiler.AST.Monomorphized as Mono
import Data.Map as Dict exposing (Dict)


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
    = SlotVar String Int
    | SlotParam Int Int
    | SlotRecord String String
    | SlotTuple String Int
    | SlotCtor String Int
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
    { parent : Dict Int Int NodeId
    }


{-| The staging graph containing nodes and union-find structure.
-}
type alias StagingGraph =
    { nextNodeId : NodeId
    , nodeIndex : Dict String String NodeId
    , nodeById : Dict Int Int Node
    , uf : Uf
    }


{-| An empty union-find structure.
-}
emptyUf : Uf
emptyUf =
    { parent = Dict.empty
    }


{-| An empty staging graph.
-}
emptyStagingGraph : StagingGraph
emptyStagingGraph =
    { nextNodeId = 0
    , nodeIndex = Dict.empty
    , nodeById = Dict.empty
    , uf = emptyUf
    }



-- ============================================================================
-- PRODUCER INFO
-- ============================================================================


{-| Information about producers gathered during the first pass.
Keys are producer ID strings (from producerIdToKey).
-}
type alias ProducerInfo =
    { naturalSeg : Dict String String Segmentation
    , totalArity : Dict String String Int
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

-}
type alias StagingSolution =
    { classSeg : Dict Int Int Segmentation
    , producerClass : Dict String String ClassId
    , slotClass : Dict String String ClassId
    }
