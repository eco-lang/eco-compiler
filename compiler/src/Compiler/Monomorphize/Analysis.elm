module Compiler.Monomorphize.Analysis exposing
    ( computeCtorShapesForGraph
    , lookupUnion
    , convertCanTypeNameToMVarId, instantiateCtorField
    )

{-| The code generator lays out every value of a custom type by its constructor,
so it needs to know every constructor of every custom type the program uses,
including constructors the program never builds. This module computes that
table from a monomorphized graph.

A _ctor shape_ is one constructor of one instantiation of a custom type: its
name, its runtime tag, and the `MonoType` of each of its fields. The tag is the
one `Compiler.IR.Runtime.CtorTag.effective` gives.

`computeCtorShapesForGraph` works in two steps. It first walks every node of the
graph, its types, expressions, closure captures and parameters, destructuring
paths and decision-tree paths, and collects each distinct `MCustom` type it
finds. Then for each one it looks up the union declaration and instantiates
every constructor's field types with the type's arguments. Most of the file is
the first step.

`lookupUnion` and `convertCanTypeNameToMVarId` are the two pieces of the second
step that other modules use as well.

@docs computeCtorShapesForGraph

@docs lookupUnion

@docs convertCanTypeNameToMVarId, instantiateCtorField

-}

import Array exposing (Array)
import Compiler.Core.Id as Id
import Compiler.Core.Name exposing (Name)
import Compiler.Core.TypeIds as TypeIds
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Canonical as Can
import Compiler.IR.Mono as Mono
import Compiler.IR.Runtime.CtorTag as CtorTag
import Compiler.IR.Typed.TypeEnv as TypeEnv
import Compiler.Monomorphize.State as State exposing (MVarEnv, Substitution)
import Compiler.Monomorphize.TypeSubst as TypeSubst
import Data.Map
import Data.NonEmptyList as NE
import Dict
import System.Crash



-- ========== CUSTOM TYPE COLLECTION ==========


{-| A collected `MCustom` type's home module, type name and type arguments,
kept as the value of its layout-map entry.
-}
type alias CustomType =
    ( ModuleName.Canonical, Name, List Mono.MonoType )


{-| Returns `acc` with every `MCustom` type found in `monoType` added, including
those nested in type arguments, list elements, tuples, record fields and
function types.

A custom type already in `acc` is not entered again, so its arguments are only
walked the first time it is met.

-}
collectCustomTypesFromMonoType : Mono.MonoType -> Mono.LayoutMap CustomType -> Mono.LayoutMap CustomType
collectCustomTypesFromMonoType monoType acc =
    case monoType of
        Mono.MCustom _ home name args ->
            if Mono.layoutMapMember monoType acc then
                acc

            else
                List.foldl collectCustomTypesFromMonoType
                    (Mono.layoutMapInsert monoType ( home, name, args ) acc)
                    args

        Mono.MList _ elem ->
            collectCustomTypesFromMonoType elem acc

        Mono.MTuple _ elementTypes ->
            List.foldl collectCustomTypesFromMonoType acc (Mono.tupleToList elementTypes)

        Mono.MRecord _ fields ->
            Dict.foldl (\_ t a -> collectCustomTypesFromMonoType t a) acc fields

        Mono.MFunction _ _ argTypes resultType ->
            List.foldl collectCustomTypesFromMonoType
                (collectCustomTypesFromMonoType resultType acc)
                argTypes

        _ ->
            acc


{-| Returns `acc` with every `MCustom` type found in the types along `path` added:
the root's type and the result type of each step.
-}
collectCustomTypesFromPath : Mono.MonoPath -> Mono.LayoutMap CustomType -> Mono.LayoutMap CustomType
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


{-| Returns `acc` with every `MCustom` type found in `expr` and its
sub-expressions added.

Besides each expression's own type, this takes in closure parameter types,
destructuring paths and decision-tree paths. A record or tuple construction's
or record update's own type already holds its field or element types.

-}
collectCustomTypesFromExpr : Mono.MonoExpr -> Mono.LayoutMap CustomType -> Mono.LayoutMap CustomType
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

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> collectCustomTypesFromExpr e a) accWithType fields

        Mono.MonoRecordAccess record _ _ ->
            collectCustomTypesFromExpr record accWithType

        Mono.MonoRecordUpdate record updates _ ->
            List.foldl (\( _, e ) a -> collectCustomTypesFromExpr e a)
                (collectCustomTypesFromExpr record accWithType)
                updates

        Mono.MonoTupleCreate _ exprs _ ->
            List.foldl collectCustomTypesFromExpr accWithType (Mono.tupleToList exprs)

        Mono.MonoUnit ->
            accWithType

        Mono.MonoAccessorValue _ _ _ ->
            accWithType


{-| Returns `acc` with every `MCustom` type found in `decider` added: in the
paths it tests and in its inline leaf expressions. A leaf that jumps to a shared
branch adds nothing; the branch itself is walked with the `case` expression.
-}
collectCustomTypesFromDecider : Mono.Decider Mono.MonoChoice -> Mono.LayoutMap CustomType -> Mono.LayoutMap CustomType
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
                    List.foldl (\( dtPath, _ ) a -> collectCustomTypesFromDtPath dtPath a) acc (NE.toList tests)
            in
            collectCustomTypesFromDecider failure (collectCustomTypesFromDecider success accWithTests)

        Mono.FanOut dtPath edges fallback ->
            let
                accWithPath =
                    collectCustomTypesFromDtPath dtPath acc

                edgeAcc =
                    List.foldl (\( _, d ) a -> collectCustomTypesFromDecider d a) accWithPath (NE.toList edges)
            in
            collectCustomTypesFromDecider fallback edgeAcc


{-| Returns `acc` with every `MCustom` type found in the types along the
decision-tree path `dtPath` added.
-}
collectCustomTypesFromDtPath : Mono.MonoDtPath -> Mono.LayoutMap CustomType -> Mono.LayoutMap CustomType
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


{-| Returns every distinct `MCustom` type found in `nodes`, in their declared
types and, for nodes that have one, in their bodies. Empty slots are skipped.
-}
collectAllCustomTypes : Array (Maybe Mono.MonoNode) -> Mono.LayoutMap CustomType
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

                        Mono.MonoCtor _ shape monoType ->
                            List.foldl collectCustomTypesFromMonoType
                                (collectCustomTypesFromMonoType monoType acc)
                                shape.fieldTypes

                        Mono.MonoEnum _ _ _ monoType ->
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


{-| Returns the declaration of the custom type `typeName` from module
`canonical`, or `Nothing` if the module or the type is not in `typeEnv`.
-}
lookupUnion : TypeEnv.GlobalTypeEnv -> ModuleName.Canonical -> Name -> Maybe Can.Union
lookupUnion typeEnv canonical typeName =
    Data.Map.get ModuleName.toComparableCanonical canonical typeEnv
        |> Maybe.andThen (\moduleEnv -> Dict.get typeName moduleEnv.unions)



-- ========== CTOR SHAPE COMPUTATION ==========


{-| Returns the ctor shapes of every constructor in `alts`, in declaration
order, for the custom type from module `home` whose type parameters `vars` are
instantiated to `monoArgs`.

Each parameter gets a fresh variable from `env`, bound to its argument. If
`vars` and `monoArgs` differ in length, the parameters without an argument are
left unbound.

-}
buildCompleteCtorShapes : ModuleName.Canonical -> MVarEnv -> List Name -> List Mono.MonoType -> List Can.Ctor -> ( List Mono.CtorShape, MVarEnv )
buildCompleteCtorShapes home env vars monoArgs alts =
    let
        ( nameToId, substById, env2 ) =
            bindTypeParams env vars monoArgs

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


{-| Gives each of a custom type's parameters `vars` a fresh variable from `env`,
in order, and returns the name-to-id map, the substitution binding each
parameter's id to its argument in `monoArgs`, and the advanced `env`. When
`vars` and `monoArgs` differ in length, the parameters without an argument are
left unbound.
-}
bindTypeParams : MVarEnv -> List Name -> List Mono.MonoType -> ( Dict.Dict Name TypeIds.MVarId, Substitution, MVarEnv )
bindTypeParams env vars monoArgs =
    let
        ( revIds, env1 ) =
            List.foldl
                (\varName ( acc, e ) ->
                    let
                        ( mvarId, e1 ) =
                            State.freshMVar Mono.CEcoValue e
                    in
                    ( ( varName, mvarId ) :: acc, e1 )
                )
                ( [], env )
                vars

        ids : List ( Name, TypeIds.MVarId )
        ids =
            List.reverse revIds
    in
    ( Dict.fromList ids
    , List.foldl
        (\( ( _, mvarId ), monoType ) s -> Dict.insert (Id.toComparable mvarId) monoType s)
        Dict.empty
        (List.map2 Tuple.pair ids monoArgs)
    , env1
    )


{-| Returns the ctor shape of one constructor of a type from module `home`:
each field type has its type parameters renamed through `nameToId` and then
`subst` applied. The tag is `CtorTag.effective` of `home`, the name and the
declaration index. `env` is returned unchanged.
-}
buildCtorShapeFromUnion : ModuleName.Canonical -> MVarEnv -> Substitution -> Dict.Dict Name TypeIds.MVarId -> Can.Ctor -> ( Mono.CtorShape, MVarEnv )
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


{-| Returns `canType` with each type variable name replaced by its id in
`nameToId`.

A type variable missing from `nameToId` crashes the compiler. A record
extension variable missing from it is dropped, leaving a closed record. Inside
an alias, the alias's own parameters are not looked up in `nameToId`: each
formal gets its own id by position (`TypeIds.firstMVarId`, then the next ...),
used both as its parameter id in the argument list and in the body. These ids
may coincide with ids in `nameToId`; that is safe because an alias body
mentions only its own formals and the arguments are converted with the outer
`nameToId`.

Arrows are built with `Can.tLambda`, so they carry no arrow identity. A type
from here must not be loaded into a `Compiler.Monomorphize.Solver.Store`; the store
treats an unstamped arrow as always new and shares nothing for it.

-}
convertCanTypeNameToMVarId : Dict.Dict Name TypeIds.MVarId -> Can.Type Name -> Can.Type TypeIds.MVarId
convertCanTypeNameToMVarId nameToId canType =
    case canType of
        Can.TVar name ->
            case Dict.get name nameToId of
                Just mvarId ->
                    Can.TVar mvarId

                Nothing ->
                    System.Crash.crash "Analysis" "convertCanTypeNameToMVarId" ("Unbound type variable: " ++ name)

        Can.TLambda _ from to ->
            Can.tLambda (convertCanTypeNameToMVarId nameToId from) (convertCanTypeNameToMVarId nameToId to)

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
                (Maybe.map (convertCanTypeNameToMVarId nameToId) rest)

        Can.TAlias canonical name args aliasType ->
            let
                -- The alias's formal parameters are bound by the alias, not the union.
                -- One id per formal, by position; the body mentions only the formals.
                formalIds : List ( Name, TypeIds.MVarId )
                formalIds =
                    List.foldl
                        (\( n, _ ) ( acc, nextId ) -> ( ( n, nextId ) :: acc, Id.succ nextId ))
                        ( [], TypeIds.firstMVarId )
                        args
                        |> Tuple.first
                        |> List.reverse

                innerNameToId : Dict.Dict Name TypeIds.MVarId
                innerNameToId =
                    List.foldl (\( n, pid ) acc -> Dict.insert n pid acc) nameToId formalIds
            in
            Can.TAlias canonical
                name
                (List.map2
                    (\( _, pid ) ( _, t ) ->
                        ( pid, convertCanTypeNameToMVarId nameToId t )
                    )
                    formalIds
                    args
                )
                (case aliasType of
                    Can.Holey inner ->
                        Can.Holey (convertCanTypeNameToMVarId innerNameToId inner)

                    Can.Filled inner ->
                        Can.Filled (convertCanTypeNameToMVarId innerNameToId inner)
                )


{-| Returns, for every distinct custom type found anywhere in `nodes`, the ctor
shapes of all its constructors, including ones the program never builds, in
declaration order. The table is keyed by layout, as `Mono.LayoutMap` describes.

A custom type whose declaration is not in `globalTypeEnv` crashes the compiler.

-}
computeCtorShapesForGraph :
    TypeEnv.GlobalTypeEnv
    -> Array (Maybe Mono.MonoNode)
    -> Mono.LayoutMap (List Mono.CtorShape)
computeCtorShapesForGraph globalTypeEnv nodes =
    let
        customTypes =
            collectAllCustomTypes nodes

        processCustomType monoType ( canonical, typeName, monoArgs ) acc =
            case lookupUnion globalTypeEnv canonical typeName of
                Nothing ->
                    System.Crash.crash
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
    in
    Mono.layoutMapFoldl processCustomType
        Mono.layoutMapEmpty
        customTypes


{-| Returns a constructor field's declared type `fieldType` with the custom
type's parameters `vars` replaced by `typeArgs`.
-}
instantiateCtorField : List Name -> List Mono.MonoType -> Can.Type Name -> Mono.MonoType
instantiateCtorField vars typeArgs fieldType =
    let
        ( nameToId, subst, env ) =
            bindTypeParams (State.initMVarEnv TypeIds.firstMVarId Dict.empty) vars typeArgs
    in
    TypeSubst.applySubstPure env subst (convertCanTypeNameToMVarId nameToId fieldType)
