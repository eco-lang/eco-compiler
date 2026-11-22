module Compiler.MonoOpt.MemberArity exposing
    ( MemberArity(..), memberArities
    , SetClass(..), classify, setArity
    )

{-| The first-stage arities of lambda-set members, and what the lambda set on a
callee's type says about how many arguments the closure it holds takes.

A complete set (`Mono.LSet`) names every function that can flow through its
arrow. When every member takes the same number of arguments in its first stage,
a call through that arrow can split its arguments at that number and leave the
rest of the call as it is. `setArity` gives that number. Step 5 of
GlobalOptimize records it on generic calls (`CallInfo.setArity`), and code
generation uses it only behind run-time guards (CGEN_094).
`Compiler.MonoOpt.GenCallCensus` counts calls by `classify`, so the census and
the hint cannot disagree.

@docs MemberArity, memberArities
@docs SetClass, classify, setArity

-}

import Array
import Compiler.Core.Id as Id
import Compiler.Elm.ModuleName as ModuleName
import Compiler.IR.Mono as Mono
import Compiler.IR.Mono.Traverse as MonoTraverse
import Dict exposing (Dict)
import Set exposing (Set)


{-| What is known of a member's first-stage arity: the arities of the closures
and values that carry it (`Known`), that it is a kernel function, whose closure
takes its whole flattened type's parameters (`KernelFlat`), or why it is not
known (`Unknown`: `define` or `node` for a global whose node shows no arity,
`noSpec` for a global with no specialization).
-}
type MemberArity
    = Known (Set Int)
    | KernelFlat
    | Unknown String


{-| Reads the member arities of a graph: the parameter counts of the closures
that carry each member (`lssMember`, else `srcLambda`, else the single member
of their type's head set), and for a member that `lssMemberOrigins` describes
and no closure carries, the arity of the value it stands for. It must be given
the graph before `Mono.clearLssTables` empties `lssMemberOrigins`.
-}
memberArities : Mono.MonoGraph -> Dict Int MemberArity
memberArities (Mono.MonoGraph mono) =
    let
        addKnown m arity acc =
            Dict.update m
                (\old ->
                    case old of
                        Just (Known xs) ->
                            Just (Known (Set.insert arity xs))

                        _ ->
                            Just (Known (Set.singleton arity))
                )
                acc

        closureMember info tipe =
            case info.lssMember of
                Just m ->
                    Just m

                Nothing ->
                    case info.srcLambda of
                        Just m ->
                            Just (Id.toComparable m)

                        Nothing ->
                            Mono.singletonHeadMember tipe

        fromClosures acc e =
            case e of
                Mono.MonoClosure info _ tipe ->
                    case closureMember info tipe of
                        Just m ->
                            addKnown m (List.length info.params) acc

                        Nothing ->
                            acc

                _ ->
                    acc

        nodeExpr node =
            case node of
                Mono.MonoDefine e _ ->
                    Just e

                Mono.MonoTailFunc _ e _ ->
                    Just e

                Mono.MonoPortIncoming e _ ->
                    Just e

                Mono.MonoPortOutgoing e _ ->
                    Just e

                _ ->
                    Nothing

        closureArities =
            Array.foldl
                (\maybeNode acc ->
                    case Maybe.andThen nodeExpr maybeNode of
                        Just e ->
                            MonoTraverse.foldExprAccFirst fromClosures acc e

                        Nothing ->
                            acc
                )
                Dict.empty
                mono.nodes

        flatArity t =
            case t of
                Mono.MFunction _ _ argTypes result ->
                    List.length argTypes + flatArity result

                _ ->
                    0

        nodeArity node =
            case node of
                Mono.MonoTailFunc ps _ _ ->
                    Ok (List.length ps)

                Mono.MonoDefine (Mono.MonoClosure info _ _) _ ->
                    Ok (List.length info.params)

                Mono.MonoPortIncoming (Mono.MonoClosure info _ _) _ ->
                    Ok (List.length info.params)

                Mono.MonoPortOutgoing (Mono.MonoClosure info _ _) _ ->
                    Ok (List.length info.params)

                Mono.MonoCtor _ shape _ ->
                    Ok (List.length shape.fieldTypes)

                Mono.MonoExtern t ->
                    Ok (flatArity t)

                Mono.MonoManagerLeaf _ t ->
                    Ok (flatArity t)

                Mono.MonoDefine _ _ ->
                    Err "define"

                _ ->
                    Err "node"

        -- Each global's node arities, by (home, name).
        globals =
            Array.foldl
                (\entry ( specId, acc ) ->
                    case ( entry, Array.get specId mono.nodes |> Maybe.andThen identity ) of
                        ( Just ( Mono.Global home name, _ ), Just node ) ->
                            ( specId + 1
                            , Dict.update ( ModuleName.toComparableCanonical home, name )
                                (\old -> Just (nodeArity node :: Maybe.withDefault [] old))
                                acc
                            )

                        _ ->
                            ( specId + 1, acc )
                )
                ( 0, Dict.empty )
                mono.registry.reverseMapping
                |> Tuple.second

        globalArity home name =
            case Dict.get ( ModuleName.toComparableCanonical home, name ) globals of
                Just results ->
                    List.foldl
                        (\r acc ->
                            case ( r, acc ) of
                                ( Ok a, Ok xs ) ->
                                    Ok (Set.insert a xs)

                                ( Err e, _ ) ->
                                    Err e

                                ( _, Err e ) ->
                                    Err e
                        )
                        (Ok Set.empty)
                        results

                Nothing ->
                    Err "noSpec"

        fromResult r =
            case r of
                Ok xs ->
                    Known xs

                Err why ->
                    Unknown why

        originArity origin =
            case origin of
                Mono.OriginGlobal home name ->
                    fromResult (globalArity home name)

                Mono.OriginCtor home name ->
                    fromResult (globalArity home name)

                Mono.OriginKernel _ _ _ ->
                    KernelFlat

                Mono.OriginAccessor _ ->
                    Known (Set.singleton 1)

                Mono.OriginPap home name k ->
                    fromResult (globalArity home name |> Result.map (Set.map (\a -> a - k)))
    in
    Dict.foldl
        (\m origin acc ->
            case Dict.get m acc of
                Just (Known _) ->
                    acc

                _ ->
                    Dict.insert m (originArity origin) acc
        )
        closureArities
        mono.lssMemberOrigins


{-| What the lambda set at the head of a callee's type says about the arity of
the closure it holds: no complete set (`SetTop` with the ⊤'s provenance label,
`SetVar`, `SetPartial`), a complete set with a member whose arity is not known
(`SetUnresolved`, with why: `none` for a member with no entry), a complete set
with no members (`SetEmpty`), members whose arities differ (`SetDisagree`), or
members that all take the same number of arguments (`SetAgree`).
-}
type SetClass
    = SetTop String
    | SetVar
    | SetPartial
    | SetUnresolved String
    | SetEmpty
    | SetDisagree
    | SetAgree Int


{-| Classifies the lambda set at the head of `calleeType`. A kernel member
takes as many arguments as `calleeType` has once flattened, as code generation
gives a kernel function value (`Ctx.kernelFuncSignatureFromType`).
-}
classify : Dict Int MemberArity -> Mono.MonoType -> SetClass
classify arities calleeType =
    case Mono.headAnno calleeType of
        Mono.LTop code ->
            SetTop (Mono.topKindLabel code)

        Mono.LVar _ ->
            SetVar

        Mono.LPartial _ ->
            SetPartial

        Mono.LSet members ->
            let
                memberSet m =
                    case Dict.get m arities of
                        Just (Known xs) ->
                            Ok xs

                        Just KernelFlat ->
                            Ok (Set.singleton (List.length (Tuple.first (Mono.decomposeFunctionType calleeType))))

                        Just (Unknown why) ->
                            Err why

                        Nothing ->
                            Err "none"

                resolved =
                    List.foldr
                        (\m acc ->
                            case ( memberSet m, acc ) of
                                ( Ok xs, Ok ys ) ->
                                    Ok (Set.union xs ys)

                                ( Err e, _ ) ->
                                    Err e

                                ( _, Err e ) ->
                                    Err e
                        )
                        (Ok Set.empty)
                        members
            in
            case resolved of
                Err why ->
                    SetUnresolved why

                Ok set ->
                    case Set.toList set of
                        [ arity ] ->
                            SetAgree arity

                        [] ->
                            SetEmpty

                        _ ->
                            SetDisagree


{-| The first-stage arity every member of the callee type's head set agrees
on, when the set is complete, every member's arity is known, and they agree on
one arity of at least 1.
-}
setArity : Dict Int MemberArity -> Mono.MonoType -> Maybe Int
setArity arities calleeType =
    case classify arities calleeType of
        SetAgree n ->
            if n >= 1 then
                Just n

            else
                Nothing

        _ ->
            Nothing
