module Compiler.GlobalOpt.Staging.GraphBuilder exposing (buildStagingGraph)

{-| Builds the staging graph by traversing the MonoGraph and creating
union-find edges between producers and slots that must share staging.

This module handles:

  - Direct function returns from if/case branches
  - Function-typed fields in records, tuples, constructors, lists
  - Let bindings that bind function values
  - Captures in closures that are function-typed


# API

@docs buildStagingGraph

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.GlobalOpt.Staging.Types exposing (Node(..), ProducerId(..), ProducerInfo, SlotId(..), StagingGraph, emptyStagingGraph)
import Compiler.GlobalOpt.Staging.UnionFind exposing (ensureNode, unionNodes)
import Dict exposing (Dict)


type alias BuildCtx =
    { nextExprId : Int
    , varBindings : Dict String ProducerId
    }


emptyBuildCtx : BuildCtx
emptyBuildCtx =
    { nextExprId = 0
    , varBindings = Dict.empty
    }


freshExprId : BuildCtx -> ( Int, BuildCtx )
freshExprId ctx =
    ( ctx.nextExprId, { ctx | nextExprId = ctx.nextExprId + 1 } )



-- ============================================================================
-- BUILD STAGING GRAPH
-- ============================================================================


{-| Build the staging graph from a MonoGraph.
-}
buildStagingGraph : Mono.MonoGraph -> ProducerInfo -> StagingGraph
buildStagingGraph (Mono.MonoGraph mono) _ =
    let
        foldNode nodeId node ( sg, ctx ) =
            case node of
                Mono.MonoDefine expr _ ->
                    buildStagingGraphExpr expr sg ctx

                Mono.MonoTailFunc params body _ ->
                    let
                        pid =
                            ProducerTailFunc nodeId

                        -- Ensure the producer node exists in the staging graph
                        ( _, sgWithProducer ) =
                            ensureNode (NodeProducer pid) sg

                        -- Register function-typed params as slots
                        ( sg1, ctx1 ) =
                            List.foldl
                                (\( index, ( _, ty ) ) ( accSg, accCtx ) ->
                                    if Mono.isFunctionType ty then
                                        let
                                            slot =
                                                SlotParam nodeId index

                                            nodeSlot =
                                                NodeSlot slot

                                            ( _, accSg1 ) =
                                                ensureNode nodeSlot accSg
                                        in
                                        ( accSg1, accCtx )

                                    else
                                        ( accSg, accCtx )
                                )
                                ( sgWithProducer, ctx )
                                (List.indexedMap Tuple.pair params)
                    in
                    buildStagingGraphExpr body sg1 ctx1

                Mono.MonoCycle bindings _ ->
                    List.foldl
                        (\( _, expr ) ( accSg, accCtx ) -> buildStagingGraphExpr expr accSg accCtx)
                        ( sg, ctx )
                        bindings

                _ ->
                    ( sg, ctx )

        ( finalSg, _ ) =
            Array.foldl
                (\maybeNode ( nodeId, acc ) ->
                    case maybeNode of
                        Nothing ->
                            ( nodeId + 1, acc )

                        Just node ->
                            ( nodeId + 1, foldNode nodeId node acc )
                )
                ( 0, ( emptyStagingGraph, emptyBuildCtx ) )
                mono.nodes
                |> Tuple.second
    in
    finalSg



-- ============================================================================
-- BUILD STAGING GRAPH FOR EXPRESSIONS
-- ============================================================================


buildStagingGraphExpr : Mono.MonoExpr -> StagingGraph -> BuildCtx -> ( StagingGraph, BuildCtx )
buildStagingGraphExpr expr sg0 ctx0 =
    case expr of
        Mono.MonoIf branches elseExpr exprType ->
            let
                -- Recurse into all condition and then expressions
                ( sg1, ctx1 ) =
                    List.foldl
                        (\( cond, then_ ) ( accSg, accCtx ) ->
                            let
                                ( sgN, ctxN ) =
                                    buildStagingGraphExpr cond accSg accCtx
                            in
                            buildStagingGraphExpr then_ sgN ctxN
                        )
                        ( sg0, ctx0 )
                        branches

                ( sg2, ctx2 ) =
                    buildStagingGraphExpr elseExpr sg1 ctx1
            in
            if Mono.isFunctionType exprType then
                -- Create joinpoint for if result
                let
                    ( exprId, ctx3 ) =
                        freshExprId ctx2

                    resultSlot =
                        SlotIfResult exprId

                    nodeResult =
                        NodeSlot resultSlot

                    -- Connect all then branches and else branch to result
                    sg3 =
                        List.foldl
                            (\( _, then_ ) accSg ->
                                connectBranchProducer then_ nodeResult ctx3 accSg
                            )
                            sg2
                            branches

                    sg4 =
                        connectBranchProducer elseExpr nodeResult ctx3 sg3
                in
                ( sg4, ctx3 )

            else
                -- Handle aggregate joinpoints in non-function result
                let
                    sg3 =
                        addAggregateJoinpointsFromBranches
                            (List.map Tuple.second branches ++ [ elseExpr ])
                            ctx2
                            sg2
                in
                ( sg3, ctx2 )

        Mono.MonoCase _ _ _ branches exprType ->
            let
                -- Recurse into all branch expressions
                ( sg1, ctx1 ) =
                    List.foldl
                        (\( _, branchExpr ) ( accSg, accCtx ) ->
                            buildStagingGraphExpr branchExpr accSg accCtx
                        )
                        ( sg0, ctx0 )
                        branches
            in
            if Mono.isFunctionType exprType then
                -- Create joinpoint for case result
                let
                    ( exprId, ctx2 ) =
                        freshExprId ctx1

                    resultSlot =
                        SlotCaseResult exprId

                    nodeResult =
                        NodeSlot resultSlot

                    -- Connect all branches to result
                    sg2 =
                        List.foldl
                            (\( _, branchExpr ) accSg ->
                                connectBranchProducer branchExpr nodeResult ctx2 accSg
                            )
                            sg1
                            branches
                in
                ( sg2, ctx2 )

            else
                -- Handle aggregate joinpoints
                let
                    sg2 =
                        addAggregateJoinpointsFromBranches
                            (List.map Tuple.second branches)
                            ctx1
                            sg1
                in
                ( sg2, ctx1 )

        Mono.MonoLet def body _ ->
            let
                ( sg1, ctx1 ) =
                    buildStagingGraphDef def sg0 ctx0
            in
            buildStagingGraphExpr body sg1 ctx1

        Mono.MonoClosure closureInfo body _ ->
            -- Register this closure as a producer and add capture constraints
            let
                pid =
                    ProducerClosure closureInfo.lambdaId

                -- Ensure the producer node exists in the staging graph
                ( _, sgWithProducer ) =
                    ensureNode (NodeProducer pid) sg0

                sg1 =
                    List.foldl
                        (\( index, ( _, captureExpr, _ ) ) accSg ->
                            if Mono.isFunctionType (Mono.typeOf captureExpr) then
                                let
                                    slot =
                                        SlotCapture closureInfo.lambdaId index

                                    nodeSlot =
                                        NodeSlot slot
                                in
                                connectBranchProducer captureExpr nodeSlot ctx0 accSg

                            else
                                accSg
                        )
                        sgWithProducer
                        (List.indexedMap Tuple.pair closureInfo.captures)
            in
            -- Recurse into body
            buildStagingGraphExpr body sg1 ctx0

        Mono.MonoCall _ callee args _ _ ->
            let
                ( sg1, ctx1 ) =
                    buildStagingGraphExpr callee sg0 ctx0
            in
            List.foldl
                (\arg ( accSg, accCtx ) -> buildStagingGraphExpr arg accSg accCtx)
                ( sg1, ctx1 )
                args

        Mono.MonoRecordCreate fields recordType ->
            let
                ( sg1, ctx1 ) =
                    List.foldl
                        (\( _, fieldExpr ) ( accSg, accCtx ) ->
                            buildStagingGraphExpr fieldExpr accSg accCtx
                        )
                        ( sg0, ctx0 )
                        fields

                -- Add record field slots
                recordKey =
                    recordKeyFromType recordType

                sg2 =
                    List.foldl
                        (\( fieldName, fieldExpr ) accSg ->
                            if Mono.isFunctionType (Mono.typeOf fieldExpr) then
                                let
                                    slot =
                                        SlotRecord recordKey fieldName

                                    nodeSlot =
                                        NodeSlot slot
                                in
                                connectBranchProducer fieldExpr nodeSlot ctx1 accSg

                            else
                                accSg
                        )
                        sg1
                        fields
            in
            ( sg2, ctx1 )

        Mono.MonoTupleCreate _ exprs tupleType ->
            let
                ( sg1, ctx1 ) =
                    List.foldl
                        (\e ( accSg, accCtx ) -> buildStagingGraphExpr e accSg accCtx)
                        ( sg0, ctx0 )
                        exprs

                -- Add tuple element slots
                tupleKey =
                    tupleKeyFromType tupleType

                sg2 =
                    List.foldl
                        (\( index, e ) accSg ->
                            if Mono.isFunctionType (Mono.typeOf e) then
                                let
                                    slot =
                                        SlotTuple tupleKey index

                                    nodeSlot =
                                        NodeSlot slot
                                in
                                connectBranchProducer e nodeSlot ctx1 accSg

                            else
                                accSg
                        )
                        sg1
                        (List.indexedMap Tuple.pair exprs)
            in
            ( sg2, ctx1 )

        Mono.MonoList _ exprs listType ->
            let
                ( sg1, ctx1 ) =
                    List.foldl
                        (\e ( accSg, accCtx ) -> buildStagingGraphExpr e accSg accCtx)
                        ( sg0, ctx0 )
                        exprs

                -- Add list element slots
                listKey =
                    listKeyFromType listType

                sg2 =
                    List.foldl
                        (\( index, e ) accSg ->
                            if Mono.isFunctionType (Mono.typeOf e) then
                                let
                                    slot =
                                        SlotList listKey index

                                    nodeSlot =
                                        NodeSlot slot
                                in
                                connectBranchProducer e nodeSlot ctx1 accSg

                            else
                                accSg
                        )
                        sg1
                        (List.indexedMap Tuple.pair exprs)
            in
            ( sg2, ctx1 )

        Mono.MonoRecordAccess inner _ _ ->
            buildStagingGraphExpr inner sg0 ctx0

        Mono.MonoRecordUpdate base fields _ ->
            let
                ( sg1, ctx1 ) =
                    buildStagingGraphExpr base sg0 ctx0
            in
            List.foldl
                (\( _, fieldExpr ) ( accSg, accCtx ) ->
                    buildStagingGraphExpr fieldExpr accSg accCtx
                )
                ( sg1, ctx1 )
                fields

        Mono.MonoDestruct _ inner _ ->
            buildStagingGraphExpr inner sg0 ctx0

        Mono.MonoTailCall _ args _ ->
            List.foldl
                (\( _, argExpr ) ( accSg, accCtx ) ->
                    buildStagingGraphExpr argExpr accSg accCtx
                )
                ( sg0, ctx0 )
                args

        _ ->
            ( sg0, ctx0 )


buildStagingGraphDef : Mono.MonoDef -> StagingGraph -> BuildCtx -> ( StagingGraph, BuildCtx )
buildStagingGraphDef def sg ctx =
    case def of
        Mono.MonoDef _ expr ->
            buildStagingGraphExpr expr sg ctx

        Mono.MonoTailDef _ _ expr ->
            buildStagingGraphExpr expr sg ctx



-- ============================================================================
-- HELPERS
-- ============================================================================


{-| Connect a branch expression's producer to a result slot.
-}
connectBranchProducer : Mono.MonoExpr -> Node -> BuildCtx -> StagingGraph -> StagingGraph
connectBranchProducer branchExpr nodeResult ctx sg =
    case producerFromExpr branchExpr ctx of
        Just producer ->
            unionNodes (NodeProducer producer) nodeResult sg

        Nothing ->
            -- Not a direct producer - could be a variable reference or complex expression
            -- In that case, we'd need to trace through to find the producer
            -- For now, just ensure the result slot exists
            Tuple.second (ensureNode nodeResult sg)


{-| Extract a producer from an expression if it's a direct producer site.
-}
producerFromExpr : Mono.MonoExpr -> BuildCtx -> Maybe ProducerId
producerFromExpr expr ctx =
    case expr of
        Mono.MonoClosure closureInfo _ _ ->
            Just (ProducerClosure closureInfo.lambdaId)

        Mono.MonoVarKernel _ home name _ ->
            Just (ProducerKernel (home ++ "." ++ name))

        Mono.MonoVarLocal name _ ->
            -- Look up in context if this var was bound to a producer
            Dict.get name ctx.varBindings

        _ ->
            Nothing


{-| Handle aggregate joinpoints when the result type is not a function
but branches may still contain function-typed fields.
-}
addAggregateJoinpointsFromBranches : List Mono.MonoExpr -> BuildCtx -> StagingGraph -> StagingGraph
addAggregateJoinpointsFromBranches branches ctx sg =
    -- For each branch, if it's a record/tuple/list creation with function fields,
    -- we need to unify those fields across branches
    -- This is complex because we need to match up field names/indices
    -- For simplicity, we'll handle this by ensuring all corresponding
    -- slots are in the same equivalence class
    -- Group branches by their structure (record, tuple, list)
    let
        recordBranches =
            List.filterMap
                (\e ->
                    case e of
                        Mono.MonoRecordCreate fields ty ->
                            Just ( fields, ty )

                        _ ->
                            Nothing
                )
                branches

        tupleBranches =
            List.filterMap
                (\e ->
                    case e of
                        Mono.MonoTupleCreate _ exprs ty ->
                            Just ( exprs, ty )

                        _ ->
                            Nothing
                )
                branches

        -- Unify record fields across branches
        sg1 =
            unifyRecordFieldsAcrossBranches recordBranches sg ctx
    in
    unifyTupleElementsAcrossBranches tupleBranches sg1 ctx


unifyRecordFieldsAcrossBranches :
    List ( List ( String, Mono.MonoExpr ), Mono.MonoType )
    -> StagingGraph
    -> BuildCtx
    -> StagingGraph
unifyRecordFieldsAcrossBranches recordBranches sg ctx =
    case recordBranches of
        [] ->
            sg

        ( firstFields, firstType ) :: restBranches ->
            -- Use first branch's type as the canonical key
            let
                recordKey =
                    recordKeyFromType firstType
            in
            -- For each field in the first branch that's a function type,
            -- unify it with the corresponding field in other branches
            List.foldl
                (\( _, restFields ) accSg ->
                    List.foldl
                        (\( ( fstName, fstExpr ), ( _, sndExpr ) ) innerSg ->
                            if Mono.isFunctionType (Mono.typeOf fstExpr) then
                                let
                                    slot =
                                        SlotRecord recordKey fstName

                                    nodeSlot =
                                        NodeSlot slot
                                in
                                -- Connect both producers to the same slot
                                innerSg
                                    |> connectBranchProducer fstExpr nodeSlot ctx
                                    |> (\s -> connectBranchProducer sndExpr nodeSlot ctx s)

                            else
                                innerSg
                        )
                        accSg
                        (List.map2 Tuple.pair firstFields restFields)
                )
                sg
                (List.map Tuple.first restBranches |> List.map (\f -> ( firstType, f )))


unifyTupleElementsAcrossBranches :
    List ( List Mono.MonoExpr, Mono.MonoType )
    -> StagingGraph
    -> BuildCtx
    -> StagingGraph
unifyTupleElementsAcrossBranches tupleBranches sg ctx =
    case tupleBranches of
        [] ->
            sg

        ( firstExprs, firstType ) :: restBranches ->
            let
                tupleKey =
                    tupleKeyFromType firstType
            in
            List.foldl
                (\( _, restExprs ) accSg ->
                    List.foldl
                        (\( index, ( fstExpr, sndExpr ) ) innerSg ->
                            if Mono.isFunctionType (Mono.typeOf fstExpr) then
                                let
                                    slot =
                                        SlotTuple tupleKey index

                                    nodeSlot =
                                        NodeSlot slot
                                in
                                innerSg
                                    |> connectBranchProducer fstExpr nodeSlot ctx
                                    |> (\s -> connectBranchProducer sndExpr nodeSlot ctx s)

                            else
                                innerSg
                        )
                        accSg
                        (List.indexedMap Tuple.pair (List.map2 Tuple.pair firstExprs restExprs))
                )
                sg
                (List.map Tuple.first restBranches |> List.map (\e -> ( firstType, e )))



-- ============================================================================
-- TYPE KEY GENERATION
-- ============================================================================


{-| Generate a key for a record type based on its field names.
-}
recordKeyFromType : Mono.MonoType -> String
recordKeyFromType monoType =
    case monoType of
        Mono.MRecord fields ->
            Dict.keys fields
                |> List.sort
                |> String.join ","

        _ ->
            "unknown_record"


{-| Generate a key for a tuple type based on element count.
-}
tupleKeyFromType : Mono.MonoType -> String
tupleKeyFromType monoType =
    case monoType of
        Mono.MTuple elements ->
            "tuple" ++ String.fromInt (List.length elements)

        _ ->
            "unknown_tuple"


{-| Generate a key for a list type based on element type.
-}
listKeyFromType : Mono.MonoType -> String
listKeyFromType monoType =
    case monoType of
        Mono.MList elemType ->
            "list:" ++ monoTypeToKey elemType

        _ ->
            "unknown_list"


{-| Convert a MonoType to a string key (simplified).
-}
monoTypeToKey : Mono.MonoType -> String
monoTypeToKey monoType =
    case monoType of
        Mono.MInt ->
            "Int"

        Mono.MFloat ->
            "Float"

        Mono.MBool ->
            "Bool"

        Mono.MChar ->
            "Char"

        Mono.MString ->
            "String"

        Mono.MUnit ->
            "Unit"

        Mono.MFunction args ret ->
            "Fn(" ++ String.join "," (List.map monoTypeToKey args) ++ ")->" ++ monoTypeToKey ret

        Mono.MList elem ->
            "List(" ++ monoTypeToKey elem ++ ")"

        Mono.MTuple elems ->
            "Tuple(" ++ String.join "," (List.map monoTypeToKey elems) ++ ")"

        Mono.MRecord fields ->
            "Record{" ++ String.join "," (Dict.keys fields) ++ "}"

        Mono.MCustom _ name _ ->
            "Custom:" ++ name

        Mono.MVar name _ ->
            "Var:" ++ name
