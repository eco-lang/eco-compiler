module TestLogic.Generate.CodeGen.ProjectionHeapLayoutConsistency exposing (expectProjectionHeapLayoutConsistency)

{-| Test logic for REP\_BOUNDARY\_003: Projection result types must match heap field layout.

At every call site where a list value is passed as an argument, the caller's
list element type and the callee's corresponding parameter element type must
agree on unboxability. If the caller has `MList MInt` (unboxed i64 heads) but
the callee expects `MList (MVar \_ CEcoValue)` (boxed !eco.value heads), the
callee's `eco.project.list\_head` will reinterpret unboxed data as a heap pointer,
causing a segfault at runtime.

This is checked at the MonoGraph level by walking all MonoCall nodes and
comparing argument types against callee parameter types.

@docs expectProjectionHeapLayoutConsistency

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Generate.MLIR.Types as Types
import Dict
import Expect exposing (Expectation)
import TestLogic.TestPipeline exposing (runToMlir)


{-| Verify that list element types agree on unboxability across call boundaries.
-}
expectProjectionHeapLayoutConsistency : Src.Module -> Expectation
expectProjectionHeapLayoutConsistency srcModule =
    case runToMlir srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { monoGraph } ->
            let
                issues =
                    checkListElemConsistency monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- MAIN CHECK: walk all nodes, check all MonoCall sites
-- ============================================================================


checkListElemConsistency : Mono.MonoGraph -> List String
checkListElemConsistency (Mono.MonoGraph data) =
    let
        callIssues =
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Nothing ->
                            ( specId + 1, acc )

                        Just node ->
                            ( specId + 1, checkNode specId data.registry node ++ acc )
                )
                ( 0, [] )
                data.nodes
                |> Tuple.second

        -- Also check: for any two specializations of the same Global that have
        -- MList in their type, the element types must agree on unboxability.
        -- This catches cases where the monomorphizer produces one specialization
        -- with MList MInt and another with MList (MVar _ CEcoValue) for the same
        -- function, even if no direct call edge connects them.
        specIssues =
            checkSpecializationConsistency data.registry
    in
    callIssues ++ specIssues


checkNode : Int -> Mono.SpecializationRegistry -> Mono.MonoNode -> List String
checkNode specId registry node =
    let
        ctx =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr _ ->
            collectCallIssues ctx registry expr

        Mono.MonoTailFunc _ expr _ ->
            collectCallIssues ctx registry expr

        Mono.MonoPortIncoming expr _ ->
            collectCallIssues ctx registry expr

        Mono.MonoPortOutgoing expr _ ->
            collectCallIssues ctx registry expr

        Mono.MonoCycle defs _ ->
            List.concatMap (\( _, e ) -> collectCallIssues ctx registry e) defs

        _ ->
            []



-- ============================================================================
-- EXPRESSION WALKER
-- ============================================================================


collectCallIssues : String -> Mono.SpecializationRegistry -> Mono.MonoExpr -> List String
collectCallIssues ctx registry expr =
    case expr of
        Mono.MonoCall _ funcExpr args _ _ ->
            checkCallSite ctx registry funcExpr args
                ++ collectCallIssues ctx registry funcExpr
                ++ List.concatMap (collectCallIssues ctx registry) args

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.concatMap (\( _, e, _ ) -> collectCallIssues ctx registry e) closureInfo.captures
                ++ collectCallIssues ctx registry bodyExpr

        Mono.MonoLet def bodyExpr _ ->
            collectDefIssues ctx registry def
                ++ collectCallIssues ctx registry bodyExpr

        Mono.MonoIf branches elseExpr _ ->
            List.concatMap (\( c, t ) -> collectCallIssues ctx registry c ++ collectCallIssues ctx registry t) branches
                ++ collectCallIssues ctx registry elseExpr

        Mono.MonoCase _ _ decider branches _ ->
            collectDeciderIssues ctx registry decider
                ++ List.concatMap (\( _, e ) -> collectCallIssues ctx registry e) branches

        Mono.MonoDestruct _ valueExpr _ ->
            collectCallIssues ctx registry valueExpr

        Mono.MonoList _ exprs _ ->
            List.concatMap (collectCallIssues ctx registry) exprs

        Mono.MonoRecordCreate fieldExprs _ ->
            List.concatMap (\( _, e ) -> collectCallIssues ctx registry e) fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ ->
            collectCallIssues ctx registry recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            collectCallIssues ctx registry recordExpr
                ++ List.concatMap (\( _, e ) -> collectCallIssues ctx registry e) updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.concatMap (collectCallIssues ctx registry) elementExprs

        Mono.MonoTailCall _ args _ ->
            List.concatMap (\( _, e ) -> collectCallIssues ctx registry e) args

        _ ->
            []


collectDefIssues : String -> Mono.SpecializationRegistry -> Mono.MonoDef -> List String
collectDefIssues ctx registry def =
    case def of
        Mono.MonoDef _ expr ->
            collectCallIssues ctx registry expr

        Mono.MonoTailDef _ _ expr ->
            collectCallIssues ctx registry expr


collectDeciderIssues : String -> Mono.SpecializationRegistry -> Mono.Decider Mono.MonoChoice -> List String
collectDeciderIssues ctx registry decider =
    case decider of
        Mono.Leaf _ ->
            []

        Mono.Chain _ success failure ->
            collectDeciderIssues ctx registry success
                ++ collectDeciderIssues ctx registry failure

        Mono.FanOut _ edges fallback ->
            List.concatMap (\( _, d ) -> collectDeciderIssues ctx registry d) edges
                ++ collectDeciderIssues ctx registry fallback



-- ============================================================================
-- CALL SITE CHECK
-- ============================================================================


{-| At a MonoCall site, check that list arguments have consistent element types
with the callee's parameter types.

Only checks calls to global functions (MonoVarGlobal) where we can look up the
callee's full MonoType from the registry.

-}
checkCallSite : String -> Mono.SpecializationRegistry -> Mono.MonoExpr -> List Mono.MonoExpr -> List String
checkCallSite ctx registry funcExpr args =
    case funcExpr of
        Mono.MonoVarGlobal _ calleeSpecId _ ->
            case lookupCalleeParamTypes registry calleeSpecId of
                Nothing ->
                    []

                Just calleeParamTypes ->
                    checkArgListTypes ctx calleeSpecId calleeParamTypes args

        _ ->
            []


{-| Look up the callee's parameter types from the registry.
-}
lookupCalleeParamTypes : Mono.SpecializationRegistry -> Int -> Maybe (List Mono.MonoType)
lookupCalleeParamTypes registry specId =
    case Array.get specId registry.reverseMapping of
        Just (Just ( _, monoType, _ )) ->
            case monoType of
                Mono.MFunction paramTypes _ ->
                    Just paramTypes

                _ ->
                    Nothing

        _ ->
            Nothing


{-| Check each argument against the corresponding callee parameter type.
-}
checkArgListTypes : String -> Int -> List Mono.MonoType -> List Mono.MonoExpr -> List String
checkArgListTypes ctx calleeSpecId paramTypes args =
    List.map2
        (\paramType argExpr ->
            checkListArgConsistency ctx calleeSpecId paramType (Mono.typeOf argExpr)
        )
        paramTypes
        args
        |> List.concat


{-| If both the caller's arg type and callee's param type are MList, check that
the element types agree on unboxability.
-}
checkListArgConsistency : String -> Int -> Mono.MonoType -> Mono.MonoType -> List String
checkListArgConsistency ctx calleeSpecId calleeParamType callerArgType =
    case ( calleeParamType, callerArgType ) of
        ( Mono.MList calleeElem, Mono.MList callerElem ) ->
            let
                calleeUnboxed =
                    isUnboxableElem calleeElem

                callerUnboxed =
                    isUnboxableElem callerElem
            in
            if calleeUnboxed /= callerUnboxed then
                [ ctx
                    ++ " [REP_BOUNDARY_003]: List element unboxability mismatch at call to SpecId "
                    ++ String.fromInt calleeSpecId
                    ++ ": caller has MList "
                    ++ monoTypeLabel callerElem
                    ++ " ("
                    ++ (if callerUnboxed then
                            "unboxed"

                        else
                            "boxed"
                       )
                    ++ ") but callee expects MList "
                    ++ monoTypeLabel calleeElem
                    ++ " ("
                    ++ (if calleeUnboxed then
                            "unboxed"

                        else
                            "boxed"
                       )
                    ++ ")"
                ]

            else
                []

        _ ->
            []



-- ============================================================================
-- HELPERS
-- ============================================================================


-- ============================================================================
-- SPECIALIZATION CONSISTENCY CHECK
-- ============================================================================


{-| Check that all specializations of the same Global function agree on
list element unboxability.

If Global "List.foldl" has two specializations, one with MList MInt (unboxed)
and one with MList (MVar \_ CEcoValue) (boxed), that's a problem: code compiled
for the boxed specialization will misinterpret unboxed list heads when called
with a list that was constructed with unboxed heads.

-}
checkSpecializationConsistency : Mono.SpecializationRegistry -> List String
checkSpecializationConsistency registry =
    let
        -- Build: Global -> List (specId, elemType, isUnboxed)
        specsByGlobal =
            Array.foldl
                (\maybeEntry ( i, acc ) ->
                    case maybeEntry of
                        Just ( global, monoType, _ ) ->
                            case collectListElemTypes monoType of
                                [] ->
                                    ( i + 1, acc )

                                elems ->
                                    let
                                        key =
                                            globalToString global

                                        entries =
                                            List.map (\e -> { specId = i, elem = e, unboxed = isUnboxableElem e }) elems

                                        existing =
                                            Dict.get key acc |> Maybe.withDefault []
                                    in
                                    ( i + 1, Dict.insert key (existing ++ entries) acc )

                        Nothing ->
                            ( i + 1, acc )
                )
                ( 0, Dict.empty )
                registry.reverseMapping
                |> Tuple.second
    in
    -- For each Global, check if any specialization has a CEcoValue-constrained
    -- list element coexisting with a specialization that has an unboxable concrete
    -- element type. This catches the case where List.foldl is specialized once for
    -- MList MInt (unboxed) and once for MList (MVar _ CEcoValue) (boxed) —
    -- the boxed specialization will misinterpret unboxed cons cell heads.
    --
    -- We do NOT flag different concrete types (e.g. MList MInt vs MList MString)
    -- since those are legitimate different instantiations.
    Dict.foldl
        (\globalName entries acc ->
            let
                hasConcreteUnboxed =
                    List.any (\e -> e.unboxed && not (isErasedElem e.elem)) entries

                hasErasedBoxed =
                    List.any (\e -> not e.unboxed && isErasedElem e.elem) entries
            in
            if hasConcreteUnboxed && hasErasedBoxed then
                let
                    detail =
                        List.map
                            (\e ->
                                "SpecId "
                                    ++ String.fromInt e.specId
                                    ++ " elem="
                                    ++ monoTypeLabel e.elem
                                    ++ " ("
                                    ++ (if e.unboxed then
                                            "unboxed"

                                        else
                                            "boxed"
                                       )
                                    ++ ")"
                            )
                            entries
                in
                ("[REP_BOUNDARY_003]: Specializations of "
                    ++ globalName
                    ++ " have conflicting list element layout: a concrete unboxed element "
                    ++ "coexists with an erased (CEcoValue) boxed element — "
                    ++ String.join ", " detail
                )
                    :: acc

            else
                acc
        )
        []
        specsByGlobal


{-| Collect all MList element types from a MonoType (there may be multiple
if a function takes multiple list parameters with different element types).
-}
collectListElemTypes : Mono.MonoType -> List Mono.MonoType
collectListElemTypes monoType =
    case monoType of
        Mono.MList elemType ->
            [ elemType ]

        Mono.MFunction argTypes returnType ->
            List.concatMap collectListElemTypes argTypes
                ++ collectListElemTypes returnType

        Mono.MTuple elemTypes ->
            List.concatMap collectListElemTypes elemTypes

        _ ->
            []


globalToString : Mono.Global -> String
globalToString global =
    case global of
        Mono.Global _ name ->
            name

        Mono.Accessor name ->
            "." ++ name


{-| True if a list element type is an erased type variable (MVar \_ CEcoValue).

These represent "unknown/polymorphic" element types that the monomorphizer
chose not to specialize. If the same function also has a specialization with
a concrete unboxable element type (e.g. MInt), the erased version will
misinterpret unboxed data as heap pointers.

-}
isErasedElem : Mono.MonoType -> Bool
isErasedElem elemType =
    case elemType of
        Mono.MVar _ Mono.CEcoValue ->
            True

        _ ->
            False


{-| True if a list element MonoType would be stored unboxed in a cons cell.
-}
isUnboxableElem : Mono.MonoType -> Bool
isUnboxableElem elemType =
    Types.isUnboxable (Types.monoTypeToAbi elemType)


monoTypeLabel : Mono.MonoType -> String
monoTypeLabel t =
    case t of
        Mono.MInt ->
            "MInt"

        Mono.MFloat ->
            "MFloat"

        Mono.MChar ->
            "MChar"

        Mono.MBool ->
            "MBool"

        Mono.MString ->
            "MString"

        Mono.MUnit ->
            "MUnit"

        Mono.MVar _ Mono.CEcoValue ->
            "MVar CEcoValue"

        Mono.MVar _ Mono.CNumber ->
            "MVar CNumber"

        Mono.MList inner ->
            "MList (" ++ monoTypeLabel inner ++ ")"

        _ ->
            "composite"
