module Compiler.Monomorphize.ValidateLayout exposing (validate)

{-| Checks a finished monomorphized program for places where two views of one
runtime value disagree about how that value is laid out, which would make some
emitted code read or write it in the wrong representation.

The check rests on one fact: how a value is stored in a heap object follows
from its recorded type alone. Only `Int`, `Float` and `Char` are stored
unboxed; everything else, `Bool` included, is a boxed pointer. Call that class
of a type its _ABI kind_: raw-int, raw-float, raw-char or boxed. When two types
recorded for the same value have different ABI kinds, at least one site that
uses the value has been given the wrong layout.

`validate` walks every `MonoDefine` and `MonoTailFunc` node of a `MonoGraph`
(other nodes are not looked at) and reports three shapes of disagreement:

1.  A destructuring path. If its outermost step indexes into a tuple or a list,
    and the destructured name needs a raw primitive, the element the step reads
    must have that same ABI kind. A raw element bound to a boxed name is
    allowed, since the value is boxed as it is read. Indexing into a
    custom-type constructor is not checked here, because construction and
    projection both take that layout from the constructor itself rather than
    from the types at each site. In addition, every step of the path that
    indexes into a tuple must read a type of the same ABI kind as the tuple's
    slot.
2.  A `MonoTailCall`. Each argument must have the ABI kind of the loop
    parameter of the same name.
3.  A `MonoTupleCreate`. Each element must have the ABI kind of the
    corresponding slot of the tuple's recorded type.

Captured closure values and ordinary call arguments are not checked. At the
level of types, a disagreement there can be a harmless one between an erased
type variable and a concrete type, which a check of one node at a time cannot
tell apart from a real mismatch.

@docs validate

-}

import Array
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.Monomorphize.MonoTraverse as Traverse
import Dict


{-| Returns one message for each layout disagreement found in the graph, or an
empty list when there is none. Each message starts with
`MONO_029 violation (spec N):`, where `N` is the specialization the
disagreement was found in.
-}
validate : Mono.MonoGraph -> List String
validate (Mono.MonoGraph graph) =
    Array.foldl
        (\( specId, maybeNode ) acc ->
            case maybeNode of
                Nothing ->
                    acc

                Just node ->
                    validateNode specId node acc
        )
        []
        (Array.indexedMap Tuple.pair graph.nodes)


{-| Adds to `acc0` the violations found in one node, identified by `specId`.
A node other than a `MonoDefine` or a `MonoTailFunc` adds nothing.
-}
validateNode : Int -> Mono.MonoNode -> List String -> List String
validateNode specId node acc0 =
    let
        ( frames0, expr ) =
            case node of
                Mono.MonoDefine e _ ->
                    ( Dict.empty, Just e )

                Mono.MonoTailFunc params body _ ->
                    ( Dict.singleton "" params, Just body )

                _ ->
                    ( Dict.empty, Nothing )
    in
    case expr of
        Nothing ->
            acc0

        Just e ->
            let
                -- The node's own loop has no name here, so it is filed under "".
                frames =
                    Traverse.foldExpr
                        (\ex fs ->
                            case ex of
                                Mono.MonoLet (Mono.MonoTailDef n ps _) _ _ ->
                                    Dict.insert n ps fs

                                _ ->
                                    fs
                        )
                        frames0
                        e
            in
            Traverse.foldExpr (checkExpr specId frames) acc0 e


{-| Adds to `acc` the violations of one expression, without looking into its
sub-expressions. `frames` maps each local loop's name to its parameters, with
the node's own parameters under `""`; a tail call to a name not in `frames`
is checked against the `""` entry, and is not checked when there is none.
-}
checkExpr : Int -> Dict.Dict Name (List ( Name, Mono.MonoType )) -> Mono.MonoExpr -> List String -> List String
checkExpr specId frames expr acc =
    case expr of
        Mono.MonoDestruct (Mono.MonoDestructor name path leafType) _ _ ->
            checkPath specId name leafType path acc

        Mono.MonoTailCall callee args _ ->
            let
                params =
                    case Dict.get callee frames of
                        Just ps ->
                            Just ps

                        Nothing ->
                            Dict.get "" frames
            in
            case params of
                Nothing ->
                    acc

                Just ps ->
                    List.foldl
                        (\( argName, argExpr ) a ->
                            case List.filter (\( pn, _ ) -> pn == argName) ps of
                                ( _, pType ) :: _ ->
                                    if abiKind (Mono.typeOf argExpr) /= abiKind pType then
                                        violation specId
                                            ("MonoTailCall " ++ callee ++ " arg " ++ argName ++ ": " ++ kindName (Mono.typeOf argExpr) ++ " vs loop param " ++ kindName pType)
                                            a

                                    else
                                        a

                                [] ->
                                    a
                        )
                        acc
                        args

        Mono.MonoTupleCreate _ elems nodeType ->
            case nodeType of
                Mono.MTuple _ slotTypes ->
                    List.foldl
                        (\( i, ( elemExpr, slotType ) ) a ->
                            if abiKind (Mono.typeOf elemExpr) /= abiKind slotType then
                                violation specId
                                    ("MonoTupleCreate slot " ++ String.fromInt i ++ ": element " ++ kindName (Mono.typeOf elemExpr) ++ " vs slot " ++ kindName slotType)
                                    a

                            else
                                a
                        )
                        acc
                        (List.indexedMap Tuple.pair (List.map2 Tuple.pair elems slotTypes))

                _ ->
                    acc

        _ ->
            acc


{-| Adds to `acc0` the violations of the destructuring path of `name`, whose
bound type is `leafType`: the outermost step's element against `leafType`, as
the module docstring describes, then every tuple step against its slot.
-}
checkPath : Int -> Name -> Mono.MonoType -> Mono.MonoPath -> List String -> List String
checkPath specId name leafType path acc0 =
    let
        acc1 =
            case path of
                Mono.MonoIndex _ kind elemType _ ->
                    -- A boxed leaf is never reported: a raw element is boxed as it is read.
                    if perSiteTyped kind && abiKind leafType /= KBoxed && abiKind elemType /= abiKind leafType then
                        violation specId
                            ("destructor " ++ name ++ ": path element " ++ kindName elemType ++ " vs leaf " ++ kindName leafType)
                            acc0

                    else
                        acc0

                _ ->
                    acc0
    in
    checkPathChain specId name path acc1


{-| Tells whether a container's slot layout comes from the types at each site,
which is true of tuples and lists and false of custom-type constructors.
-}
perSiteTyped : Mono.ContainerKind -> Bool
perSiteTyped kind =
    case kind of
        Mono.CustomContainer _ ->
            False

        _ ->
            True


{-| Adds to `acc` a violation for every step of `path` that indexes into a
tuple and reads a type whose ABI kind differs from that tuple slot's.
-}
checkPathChain : Int -> Name -> Mono.MonoPath -> List String -> List String
checkPathChain specId name path acc =
    case path of
        Mono.MonoIndex i _ elemType subPath ->
            let
                acc1 =
                    case Mono.getMonoPathType subPath of
                        Mono.MTuple _ slotTypes ->
                            case List.head (List.drop i slotTypes) of
                                Just slotType ->
                                    if abiKind slotType /= abiKind elemType then
                                        violation specId
                                            ("destructor " ++ name ++ ": tuple slot " ++ String.fromInt i ++ " " ++ kindName slotType ++ " vs projected " ++ kindName elemType)
                                            acc

                                    else
                                        acc

                                Nothing ->
                                    acc

                        _ ->
                            acc
            in
            checkPathChain specId name subPath acc1

        Mono.MonoField _ _ subPath ->
            checkPathChain specId name subPath acc

        Mono.MonoUnbox _ subPath ->
            checkPathChain specId name subPath acc

        Mono.MonoRoot _ _ ->
            acc


{-| Adds the message `msg`, prefixed with the violation tag and `specId`, to
`acc`.
-}
violation : Int -> String -> List String -> List String
violation specId msg acc =
    ("MONO_029 violation (spec " ++ String.fromInt specId ++ "): " ++ msg) :: acc


{-| The ABI kind of a recorded type: how a value of that type is stored in a
heap object.
-}
type AbiKind
    = KRawInt
    | KRawFloat
    | KRawChar
    | KBoxed


{-| Returns the ABI kind of a type. `Int`, `Float` and `Char` are raw, and so is
a type variable constrained to `number`, which counts as raw-int; every other
type is boxed.
-}
abiKind : Mono.MonoType -> AbiKind
abiKind t =
    case t of
        Mono.MInt ->
            KRawInt

        Mono.MFloat ->
            KRawFloat

        Mono.MChar ->
            KRawChar

        Mono.MVar _ Mono.CNumber ->
            KRawInt

        _ ->
            KBoxed


{-| Returns the name of a type's ABI kind as it appears in violation messages.
-}
kindName : Mono.MonoType -> String
kindName t =
    case abiKind t of
        KRawInt ->
            "raw-int"

        KRawFloat ->
            "raw-float"

        KRawChar ->
            "raw-char"

        KBoxed ->
            "boxed"
