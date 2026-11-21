module Compiler.MonoOpt.KernelVisible exposing
    ( KvSet, compute, empty
    , isVisible, isVisibleCtor, isVisibleInstance
    , size, ctorList, rootCount
    , mapInstances, instancesSubset
    )

{-| The kernel-visibility set of a program (plans/constructor-representation-levels.md
§4, invariant MONO_032): the custom type constructors whose values a C++ kernel
builds, reads, or receives in a known shape, so that no representation pass may
change them.

The set is the closure of a set of root types, computed once after
monomorphization from the table in `Compiler.IR.Kernel.Visibility`:

  - every argument and result type of a call to a kernel the table does not
    list, and the type of such a kernel used as a value, closed **deny-all**
    (a listed kernel used as a value is treated as a call of it): every
    type argument, every constructor field, list element, tuple element,
    record field, function parameter and function result is followed;
  - for a kernel the table lists as `Inspects ts`, and for an effect manager's
    leaf (`MonoManagerLeaf`) with the types `managerUses` gives, the listed
    types found in the call's argument and result types, closed **declared**:
    only the fields whose declared type is not a bare type variable are
    followed, and of a function only the parameters are followed (the kernel builds those; it passes the
    results on without looking at them);
  - the types of ports, and the type of the flags decoder, closed deny-all;
  - every kernel-owned type (`Visibility.kernelOwned`) the program reaches;
  - a reference to a kernel alias (a global whose node is
    `MonoDefine (MonoVarKernel …)`, the shared specialization AliasForward
    keeps, with type variables where the kernel's types are) is taken as a
    reference to that kernel at the use site's type, so the table's rule applies
    to the types the kernel really receives and returns
    (plans/constructor-representation-followups.md F2).

A `Transparent` kernel adds nothing. The closure needs no fixed point with
erasure: it already holds every type nested in a root, and erasure only removes
types outside the set.

@docs KvSet, compute, empty
@docs isVisible, isVisibleCtor, isVisibleInstance
@docs size, ctorList

-}

import Array
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Canonical as Can
import Compiler.IR.Kernel.Visibility as Visibility
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as Traverse
import Compiler.IR.Typed.TypeEnv as TypeEnv
import Compiler.Monomorphize.Analysis as Analysis
import Dict
import Set exposing (Set)


{-| The kernel-visible type constructors, each as its home module
(`ModuleName.toComparableCanonical`) and type name, and the kernel-visible
custom types themselves, under the layout key (`Mono.LayoutSet`). A pass that decides
per type constructor (`EraseWrappers`) reads the first; one that decides per
instantiation (`NullableMaybe`) reads the second, so that `String.toInt`'s
`Maybe Int` does not make every `Maybe` visible. `roots` counts the root types
the closure started from, for the report.
-}
type KvSet
    = KvSet { ctors : Set ( String, String ), instances : Mono.LayoutSet, roots : Int }


{-| The set with nothing in it.
-}
empty : KvSet
empty =
    KvSet { ctors = Set.empty, instances = Mono.layoutSetEmpty, roots = 0 }


{-| The number of type constructors in the set.
-}
size : KvSet -> Int
size (KvSet kv) =
    Set.size kv.ctors


{-| The set with each instance type replaced by `f` of it, the type
constructors unchanged. A representation pass that rewrites types
(`Compiler.MonoOpt.EraseWrappers`) carries the set over this way instead of
computing it again on the rewritten graph.
-}
mapInstances : (Mono.MonoType -> Mono.MonoType) -> KvSet -> KvSet
mapInstances f (KvSet kv) =
    KvSet { kv | instances = Mono.layoutMapFoldl (\t () acc -> Mono.layoutSetInsert (f t) acc) Mono.layoutSetEmpty kv.instances }


{-| Returns whether every instance type of the first set is in the second.
-}
instancesSubset : KvSet -> KvSet -> Bool
instancesSubset (KvSet a) (KvSet b) =
    Mono.layoutMapFoldl (\t () ok -> ok && Mono.layoutSetMember t b.instances) True a.instances


{-| The number of root types the set was computed from.
-}
rootCount : KvSet -> Int
rootCount (KvSet kv) =
    kv.roots


{-| The type constructors in the set, as ( home, name ) pairs.
-}
ctorList : KvSet -> List ( String, String )
ctorList (KvSet kv) =
    Set.toList kv.ctors


{-| Returns whether `t` is a custom type whose type constructor is in the set.
-}
isVisible : KvSet -> Mono.MonoType -> Bool
isVisible kv t =
    case t of
        Mono.MCustom _ home name _ ->
            isVisibleCtor kv home name

        _ ->
            False


{-| Returns whether the type constructor `home`.`name` is in the set.
-}
isVisibleCtor : KvSet -> ModuleName.Canonical -> String -> Bool
isVisibleCtor (KvSet kv) home name =
    Set.member ( ModuleName.toComparableCanonical home, name ) kv.ctors


{-| Returns whether the custom type `t` itself, at its type arguments, is in the
set.
-}
isVisibleInstance : KvSet -> Mono.MonoType -> Bool
isVisibleInstance (KvSet kv) t =
    Mono.layoutSetMember t kv.instances


type Mode
    = DenyAll
    | Declared (Set Visibility.TypeRef)


type alias Acc =
    { ctors : Set ( String, String )
    , instances : Mono.LayoutSet
    , seenDeny : Mono.LayoutSet
    , seenField : Mono.LayoutSet
    }


{-| Computes the kernel-visibility set of `graph`.
-}
compute : TypeEnv.GlobalTypeEnv -> Mono.MonoGraph -> KvSet
compute typeEnv ((Mono.MonoGraph g) as graph) =
    let
        -- The kernel each kernel-alias node forwards to, by SpecId.
        aliases : Dict.Dict Int ( String, String )
        aliases =
            Tuple.second
                (Array.foldl
                    (\maybeNode ( i, acc ) ->
                        ( i + 1
                        , case maybeNode of
                            Just (Mono.MonoDefine (Mono.MonoVarKernel _ _ home name _) _) ->
                                Dict.insert i ( home, name ) acc

                            _ ->
                                acc
                        )
                    )
                    ( 0, Dict.empty )
                    g.nodes
                )

        roots : List ( Mode, Mono.MonoType )
        roots =
            Array.foldl
                (\maybeNode acc ->
                    case maybeNode of
                        Just node ->
                            nodeRoots aliases node ++ acc

                        Nothing ->
                            acc
                )
                []
                g.nodes
                ++ flagsRoots graph

        ownedRoots : List ( Mode, Mono.MonoType )
        ownedRoots =
            Mono.layoutMapFoldl
                (\key _ acc ->
                    case key of
                        Mono.MCustom _ home name _ ->
                            if Visibility.isKernelOwned (ModuleName.toComparableCanonical home) name then
                                ( Declared (Set.singleton ( ModuleName.toComparableCanonical home, name )), key ) :: acc

                            else
                                acc

                        _ ->
                            acc
                )
                []
                g.ctorShapes

        env =
            { typeEnv = typeEnv, ctorShapes = g.ctorShapes }

        final =
            List.foldl
                (\( mode, t ) acc ->
                    case mode of
                        DenyAll ->
                            denyAll env t acc

                        Declared refs ->
                            declared env refs t acc
                )
                { ctors = Set.empty, instances = Mono.layoutSetEmpty, seenDeny = Mono.layoutSetEmpty, seenField = Mono.layoutSetEmpty }
                (ownedRoots ++ roots)
    in
    KvSet { ctors = final.ctors, instances = final.instances, roots = List.length ownedRoots + List.length roots }


type alias Env =
    { typeEnv : TypeEnv.GlobalTypeEnv
    , ctorShapes : Mono.LayoutMap (List Mono.CtorShape)
    }


{-| The constructors of the custom type `t`: from the graph's table, or else
from its declaration (an effect manager's command type is only in a
`MonoManagerLeaf` node's type, which the table does not collect).
-}
shapesOf : Env -> Mono.MonoType -> Maybe (List Mono.CtorShape)
shapesOf env t =
    case Mono.layoutMapGet t env.ctorShapes of
        Just shapes ->
            Just shapes

        Nothing ->
            Analysis.ctorShapesOf env.typeEnv t


flagsRoots : Mono.MonoGraph -> List ( Mode, Mono.MonoType )
flagsRoots (Mono.MonoGraph g) =
    case g.flagsDecoder of
        Just specId ->
            case Array.get specId g.nodes |> Maybe.andThen identity of
                Just node ->
                    [ ( DenyAll, Mono.nodeType node ) ]

                Nothing ->
                    []

        Nothing ->
            []


nodeRoots : Dict.Dict Int ( String, String ) -> Mono.MonoNode -> List ( Mode, Mono.MonoType )
nodeRoots aliases node =
    case node of
        Mono.MonoDefine expr _ ->
            exprRoots aliases expr []

        Mono.MonoTailFunc _ expr _ ->
            exprRoots aliases expr []

        Mono.MonoPortIncoming expr t ->
            ( DenyAll, t ) :: exprRoots aliases expr []

        Mono.MonoPortOutgoing expr t ->
            ( DenyAll, t ) :: exprRoots aliases expr []

        Mono.MonoManagerLeaf home t ->
            case Dict.get (ModuleName.toComparableCanonical home) Visibility.managerUses of
                Just refs ->
                    [ ( Declared (Set.fromList refs), t ) ]

                Nothing ->
                    [ ( DenyAll, t ) ]

        Mono.MonoCtor _ _ _ ->
            []

        Mono.MonoEnum _ _ _ _ ->
            []

        Mono.MonoExtern _ ->
            []


exprRoots : Dict.Dict Int ( String, String ) -> Mono.MonoExpr -> List ( Mode, Mono.MonoType ) -> List ( Mode, Mono.MonoType )
exprRoots aliases expr acc =
    case expr of
        Mono.MonoCall _ (Mono.MonoVarKernel _ _ home name _) args resultType _ ->
            let
                types =
                    resultType :: List.map Mono.typeOf args

                acc1 =
                    case Dict.get ( home, name ) Visibility.kernelUse of
                        Just Visibility.Transparent ->
                            acc

                        Just (Visibility.Inspects refs) ->
                            List.map (\t -> ( Declared (Set.fromList refs), t )) types ++ acc

                        Nothing ->
                            List.map (\t -> ( DenyAll, t )) types ++ acc
            in
            List.foldl (exprRoots aliases) acc1 args

        Mono.MonoVarKernel _ _ home name t ->
            -- A kernel used as a value: its table entry applies to its own type as to a call's.
            kernelValueRoots home name t acc

        Mono.MonoVarGlobal _ specId t ->
            -- A kernel alias, at this use's type (a call of it closes over the same parameter and
            -- result types as the function type does).
            case Dict.get specId aliases of
                Just ( home, name ) ->
                    kernelValueRoots home name t acc

                Nothing ->
                    acc

        _ ->
            List.foldl (exprRoots aliases) acc (Traverse.childrenOf expr)


{-| The roots of the kernel `home.name` used as a value of type `t`.
-}
kernelValueRoots : String -> String -> Mono.MonoType -> List ( Mode, Mono.MonoType ) -> List ( Mode, Mono.MonoType )
kernelValueRoots home name t acc =
    case Dict.get ( home, name ) Visibility.kernelUse of
        Just Visibility.Transparent ->
            acc

        Just (Visibility.Inspects refs) ->
            ( Declared (Set.fromList refs), t ) :: acc

        Nothing ->
            ( DenyAll, t ) :: acc


addCtor : ModuleName.Canonical -> String -> Mono.MonoType -> Acc -> Acc
addCtor home name t acc =
    { acc
        | ctors = Set.insert ( ModuleName.toComparableCanonical home, name ) acc.ctors
        , instances = Mono.layoutSetInsert t acc.instances
    }


{-| Marks every custom type reachable from `t` by any path.
-}
denyAll : Env -> Mono.MonoType -> Acc -> Acc
denyAll env t acc =
    case t of
        Mono.MCustom _ home name args ->
            if Mono.layoutSetMember t acc.seenDeny then
                acc

            else
                let
                    acc1 =
                        addCtor home name t { acc | seenDeny = Mono.layoutSetInsert t acc.seenDeny }

                    acc2 =
                        List.foldl (denyAll env) acc1 args
                in
                case shapesOf env t of
                    Just shapes ->
                        List.foldl (\s a -> List.foldl (denyAll env) a s.fieldTypes) acc2 shapes

                    Nothing ->
                        acc2

        Mono.MList _ e ->
            denyAll env e acc

        Mono.MTuple _ shape ->
            List.foldl (denyAll env) acc (Mono.tupleToList shape)

        Mono.MRecord _ fields ->
            Dict.foldl (\_ ft a -> denyAll env ft a) acc fields

        Mono.MFunction _ _ params result ->
            List.foldl (denyAll env) (denyAll env result acc) params

        _ ->
            acc


{-| Marks the types of `refs` found anywhere in `t`, each closed by
`fieldClosure`.
-}
declared : Env -> Set Visibility.TypeRef -> Mono.MonoType -> Acc -> Acc
declared env refs t acc =
    case t of
        Mono.MCustom _ home name args ->
            let
                acc1 =
                    if Set.member ( ModuleName.toComparableCanonical home, name ) refs then
                        fieldClosure env t acc

                    else
                        acc
            in
            List.foldl (declared env refs) acc1 args

        Mono.MList _ e ->
            declared env refs e acc

        Mono.MTuple _ shape ->
            List.foldl (declared env refs) acc (Mono.tupleToList shape)

        Mono.MRecord _ fields ->
            Dict.foldl (\_ ft a -> declared env refs ft a) acc fields

        Mono.MFunction _ _ params result ->
            List.foldl (declared env refs) (declared env refs result acc) params

        _ ->
            acc


{-| Marks `t` and what a kernel that builds or reads `t` can see of it: the
fields of a custom type whose declared type is not a bare type variable, the
parts of a list, tuple or record, and the parameters of a function. A
kernel-owned type is looked into like any other: an effect manager's command
type is kernel-owned and the kernel reads its fields, while an opaque type
(`type Bytes = Bytes`, `type JsArray a = JsArray a`) has no field that is not a
type variable.
-}
fieldClosure : Env -> Mono.MonoType -> Acc -> Acc
fieldClosure env t acc =
    case t of
        Mono.MCustom _ home name _ ->
            if Mono.layoutSetMember t acc.seenField then
                acc

            else
                let
                    acc1 =
                        addCtor home name t { acc | seenField = Mono.layoutSetInsert t acc.seenField }
                in
                case shapesOf env t of
                        Just shapes ->
                            let
                                varFields =
                                    declaredVarFields env home name
                            in
                            List.foldl
                                (\shape a ->
                                    List.foldl
                                        (\( i, ft ) a2 ->
                                            if Set.member ( shape.name, i ) varFields then
                                                a2

                                            else
                                                fieldClosure env ft a2
                                        )
                                        a
                                        (List.indexedMap Tuple.pair shape.fieldTypes)
                                )
                                acc1
                                shapes

                        Nothing ->
                            acc1

        Mono.MList _ e ->
            fieldClosure env e acc

        Mono.MTuple _ shape ->
            List.foldl (fieldClosure env) acc (Mono.tupleToList shape)

        Mono.MRecord _ fields ->
            Dict.foldl (\_ ft a -> fieldClosure env ft a) acc fields

        Mono.MFunction _ _ params _ ->
            List.foldl (fieldClosure env) acc params

        _ ->
            acc


{-| The ( constructor name, field index ) pairs of the custom type
`home`.`name` whose declared type is a bare type variable.
-}
declaredVarFields : Env -> ModuleName.Canonical -> String -> Set ( String, Int )
declaredVarFields env home name =
    case Analysis.lookupUnion env.typeEnv home name of
        Just (Can.Union u) ->
            List.foldl
                (\(Can.Ctor c) acc ->
                    List.foldl
                        (\( i, argType ) a ->
                            case argType of
                                Can.TVar _ ->
                                    Set.insert ( c.name, i ) a

                                _ ->
                                    a
                        )
                        acc
                        (List.indexedMap Tuple.pair c.args)
                )
                Set.empty
                u.alts

        Nothing ->
            Set.empty
