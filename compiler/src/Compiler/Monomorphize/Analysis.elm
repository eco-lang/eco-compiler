module Compiler.Monomorphize.Analysis exposing
    ( computeCtorShapesForGraph
    , lookupUnion
    , convertCanTypeNameToMVarId
    )

{-| Analysis passes for monomorphization.

This module handles:

  - Dependency collection (finding global references)
  - Custom type collection (finding all Mono.mCustom types)
  - Union type lookup
  - Ctor shape computation for the graph


# Dependency Collection


# Custom Type Collection


# Ctor Shape Computation

@docs computeCtorShapesForGraph


# Union Type Lookup

@docs lookupUnion


# Type Conversion

@docs convertCanTypeNameToMVarId

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypeIds as TypeIds
import Compiler.Data.CtorTag as CtorTag
import Compiler.Data.Id as Id
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Monomorphize.State as State exposing (MVarEnv, Substitution)
import Compiler.Monomorphize.TypeSubst as TypeSubst
import Data.Map
import Dict
import System.TypeCheck.IO as IO
import Utils.Crash



-- ========== CUSTOM TYPE COLLECTION ==========


{-| Collect all Mono.mCustom types from a MonoType, recursively traversing nested structures.
-}
collectCustomTypesFromMonoType : Mono.MonoType -> Mono.LayoutMap () -> Mono.LayoutMap ()
collectCustomTypesFromMonoType monoType acc =
    case monoType of
        Mono.MCustom _ _ _ args ->
            -- K4: the probe and the insert both key on the hash the type already
            -- carries. This used to build a full comparable string per probe (and
            -- K1.2 had already halved it from two).
            if Mono.layoutMapMember monoType acc then
                acc

            else
                -- Add this MCustom, then recurse into type args
                List.foldl collectCustomTypesFromMonoType
                    (Mono.layoutMapInsert monoType () acc)
                    args

        Mono.MList _ elem ->
            collectCustomTypesFromMonoType elem acc

        Mono.MTuple _ elementTypes ->
            List.foldl collectCustomTypesFromMonoType acc elementTypes

        Mono.MRecord _ fields ->
            Dict.foldl (\_ t a -> collectCustomTypesFromMonoType t a) acc fields

        Mono.MFunction _ _ argTypes resultType ->
            List.foldl collectCustomTypesFromMonoType
                (collectCustomTypesFromMonoType resultType acc)
                argTypes

        _ ->
            acc


{-| Collect custom types from a MonoPath.
The path contains intermediate container types that need their shapes computed.
-}
collectCustomTypesFromPath : Mono.MonoPath -> Mono.LayoutMap () -> Mono.LayoutMap ()
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


{-| Collect all Mono.mCustom types from a MonoExpr and its sub-expressions.
-}
collectCustomTypesFromExpr : Mono.MonoExpr -> Mono.LayoutMap () -> Mono.LayoutMap ()
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

        Mono.MonoVarKernel _ _ _ _ _ ->
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
                        Mono.MRecord _ fieldDict ->
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
                        Mono.MRecord _ fields ->
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
                        Mono.MTuple _ types ->
                            types

                        _ ->
                            []

                elemAcc =
                    List.foldl collectCustomTypesFromMonoType accWithType elemTypes
            in
            List.foldl collectCustomTypesFromExpr elemAcc exprs

        Mono.MonoUnit ->
            accWithType

        Mono.MonoAccessorValue _ _ _ ->
            accWithType


{-| Collect custom types from a decision tree.
-}
collectCustomTypesFromDecider : Mono.Decider Mono.MonoChoice -> Mono.LayoutMap () -> Mono.LayoutMap ()
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
collectCustomTypesFromDtPath : Mono.MonoDtPath -> Mono.LayoutMap () -> Mono.LayoutMap ()
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


{-| Collect all Mono.mCustom types from all nodes in the graph.
-}
collectAllCustomTypes : Array (Maybe Mono.MonoNode) -> Mono.LayoutMap ()
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
        )
        Mono.layoutMapEmpty
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
Uses TypeSubst.applySubst to convert Can.Type Name to MonoType.

`home` is the canonical module that owns the type; it lets us assign reserved
runtime tags to constructors of types the runtime recognises (e.g. `Dict`).

-}
buildCompleteCtorShapes : IO.Canonical -> MVarEnv -> List Name -> List Mono.MonoType -> List Can.Ctor -> ( List Mono.CtorShape, MVarEnv )
buildCompleteCtorShapes home env vars monoArgs alts =
    let
        -- Allocate fresh MVarIds for each type parameter name and build the substitution
        -- Build a name-to-MVarId mapping for converting Can.Type Name to Can.Type MVarId
        ( nameToId, env2 ) =
            List.foldl
                (\varName ( acc, e ) ->
                    let
                        ( mvarId, e1 ) =
                            State.freshMVar Mono.CEcoValue e
                    in
                    ( Dict.insert varName mvarId acc, e1 )
                )
                ( Dict.empty, env )
                vars

        -- Build Int-keyed substitution using the name-to-MVarId mapping
        substById : Substitution
        substById =
            List.foldl
                (\( varName, monoType ) s ->
                    case Dict.get varName nameToId of
                        Just mvarId ->
                            Dict.insert (Id.toComparable mvarId) monoType s

                        Nothing ->
                            s
                )
                Dict.empty
                (List.map2 Tuple.pair vars monoArgs)

        ( revShapes, finalEnv ) =
            List.foldl
                (\ctor ( acc, e ) ->
                    let
                        ( shape, e1 ) =
                            buildCtorShapeFromUnion home e substById nameToId ctor
                    in
                    ( shape :: acc, e1 )
                )
                ( [], env2 )
                alts
    in
    ( List.reverse revShapes, finalEnv )


{-| Build a CtorShape from a Can.Ctor using the given substitution.
Converts Can.Type Name field types to Can.Type MVarId using nameToId mapping,
then applies the Int-keyed substitution.

`home` is used to pick a reserved ctor tag for runtime-recognised types
(see `Compiler.Data.CtorTag`).

-}
buildCtorShapeFromUnion : IO.Canonical -> MVarEnv -> Substitution -> Dict.Dict Name TypeIds.MVarId -> Can.Ctor -> ( Mono.CtorShape, MVarEnv )
buildCtorShapeFromUnion home env subst nameToId (Can.Ctor ctorData) =
    let
        monoFieldTypes =
            List.map
                (\t -> TypeSubst.applySubstPure env subst (convertCanTypeNameToMVarId nameToId t))
                ctorData.args
    in
    ( { name = ctorData.name
      , tag = CtorTag.effective home ctorData.name ctorData.index
      , fieldTypes = monoFieldTypes
      }
    , env
    )


{-| Convert a Can.Type Name to Can.Type MVarId using a name-to-id mapping.
Names not in the mapping are given a dummy MVarId (they'll be treated as
unconstrained type variables by applySubst).
-}
convertCanTypeNameToMVarId : Dict.Dict Name TypeIds.MVarId -> Can.Type Name -> Can.Type TypeIds.MVarId
convertCanTypeNameToMVarId nameToId canType =
    case canType of
        Can.TVar name ->
            case Dict.get name nameToId of
                Just mvarId ->
                    Can.TVar mvarId

                Nothing ->
                    Utils.Crash.crash "Analysis" "convertCanTypeNameToMVarId" ("Unbound type variable: " ++ name)

        Can.TLambda from to ->
            Can.TLambda (convertCanTypeNameToMVarId nameToId from) (convertCanTypeNameToMVarId nameToId to)

        Can.TType canonical name args ->
            Can.TType canonical name (List.map (convertCanTypeNameToMVarId nameToId) args)

        Can.TRecord fields ext ->
            Can.TRecord
                (Dict.map (\_ (Can.FieldType idx t) -> Can.FieldType idx (convertCanTypeNameToMVarId nameToId t)) fields)
                (Maybe.andThen (\n -> Dict.get n nameToId) ext)

        Can.TUnit ->
            Can.TUnit

        Can.TTuple a b rest ->
            Can.TTuple
                (convertCanTypeNameToMVarId nameToId a)
                (convertCanTypeNameToMVarId nameToId b)
                (List.map (convertCanTypeNameToMVarId nameToId) rest)

        Can.TAlias canonical name args aliasType ->
            let
                -- The first element of each pair is the alias's *formal*
                -- parameter name (e.g. "a" in `type alias Pair a = ...`),
                -- which is bound by the alias declaration itself and is
                -- not in the surrounding union's nameToId. Extend nameToId
                -- with dummy bindings for those formal-param names so the
                -- body recursion (Holey/Filled) can resolve TVar references
                -- to them. Downstream consumers (applySubst) key on the
                -- converted argument types, not on these dummy ids.
                innerNameToId : Dict.Dict Name TypeIds.MVarId
                innerNameToId =
                    List.foldl
                        (\( n, _ ) acc -> Dict.insert n TypeIds.firstMVarId acc)
                        nameToId
                        args
            in
            Can.TAlias canonical
                name
                (List.map
                    (\( _, t ) ->
                        ( TypeIds.firstMVarId, convertCanTypeNameToMVarId nameToId t )
                    )
                    args
                )
                (case aliasType of
                    Can.Holey inner ->
                        Can.Holey (convertCanTypeNameToMVarId innerNameToId inner)

                    Can.Filled inner ->
                        Can.Filled (convertCanTypeNameToMVarId innerNameToId inner)
                )


{-| Compute complete ctor shapes for all custom types in the graph.
For each MCustom, looks up the union definition and builds shapes for ALL constructors,
even those not directly used in code.
-}
computeCtorShapesForGraph :
    TypeEnv.GlobalTypeEnv
    -> Array (Maybe Mono.MonoNode)
    -> Mono.LayoutMap (List Mono.CtorShape)
computeCtorShapesForGraph globalTypeEnv nodes =
    let
        customTypes =
            collectAllCustomTypes nodes

        processCustomType monoType acc =
            case monoType of
                Mono.MCustom _ canonical typeName monoArgs ->
                    case lookupUnion globalTypeEnv canonical typeName of
                        Nothing ->
                            Utils.Crash.crash
                                ("Missing union for ctor shape: "
                                    ++ ModuleName.toComparableCanonical canonical
                                    ++ "."
                                    ++ typeName
                                )

                        Just (Can.Union unionData) ->
                            let
                                ( completeCtors, _ ) =
                                    buildCompleteCtorShapes canonical (State.initMVarEnv TypeIds.firstMVarId Dict.empty) unionData.vars monoArgs unionData.alts
                            in
                            Mono.layoutMapInsert monoType completeCtors acc

                _ ->
                    acc

    in
    Mono.layoutMapFoldl (\monoType _ acc -> processCustomType monoType acc)
        Mono.layoutMapEmpty
        customTypes
