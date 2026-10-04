module Compiler.GlobalOpt.Staging.Types exposing
    ( ProducerId(..), SlotId(..), NodeId, ClassId
    , Node(..), StagingGraph, Uf, StagingSolution
    , ProducerInfo, Segmentation
    , emptyStagingGraph, emptyProducerInfo
    )

{-| Staging decides how each function value takes its arguments, and this module
holds the vocabulary that decision is worked out in.

A function value can take its arguments in groups, called stages, and the list
of group sizes is its segmentation. A function value that is passed around must
agree on a segmentation with everywhere it can be called from, so the analysis
groups together everything that can hold the same function value and picks one
segmentation for each group.

Two kinds of thing are grouped. A producer is a place where a function value is
created: a closure, a tail-recursive function, or a kernel function. A slot is a
place that can hold a function value: a parameter, a field of a record, an
element of a tuple or list, a closure capture, or the result of an `if` or
`case`. Producers and slots are the nodes of a graph, and nodes that must agree
are joined into one equivalence class with a union-find structure, which is a
forest in which two nodes are in the same class when they have the same root.

The maps in `ProducerInfo` and `StagingSolution` are keyed by strings, not by
the id values themselves. The strings are made by
`Compiler.GlobalOpt.Staging.UnionFind.producerIdToKey` and `slotIdToKey`.


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


{-| How a function's arguments are grouped into stages: the number each stage
takes, outermost first.

This is a separate name for `List Int` with the same meaning as
`Compiler.AST.Monomorphized.Segmentation`, not a re-export of it. Either is
accepted where the other is expected, and the compiler checks nothing that the
name suggests.

-}
type alias Segmentation =
    List Int



-- ============================================================================
-- PRODUCER AND SLOT IDS
-- ============================================================================


{-| A place where a function value is created.

`ProducerClosure` is a closure, identified by its lambda.

`ProducerTailFunc` is a tail-recursive function, identified by the index of its
node in the program graph.

`ProducerKernel` is a kernel function, identified by a name string. Nothing here
fixes the form of that string, and two producers built from different strings
are different producers even when they name the same kernel.

-}
type ProducerId
    = ProducerClosure Mono.LambdaId
    | ProducerTailFunc Int
    | ProducerKernel String


{-| A place that can hold a function value.

`SlotParam` is a parameter, given by the index of its function's node in the
program graph and the parameter's position.

`SlotRecord` is a field, given by a string key for the record and the field
name. `SlotTuple` and `SlotList` are elements, given by a string key for the
container and the element's position. Because the key names a kind of container
rather than one expression, every container that produces the same key shares
the slot.

`SlotCapture` is a value captured by a closure, given by the closure's lambda
and the capture's position.

`SlotIfResult` and `SlotCaseResult` are the result of one `if` or `case`
expression, given by a number assigned to that expression.

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


{-| The index of a node in a `StagingGraph`, counting from zero in the order
nodes are added.

This is a name for `Int`, not a new type, so any `Int` is accepted, including a
`ClassId`.

-}
type alias NodeId =
    Int


{-| The number of an equivalence class in a `StagingSolution`.

This is a name for `Int`, not a new type, so any `Int` is accepted, including a
`NodeId`.

-}
type alias ClassId =
    Int


{-| A node of the staging graph: a producer or a slot.
-}
type Node
    = NodeProducer ProducerId
    | NodeSlot SlotId


{-| A union-find structure over node ids, recording which nodes are in the same
equivalence class.

`parent` holds, at each node id, the id of that node's parent. A node that is
its own parent is the root of its class.

-}
type alias Uf =
    { parent : Array Int
    }


{-| The set of producers and slots found so far, with the classes they have
been joined into.

`nodeIndex` maps a key string for each node to its id, so that a node is added
only once. `nodeById` holds the node at each id, and `nextNodeId` is the id the
next node added will get.

-}
type alias StagingGraph =
    { nextNodeId : NodeId
    , nodeIndex : Dict String NodeId
    , nodeById : Array Node
    , uf : Uf
    }


{-| A union-find structure with no nodes.
-}
emptyUf : Uf
emptyUf =
    { parent = Array.empty
    }


{-| A staging graph with no nodes.
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


{-| What is known about each producer by its own definition.

`naturalSeg` holds, for each producer key, the segmentation that producer has
before any class forces a choice on it. A producer with no entry contributes no
segmentation.

-}
type alias ProducerInfo =
    { naturalSeg : Dict String Segmentation
    }


{-| Producer information with no producers in it.
-}
emptyProducerInfo : ProducerInfo
emptyProducerInfo =
    { naturalSeg = Dict.empty
    }



-- ============================================================================
-- STAGING SOLUTION
-- ============================================================================


{-| The result of staging: the class each producer and slot belongs to, and the
segmentation chosen for each class.

`classSeg` is indexed by `ClassId`. A class with no segmentation to go on is
not recorded as `Nothing` here; its slots are listed in `dynamicSlots`.
`producerClass` and `slotClass` are keyed by producer and slot key strings.
`dynamicSlots` holds the keys of slots whose calls are to use generic apply,
because no segmentation could be relied on for their class.

-}
type alias StagingSolution =
    { classSeg : Array (Maybe Segmentation)
    , producerClass : Dict String ClassId
    , slotClass : Dict String ClassId
    , dynamicSlots : Set String
    }
