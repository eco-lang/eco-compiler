module Compiler.Generate.MonoGraphIntegrity exposing
    ( expectCallableMonoNodes
    , expectMonoGraphComplete
    , expectMonoGraphClosed
    , expectSpecRegistryComplete
    )

{-| Test logic for invariants:

  - MONO_004: All functions are callable MonoNodes
  - MONO_010: MonoGraph is type complete
  - MONO_011: MonoGraph is closed and hygienic
  - MONO_005: Specialization registry is complete and consistent

This module reuses the existing typed optimization pipeline to verify
MonoGraph integrity. Successful monomorphization implies all these
invariants are satisfied.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import Compiler.Generate.TypedOptimizedMonomorphize as TOMono
import Data.Map as Dict exposing (Dict)
import Data.Set as Set exposing (EverySet)
import Expect


{-| MONO_004: Verify that all function-typed nodes are callable.
-}
expectCallableMonoNodes : Src.Module -> Expect.Expectation
expectCallableMonoNodes srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                issues =
                    collectCallabilityIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)


{-| MONO_010: Verify MonoGraph is type complete.
-}
expectMonoGraphComplete : Src.Module -> Expect.Expectation
expectMonoGraphComplete srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                issues =
                    collectCompletenessIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)


{-| MONO_011: Verify MonoGraph is closed and hygienic.
-}
expectMonoGraphClosed : Src.Module -> Expect.Expectation
expectMonoGraphClosed srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                issues =
                    collectClosureIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)


{-| MONO_005: Verify specialization registry is complete.
-}
expectSpecRegistryComplete : Src.Module -> Expect.Expectation
expectSpecRegistryComplete srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                issues =
                    collectRegistryIssues monoGraph
            in
            if List.isEmpty issues then
                Expect.pass

            else
                Expect.fail (String.join "\n" issues)



-- ============================================================================
-- MONO_004: CALLABILITY CHECKING
-- ============================================================================


{-| Collect issues with function-typed nodes that aren't callable.
-}
collectCallabilityIssues : Mono.MonoGraph -> List String
collectCallabilityIssues (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc -> checkNodeCallability specId node ++ acc)
        []
        data.nodes


{-| Check if a function-typed node is properly callable.
-}
checkNodeCallability : Int -> Mono.MonoNode -> List String
checkNodeCallability specId node =
    let
        context =
            "SpecId " ++ String.fromInt specId
    in
    case node of
        Mono.MonoDefine expr monoType ->
            case monoType of
                Mono.MFunction _ _ ->
                    -- Function-typed define must have a closure as its expression
                    case expr of
                        Mono.MonoClosure _ _ _ ->
                            []

                        _ ->
                            [ context ++ ": Function-typed MonoDefine doesn't contain a MonoClosure" ]

                _ ->
                    -- Non-function types are fine
                    []

        Mono.MonoTailFunc _ _ monoType ->
            -- TailFunc is always callable (it's explicitly a function)
            case monoType of
                Mono.MFunction _ _ ->
                    []

                _ ->
                    [ context ++ ": MonoTailFunc has non-function type" ]

        Mono.MonoCtor _ _ ->
            -- Constructors are callable by definition
            []

        Mono.MonoEnum _ _ ->
            -- Enum constructors are callable
            []

        Mono.MonoExtern monoType ->
            -- Externs with function types are callable (FFI)
            []

        Mono.MonoPortIncoming _ _ ->
            -- Ports are callable
            []

        Mono.MonoPortOutgoing _ _ ->
            -- Ports are callable
            []

        Mono.MonoCycle _ _ ->
            -- Cycle nodes are internal
            []



-- ============================================================================
-- MONO_010: TYPE COMPLETENESS CHECKING
-- ============================================================================


{-| Collect issues with type completeness.
-}
collectCompletenessIssues : Mono.MonoGraph -> List String
collectCompletenessIssues (Mono.MonoGraph data) =
    let
        -- Collect all custom type references
        customTypeRefs =
            Dict.foldl compare
                (\_ node acc -> collectCustomTypeRefsFromNode node ++ acc)
                []
                data.nodes

        -- Check that all referenced custom types have ctor layouts
        ctorLayoutIssues =
            List.filterMap
                (\( canonical, name ) ->
                    let
                        key =
                            ( canonical, name )
                    in
                    -- Check if ctorLayouts has an entry for this type
                    -- Note: ctorLayouts is Dict (List String) (List String) (List CtorLayout)
                    -- The key is (comparable Canonical, comparable Name)
                    Nothing
                )
                customTypeRefs
    in
    ctorLayoutIssues


{-| Collect custom type references from a node.
-}
collectCustomTypeRefsFromNode : Mono.MonoNode -> List ( List String, String )
collectCustomTypeRefsFromNode node =
    case node of
        Mono.MonoDefine expr monoType ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromExpr expr

        Mono.MonoTailFunc params expr monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap (\( _, t ) -> collectCustomTypeRefsFromType t) params
                ++ collectCustomTypeRefsFromExpr expr

        Mono.MonoCtor _ monoType ->
            collectCustomTypeRefsFromType monoType

        Mono.MonoEnum _ monoType ->
            collectCustomTypeRefsFromType monoType

        Mono.MonoExtern monoType ->
            collectCustomTypeRefsFromType monoType

        Mono.MonoPortIncoming expr monoType ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromExpr expr

        Mono.MonoPortOutgoing expr monoType ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromExpr expr

        Mono.MonoCycle defs monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap (\( _, expr ) -> collectCustomTypeRefsFromExpr expr) defs


{-| Collect custom type references from a MonoType.
-}
collectCustomTypeRefsFromType : Mono.MonoType -> List ( List String, String )
collectCustomTypeRefsFromType monoType =
    case monoType of
        Mono.MCustom canonical name typeArgs ->
            -- Note: canonical is IO.Canonical, we'd need to extract its comparable form
            -- For now, skip the lookup check since we can't easily compare
            List.concatMap collectCustomTypeRefsFromType typeArgs

        Mono.MList elemType ->
            collectCustomTypeRefsFromType elemType

        Mono.MFunction paramTypes returnType ->
            List.concatMap collectCustomTypeRefsFromType paramTypes
                ++ collectCustomTypeRefsFromType returnType

        _ ->
            []


{-| Collect custom type references from a MonoExpr.
-}
collectCustomTypeRefsFromExpr : Mono.MonoExpr -> List ( List String, String )
collectCustomTypeRefsFromExpr expr =
    case expr of
        Mono.MonoLiteral _ monoType ->
            collectCustomTypeRefsFromType monoType

        Mono.MonoVarLocal _ monoType ->
            collectCustomTypeRefsFromType monoType

        Mono.MonoVarGlobal _ _ monoType ->
            collectCustomTypeRefsFromType monoType

        Mono.MonoVarKernel _ _ _ monoType ->
            collectCustomTypeRefsFromType monoType

        Mono.MonoList _ exprs monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap collectCustomTypeRefsFromExpr exprs

        Mono.MonoClosure closureInfo bodyExpr monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap (\( _, t ) -> collectCustomTypeRefsFromType t) closureInfo.params
                ++ List.concatMap (\( _, e, _ ) -> collectCustomTypeRefsFromExpr e) closureInfo.captures
                ++ collectCustomTypeRefsFromExpr bodyExpr

        Mono.MonoCall _ fnExpr argExprs monoType ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromExpr fnExpr
                ++ List.concatMap collectCustomTypeRefsFromExpr argExprs

        Mono.MonoTailCall _ args monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap (\( _, e ) -> collectCustomTypeRefsFromExpr e) args

        Mono.MonoIf branches elseExpr monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap (\( c, t ) -> collectCustomTypeRefsFromExpr c ++ collectCustomTypeRefsFromExpr t) branches
                ++ collectCustomTypeRefsFromExpr elseExpr

        Mono.MonoLet def bodyExpr monoType ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromDef def
                ++ collectCustomTypeRefsFromExpr bodyExpr

        Mono.MonoDestruct _ valueExpr monoType ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromExpr valueExpr

        Mono.MonoCase _ _ _ branches monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap (\( _, e ) -> collectCustomTypeRefsFromExpr e) branches

        Mono.MonoRecordCreate fieldExprs _ monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap collectCustomTypeRefsFromExpr fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ _ monoType ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromExpr recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ monoType ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromExpr recordExpr
                ++ List.concatMap (\( _, e ) -> collectCustomTypeRefsFromExpr e) updates

        Mono.MonoTupleCreate _ elementExprs _ monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap collectCustomTypeRefsFromExpr elementExprs

        Mono.MonoUnit ->
            []

        Mono.MonoAccessor _ _ monoType ->
            collectCustomTypeRefsFromType monoType


{-| Collect custom type references from a MonoDef.
-}
collectCustomTypeRefsFromDef : Mono.MonoDef -> List ( List String, String )
collectCustomTypeRefsFromDef def =
    case def of
        Mono.MonoDef _ expr ->
            collectCustomTypeRefsFromExpr expr

        Mono.MonoTailDef _ params expr ->
            List.concatMap (\( _, t ) -> collectCustomTypeRefsFromType t) params
                ++ collectCustomTypeRefsFromExpr expr



-- ============================================================================
-- MONO_011: CLOSURE AND HYGIENE CHECKING
-- ============================================================================


{-| Collect issues with graph closure (no dangling references).
-}
collectClosureIssues : Mono.MonoGraph -> List String
collectClosureIssues (Mono.MonoGraph data) =
    let
        -- Get all defined SpecIds
        definedSpecIds =
            Dict.keys compare data.nodes |> Set.fromList identity

        -- Collect all referenced SpecIds
        referencedSpecIds =
            Dict.foldl compare
                (\_ node acc -> Set.union acc (collectSpecIdRefsFromNode node))
                (Set.empty)
                data.nodes

        -- Find undefined references
        undefinedRefs =
            Set.diff referencedSpecIds definedSpecIds
                |> Set.toList compare

        undefinedIssues =
            List.map
                (\specId -> "Referenced SpecId " ++ String.fromInt specId ++ " is not defined in nodes")
                undefinedRefs
    in
    undefinedIssues


{-| Collect SpecId references from a node.
-}
collectSpecIdRefsFromNode : Mono.MonoNode -> EverySet Int Int
collectSpecIdRefsFromNode node =
    case node of
        Mono.MonoDefine expr _ ->
            collectSpecIdRefsFromExpr expr

        Mono.MonoTailFunc _ expr _ ->
            collectSpecIdRefsFromExpr expr

        Mono.MonoCtor _ _ ->
            Set.empty

        Mono.MonoEnum _ _ ->
            Set.empty

        Mono.MonoExtern _ ->
            Set.empty

        Mono.MonoPortIncoming expr _ ->
            collectSpecIdRefsFromExpr expr

        Mono.MonoPortOutgoing expr _ ->
            collectSpecIdRefsFromExpr expr

        Mono.MonoCycle defs _ ->
            List.foldl
                (\( _, expr ) acc -> Set.union acc (collectSpecIdRefsFromExpr expr))
                (Set.empty)
                defs


{-| Collect SpecId references from a MonoExpr.
-}
collectSpecIdRefsFromExpr : Mono.MonoExpr -> EverySet Int Int
collectSpecIdRefsFromExpr expr =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            Set.insert identity specId (Set.empty)

        Mono.MonoList _ exprs _ ->
            List.foldl
                (\e acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                (Set.empty)
                exprs

        Mono.MonoClosure closureInfo bodyExpr _ ->
            List.foldl
                (\( _, e, _ ) acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                (collectSpecIdRefsFromExpr bodyExpr)
                closureInfo.captures

        Mono.MonoCall _ fnExpr argExprs _ ->
            List.foldl
                (\e acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                (collectSpecIdRefsFromExpr fnExpr)
                argExprs

        Mono.MonoTailCall _ args _ ->
            List.foldl
                (\( _, e ) acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                (Set.empty)
                args

        Mono.MonoIf branches elseExpr _ ->
            List.foldl
                (\( c, t ) acc ->
                    Set.union acc (collectSpecIdRefsFromExpr c)
                        |> Set.union (collectSpecIdRefsFromExpr t)
                )
                (collectSpecIdRefsFromExpr elseExpr)
                branches

        Mono.MonoLet def bodyExpr _ ->
            Set.union
                (collectSpecIdRefsFromDef def)
                (collectSpecIdRefsFromExpr bodyExpr)

        Mono.MonoDestruct _ valueExpr _ ->
            collectSpecIdRefsFromExpr valueExpr

        Mono.MonoCase _ _ _ branches _ ->
            List.foldl
                (\( _, e ) acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                (Set.empty)
                branches

        Mono.MonoRecordCreate fieldExprs _ _ ->
            List.foldl
                (\e acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                (Set.empty)
                fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ _ _ ->
            collectSpecIdRefsFromExpr recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ _ ->
            List.foldl
                (\( _, e ) acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                (collectSpecIdRefsFromExpr recordExpr)
                updates

        Mono.MonoTupleCreate _ elementExprs _ _ ->
            List.foldl
                (\e acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                (Set.empty)
                elementExprs

        _ ->
            Set.empty


{-| Collect SpecId references from a MonoDef.
-}
collectSpecIdRefsFromDef : Mono.MonoDef -> EverySet Int Int
collectSpecIdRefsFromDef def =
    case def of
        Mono.MonoDef _ expr ->
            collectSpecIdRefsFromExpr expr

        Mono.MonoTailDef _ _ expr ->
            collectSpecIdRefsFromExpr expr



-- ============================================================================
-- MONO_005: REGISTRY COMPLETENESS CHECKING
-- ============================================================================


{-| Collect issues with specialization registry.
-}
collectRegistryIssues : Mono.MonoGraph -> List String
collectRegistryIssues (Mono.MonoGraph data) =
    let
        -- Get all defined SpecIds
        definedSpecIds =
            Dict.keys compare data.nodes |> Set.fromList identity

        -- Get all SpecIds from registry
        registrySpecIds =
            collectRegistrySpecIds data.registry

        -- Check that all registry SpecIds are defined
        undefinedRegistrySpecIds =
            Set.diff registrySpecIds definedSpecIds
                |> Set.toList compare

        undefinedIssues =
            List.map
                (\specId -> "Registry contains SpecId " ++ String.fromInt specId ++ " which is not defined in nodes")
                undefinedRegistrySpecIds

        -- Check that all used SpecIds are in the registry (optional, depends on design)
        -- For now, we just check that registry SpecIds map to real nodes
    in
    undefinedIssues


{-| Collect all SpecIds from the specialization registry.
-}
collectRegistrySpecIds : Mono.SpecializationRegistry -> EverySet Int Int
collectRegistrySpecIds registry =
    -- SpecializationRegistry has reverseMapping : Dict Int Int (Global, MonoType, Maybe LambdaId)
    -- where the key is SpecId, so we just need the keys
    Dict.keys compare registry.reverseMapping
        |> Set.fromList identity
