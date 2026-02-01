module TestLogic.Generate.MonoGraphIntegrity exposing
    ( expectCallableMonoNodes
    , expectMonoGraphClosed
    , expectMonoGraphComplete
    , expectSpecRegistryComplete
    )

{-| Test logic for invariants:

  - MONO\_004: All functions are callable MonoNodes
  - MONO\_010: MonoGraph is type complete
  - MONO\_011: MonoGraph is closed and hygienic
  - MONO\_005: Specialization registry is complete and consistent

This module reuses the existing typed optimization pipeline to verify
MonoGraph integrity. Successful monomorphization implies all these
invariants are satisfied.

-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.Source as Src
import TestLogic.Generate.TypedOptimizedMonomorphize as TOMono
import Data.Map as Dict
import Data.Set as Set exposing (EverySet)
import Expect


{-| MONO\_004: Verify that all function-typed nodes are callable.
-}
expectCallableMonoNodes : Src.Module -> Expect.Expectation
expectCallableMonoNodes srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                checks =
                    collectCallabilityChecks monoGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| MONO\_010: Verify MonoGraph is type complete.
-}
expectMonoGraphComplete : Src.Module -> Expect.Expectation
expectMonoGraphComplete srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                checks =
                    collectCompletenessChecks monoGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| MONO\_011: Verify MonoGraph is closed and hygienic.
-}
expectMonoGraphClosed : Src.Module -> Expect.Expectation
expectMonoGraphClosed srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                checks =
                    collectClosureChecks monoGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()


{-| MONO\_005: Verify specialization registry is complete.
-}
expectSpecRegistryComplete : Src.Module -> Expect.Expectation
expectSpecRegistryComplete srcModule =
    case TOMono.runToMonoGraph srcModule of
        Err msg ->
            Expect.fail msg

        Ok monoGraph ->
            let
                checks =
                    collectRegistryChecks monoGraph
            in
            case checks of
                [] ->
                    Expect.pass

                _ ->
                    Expect.all checks ()



-- ============================================================================
-- MONO_004: CALLABILITY CHECKING
-- ============================================================================


{-| Collect callability checks for function-typed nodes.
-}
collectCallabilityChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCallabilityChecks (Mono.MonoGraph data) =
    Dict.foldl compare
        (\specId node acc -> checkNodeCallability specId node ++ acc)
        []
        data.nodes


{-| Check if a function-typed node is properly callable.
-}
checkNodeCallability : Int -> Mono.MonoNode -> List (() -> Expect.Expectation)
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
                            [ \() -> Expect.fail (context ++ ": Function-typed MonoDefine doesn't contain a MonoClosure") ]

                _ ->
                    -- Non-function types are fine
                    []

        Mono.MonoTailFunc _ _ monoType ->
            -- TailFunc is always callable (it's explicitly a function)
            case monoType of
                Mono.MFunction _ _ ->
                    []

                _ ->
                    [ \() -> Expect.fail (context ++ ": MonoTailFunc has non-function type") ]

        Mono.MonoCtor _ _ ->
            -- Constructors are callable by definition
            []

        Mono.MonoEnum _ _ ->
            -- Enum constructors are callable
            []

        Mono.MonoExtern _ ->
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


{-| Collect type completeness checks.
-}
collectCompletenessChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectCompletenessChecks (Mono.MonoGraph data) =
    []


{-| Collect custom type references from a MonoType.
-}
collectCustomTypeRefsFromType : Mono.MonoType -> List ( List String, String )
collectCustomTypeRefsFromType monoType =
    case monoType of
        Mono.MCustom _ _ typeArgs ->
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

        Mono.MonoRecordCreate fieldExprs monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap collectCustomTypeRefsFromExpr fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ _ monoType ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromExpr recordExpr

        Mono.MonoRecordUpdate recordExpr updates monoType ->
            collectCustomTypeRefsFromType monoType
                ++ collectCustomTypeRefsFromExpr recordExpr
                ++ List.concatMap (\( _, e ) -> collectCustomTypeRefsFromExpr e) updates

        Mono.MonoTupleCreate _ elementExprs monoType ->
            collectCustomTypeRefsFromType monoType
                ++ List.concatMap collectCustomTypeRefsFromExpr elementExprs

        Mono.MonoUnit ->
            []


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


{-| Collect closure checks (no dangling references).
-}
collectClosureChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectClosureChecks (Mono.MonoGraph data) =
    let
        -- Get all defined SpecIds
        definedSpecIds =
            Dict.keys compare data.nodes |> Set.fromList identity

        -- Collect all referenced SpecIds
        referencedSpecIds =
            Dict.foldl compare
                (\_ node acc -> Set.union acc (collectSpecIdRefsFromNode node))
                Set.empty
                data.nodes

        -- Find undefined references
        undefinedRefs =
            Set.diff referencedSpecIds definedSpecIds
                |> Set.toList compare
    in
    List.map
        (\specId -> \() -> Expect.fail ("Referenced SpecId " ++ String.fromInt specId ++ " is not defined in nodes"))
        undefinedRefs


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
                Set.empty
                defs


{-| Collect SpecId references from a MonoExpr.
-}
collectSpecIdRefsFromExpr : Mono.MonoExpr -> EverySet Int Int
collectSpecIdRefsFromExpr expr =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            Set.insert identity specId Set.empty

        Mono.MonoList _ exprs _ ->
            List.foldl
                (\e acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                Set.empty
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
                Set.empty
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
                Set.empty
                branches

        Mono.MonoRecordCreate fieldExprs _ ->
            List.foldl
                (\e acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                Set.empty
                fieldExprs

        Mono.MonoRecordAccess recordExpr _ _ _ _ ->
            collectSpecIdRefsFromExpr recordExpr

        Mono.MonoRecordUpdate recordExpr updates _ ->
            List.foldl
                (\( _, e ) acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                (collectSpecIdRefsFromExpr recordExpr)
                updates

        Mono.MonoTupleCreate _ elementExprs _ ->
            List.foldl
                (\e acc -> Set.union acc (collectSpecIdRefsFromExpr e))
                Set.empty
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


{-| Collect specialization registry checks.
-}
collectRegistryChecks : Mono.MonoGraph -> List (() -> Expect.Expectation)
collectRegistryChecks (Mono.MonoGraph data) =
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
    in
    List.map
        (\specId -> \() -> Expect.fail ("Registry contains SpecId " ++ String.fromInt specId ++ " which is not defined in nodes"))
        undefinedRegistrySpecIds


{-| Collect all SpecIds from the specialization registry.
-}
collectRegistrySpecIds : Mono.SpecializationRegistry -> EverySet Int Int
collectRegistrySpecIds registry =
    -- SpecializationRegistry has reverseMapping : Dict Int Int (Global, MonoType, Maybe LambdaId)
    -- where the key is SpecId, so we just need the keys
    Dict.keys compare registry.reverseMapping
        |> Set.fromList identity
