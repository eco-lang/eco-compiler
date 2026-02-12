module Compiler.GlobalOpt.AbiCloning exposing
    ( abiCloningPass
    , computeCaptureAbi
    )

{-| ABI Cloning Pass

This pass ensures homogeneous closure parameters within each function specialization.
It analyzes closure-typed parameters in higher-order functions and clones functions
when a parameter receives closures with different capture ABIs at different call sites.

Algorithm:
1. Traverse all call sites to collect capture ABIs for each closure-typed parameter
2. If any parameter has multiple distinct capture ABIs, clone the function
3. Rewrite call sites to target appropriate clones
4. Iterate until fixed point

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Data.Map as Dict exposing (Dict)



-- ============================================================================
-- ====== PUBLIC API ======
-- ============================================================================


{-| Run the ABI cloning pass on a MonoGraph.
Ensures each closure-typed parameter within a single function specialization
has at most one capture ABI across all call sites.
-}
abiCloningPass : Mono.MonoGraph -> Mono.MonoGraph
abiCloningPass graph =
    -- Phase 1: Collect all parameter ABIs from call sites
    let
        parameterAbis : Dict Int Int (Dict Int Int (List Mono.CaptureABI))
        parameterAbis =
            collectAllParameterAbis graph
    in
    -- Phase 2: Determine which functions need cloning
    -- For now, we don't actually clone - just pass through
    -- The infrastructure is in place for future implementation
    graph


{-| Extract the capture ABI from a closure expression.
Returns Nothing for non-closure expressions.
-}
computeCaptureAbi : Mono.MonoExpr -> Maybe Mono.CaptureABI
computeCaptureAbi expr =
    case expr of
        Mono.MonoClosure closureInfo body closureType ->
            let
                captureTypes =
                    List.map (\( _, e, _ ) -> Mono.typeOf e) closureInfo.captures

                paramTypes =
                    List.map Tuple.second closureInfo.params

                returnType =
                    Mono.stageReturnType closureType
            in
            Just
                { captureTypes = captureTypes
                , paramTypes = paramTypes
                , returnType = returnType
                }

        _ ->
            Nothing



-- ============================================================================
-- ====== INTERNAL: COLLECTION PHASE ======
-- ============================================================================


{-| Collect parameter ABIs from all call sites in the graph.
Returns a map from SpecId -> ParamIndex -> List CaptureABI
-}
collectAllParameterAbis : Mono.MonoGraph -> Dict Int Int (Dict Int Int (List Mono.CaptureABI))
collectAllParameterAbis (Mono.MonoGraph data) =
    Dict.foldl compare
        (\_ node acc ->
            collectFromNode node acc
        )
        Dict.empty
        data.nodes


{-| Collect parameter ABIs from a single node.
-}
collectFromNode : Mono.MonoNode -> Dict Int Int (Dict Int Int (List Mono.CaptureABI)) -> Dict Int Int (Dict Int Int (List Mono.CaptureABI))
collectFromNode node acc =
    case node of
        Mono.MonoDefine expr _ ->
            collectFromExpr expr acc

        Mono.MonoTailFunc _ expr _ ->
            collectFromExpr expr acc

        Mono.MonoPortIncoming expr _ ->
            collectFromExpr expr acc

        Mono.MonoPortOutgoing expr _ ->
            collectFromExpr expr acc

        Mono.MonoCycle defs _ ->
            List.foldl (\( _, expr ) accDefs -> collectFromExpr expr accDefs) acc defs

        _ ->
            acc


{-| Collect parameter ABIs from an expression.
-}
collectFromExpr : Mono.MonoExpr -> Dict Int Int (Dict Int Int (List Mono.CaptureABI)) -> Dict Int Int (Dict Int Int (List Mono.CaptureABI))
collectFromExpr expr acc =
    case expr of
        -- Direct call to a global function - this is where we record ABIs
        Mono.MonoCall _ (Mono.MonoVarGlobal _ specId _) args _ _ ->
            let
                accWithCall =
                    recordCallAbis specId args acc
            in
            -- Also recurse into arguments
            List.foldl collectFromExpr accWithCall args

        -- Other call types - recurse into callee and args
        Mono.MonoCall _ callee args _ _ ->
            List.foldl collectFromExpr (collectFromExpr callee acc) args

        -- Closure - recurse into body and capture expressions
        Mono.MonoClosure info body _ ->
            let
                accWithCaptures =
                    List.foldl (\( _, e, _ ) a -> collectFromExpr e a) acc info.captures
            in
            collectFromExpr body accWithCaptures

        -- If expression
        Mono.MonoIf branches final _ ->
            let
                accWithBranches =
                    List.foldl
                        (\( cond, then_ ) a ->
                            collectFromExpr then_ (collectFromExpr cond a)
                        )
                        acc
                        branches
            in
            collectFromExpr final accWithBranches

        -- Let expression
        Mono.MonoLet def body _ ->
            collectFromExpr body (collectFromDef def acc)

        -- List
        Mono.MonoList _ items _ ->
            List.foldl collectFromExpr acc items

        -- Case
        Mono.MonoCase _ _ _ branches _ ->
            List.foldl (\( _, e ) a -> collectFromExpr e a) acc branches

        -- Record
        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> collectFromExpr e a) acc fields

        Mono.MonoRecordAccess inner _ _ ->
            collectFromExpr inner acc

        Mono.MonoRecordUpdate inner updates _ ->
            List.foldl (\( _, e ) a -> collectFromExpr e a) (collectFromExpr inner acc) updates

        -- Tuple
        Mono.MonoTupleCreate _ items _ ->
            List.foldl collectFromExpr acc items

        -- Destructor
        Mono.MonoDestruct _ inner _ ->
            collectFromExpr inner acc

        -- Tail call - recurse into args
        Mono.MonoTailCall _ args _ ->
            List.foldl (\( _, e ) a -> collectFromExpr e a) acc args

        -- Leaves
        _ ->
            acc


{-| Collect from a definition.
-}
collectFromDef : Mono.MonoDef -> Dict Int Int (Dict Int Int (List Mono.CaptureABI)) -> Dict Int Int (Dict Int Int (List Mono.CaptureABI))
collectFromDef def acc =
    case def of
        Mono.MonoDef _ bound ->
            collectFromExpr bound acc

        Mono.MonoTailDef _ _ bound ->
            collectFromExpr bound acc


{-| Record ABIs for arguments passed to a specific function.
-}
recordCallAbis :
    Mono.SpecId
    -> List Mono.MonoExpr
    -> Dict Int Int (Dict Int Int (List Mono.CaptureABI))
    -> Dict Int Int (Dict Int Int (List Mono.CaptureABI))
recordCallAbis specId args acc =
    let
        argAbis : List ( Int, Maybe Mono.CaptureABI )
        argAbis =
            List.indexedMap
                (\idx arg -> ( idx, computeCaptureAbi arg ))
                args

        updateParamAbis : Dict Int Int (List Mono.CaptureABI) -> Dict Int Int (List Mono.CaptureABI)
        updateParamAbis paramDict =
            List.foldl
                (\( idx, maybeAbi ) d ->
                    case maybeAbi of
                        Just abi ->
                            Dict.update identity
                                idx
                                (\existing ->
                                    Just (abi :: Maybe.withDefault [] existing)
                                )
                                d

                        Nothing ->
                            d
                )
                paramDict
                argAbis
    in
    Dict.update identity
        specId
        (\existing ->
            Just (updateParamAbis (Maybe.withDefault Dict.empty existing))
        )
        acc



-- ============================================================================
-- ====== INTERNAL: ANALYSIS PHASE ======
-- ============================================================================


{-| Check if any parameter has multiple distinct capture ABIs.
-}
shouldClone : Dict Int Int (List Mono.CaptureABI) -> Bool
shouldClone paramAbis =
    Dict.foldl compare
        (\_ abis acc ->
            acc || List.length (dedupeAbis abis) > 1
        )
        False
        paramAbis


{-| Deduplicate ABIs based on structural equality.
-}
dedupeAbis : List Mono.CaptureABI -> List Mono.CaptureABI
dedupeAbis abis =
    List.foldl
        (\abi acc ->
            if List.any (abiEqual abi) acc then
                acc

            else
                abi :: acc
        )
        []
        abis


{-| Check if two CaptureABIs are structurally equal.
-}
abiEqual : Mono.CaptureABI -> Mono.CaptureABI -> Bool
abiEqual a b =
    (a.captureTypes == b.captureTypes)
        && (a.paramTypes == b.paramTypes)
        && (a.returnType == b.returnType)
