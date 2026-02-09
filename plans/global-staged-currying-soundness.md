# Plan: Global Staged Currying Soundness

## Overview

This plan implements a complete algorithm for determining correct staged-currying calling conventions for **all** function-carrying constructs in the monomorphized IR, not just direct `if`/`case` returns.

**Current State:**
- `normalizeCaseIfAbi` only handles case/if expressions that directly return functions
- Functions flowing through records, tuples, constructors, lists, and captures are not normalized
- Call sites may encounter functions with incompatible stagings from different code paths

**Target State:**
- Every function value in the IR has a globally consistent staging
- All producers flowing into the same "ABI class" share a single canonical staging
- `annotateCallStaging` becomes a pure lookup—no guesswork at call sites

---

## Updated Pipeline

### Main Driver: `MonoGlobalOptimize.globalOptimize`

**File:** `compiler/src/Compiler/GlobalOpt/MonoGlobalOptimize.elm`

```elm
module Compiler.GlobalOpt.MonoGlobalOptimize exposing (globalOptimize)

import Compiler.Generate.Monomorphized as Mono
import Compiler.GlobalOpt.Staging as Staging
import Compiler.GlobalOpt.CallInfo as CallInfo  -- hypothetical helper

{-| Global optimization driver.

    New structure:

    1. Analyze & solve staging (build joinpoints, choose canonical segs, rewrite graph)
    2. Validate closure staging invariants
    3. Annotate call sites with CallInfo using solved staging
-}
globalOptimize :
    TypeEnv
    -> Mono.MonoGraph
    -> Mono.MonoGraph
globalOptimize typeEnv graph0 =
    let
        -- Phase 1+2: staging analysis + graph rewrite (wrappers + types)
        ( stagingSolution, graph1 ) =
            Staging.analyzeAndSolveStaging typeEnv graph0

        -- Phase 3: validate closure staging invariants (GOPT_001, GOPT_003)
        graph2 =
            Staging.validateClosureStaging graph1

        -- Phase 4: annotate call staging metadata using stagingSolution
        graph3 =
            Staging.annotateCallStaging stagingSolution graph2
    in
    graph3
```

This replaces the old sequence `canonicalizeClosureStaging` / `normalizeCaseIfAbi` / `validateClosureStaging` / `annotateReturnedClosureArity`.

---

## New Module: `Compiler.GlobalOpt.Staging`

**File:** `compiler/src/Compiler/GlobalOpt/Staging.elm`

### Module Header and Imports

```elm
module Compiler.GlobalOpt.Staging
    exposing
        ( StagingSolution
        , analyzeAndSolveStaging
        , validateClosureStaging
        , annotateCallStaging
        )

import Dict exposing (Dict)
import Set exposing (Set)

import Compiler.Generate.Monomorphized as Mono
import Compiler.GlobalOpt.MonoReturnArity as MonoReturnArity
import Compiler.GlobalOpt.Closure as Closure  -- for flattenTypeToArity etc.
import Compiler.GlobalOpt.AbiWrapper as AbiWrapper  -- for buildAbiWrapperGO-style helpers
import Utils.Crash as Crash
```

---

## Core Data Structures

### Producer and Slot IDs

```elm
-- A Segmentation is already defined in Monomorphized.elm:
-- type alias Segmentation = List Int
-- We refer to it as Mono.Segmentation.

-- Function producers: closures, tail-funcs, externs
type ProducerId
    = ProducerClosure Int   -- closure node id or lambda id
    | ProducerTailFunc Int  -- tail func id
    | ProducerKernel String -- unique kernel identifier (e.g. "Basics.add")


-- Slots: semantic places that can hold a function
type SlotId
    = SlotVar String Int        -- variable name + binding id
    | SlotParam Int Int         -- func id + param index
    | SlotRecord String String  -- record type key + field name
    | SlotTuple String Int      -- tuple type key + element index
    | SlotCtor String Int       -- constructor name + arg index
    | SlotList String Int       -- list context key + element index
    | SlotCapture Int Int       -- closure id + capture index
```

### Union-Find Graph

```elm
-- Internal graph node for union-find
type alias NodeId = Int

type Node
    = NodeProducer ProducerId
    | NodeSlot SlotId

type alias ClassId = Int

-- Staging graph with union-find
type alias StagingGraph =
    { nextNodeId : NodeId
    , nodeIndex : Dict Node NodeId
    , uf : Uf
    }

-- Union-find structure
type alias Uf =
    { parent : Dict NodeId NodeId
    , nextClassId : Int
    , nodeToClass : Dict NodeId ClassId
    }

emptyUf : Uf
emptyUf =
    { parent = Dict.empty
    , nextClassId = 0
    , nodeToClass = Dict.empty
    }

emptyStagingGraph : StagingGraph
emptyStagingGraph =
    { nextNodeId = 0
    , nodeIndex = Dict.empty
    , uf = emptyUf
    }
```

### Union-Find Operations

```elm
ufFind : NodeId -> Uf -> ( NodeId, Uf )
ufFind node uf =
    case Dict.get node uf.parent of
        Nothing ->
            ( node, uf )

        Just parent ->
            let
                ( root, uf1 ) =
                    ufFind parent uf

                -- Path compression
                uf2 =
                    { uf1 | parent = Dict.insert node root uf1.parent }
            in
            ( root, uf2 )


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
        { uf2 | parent = Dict.insert rootB rootA uf2.parent }


ensureNode : Node -> StagingGraph -> ( NodeId, StagingGraph )
ensureNode node sg0 =
    case Dict.get node sg0.nodeIndex of
        Just nid ->
            ( nid, sg0 )

        Nothing ->
            let
                nid = sg0.nextNodeId
                sg1 =
                    { sg0
                        | nextNodeId = nid + 1
                        , nodeIndex = Dict.insert node nid sg0.nodeIndex
                    }
            in
            ( nid, sg1 )


unionNodes : Node -> Node -> StagingGraph -> StagingGraph
unionNodes a b sg0 =
    let
        ( idA, sg1 ) = ensureNode a sg0
        ( idB, sg2 ) = ensureNode b sg1
        uf3 = ufUnion idA idB sg2.uf
    in
    { sg2 | uf = uf3 }
```

### Staging Solution (Output)

```elm
-- Global staging solution, exposed to other passes
type alias StagingSolution =
    { classSeg : Dict ClassId Mono.Segmentation
    , producerClass : Dict ProducerId ClassId
    , slotClass : Dict SlotId ClassId
    }
```

---

## Module Structure

```
Compiler/GlobalOpt/
├── MonoGlobalOptimize.elm      -- Main driver (updated)
├── Staging.elm                 -- NEW: Main staging algorithm
├── Staging/
│   ├── Types.elm               -- ProducerId, SlotId, StagingGraph, etc.
│   ├── UnionFind.elm           -- Union-find implementation
│   ├── ProducerInfo.elm        -- Natural staging computation
│   ├── GraphBuilder.elm        -- Constraint collection
│   ├── Solver.elm              -- Class assignment + canonical selection
│   └── Rewriter.elm            -- Wrapper synthesis + type adjustment
├── AbiWrapper.elm              -- Wrapper building helpers (extended)
├── CallInfo.elm                -- NEW: CallInfo construction helpers
├── MonoReturnArity.elm         -- Existing (may absorb some logic)
└── MonoInlineSimplify.elm      -- Existing (unchanged)
```

---

## Implementation Phases

### Phase 1+2 Top-Level: `analyzeAndSolveStaging`

**File:** `Compiler/GlobalOpt/Staging.elm`

```elm
analyzeAndSolveStaging :
    TypeEnv
    -> Mono.MonoGraph
    -> ( StagingSolution, Mono.MonoGraph )
analyzeAndSolveStaging typeEnv graph0 =
    let
        -- 1. Compute natural staging and producer ids from closures/kernels
        producerInfo =
            computeProducerInfo graph0

        -- 2. Build staging graph: producers + slots, with joinpoint edges
        sg =
            buildStagingGraph graph0 producerInfo

        -- 3. Solve: from uf into classes, choose canonical segmentation per class
        ( stagingSolution, canonicalizedGraph ) =
            solveStagingGraph typeEnv producerInfo sg graph0
    in
    ( stagingSolution, canonicalizedGraph )
```

---

### Phase 1: Compute Natural Staging Per Producer

**File:** `Compiler/GlobalOpt/Staging/ProducerInfo.elm`

```elm
type alias ProducerInfo =
    { naturalSeg : Dict ProducerId Mono.Segmentation
    , totalArity : Dict ProducerId Int
    }


computeProducerInfo : Mono.MonoGraph -> ProducerInfo
computeProducerInfo (Mono.MonoGraph mono) =
    let
        foldNode ( nodeId, node ) acc =
            case node of
                Mono.MonoDefine expr monoType ->
                    acc |> addProducersFromExpr expr

                Mono.MonoTailFunc params body monoType ->
                    let
                        pid = ProducerTailFunc nodeId
                        seg = detectNaturalSegFromExpr params body
                        arity = MonoReturnArity.countTotalArity monoType
                    in
                    { acc
                        | naturalSeg = Dict.insert pid seg acc.naturalSeg
                        , totalArity = Dict.insert pid arity acc.totalArity
                    }

                Mono.MonoExtern abiType ->
                    let
                        pid = ProducerKernel (kernelNameFromNodeId nodeId)
                        arity = MonoReturnArity.countTotalArity abiType
                        seg = [ arity ]  -- Kernels are always flat
                    in
                    { acc
                        | naturalSeg = Dict.insert pid seg acc.naturalSeg
                        , totalArity = Dict.insert pid arity acc.totalArity
                    }

                _ ->
                    acc
    in
    Dict.foldl foldNode
        { naturalSeg = Dict.empty, totalArity = Dict.empty }
        mono.nodes


detectNaturalSegFromExpr :
    List ( Mono.Name, Mono.MonoType )
    -> Mono.MonoExpr
    -> Mono.Segmentation
detectNaturalSegFromExpr params body =
    let
        thisStage = List.length params

        innerStages =
            case body of
                -- Note: Adapt pattern to your actual MonoExpr constructor
                -- Could be Mono.MonoClosure or Mono.MClosure depending on naming
                Mono.MClosure innerParams innerBody innerType ->
                    detectNaturalSegFromExpr innerParams innerBody

                _ ->
                    []
    in
    thisStage :: innerStages
```

**Note:** Adjust pattern matches to your real `MonoExpr`/closure representations. The codebase may use `MonoClosure` or `MClosure` depending on the module.

---

### Phase 2: Build Staging Graph (Constraint Collection)

**File:** `Compiler/GlobalOpt/Staging/GraphBuilder.elm`

#### Top-level traversal

```elm
buildStagingGraph :
    Mono.MonoGraph
    -> ProducerInfo
    -> StagingGraph
buildStagingGraph (Mono.MonoGraph mono) producerInfo =
    let
        foldNode ( nodeId, node ) sg0 =
            case node of
                Mono.MonoDefine expr monoType ->
                    buildStagingGraphExpr expr sg0

                Mono.MonoTailFunc params body monoType ->
                    -- params of function type are potential slots
                    let
                        sg1 =
                            List.indexedMap Tuple.pair params
                                |> List.foldl
                                    (\( index, ( name, ty ) ) sg ->
                                        if Mono.isFunctionType ty then
                                            let
                                                slot = SlotParam nodeId index
                                                nodeSlot = NodeSlot slot
                                            in
                                            Tuple.second (ensureNode nodeSlot sg)
                                        else
                                            sg
                                    )
                                    sg0
                    in
                    buildStagingGraphExpr body sg1

                _ ->
                    sg0
    in
    Dict.foldl foldNode emptyStagingGraph mono.nodes
```

#### Expression traversal with constraint generation

**Note:** The code below uses short-form constructor names (`MIf`, `MCase`, etc.) as in the user's sketch. Adapt to actual names in your codebase (`MonoIf`, `MonoCase`, etc.).

```elm
buildStagingGraphExpr : Mono.MonoExpr -> StagingGraph -> StagingGraph
buildStagingGraphExpr expr sg0 =
    case expr of
        Mono.MIf cond thenBranch elseBranch exprType ->
            let
                sg1 =
                    buildStagingGraphExpr cond sg0

                sg2 =
                    buildStagingGraphExpr thenBranch sg1

                sg3 =
                    buildStagingGraphExpr elseBranch sg2
            in
            if Mono.isFunctionType exprType then
                -- Direct function result joinpoint:
                -- result slot for this if
                let
                    resultSlot =
                        SlotVar ("<if-result>", expr.nodeId)  -- pseudo-id

                    nodeResult =
                        NodeSlot resultSlot

                    -- Connect branch producers with resultSlot
                    sg4 =
                        connectBranchProducer thenBranch nodeResult sg3

                    sg5 =
                        connectBranchProducer elseBranch nodeResult sg4
                in
                sg5

            else
                -- Aggregate / non-function: handle fields/ctors/tuples/lists here
                addAggregateJoinpoints expr sg3

        Mono.MCase scrutinee branches defaultExpr exprType ->
            let
                sg1 =
                    buildStagingGraphExpr scrutinee sg0

                sg2 =
                    List.foldl
                        (\branch sg -> buildStagingGraphExpr branch.body sg)
                        sg1
                        branches

                sg3 =
                    case defaultExpr of
                        Nothing ->
                            sg2

                        Just defExpr ->
                            buildStagingGraphExpr defExpr sg2
            in
            if Mono.isFunctionType exprType then
                let
                    resultSlot =
                        SlotVar ("<case-result>", expr.nodeId)

                    nodeResult =
                        NodeSlot resultSlot

                    sg4 =
                        List.foldl
                            (\branch sg ->
                                connectBranchProducer branch.body nodeResult sg
                            )
                            sg3
                            branches

                    sg5 =
                        case defaultExpr of
                            Nothing ->
                                sg4

                            Just defExpr ->
                                connectBranchProducer defExpr nodeResult sg4
                in
                sg5

            else
                addAggregateJoinpoints expr sg3

        -- Other expressions: recurse
        Mono.MRecord recordFields recordType ->
            List.foldl
                (\( fieldName, fieldExpr ) sg ->
                    buildStagingGraphExpr fieldExpr sg
                )
                sg0
                recordFields

        Mono.MTuple exprs tupleType ->
            List.foldl buildStagingGraphExpr sg0 exprs

        Mono.MCtor ctorId args ctorType ->
            List.foldl buildStagingGraphExpr sg0 args

        Mono.MList elems listType ->
            List.foldl buildStagingGraphExpr sg0 elems

        Mono.MLet name boundExpr bodyExpr exprType ->
            let
                sg1 =
                    buildStagingGraphExpr boundExpr sg0

                sg2 =
                    buildStagingGraphExpr bodyExpr sg1
            in
            sg2

        Mono.MCall callee args callType ->
            let
                sg1 =
                    buildStagingGraphExpr callee sg0

                sg2 =
                    List.foldl buildStagingGraphExpr sg1 args
            in
            sg2

        _ ->
            sg0
```

#### Helper: Connect branch producer to result slot

```elm
connectBranchProducer :
    Mono.MonoExpr
    -> Node
    -> StagingGraph
    -> StagingGraph
connectBranchProducer branchExpr nodeResult sg0 =
    if Mono.isFunctionType (Mono.typeOf branchExpr) then
        let
            producer =
                producerFromExpr branchExpr

            sg1 =
                unionNodes (NodeProducer producer) nodeResult sg0
        in
        sg1

    else
        sg0
```

#### Helper: Add aggregate joinpoints (records, tuples, ctors, lists)

```elm
addAggregateJoinpoints : Mono.MonoExpr -> StagingGraph -> StagingGraph
addAggregateJoinpoints expr sg0 =
    case expr of
        Mono.MRecord fields recordType ->
            List.foldl
                (\( fieldName, fieldExpr ) sg ->
                    if Mono.isFunctionType (Mono.typeOf fieldExpr) then
                        let
                            recordKey =
                                recordKeyFromType recordType

                            slot =
                                SlotRecord recordKey fieldName

                            nodeSlot =
                                NodeSlot slot

                            producer =
                                producerFromExpr fieldExpr
                        in
                        unionNodes (NodeProducer producer) nodeSlot sg

                    else
                        sg
                )
                sg0
                fields

        Mono.MTuple exprs tupleType ->
            let
                tupleKey =
                    tupleKeyFromType tupleType
            in
            List.indexedFoldl
                (\index e sg ->
                    if Mono.isFunctionType (Mono.typeOf e) then
                        let
                            slot =
                                SlotTuple tupleKey index

                            nodeSlot =
                                NodeSlot slot

                            producer =
                                producerFromExpr e
                        in
                        unionNodes (NodeProducer producer) nodeSlot sg

                    else
                        sg
                )
                sg0
                exprs

        Mono.MCtor ctorId args ctorType ->
            List.indexedFoldl
                (\index e sg ->
                    if Mono.isFunctionType (Mono.typeOf e) then
                        let
                            slot =
                                SlotCtor (ctorName ctorId) index

                            nodeSlot =
                                NodeSlot slot

                            producer =
                                producerFromExpr e
                        in
                        unionNodes (NodeProducer producer) nodeSlot sg

                    else
                        sg
                )
                sg0
                args

        Mono.MList elems listType ->
            let
                listCtxKey =
                    listContextKeyFromExpr expr
            in
            List.indexedFoldl
                (\index e sg ->
                    if Mono.isFunctionType (Mono.typeOf e) then
                        let
                            slot =
                                SlotList listCtxKey index

                            nodeSlot =
                                NodeSlot slot

                            producer =
                                producerFromExpr e
                        in
                        unionNodes (NodeProducer producer) nodeSlot sg

                    else
                        sg
                )
                sg0
                elems

        _ ->
            sg0


producerFromExpr : Mono.MonoExpr -> ProducerId
producerFromExpr expr =
    case expr of
        Mono.MClosure closureId _ _ ->
            ProducerClosure closureId

        Mono.MVarKernel home name ty ->
            ProducerKernel (home ++ "." ++ name)

        -- You may need more cases, depending on your IR.
        _ ->
            Crash.crash
                ("producerFromExpr: unsupported expression " ++ Debug.toString expr)
```

---

### Phase 3: Solve for Canonical Stagings

**File:** `Compiler/GlobalOpt/Staging/Solver.elm`

#### Top-level solver

```elm
solveStagingGraph :
    TypeEnv
    -> ProducerInfo
    -> StagingGraph
    -> Mono.MonoGraph
    -> ( StagingSolution, Mono.MonoGraph )
solveStagingGraph typeEnv producerInfo sg graph0 =
    let
        -- 1) Build mapping NodeId -> ClassId from uf.parents
        classResult =
            buildClasses sg

        ( nodeToClass, classMembers ) =
            classResult

        -- 2) For each class, choose canonical segmentation
        classSeg =
            chooseCanonicalSegs producerInfo sg nodeToClass classMembers

        -- 3) Build producerClass / slotClass maps
        ( producerClass, slotClass ) =
            mapProducersAndSlotsToClasses sg nodeToClass classSeg

        solution =
            { classSeg = classSeg
            , producerClass = producerClass
            , slotClass = slotClass
            }

        -- 4) Rewrite graph: insert wrappers and adjust types according to solution
        graph1 =
            applyStagingSolution typeEnv solution producerInfo graph0
    in
    ( solution, graph1 )
```

#### Build equivalence classes

```elm
buildClasses :
    StagingGraph
    -> ( Dict NodeId ClassId, Dict ClassId (List NodeId) )
buildClasses sg =
    let
        assignClass ( node, nid ) ( nextClass, nodeToClass, classMembers ) =
            let
                ( rootId, uf1 ) =
                    ufFind nid sg.uf

                maybeClassId =
                    Dict.get rootId nodeToClass

                ( classId, nextClass2, nodeToClass2 ) =
                    case maybeClassId of
                        Just cid ->
                            ( cid, nextClass, nodeToClass )

                        Nothing ->
                            ( nextClass
                            , nextClass + 1
                            , Dict.insert rootId nextClass nodeToClass
                            )
            in
            ( nextClass2
            , Dict.insert nid classId nodeToClass2
            , Dict.update classId
                (\maybeList ->
                    Just (nid :: Maybe.withDefault [] maybeList)
                )
                classMembers
            )

        (_, nodeToClass, classMembers) =
            Dict.foldl assignClass
                ( 0, Dict.empty, Dict.empty )
                sg.nodeIndex
    in
    ( nodeToClass, classMembers )
```

#### Choose canonical staging per class

```elm
chooseCanonicalSegs :
    ProducerInfo
    -> StagingGraph
    -> Dict NodeId ClassId
    -> Dict ClassId (List NodeId)
    -> Dict ClassId Mono.Segmentation
chooseCanonicalSegs producerInfo sg nodeToClass classMembers =
    let
        -- Helper: reverse lookup NodeId -> Node
        -- (You can maintain a second dict, or invert sg.nodeIndex)
        findNodeById : NodeId -> Dict Node NodeId -> Maybe Node
        findNodeById targetId index =
            Dict.foldl
                (\node nid acc ->
                    if nid == targetId then
                        Just node
                    else
                        acc
                )
                Nothing
                index

        stagingForNode nid =
            case findNodeById nid sg.nodeIndex of
                Just (NodeProducer pid) ->
                    Dict.get pid producerInfo.naturalSeg
                        |> Maybe.withDefault []  -- should not happen

                Just (NodeSlot _) ->
                    []  -- slots themselves don't add natural staging

                Nothing ->
                    []

        chooseForClass cid nodes =
            let
                segs =
                    List.filter (\s -> not (List.isEmpty s))
                        (List.map stagingForNode nodes)

                canonical =
                    if List.isEmpty segs then
                        []  -- no producers? degenerate
                    else
                        AbiWrapper.chooseCanonicalSegmentation segs
            in
            ( cid, canonical )
    in
    Dict.fromList
        (List.map
            (\( cid, nodes ) -> chooseForClass cid nodes)
            (Dict.toList classMembers)
        )


-- Reuse existing majority-voting logic
-- AbiWrapper.chooseCanonicalSegmentation : List Segmentation -> Segmentation
```

#### Map producers and slots to classes

```elm
mapProducersAndSlotsToClasses :
    StagingGraph
    -> Dict NodeId ClassId
    -> Dict ClassId Mono.Segmentation
    -> ( Dict ProducerId ClassId, Dict SlotId ClassId )
mapProducersAndSlotsToClasses sg nodeToClass classSeg =
    let
        foldNode ( node, nid ) ( prodMap, slotMap ) =
            let
                maybeClassId =
                    Dict.get nid nodeToClass
            in
            case ( node, maybeClassId ) of
                ( NodeProducer pid, Just cid ) ->
                    ( Dict.insert pid cid prodMap, slotMap )

                ( NodeSlot sid, Just cid ) ->
                    ( prodMap, Dict.insert sid cid slotMap )

                _ ->
                    ( prodMap, slotMap )
    in
    Dict.foldl foldNode
        ( Dict.empty, Dict.empty )
        sg.nodeIndex
```

---

### Phase 4: Apply Staging Solution (Rewrite Graph)

**File:** `Compiler/GlobalOpt/Staging/Rewriter.elm`

#### Top-level rewriter

```elm
applyStagingSolution :
    TypeEnv
    -> StagingSolution
    -> ProducerInfo
    -> Mono.MonoGraph
    -> Mono.MonoGraph
applyStagingSolution typeEnv solution producerInfo (Mono.MonoGraph mono0) =
    let
        -- Step 1: Wrap producers that need different staging
        nodes1 =
            Dict.map
                (\nodeId node -> rewriteNodeProducers solution producerInfo nodeId node)
                mono0.nodes

        mono1 =
            { mono0 | nodes = nodes1 }

        -- Step 2: Adjust types to match canonical staging (via flattenTypeToArity)
        nodes2 =
            Dict.map
                (\nodeId node -> adjustNodeTypesToStaging solution producerInfo nodeId node)
                mono1.nodes

        mono2 =
            { mono1 | nodes = nodes2 }
    in
    Mono.MonoGraph mono2
```

#### Rewrite node producers

```elm
rewriteNodeProducers :
    StagingSolution
    -> ProducerInfo
    -> Int
    -> Mono.MonoNode
    -> Mono.MonoNode
rewriteNodeProducers solution producerInfo nodeId node =
    case node of
        Mono.MonoTailFunc params body monoType ->
            let
                pid =
                    ProducerTailFunc nodeId

                maybeClassId =
                    Dict.get pid solution.producerClass
            in
            case maybeClassId of
                Nothing ->
                    node

                Just cid ->
                    let
                        sigmaC =
                            Dict.get cid solution.classSeg
                                |> Maybe.withDefault []

                        natSeg =
                            Dict.get pid producerInfo.naturalSeg
                                |> Maybe.withDefault []

                        newNode =
                            if natSeg == sigmaC then
                                node
                            else
                                AbiWrapper.wrapTailFuncToSegmentation
                                    pid
                                    natSeg
                                    sigmaC
                                    params
                                    body
                                    monoType
                    in
                    newNode

        Mono.MonoDefine expr monoType ->
            -- Walk expression, wrapping MonoClosure producers similarly.
            Mono.MonoDefine
                (rewriteExprProducers solution producerInfo expr)
                monoType

        _ ->
            node
```

#### Rewrite expression producers

```elm
rewriteExprProducers :
    StagingSolution
    -> ProducerInfo
    -> Mono.MonoExpr
    -> Mono.MonoExpr
rewriteExprProducers solution producerInfo expr =
    case expr of
        Mono.MClosure closureInfo body monoType ->
            let
                pid =
                    ProducerClosure closureInfo.id

                maybeClassId =
                    Dict.get pid solution.producerClass
            in
            case maybeClassId of
                Nothing ->
                    expr

                Just cid ->
                    let
                        sigmaC =
                            Dict.get cid solution.classSeg
                                |> Maybe.withDefault []

                        natSeg =
                            Dict.get pid producerInfo.naturalSeg
                                |> Maybe.withDefault []

                        newExpr =
                            if natSeg == sigmaC then
                                expr
                            else
                                AbiWrapper.wrapClosureToSegmentation
                                    pid
                                    natSeg
                                    sigmaC
                                    closureInfo
                                    body
                                    monoType
                    in
                    newExpr

        Mono.MIf cond thenBranch elseBranch ty ->
            Mono.MIf
                (rewriteExprProducers solution producerInfo cond)
                (rewriteExprProducers solution producerInfo thenBranch)
                (rewriteExprProducers solution producerInfo elseBranch)
                ty

        Mono.MCase scrut branches defaultExpr ty ->
            Mono.MCase
                scrut
                (List.map
                    (\branch ->
                        { branch | body = rewriteExprProducers solution producerInfo branch.body }
                    )
                    branches
                )
                (Maybe.map (rewriteExprProducers solution producerInfo) defaultExpr)
                ty

        Mono.MRecord fields ty ->
            Mono.MRecord
                (List.map
                    (\( name, e ) -> ( name, rewriteExprProducers solution producerInfo e ))
                    fields
                )
                ty

        Mono.MTuple exprs ty ->
            Mono.MTuple
                (List.map (rewriteExprProducers solution producerInfo) exprs)
                ty

        Mono.MCtor ctorId args ty ->
            Mono.MCtor
                ctorId
                (List.map (rewriteExprProducers solution producerInfo) args)
                ty

        Mono.MList elems ty ->
            Mono.MList
                (List.map (rewriteExprProducers solution producerInfo) elems)
                ty

        Mono.MLet name boundExpr bodyExpr ty ->
            Mono.MLet
                name
                (rewriteExprProducers solution producerInfo boundExpr)
                (rewriteExprProducers solution producerInfo bodyExpr)
                ty

        Mono.MCall callee args ty ->
            Mono.MCall
                (rewriteExprProducers solution producerInfo callee)
                (List.map (rewriteExprProducers solution producerInfo) args)
                ty

        _ ->
            expr
```

#### Adjust types to match staging

```elm
adjustNodeTypesToStaging :
    StagingSolution
    -> ProducerInfo
    -> Int
    -> Mono.MonoNode
    -> Mono.MonoNode
adjustNodeTypesToStaging solution producerInfo nodeId node =
    case node of
        Mono.MonoTailFunc params body monoType ->
            let
                pid =
                    ProducerTailFunc nodeId

                maybeClassId =
                    Dict.get pid solution.producerClass
            in
            case maybeClassId of
                Nothing ->
                    node

                Just cid ->
                    let
                        sigmaC =
                            Dict.get cid solution.classSeg
                                |> Maybe.withDefault []

                        totalArgs =
                            Dict.get pid producerInfo.totalArity
                                |> Maybe.withDefault (List.length params)

                        newType =
                            Closure.flattenTypeToArity totalArgs monoType
                            -- or a version that encodes sigmaC precisely if you still
                            -- differentiate multiple stages at Mono level.
                    in
                    Mono.MonoTailFunc params body newType

        Mono.MonoDefine expr monoType ->
            -- If expr is a closure, similar adjustment, else leave
            Mono.MonoDefine expr monoType

        _ ->
            node
```

---

### Phase 5: Validate Closure Staging

**File:** `Compiler/GlobalOpt/Staging.elm`

```elm
validateClosureStaging : Mono.MonoGraph -> Mono.MonoGraph
validateClosureStaging graph =
    -- Existing implementation:
    --   walk all closures/tail-funcs,
    --   check length(params) <= functionTypeArgCount,
    --   and that case/if result types align with branches for functions.
    -- If violation, Crash.crash with a GOPT_xxx invariant message.
    graph
```

Just ensure tests now also cover function-typed fields in aggregates if you add specific invariants there.

---

### Phase 6: Annotate Call Staging

**File:** `Compiler/GlobalOpt/Staging.elm` (or separate `CallAnnotation.elm`)

#### Top-level annotation

```elm
annotateCallStaging :
    StagingSolution
    -> Mono.MonoGraph
    -> Mono.MonoGraph
annotateCallStaging solution (Mono.MonoGraph mono0) =
    let
        annotateNode nodeId node =
            case node of
                Mono.MonoDefine expr ty ->
                    Mono.MonoDefine
                        (annotateExprCalls solution expr)
                        ty

                Mono.MonoTailFunc params body ty ->
                    Mono.MonoTailFunc
                        params
                        (annotateExprCalls solution body)
                        ty

                _ ->
                    node

        nodes1 =
            Dict.map annotateNode mono0.nodes

        mono1 =
            { mono0 | nodes = nodes1 }
    in
    Mono.MonoGraph mono1
```

#### Annotate expression calls

```elm
annotateExprCalls : StagingSolution -> Mono.MonoExpr -> Mono.MonoExpr
annotateExprCalls solution expr =
    case expr of
        Mono.MCall callee args callType ->
            let
                annotatedCallee =
                    annotateExprCalls solution callee

                annotatedArgs =
                    List.map (annotateExprCalls solution) args

                callInfo =
                    computeCallInfoForExpr solution annotatedCallee annotatedArgs callType
            in
            Mono.MCallWithInfo annotatedCallee annotatedArgs callType callInfo

        Mono.MIf cond thenBranch elseBranch ty ->
            Mono.MIf
                (annotateExprCalls solution cond)
                (annotateExprCalls solution thenBranch)
                (annotateExprCalls solution elseBranch)
                ty

        Mono.MCase scrutinee branches defaultExpr ty ->
            Mono.MCase
                scrutinee
                (List.map
                    (\branch ->
                        { branch | body = annotateExprCalls solution branch.body }
                    )
                    branches
                )
                (Maybe.map (annotateExprCalls solution) defaultExpr)
                ty

        Mono.MRecord fields ty ->
            Mono.MRecord
                (List.map
                    (\( name, e ) -> ( name, annotateExprCalls solution e ))
                    fields
                )
                ty

        Mono.MTuple exprs ty ->
            Mono.MTuple
                (List.map (annotateExprCalls solution) exprs)
                ty

        Mono.MCtor ctorId args ty ->
            Mono.MCtor
                ctorId
                (List.map (annotateExprCalls solution) args)
                ty

        Mono.MList elems ty ->
            Mono.MList
                (List.map (annotateExprCalls solution) elems)
                ty

        Mono.MLet name boundExpr bodyExpr ty ->
            Mono.MLet
                name
                (annotateExprCalls solution boundExpr)
                (annotateExprCalls solution bodyExpr)
                ty

        _ ->
            expr
```

#### Compute CallInfo for expression

```elm
computeCallInfoForExpr :
    StagingSolution
    -> Mono.MonoExpr
    -> List Mono.MonoExpr
    -> Mono.MonoType
    -> Mono.CallInfo
computeCallInfoForExpr solution callee args callType =
    let
        calleeType =
            Mono.typeOf callee

        argsApplied =
            List.length args
    in
    case callee of
        Mono.MVarKernel home name _ ->
            let
                arity =
                    MonoReturnArity.countTotalArity calleeType

                stageArities =
                    [ arity ]
            in
            CallInfo.new
                { callModel = Mono.FlattenedExternal
                , stageArities = stageArities
                , argsApplied = argsApplied
                }

        _ ->
            let
                -- Derive segmentation either from solution.producerClass
                -- or directly from calleeType (now canonical)
                stageArities =
                    MonoReturnArity.segmentationFromType calleeType

                callModel =
                    Mono.StageCurried
            in
            CallInfo.new
                { callModel = callModel
                , stageArities = stageArities
                , argsApplied = argsApplied
                }
```

#### CallInfo.new helper

**File:** `Compiler/GlobalOpt/CallInfo.elm`

```elm
module Compiler.GlobalOpt.CallInfo exposing (new)

import Compiler.Generate.Monomorphized as Mono

{-| Construct a CallInfo, computing derived fields from the inputs.

Given callModel, stageArities, and argsApplied, this helper computes:
- isSingleStageSaturated
- initialRemaining
- remainingStageArities
-}
new :
    { callModel : Mono.CallModel
    , stageArities : List Int
    , argsApplied : Int
    }
    -> Mono.CallInfo
new { callModel, stageArities, argsApplied } =
    let
        firstStage =
            List.head stageArities |> Maybe.withDefault 0

        isSingleStageSaturated =
            argsApplied == firstStage

        initialRemaining =
            firstStage

        remainingStageArities =
            computeRemaining stageArities argsApplied
    in
    { callModel = callModel
    , stageArities = stageArities
    , isSingleStageSaturated = isSingleStageSaturated
    , initialRemaining = initialRemaining
    , remainingStageArities = remainingStageArities
    }


computeRemaining : List Int -> Int -> List Int
computeRemaining stageArities argsApplied =
    case stageArities of
        [] ->
            []

        first :: rest ->
            if argsApplied >= first then
                computeRemaining rest (argsApplied - first)
            else
                (first - argsApplied) :: rest
```

---

## Implementation Checklist

### Phase 1: Data Structures and Union-Find
- [ ] Create `Compiler/GlobalOpt/Staging/Types.elm` with `ProducerId`, `SlotId`, `Node`, `StagingGraph`
- [ ] Create `Compiler/GlobalOpt/Staging/UnionFind.elm` with `Uf`, `ufFind`, `ufUnion`, `ensureNode`, `unionNodes`
- [ ] Add helper functions for Node/Slot key generation (`recordKeyFromType`, `tupleKeyFromType`, `ctorName`, `listContextKeyFromExpr`)

### Phase 2: Natural Staging Computation
- [ ] Create `Compiler/GlobalOpt/Staging/ProducerInfo.elm`
- [ ] Implement `computeProducerInfo` traversal
- [ ] Implement `detectNaturalSegFromExpr` for closures/tail-funcs
- [ ] Implement `addProducersFromExpr` for closures in MonoDefine nodes
- [ ] Implement `kernelNameFromNodeId` helper
- [ ] Handle kernel/extern fixed ABIs

### Phase 3: Graph Building (Constraint Collection)
- [ ] Create `Compiler/GlobalOpt/Staging/GraphBuilder.elm`
- [ ] Implement `buildStagingGraph` main traversal
- [ ] Implement `buildStagingGraphExpr` for all expression types (MIf, MCase, MRecord, MTuple, MCtor, MList, MLet, MCall)
- [ ] Implement `connectBranchProducer` for if/case direct function results
- [ ] Implement `addAggregateJoinpoints` for records/tuples/ctors/lists
- [ ] Implement `producerFromExpr` to resolve expressions to producers
- [ ] Add let-binding constraints
- [ ] Add capture constraints

### Phase 4: Solver
- [ ] Create `Compiler/GlobalOpt/Staging/Solver.elm`
- [ ] Implement `solveStagingGraph` top-level
- [ ] Implement `buildClasses` from union-find
- [ ] Implement `findNodeById` helper for reverse lookup
- [ ] Implement `chooseCanonicalSegs` with majority voting
- [ ] Implement `mapProducersAndSlotsToClasses`
- [ ] Add kernel compatibility checks (force kernel staging if kernel in class)

### Phase 5: Rewriter
- [ ] Create `Compiler/GlobalOpt/Staging/Rewriter.elm`
- [ ] Implement `applyStagingSolution` top-level
- [ ] Implement `rewriteNodeProducers` for tail-funcs and defines
- [ ] Implement `rewriteExprProducers` for closures and all expressions
- [ ] Extend `AbiWrapper` with `wrapTailFuncToSegmentation` and `wrapClosureToSegmentation`
- [ ] Implement `adjustNodeTypesToStaging` for type flattening

### Phase 6: Call Annotation
- [ ] Create `Compiler/GlobalOpt/CallInfo.elm` with `new` helper
- [ ] Implement `annotateCallStaging` as pure lookup
- [ ] Implement `annotateExprCalls` traversal for all expression types
- [ ] Implement `computeCallInfoForExpr` using solution
- [ ] Ensure `CallInfo` structure matches MLIR codegen expectations

### Phase 7: Validation
- [ ] Implement `validateClosureStaging` stub (reuse existing or extend)
- [ ] Add validation for function-typed aggregate fields

### Phase 8: Integration
- [ ] Update `MonoGlobalOptimize.globalOptimize` to use new pipeline
- [ ] Create main `Staging.elm` module exposing `analyzeAndSolveStaging`, `validateClosureStaging`, `annotateCallStaging`
- [ ] Remove or deprecate old `normalizeCaseIfAbi`, `canonicalizeClosureStaging`
- [ ] Verify imports and module dependencies

### Phase 9: Testing
- [ ] Add unit tests for union-find
- [ ] Add tests for natural staging detection
- [ ] Add tests for aggregate joinpoints (records, tuples, ctors, lists)
- [ ] Add integration tests for end-to-end staging
- [ ] Ensure all 7515+ existing tests pass

---

## Open Questions

### Q1: How to handle `producerFromExpr` for complex expressions?

When an expression is not a direct closure/kernel but a variable or projection, we need to trace back to the actual producer.

**Options:**
- **(A)** Require all function-typed variables to have been registered as `SlotVar` and look up their producer via the slot's class
- **(B)** Recursively resolve through let-bindings during graph building
- **(C)** Use a pre-pass to build a `varToProducer` map

**Recommendation:** (B) is most straightforward given we're already traversing.

### Q2: Should `SlotRecord` be keyed by field set or by alias name?

**Options:**
- **(A)** Canonical field set hash (coarser, more sharing)
- **(B)** Record alias name if available (finer, more precise)

**Recommendation:** (A) for simplicity, since records with same fields are interchangeable.

### Q3: How to represent `StagingSolution` for MLIR codegen?

**Options:**
- **(A)** Store in a side table passed to codegen
- **(B)** Embed staging in `MonoType` (already flattened)
- **(C)** Store `CallInfo` directly on `MonoCall` nodes

**Recommendation:** (C) is cleanest—attach `CallInfo` to calls, and MLIR codegen just reads it.

### Q4: What if a kernel appears in a class with user closures?

**Constraint:** Kernels have fixed ABI `[arity]`. If they're unified with closures of different staging, we must use the kernel's staging.

**Action:** During `chooseCanonicalSegs`, if any producer is a kernel, force `canonicalSeg = kernelSeg`. If multiple kernels with different ABIs (shouldn't happen), report error.

### Q5: MonoExpr representation for CallInfo?

Current `MonoCall` doesn't have a `CallInfo` field. Options:
- **(A)** Add `MCallWithInfo` variant
- **(B)** Store `CallInfo` in a separate `Dict SpecId CallInfo`
- **(C)** Compute `CallInfo` lazily in MLIR codegen from canonical types

**Recommendation:** (A) is cleanest for codegen—no need to look up side tables.

### Q6: Expression constructor naming convention?

The codebase may use either:
- Long form: `MonoIf`, `MonoCase`, `MonoRecord`, etc.
- Short form: `MIf`, `MCase`, `MRecord`, etc.

**Action:** Adapt pattern matches in implementation to match actual constructor names in `Compiler.Generate.Monomorphized`.

---

## Assumptions

1. **Well-typed input:** MonoGraph is fully monomorphized with no type variables (except `CEcoValue` in kernel ABIs).

2. **Finite function flows:** Function values don't flow through unbounded recursion creating infinite ABI classes.

3. **Kernel ABIs are fixed:** Kernels cannot adapt—algorithm must choose their staging.

4. **Slot keys are stable:** Record/tuple type keys can be computed consistently across branches.

5. **Union-find is sufficient:** We don't need full unification—just equivalence partitioning.

6. **Wrappers have negligible overhead:** The cost of eta-wrapping is acceptable for ABI consistency.

---

## Risk Assessment

| Risk | Severity | Mitigation |
|------|----------|------------|
| Complex expression tracing for `producerFromExpr` | Medium | Build comprehensive test cases; use conservative fallback |
| Performance of union-find on large programs | Low | Standard path compression; O(α(n)) per operation |
| Breaking existing tests during refactor | Medium | Incremental implementation; keep old code until new passes |
| Kernel incompatibility edge cases | Low | Explicit checks with clear error messages |
| Missing expression cases in traversal | Medium | Exhaustive pattern matching; no catch-all `_` |
| Constructor naming mismatch | Low | Verify against actual MonoExpr definitions before implementation |

---

## Success Criteria

1. All existing tests pass (7515+ tests)
2. New invariant tests for aggregate-carried functions pass
3. `annotateCallStaging` performs no unification—pure lookup only
4. MLIR codegen switches cleanly on `CallInfo.callModel`
5. No runtime staging mismatches in generated code
6. Functions in records/tuples/ctors/lists work correctly across if/case branches
