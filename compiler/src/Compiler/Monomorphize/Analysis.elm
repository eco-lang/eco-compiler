module Compiler.Monomorphize.Analysis exposing
    ( computeCtorShapesForGraph
    , lookupUnion
    )

{-| Analysis passes for monomorphization.

This module handles:

  - Dependency collection (finding global references)
  - Custom type collection (finding all MCustom types)
  - Union type lookup
  - Ctor shape computation for the graph


# Dependency Collection


# Custom Type Collection


# Ctor Shape Computation

@docs computeCtorShapesForGraph


# Union Type Lookup

@docs lookupUnion

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Data.Index as Index
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Monomorphize.State exposing (Substitution)
import Compiler.Monomorphize.TypeSubst as TypeSubst
import Data.Map
import Data.Set as EverySet exposing (EverySet)
import Dict
import System.TypeCheck.IO as IO
import Utils.Crash



-- ========== CUSTOM TYPE COLLECTION ==========


{-| Collect all MCustom types from a MonoType, recursively traversing nested structures.
-}
collectCustomTypesFromMonoType : Mono.MonoType -> EverySet String Mono.MonoType -> EverySet String Mono.MonoType
collectCustomTypesFromMonoType monoType acc =
    case monoType of
        Mono.MCustom _ _ args ->
            -- Skip if already in set (avoids redundant toComparableMonoType calls)
            if EverySet.member Mono.toComparableMonoType monoType acc then
                acc

            else
                -- Add this MCustom, then recurse into type args
                List.foldl collectCustomTypesFromMonoType
                    (EverySet.insert Mono.toComparableMonoType monoType acc)
                    args

        Mono.MList elem ->
            collectCustomTypesFromMonoType elem acc

        Mono.MTuple elementTypes ->
            List.foldl collectCustomTypesFromMonoType acc elementTypes

        Mono.MRecord fields ->
            Dict.foldl (\_ t a -> collectCustomTypesFromMonoType t a) acc fields

        Mono.MFunction argTypes resultType ->
            List.foldl collectCustomTypesFromMonoType
                (collectCustomTypesFromMonoType resultType acc)
                argTypes

        _ ->
            acc


{-| Collect custom types from a MonoPath.
The path contains intermediate container types that need their shapes computed.
-}
collectCustomTypesFromPath : Mono.MonoPath -> EverySet.EverySet String Mono.MonoType -> EverySet.EverySet String Mono.MonoType
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
collectCustomTypesFromExpr : Mono.MonoExpr -> EverySet String Mono.MonoType -> EverySet String Mono.MonoType
collectCustomTypesFromExpr expr acc =
    let
        exprType =
            Mono.typeOf expr

        accWithType =
            case exprType of
                Mono.MInt ->
                    acc

                Mono.MFloat ->
                    acc

                Mono.MBool ->
                    acc

                Mono.MChar ->
                    acc

                Mono.MString ->
                    acc

                Mono.MUnit ->
                    acc

                _ ->
                    collectCustomTypesFromMonoType exprType acc
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
                fieldAcc =
                    case monoType of
                        Mono.MRecord fieldDict ->
                            Dict.foldl (\_ t a -> collectCustomTypesFromMonoType t a) accWithType fieldDict

                        _ ->
                            accWithType
            in
            List.foldl (\( _, e ) a -> collectCustomTypesFromExpr e a) fieldAcc fields

        Mono.MonoRecordAccess record _ _ ->
            collectCustomTypesFromExpr record accWithType

        Mono.MonoRecordUpdate record updates monoType ->
            let
                fieldAcc =
                    case monoType of
                        Mono.MRecord fields ->
                            Dict.foldl (\_ t a -> collectCustomTypesFromMonoType t a) accWithType fields

                        _ ->
                            accWithType
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
collectCustomTypesFromDecider : Mono.Decider Mono.MonoChoice -> EverySet String Mono.MonoType -> EverySet String Mono.MonoType
collectCustomTypesFromDecider decider acc =
    case decider of
        Mono.Leaf choice ->
            case choice of
                Mono.Inline expr ->
                    collectCustomTypesFromExpr expr acc

                Mono.Jump _ ->
                    acc

        Mono.Chain tests success failure ->
            let
                accWithTests =
                    List.foldl (\( dtPath, _ ) a -> collectCustomTypesFromDtPath dtPath a) acc tests
            in
            collectCustomTypesFromDecider failure (collectCustomTypesFromDecider success accWithTests)

        Mono.FanOut dtPath edges fallback ->
            let
                accWithPath =
                    collectCustomTypesFromDtPath dtPath acc

                edgeAcc =
                    List.foldl (\( _, d ) a -> collectCustomTypesFromDecider d a) accWithPath edges
            in
            collectCustomTypesFromDecider fallback edgeAcc


{-| Collect custom types from a MonoDtPath (decision tree path).
-}
collectCustomTypesFromDtPath : Mono.MonoDtPath -> EverySet String Mono.MonoType -> EverySet String Mono.MonoType
collectCustomTypesFromDtPath dtPath acc =
    case dtPath of
        Mono.DtRoot _ rootType ->
            collectCustomTypesFromMonoType rootType acc

        Mono.DtIndex _ _ resultType subPath ->
            collectCustomTypesFromDtPath subPath
                (collectCustomTypesFromMonoType resultType acc)

        Mono.DtUnbox resultType subPath ->
            collectCustomTypesFromDtPath subPath
                (collectCustomTypesFromMonoType resultType acc)


{-| Collect all MCustom types from all nodes in the graph.
-}
collectAllCustomTypes : Array (Maybe Mono.MonoNode) -> EverySet String Mono.MonoType
collectAllCustomTypes nodes =
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Nothing ->
                    acc

                Just node ->
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
    case Data.Map.get ModuleName.toComparableCanonical canonical typeEnv of
        Nothing ->
            Nothing

        Just moduleEnv ->
            Dict.get typeName moduleEnv.unions



-- ========== CTOR SHAPE COMPUTATION ==========


{-| Build complete CtorShapes for all constructors in a union.
Uses TypeSubst.applySubst to convert Can.Type to MonoType.
-}
buildCompleteCtorShapes : List Name -> List Mono.MonoType -> List Can.Ctor -> List Mono.CtorShape
buildCompleteCtorShapes vars monoArgs alts =
    let
        subst : Substitution
        subst =
            List.map2 Tuple.pair vars monoArgs
                |> Dict.fromList
    in
    List.map (buildCtorShapeFromUnion subst) alts


{-| Build a CtorShape from a Can.Ctor using the given substitution.
-}
buildCtorShapeFromUnion : Substitution -> Can.Ctor -> Mono.CtorShape
buildCtorShapeFromUnion subst (Can.Ctor ctorData) =
    let
        monoFieldTypes : List Mono.MonoType
        monoFieldTypes =
            List.map (TypeSubst.applySubst subst) ctorData.args
    in
    { name = ctorData.name
    , tag = Index.toMachine ctorData.index
    , fieldTypes = monoFieldTypes
    }


{-| Compute complete ctor shapes for all custom types in the graph.
For each MCustom, looks up the union definition and builds shapes for ALL constructors,
even those not directly used in code.
-}
computeCtorShapesForGraph :
    TypeEnv.GlobalTypeEnv
    -> Array (Maybe Mono.MonoNode)
    -> Data.Map.Dict String String (List Mono.CtorShape)
computeCtorShapesForGraph globalTypeEnv nodes =
    let
        customTypes =
            collectAllCustomTypes nodes

        processCustomType monoType acc =
            case monoType of
                Mono.MCustom canonical typeName monoArgs ->
                    let
                        key =
                            Mono.toComparableMonoType monoType
                    in
                    case lookupUnion globalTypeEnv canonical typeName of
                        Nothing ->
                            Utils.Crash.crash
                                ("Missing union for ctor shape: "
                                    ++ (ModuleName.toComparableCanonical canonical
                                            ++ [ typeName ]
                                            |> String.join " "
                                       )
                                )

                        Just (Can.Union unionData) ->
                            let
                                completeCtors =
                                    buildCompleteCtorShapes unionData.vars monoArgs unionData.alts
                            in
                            Data.Map.insert identity key completeCtors acc

                _ ->
                    acc

        dummyCompare _ _ =
            EQ
    in
    EverySet.foldr dummyCompare processCustomType Data.Map.empty customTypes
