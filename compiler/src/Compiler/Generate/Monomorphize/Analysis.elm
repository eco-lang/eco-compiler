module Compiler.Generate.Monomorphize.Analysis exposing
    ( collectDepsHelp
    , collectDeciderDeps
    , collectCustomTypesFromMonoType
    , collectCustomTypesFromExpr
    , collectCustomTypesFromDecider
    , collectAllCustomTypes
    , lookupUnion
    )

{-| Analysis passes for monomorphization.

This module handles:

  - Dependency collection (finding global references)
  - Custom type collection (finding all MCustom types)
  - Union type lookup


# Dependency Collection

@docs collectDepsHelp, collectDeciderDeps


# Custom Type Collection

@docs collectCustomTypesFromMonoType, collectCustomTypesFromExpr, collectCustomTypesFromDecider, collectAllCustomTypes


# Union Type Lookup

@docs lookupUnion

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Data.Map as Dict exposing (Dict)
import Data.Set as EverySet exposing (EverySet)
import System.TypeCheck.IO as IO



-- ========== DEPENDENCY COLLECTION ==========


{-| Collect all global dependencies referenced by an expression.
-}
collectDepsHelp : Mono.MonoExpr -> EverySet Int Int -> EverySet Int Int
collectDepsHelp expr deps =
    case expr of
        Mono.MonoVarGlobal _ specId _ ->
            EverySet.insert identity specId deps

        Mono.MonoList _ exprs _ ->
            List.foldl collectDepsHelp deps exprs

        Mono.MonoClosure _ body _ ->
            collectDepsHelp body deps

        Mono.MonoCall _ func args _ ->
            List.foldl collectDepsHelp (collectDepsHelp func deps) args

        Mono.MonoTailCall _ namedExprs _ ->
            List.foldl (\( _, e ) d -> collectDepsHelp e d) deps namedExprs

        Mono.MonoIf branches final _ ->
            let
                branchDeps =
                    List.foldl
                        (\( cond, body ) d ->
                            collectDepsHelp body (collectDepsHelp cond d)
                        )
                        deps
                        branches
            in
            collectDepsHelp final branchDeps

        Mono.MonoLet def body _ ->
            let
                defDeps =
                    case def of
                        Mono.MonoDef _ e ->
                            collectDepsHelp e deps

                        Mono.MonoTailDef _ _ e ->
                            collectDepsHelp e deps
            in
            collectDepsHelp body defDeps

        Mono.MonoDestruct _ body _ ->
            collectDepsHelp body deps

        Mono.MonoCase _ _ decider jumps _ ->
            let
                deciderDeps =
                    collectDeciderDeps decider deps
            in
            List.foldl (\( _, e ) d -> collectDepsHelp e d) deciderDeps jumps

        Mono.MonoRecordCreate exprs _ _ ->
            List.foldl collectDepsHelp deps exprs

        Mono.MonoRecordAccess record _ _ _ _ ->
            collectDepsHelp record deps

        Mono.MonoRecordUpdate record updates _ _ ->
            List.foldl (\( _, e ) d -> collectDepsHelp e d) (collectDepsHelp record deps) updates

        Mono.MonoTupleCreate _ exprs _ _ ->
            List.foldl collectDepsHelp deps exprs

        _ ->
            deps


{-| Collect dependencies from a pattern match decider tree.
-}
collectDeciderDeps : Mono.Decider Mono.MonoChoice -> EverySet Int Int -> EverySet Int Int
collectDeciderDeps decider deps =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectDepsHelp expr deps

                Mono.Jump _ ->
                    deps

        Mono.Chain _ success failure ->
            collectDeciderDeps failure (collectDeciderDeps success deps)

        Mono.FanOut _ edges fallback ->
            let
                edgeDeps =
                    List.foldl (\( _, d ) acc -> collectDeciderDeps d acc) deps edges
            in
            collectDeciderDeps fallback edgeDeps



-- ========== CUSTOM TYPE COLLECTION ==========


{-| Collect all MCustom types from a MonoType, recursively traversing nested structures.
-}
collectCustomTypesFromMonoType : Mono.MonoType -> EverySet (List String) Mono.MonoType -> EverySet (List String) Mono.MonoType
collectCustomTypesFromMonoType monoType acc =
    case monoType of
        Mono.MCustom _ _ args ->
            -- Add this MCustom, then recurse into type args
            List.foldl collectCustomTypesFromMonoType
                (EverySet.insert Mono.toComparableMonoType monoType acc)
                args

        Mono.MList elem ->
            collectCustomTypesFromMonoType elem acc

        Mono.MTuple layout ->
            List.foldl (\( ty, _ ) -> collectCustomTypesFromMonoType ty) acc layout.elements

        Mono.MRecord layout ->
            List.foldl (\field -> collectCustomTypesFromMonoType field.monoType) acc layout.fields

        Mono.MFunction argTypes resultType ->
            List.foldl collectCustomTypesFromMonoType
                (collectCustomTypesFromMonoType resultType acc)
                argTypes

        _ ->
            acc


{-| Collect all MCustom types from a MonoExpr and its sub-expressions.
-}
collectCustomTypesFromExpr : Mono.MonoExpr -> EverySet (List String) Mono.MonoType -> EverySet (List String) Mono.MonoType
collectCustomTypesFromExpr expr acc =
    let
        accWithType =
            collectCustomTypesFromMonoType (Mono.typeOf expr) acc
    in
    case expr of
        Mono.MonoLiteral _ _ ->
            accWithType

        Mono.MonoVarLocal _ _ ->
            accWithType

        Mono.MonoVarGlobal _ _ _ ->
            accWithType

        Mono.MonoVarKernel _ _ _ _ ->
            accWithType

        Mono.MonoList _ exprs _ ->
            List.foldl collectCustomTypesFromExpr accWithType exprs

        Mono.MonoClosure closureInfo body _ ->
            let
                accWithCaptures =
                    List.foldl
                        (\( _, captureExpr, _ ) a -> collectCustomTypesFromExpr captureExpr a)
                        accWithType
                        closureInfo.captures

                accWithParams =
                    List.foldl
                        (\( _, paramType ) a -> collectCustomTypesFromMonoType paramType a)
                        accWithCaptures
                        closureInfo.params
            in
            collectCustomTypesFromExpr body accWithParams

        Mono.MonoCall _ func args _ ->
            List.foldl collectCustomTypesFromExpr
                (collectCustomTypesFromExpr func accWithType)
                args

        Mono.MonoTailCall _ namedExprs _ ->
            List.foldl (\( _, e ) a -> collectCustomTypesFromExpr e a) accWithType namedExprs

        Mono.MonoIf branches final _ ->
            let
                branchAcc =
                    List.foldl
                        (\( cond, body ) a ->
                            collectCustomTypesFromExpr body (collectCustomTypesFromExpr cond a)
                        )
                        accWithType
                        branches
            in
            collectCustomTypesFromExpr final branchAcc

        Mono.MonoLet def body _ ->
            let
                defAcc =
                    case def of
                        Mono.MonoDef _ e ->
                            collectCustomTypesFromExpr e accWithType

                        Mono.MonoTailDef _ _ e ->
                            collectCustomTypesFromExpr e accWithType
            in
            collectCustomTypesFromExpr body defAcc

        Mono.MonoDestruct (Mono.MonoDestructor _ _ destructType) body _ ->
            collectCustomTypesFromExpr body
                (collectCustomTypesFromMonoType destructType accWithType)

        Mono.MonoCase _ _ decider jumps _ ->
            let
                deciderAcc =
                    collectCustomTypesFromDecider decider accWithType
            in
            List.foldl (\( _, e ) a -> collectCustomTypesFromExpr e a) deciderAcc jumps

        Mono.MonoRecordCreate exprs layout _ ->
            let
                layoutAcc =
                    List.foldl (\field a -> collectCustomTypesFromMonoType field.monoType a) accWithType layout.fields
            in
            List.foldl collectCustomTypesFromExpr layoutAcc exprs

        Mono.MonoRecordAccess record _ _ _ _ ->
            collectCustomTypesFromExpr record accWithType

        Mono.MonoRecordUpdate record updates layout _ ->
            let
                layoutAcc =
                    List.foldl (\field a -> collectCustomTypesFromMonoType field.monoType a) accWithType layout.fields
            in
            List.foldl (\( _, e ) a -> collectCustomTypesFromExpr e a)
                (collectCustomTypesFromExpr record layoutAcc)
                updates

        Mono.MonoTupleCreate _ exprs layout _ ->
            let
                layoutAcc =
                    List.foldl (\( ty, _ ) a -> collectCustomTypesFromMonoType ty a) accWithType layout.elements
            in
            List.foldl collectCustomTypesFromExpr layoutAcc exprs

        Mono.MonoUnit ->
            accWithType

        Mono.MonoAccessor _ _ _ ->
            accWithType


{-| Collect custom types from a decision tree.
-}
collectCustomTypesFromDecider : Mono.Decider Mono.MonoChoice -> EverySet (List String) Mono.MonoType -> EverySet (List String) Mono.MonoType
collectCustomTypesFromDecider decider acc =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectCustomTypesFromExpr expr acc

                Mono.Jump _ ->
                    acc

        Mono.Chain _ success failure ->
            collectCustomTypesFromDecider failure (collectCustomTypesFromDecider success acc)

        Mono.FanOut _ edges fallback ->
            let
                edgeAcc =
                    List.foldl (\( _, d ) a -> collectCustomTypesFromDecider d a) acc edges
            in
            collectCustomTypesFromDecider fallback edgeAcc


{-| Collect all MCustom types from all nodes in the graph.
-}
collectAllCustomTypes : Dict Int Int Mono.MonoNode -> EverySet (List String) Mono.MonoType
collectAllCustomTypes nodes =
    Dict.foldl compare
        (\_ node acc ->
            case node of
                Mono.MonoDefine expr monoType ->
                    collectCustomTypesFromExpr expr
                        (collectCustomTypesFromMonoType monoType acc)

                Mono.MonoTailFunc params expr monoType ->
                    let
                        accWithParams =
                            List.foldl (\( _, ty ) a -> collectCustomTypesFromMonoType ty a) acc params
                    in
                    collectCustomTypesFromExpr expr
                        (collectCustomTypesFromMonoType monoType accWithParams)

                Mono.MonoCtor layout monoType ->
                    List.foldl (\field a -> collectCustomTypesFromMonoType field.monoType a)
                        (collectCustomTypesFromMonoType monoType acc)
                        layout.fields

                Mono.MonoEnum _ monoType ->
                    collectCustomTypesFromMonoType monoType acc

                Mono.MonoExtern monoType ->
                    collectCustomTypesFromMonoType monoType acc

                Mono.MonoPortIncoming expr monoType ->
                    collectCustomTypesFromExpr expr
                        (collectCustomTypesFromMonoType monoType acc)

                Mono.MonoPortOutgoing expr monoType ->
                    collectCustomTypesFromExpr expr
                        (collectCustomTypesFromMonoType monoType acc)

                Mono.MonoCycle defs monoType ->
                    List.foldl (\( _, e ) a -> collectCustomTypesFromExpr e a)
                        (collectCustomTypesFromMonoType monoType acc)
                        defs
        )
        EverySet.empty
        nodes



-- ========== UNION LOOKUP ==========


{-| Look up a union in GlobalTypeEnv by module and name.
-}
lookupUnion : TypeEnv.GlobalTypeEnv -> IO.Canonical -> Name -> Maybe Can.Union
lookupUnion typeEnv canonical typeName =
    case Dict.get ModuleName.toComparableCanonical canonical typeEnv of
        Nothing ->
            Nothing

        Just moduleEnv ->
            Dict.get identity typeName moduleEnv.unions
