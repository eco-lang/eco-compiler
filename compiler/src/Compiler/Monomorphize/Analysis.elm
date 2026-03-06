module Compiler.Monomorphize.Analysis exposing
    ( collectAllCustomTypes
    , lookupUnion
    )

{-| Analysis passes for monomorphization.

This module handles:

  - Dependency collection (finding global references)
  - Custom type collection (finding all MCustom types)
  - Union type lookup


# Dependency Collection


# Custom Type Collection

@docs collectAllCustomTypes


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

        Mono.MTuple elementTypes ->
            List.foldl collectCustomTypesFromMonoType acc elementTypes

        Mono.MRecord fields ->
            List.foldl collectCustomTypesFromMonoType acc (Dict.values compare fields)

        Mono.MFunction argTypes resultType ->
            List.foldl collectCustomTypesFromMonoType
                (collectCustomTypesFromMonoType resultType acc)
                argTypes

        _ ->
            acc


{-| Collect custom types from a MonoPath.
The path contains intermediate container types that need their shapes computed.
-}
collectCustomTypesFromPath : Mono.MonoPath -> EverySet.EverySet (List String) Mono.MonoType -> EverySet.EverySet (List String) Mono.MonoType
collectCustomTypesFromPath path acc =
    case path of
        Mono.MonoRoot _ rootType ->
            collectCustomTypesFromMonoType rootType acc

        Mono.MonoIndex _ _ resultType subPath ->
            collectCustomTypesFromPath subPath
                (collectCustomTypesFromMonoType resultType acc)

        Mono.MonoField _ resultType subPath ->
            collectCustomTypesFromPath subPath
                (collectCustomTypesFromMonoType resultType acc)

        Mono.MonoUnbox resultType subPath ->
            collectCustomTypesFromPath subPath
                (collectCustomTypesFromMonoType resultType acc)


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

        Mono.MonoCall _ func args _ _ ->
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

        Mono.MonoDestruct (Mono.MonoDestructor _ path destructType) body _ ->
            collectCustomTypesFromExpr body
                (collectCustomTypesFromPath path
                    (collectCustomTypesFromMonoType destructType accWithType)
                )

        Mono.MonoCase _ _ decider jumps _ ->
            let
                deciderAcc =
                    collectCustomTypesFromDecider decider accWithType
            in
            List.foldl (\( _, e ) a -> collectCustomTypesFromExpr e a) deciderAcc jumps

        Mono.MonoRecordCreate fields monoType ->
            let
                fieldTypes =
                    case monoType of
                        Mono.MRecord fieldDict ->
                            Dict.values compare fieldDict

                        _ ->
                            []

                fieldAcc =
                    List.foldl collectCustomTypesFromMonoType accWithType fieldTypes
            in
            List.foldl (\( _, e ) a -> collectCustomTypesFromExpr e a) fieldAcc fields

        Mono.MonoRecordAccess record _ _ ->
            collectCustomTypesFromExpr record accWithType

        Mono.MonoRecordUpdate record updates monoType ->
            let
                fieldTypes =
                    case monoType of
                        Mono.MRecord fields ->
                            Dict.values compare fields

                        _ ->
                            []

                fieldAcc =
                    List.foldl collectCustomTypesFromMonoType accWithType fieldTypes
            in
            List.foldl (\( _, e ) a -> collectCustomTypesFromExpr e a)
                (collectCustomTypesFromExpr record fieldAcc)
                updates

        Mono.MonoTupleCreate _ exprs monoType ->
            let
                elemTypes =
                    case monoType of
                        Mono.MTuple types ->
                            types

                        _ ->
                            []

                elemAcc =
                    List.foldl collectCustomTypesFromMonoType accWithType elemTypes
            in
            List.foldl collectCustomTypesFromExpr elemAcc exprs

        Mono.MonoUnit ->
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

                Mono.MonoCtor shape monoType ->
                    List.foldl collectCustomTypesFromMonoType
                        (collectCustomTypesFromMonoType monoType acc)
                        shape.fieldTypes

                Mono.MonoEnum _ monoType ->
                    collectCustomTypesFromMonoType monoType acc

                Mono.MonoExtern monoType ->
                    collectCustomTypesFromMonoType monoType acc

                Mono.MonoManagerLeaf _ monoType ->
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
