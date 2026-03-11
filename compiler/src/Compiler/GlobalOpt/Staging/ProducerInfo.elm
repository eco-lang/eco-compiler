module Compiler.GlobalOpt.Staging.ProducerInfo exposing (computeProducerInfo)

{-| Computes natural staging information for all function producers.

This module traverses the MonoGraph to identify:

  - Closures and their natural segmentation (based on nested lambda structure)
  - Tail functions and their natural segmentation
  - Kernels/externs with fixed flat ABI


# API

@docs computeProducerInfo

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.GlobalOpt.Staging.Types exposing (ProducerId(..), ProducerInfo, Segmentation, emptyProducerInfo)
import Compiler.GlobalOpt.Staging.UnionFind exposing (producerIdToKey)
import Dict



-- ============================================================================
-- COMPUTE PRODUCER INFO
-- ============================================================================


{-| Traverse the MonoGraph and gather natural staging info for all producers.
-}
computeProducerInfo : Mono.MonoGraph -> ProducerInfo
computeProducerInfo (Mono.MonoGraph mono) =
    Array.foldl
        (\maybeNode ( nodeId, acc ) ->
            case maybeNode of
                Nothing ->
                    ( nodeId + 1, acc )

                Just node ->
                    ( nodeId + 1, foldNode nodeId node acc )
        )
        ( 0, emptyProducerInfo )
        mono.nodes
        |> Tuple.second


foldNode : Int -> Mono.MonoNode -> ProducerInfo -> ProducerInfo
foldNode nodeId node acc =
    case node of
        Mono.MonoDefine expr _ ->
            addProducersFromExpr expr acc

        Mono.MonoTailFunc params body monoType ->
            let
                pid =
                    ProducerTailFunc nodeId

                seg =
                    detectNaturalSegFromParams params body

                arity =
                    Mono.countTotalArity monoType

                key =
                    producerIdToKey pid
            in
            { acc
                | naturalSeg = Dict.insert key seg acc.naturalSeg
                , totalArity = Dict.insert key arity acc.totalArity
            }

        Mono.MonoExtern monoType ->
            let
                pid =
                    ProducerKernel (kernelNameFromNodeId nodeId)

                arity =
                    Mono.countTotalArity monoType

                -- Kernels always have flat ABI
                seg =
                    if arity > 0 then
                        [ arity ]

                    else
                        []

                key =
                    producerIdToKey pid
            in
            { acc
                | naturalSeg = Dict.insert key seg acc.naturalSeg
                , totalArity = Dict.insert key arity acc.totalArity
            }

        Mono.MonoManagerLeaf _ monoType ->
            let
                pid =
                    ProducerKernel (kernelNameFromNodeId nodeId)

                arity =
                    Mono.countTotalArity monoType

                seg =
                    if arity > 0 then
                        [ arity ]

                    else
                        []

                key =
                    producerIdToKey pid
            in
            { acc
                | naturalSeg = Dict.insert key seg acc.naturalSeg
                , totalArity = Dict.insert key arity acc.totalArity
            }

        _ ->
            acc


{-| Generate a kernel name from node ID.
In practice, this would be looked up from the registry.
-}
kernelNameFromNodeId : Int -> String
kernelNameFromNodeId nodeId =
    "kernel:" ++ String.fromInt nodeId



-- ============================================================================
-- ADD PRODUCERS FROM EXPRESSION
-- ============================================================================


{-| Traverse an expression and add producer info for any closures found.
-}
addProducersFromExpr : Mono.MonoExpr -> ProducerInfo -> ProducerInfo
addProducersFromExpr expr acc =
    case expr of
        Mono.MonoClosure closureInfo body monoType ->
            let
                pid =
                    ProducerClosure closureInfo.lambdaId

                seg =
                    detectNaturalSegFromParams closureInfo.params body

                arity =
                    Mono.countTotalArity monoType

                key =
                    producerIdToKey pid

                acc1 =
                    { acc
                        | naturalSeg = Dict.insert key seg acc.naturalSeg
                        , totalArity = Dict.insert key arity acc.totalArity
                    }
            in
            -- Also recurse into the body
            addProducersFromExpr body acc1

        Mono.MonoIf branches elseExpr _ ->
            let
                acc1 =
                    List.foldl
                        (\( cond, then_ ) a -> addProducersFromExpr cond a |> addProducersFromExpr then_)
                        acc
                        branches
            in
            addProducersFromExpr elseExpr acc1

        Mono.MonoCase _ _ _ branches _ ->
            List.foldl
                (\( _, branchExpr ) a -> addProducersFromExpr branchExpr a)
                acc
                branches

        Mono.MonoLet def body _ ->
            let
                acc1 =
                    addProducersFromDef def acc
            in
            addProducersFromExpr body acc1

        Mono.MonoCall _ callee args _ _ ->
            let
                acc1 =
                    addProducersFromExpr callee acc
            in
            List.foldl addProducersFromExpr acc1 args

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> addProducersFromExpr e a) acc fields

        Mono.MonoRecordUpdate base fields _ ->
            let
                acc1 =
                    addProducersFromExpr base acc
            in
            List.foldl (\( _, e ) a -> addProducersFromExpr e a) acc1 fields

        Mono.MonoTupleCreate _ exprs _ ->
            List.foldl addProducersFromExpr acc exprs

        Mono.MonoList _ exprs _ ->
            List.foldl addProducersFromExpr acc exprs

        Mono.MonoDestruct _ inner _ ->
            addProducersFromExpr inner acc

        Mono.MonoRecordAccess inner _ _ ->
            addProducersFromExpr inner acc

        _ ->
            acc


addProducersFromDef : Mono.MonoDef -> ProducerInfo -> ProducerInfo
addProducersFromDef def acc =
    case def of
        Mono.MonoDef _ expr ->
            addProducersFromExpr expr acc

        Mono.MonoTailDef _ _ expr ->
            addProducersFromExpr expr acc



-- ============================================================================
-- DETECT NATURAL SEGMENTATION
-- ============================================================================


{-| Detect natural segmentation from a closure's params and body.
The segmentation is determined by the nesting of lambda expressions.
-}
detectNaturalSegFromParams : List ( name, type_ ) -> Mono.MonoExpr -> Segmentation
detectNaturalSegFromParams params body =
    let
        thisStage =
            List.length params

        innerStages =
            detectNaturalSegFromExpr body
    in
    if thisStage > 0 then
        thisStage :: innerStages

    else
        innerStages


{-| Detect natural segmentation from an expression (looking for nested closures).
-}
detectNaturalSegFromExpr : Mono.MonoExpr -> Segmentation
detectNaturalSegFromExpr expr =
    case expr of
        Mono.MonoClosure closureInfo body _ ->
            detectNaturalSegFromParams closureInfo.params body

        _ ->
            []
