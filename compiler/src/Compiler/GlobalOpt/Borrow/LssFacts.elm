module Compiler.GlobalOpt.Borrow.LssFacts exposing
    ( Facts, CalleeFacts(..), PoisonCause, LambdaRef, MemberInfo(..)
    , buildInstances, buildMemberTable, query, meetSig
    )

{-| Borrow inference has to decide, at every call through a closure, which
arguments the callee may only borrow and which it takes ownership of. Without
knowing which function the closure is, the only safe answer is that the callee
owns everything, a boundary called _poisoned_. This module answers the question
from the lambda sets that lambda-set specialization (LSS) leaves on function
types, so that a call whose callee is known can be _routed_ through the
callee's real borrow signature instead.

A _lambda set_ is the annotation on an arrow of a function type
(`Mono.headAnno`) listing the _members_, the functions that can flow there,
each by an integer member id. Only an `LSet` names a set that may be relied on;
an unknown set (`LTop`), a set still to be determined (`LVar`) and a lower
bound (`LPartial`) are all poisoned, so on a graph without lambda sets every
closure call is poisoned.

A member is one of three things, recorded in one table (`MemberInfo`). A
_lambda member_ stands for closures in the graph; its signature is computed
outside this module and supplied in `Facts`. A _standalone member_ stands for a
global, constructor, kernel, accessor or partial application used as a function
value (`Mono.MemberOrigin`); its signature is derived here from the callee type,
except for a partial application, which is not routed. A _blocked member_ is
one whose identity was taken from the closure's type rather than recorded on the
closure, so no signature may be taken from its instances.

`query` resolves each member of a set and either routes the call or names why
it stays poisoned. When a set has several members, their signatures are
combined with `meetSig` into one that is safe for any of them.

The rule for finding a closure's member id (`instanceMember`) is a copy of a
private function of `Compiler.GlobalOpt.AbiCloning`.


# Facts

@docs Facts, CalleeFacts, PoisonCause, LambdaRef, MemberInfo


# Building and querying

@docs buildInstances, buildMemberTable, query, meetSig

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Id as Id
import Compiler.GlobalOpt.Borrow.KernelSigs as KernelSigs
import Compiler.GlobalOpt.Borrow.Mode exposing (Mode(..))
import Compiler.GlobalOpt.Borrow.Sig as Sig exposing (BorrowSig)
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict exposing (Dict)
import Set exposing (Set)


{-| One closure instance of a lambda-set member: the lambda's id, the
specialization whose body contains the closure, its closure info, and its body.
-}
type alias LambdaRef =
    { lambdaId : Mono.LambdaId
    , enclosingSpecId : Mono.SpecId
    , closureInfo : Mono.ClosureInfo
    , body : Mono.MonoExpr
    }


{-| What one lambda-set member stands for.

`MemberBlocked` is a member that some closure was assigned only through its
type's singleton set, so its instances may not be used as a signature source.

`MemberInstances` is a lambda member with the closures in the graph that stand
for it.

`MemberStandalone` is a member that is not a lambda, with what it stands for.

-}
type MemberInfo
    = MemberBlocked
    | MemberInstances (List LambdaRef)
    | MemberStandalone Mono.MemberOrigin


{-| What `query` needs to resolve lambda-set members: what each member is, the
borrow signature of each lambda member, the specializations of each global with
their types, and the signature of a specialization.

`globalIndex` is keyed by `Mono.toComparableGlobal`.

-}
type alias Facts =
    { members : Dict Int MemberInfo
    , lambdaSigsByMember : Dict Int BorrowSig
    , globalIndex : Dict String (List ( Mono.MonoType, Mono.SpecId ))
    , sigs : Mono.SpecId -> Maybe BorrowSig
    }


{-| The answer for a call through a closure: the borrow signature to route the
call through, or the reason the call stays poisoned, owning every argument.
-}
type CalleeFacts
    = Routed BorrowSig
    | Poison PoisonCause


{-| Why a call through a closure could not be routed.

`PTop` is a lambda set that names no reliable members: `LTop`, `LVar` or
`LPartial`.

`PBlocked` is a blocked member.

`PUnresolved` is a member with no signature source: not in the member table, a
partial application, a kernel without a `KernelSigs` row, a global with no
single specialization of the callee's layout, or an `LSet` with no members.

`PNoSig` is a member resolved to a lambda member or a specialization that has
no signature.

-}
type PoisonCause
    = PTop
    | PBlocked
    | PUnresolved
    | PNoSig



-- INSTANCE INDEX (scan 1)


{-| Returns every closure in the bodies of the given nodes, indexed by member
id, together with the set of blocked members. The index of a node is its
`SpecId`.

A closure whose member id came from its type's singleton set rather than from
the closure itself (see `instanceMember`) blocks that member, and a blocked
member has no entry in the index even when other closures name it directly. A
closure with no member id at all is left out.

-}
buildInstances : Array (Maybe Mono.MonoNode) -> ( Dict Int (List LambdaRef), Set Int )
buildInstances nodes =
    let
        raw =
            Tuple.second
                (Array.foldl
                    (\maybeNode ( specId, acc ) ->
                        case maybeNode of
                            Just node ->
                                ( specId + 1, collectFromNode specId node ++ acc )

                            Nothing ->
                                ( specId + 1, acc )
                    )
                    ( 0, [] )
                    nodes
                )

        blocked =
            List.foldl
                (\( m, isBlocked, _ ) s ->
                    if isBlocked then
                        Set.insert m s

                    else
                        s
                )
                Set.empty
                raw

        byMember =
            List.foldl
                (\( m, _, ref ) d ->
                    if Set.member m blocked then
                        d

                    else
                        Dict.update m (\ex -> Just (ref :: Maybe.withDefault [] ex)) d
                )
                Dict.empty
                raw
    in
    ( byMember, blocked )


{-| Builds the member table from the closures in the given nodes (as
`buildInstances` collects them) and the origins of the members that are not
lambdas.

Origins are inserted first, then blocked members, then instance members, so a
member id that appears in more than one source takes the later kind.

-}
buildMemberTable : Array (Maybe Mono.MonoNode) -> Dict Int Mono.MemberOrigin -> Dict Int MemberInfo
buildMemberTable nodes origins =
    let
        ( byMember, blocked ) =
            buildInstances nodes

        fromOrigins =
            Dict.foldl (\m o acc -> Dict.insert m (MemberStandalone o) acc) Dict.empty origins

        withBlocked =
            Set.foldl (\m acc -> Dict.insert m MemberBlocked acc) fromOrigins blocked
    in
    Dict.foldl (\m refs acc -> Dict.insert m (MemberInstances refs) acc) withBlocked byMember


{-| Returns a `( member, isAdopted, ref )` row for each closure with a member id
in the node's body, or none for a node without a body.
-}
collectFromNode : Mono.SpecId -> Mono.MonoNode -> List ( Int, Bool, LambdaRef )
collectFromNode specId node =
    case bodyOf node of
        Just body ->
            MonoTraverse.foldExpr (collectClosure specId) [] body

        Nothing ->
            []


{-| Returns the expression body of a define, tail function or port node, and
`Nothing` for any other node.
-}
bodyOf : Mono.MonoNode -> Maybe Mono.MonoExpr
bodyOf node =
    case node of
        Mono.MonoDefine b _ ->
            Just b

        Mono.MonoTailFunc _ b _ ->
            Just b

        Mono.MonoPortIncoming b _ ->
            Just b

        Mono.MonoPortOutgoing b _ ->
            Just b

        _ ->
            Nothing


{-| Adds a row to `acc` when `expr` is a closure with a member id; any other
expression leaves `acc` unchanged.
-}
collectClosure : Mono.SpecId -> Mono.MonoExpr -> List ( Int, Bool, LambdaRef ) -> List ( Int, Bool, LambdaRef )
collectClosure specId expr acc =
    case expr of
        Mono.MonoClosure closureInfo body tipe ->
            case instanceMember closureInfo tipe of
                Just ( m, isAdopted ) ->
                    ( m
                    , isAdopted
                    , { lambdaId = closureInfo.lambdaId, enclosingSpecId = specId, closureInfo = closureInfo, body = body }
                    )
                        :: acc

                Nothing ->
                    acc

        _ ->
            acc


{-| Returns a closure's member id and whether it was _adopted_: the closure's
`lssMember` if set, else its `srcLambda`, else the single member of its type's
outermost lambda set, which is the adopted case.

This is a copy of a private function of `Compiler.GlobalOpt.AbiCloning`.

-}
instanceMember : Mono.ClosureInfo -> Mono.MonoType -> Maybe ( Int, Bool )
instanceMember closureInfo tipe =
    case closureInfo.lssMember of
        Just m ->
            Just ( m, False )

        Nothing ->
            case closureInfo.srcLambda of
                Just m ->
                    Just ( Id.toComparable m, False )

                Nothing ->
                    Maybe.map (\m -> ( m, True )) (Mono.singletonHeadMember tipe)



-- QUERY


{-| Returns the answer for a call through a closure of type `calleeType`, from
the lambda set on its outermost arrow.

`LTop`, `LVar` and `LPartial` give `Poison PTop`. For an `LSet`, each member is
resolved: a blocked member is poisoned; a lambda member routes through its
signature in `Facts`; a constructor routes through a signature owning every
argument and its result; an accessor through one borrowing its argument, with
its result borrowed and aliasing it; a kernel through its `KernelSigs`
signature; a global through the signature of its one specialization whose type
has the callee's layout. A partial application, and anything else not found, is
poisoned. With several members the first poisoned member, in set order, decides
the answer; if none is poisoned the signatures are combined with `meetSig`.

The signatures of constructors, accessors and kernels are built from
`calleeType`'s outermost arrow only.

-}
query : Facts -> Mono.MonoType -> CalleeFacts
query facts calleeType =
    case Mono.headAnno calleeType of
        Mono.LTop _ ->
            Poison PTop

        Mono.LVar _ ->
            Poison PTop

        Mono.LPartial _ ->
            -- A lower bound: functions not listed may also flow here.
            Poison PTop

        Mono.LSet [ m ] ->
            resolveMember facts calleeType m

        Mono.LSet ms ->
            let
                resolved =
                    List.map (resolveMember facts calleeType) ms
            in
            case firstPoison resolved of
                Just c ->
                    Poison c

                Nothing ->
                    case routedSigs resolved of
                        s :: rest ->
                            Routed (List.foldl meetSig s rest)

                        [] ->
                            Poison PUnresolved


{-| Returns the answer for one member of the callee's lambda set, as `query`
describes.
-}
resolveMember : Facts -> Mono.MonoType -> Int -> CalleeFacts
resolveMember facts calleeType m =
    case Dict.get m facts.members of
        Just MemberBlocked ->
            Poison PBlocked

        Just (MemberInstances _) ->
            case Dict.get m facts.lambdaSigsByMember of
                Just sig ->
                    Routed sig

                Nothing ->
                    Poison PNoSig

        Just (MemberStandalone origin) ->
            case origin of
                Mono.OriginKernel prefix home name ->
                    case KernelSigs.lookup ( prefix, home, name ) of
                        Just ksig ->
                            Routed (kernelToSig ksig calleeType)

                        Nothing ->
                            Poison PUnresolved

                Mono.OriginCtor _ ->
                    Routed (constructSig calleeType)

                Mono.OriginAccessor _ ->
                    Routed (accessorSig calleeType)

                Mono.OriginPap _ _ ->
                    -- Its signature would be the global's minus the supplied
                    -- arguments; that is not derived, so the call stays poisoned.
                    Poison PUnresolved

                Mono.OriginGlobal g ->
                    case matchGlobal facts g calleeType of
                        Just specId ->
                            case facts.sigs specId of
                                Just sig ->
                                    Routed sig

                                Nothing ->
                                    Poison PNoSig

                        Nothing ->
                            Poison PUnresolved

        Nothing ->
            Poison PUnresolved


{-| Returns the specialization of `g` whose type has the same layout as
`calleeType` (`Mono.eqLayout`), or `Nothing` when none or more than one does.
-}
matchGlobal : Facts -> Mono.Global -> Mono.MonoType -> Maybe Mono.SpecId
matchGlobal facts g calleeType =
    case Dict.get (Mono.toComparableGlobal g) facts.globalIndex of
        Just entries ->
            case List.filter (\( ty, _ ) -> Mono.eqLayout ty calleeType) entries of
                [ ( _, specId ) ] ->
                    Just specId

                _ ->
                    Nothing

        Nothing ->
            Nothing



-- SIGNATURES OF STANDALONE MEMBERS


{-| Returns the parameters and result of a function type's outermost arrow, or no
parameters and the type itself for any other type.
-}
decompose : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
decompose ty =
    case ty of
        Mono.MFunction _ _ params result ->
            ( params, result )

        _ ->
            ( [], ty )


{-| Builds the signature of a kernel member at `calleeType` from its kernel
signature.

Each parameter takes the kernel's mode for it, with `Owned` for parameters the
kernel signature does not list and extra kernel modes dropped. The result is
`Borrowed`, and when the kernel lists result aliases, result position 0 aliases
every one of them.

-}
kernelToSig : KernelSigs.KernelSig -> Mono.MonoType -> BorrowSig
kernelToSig ksig calleeType =
    let
        ( paramTypes, resultType ) =
            decompose calleeType

        modes =
            padModes (List.map paramModeToMode ksig.params) (List.length paramTypes)
    in
    { params = List.map2 Sig.uniformSigTy modes paramTypes
    , result = Sig.uniformSigTy Borrowed resultType
    , resultLts =
        case ksig.resultAliases of
            [] ->
                []

            is ->
                [ ( 0, Set.fromList is ) ]
    }


{-| Builds the signature of a constructor member at `calleeType`: every
parameter and the result owned, and the result aliasing nothing.
-}
constructSig : Mono.MonoType -> BorrowSig
constructSig calleeType =
    let
        ( paramTypes, resultType ) =
            decompose calleeType
    in
    { params = List.map (Sig.uniformSigTy Owned) paramTypes
    , result = Sig.uniformSigTy Owned resultType
    , resultLts = []
    }


{-| Builds the signature of a record accessor member at `calleeType`: every
parameter and the result borrowed, with result position 0 aliasing parameter 0,
the record the field is read from.
-}
accessorSig : Mono.MonoType -> BorrowSig
accessorSig calleeType =
    let
        ( paramTypes, resultType ) =
            decompose calleeType
    in
    { params = List.map (Sig.uniformSigTy Borrowed) paramTypes
    , result = Sig.uniformSigTy Borrowed resultType
    , resultLts = [ ( 0, Set.singleton 0 ) ]
    }


{-| Converts a kernel parameter mode to the borrow mode of the same name.
-}
paramModeToMode : KernelSigs.ParamMode -> Mode
paramModeToMode pm =
    case pm of
        KernelSigs.PBorrowed ->
            Borrowed

        KernelSigs.POwned ->
            Owned


{-| Returns `modes` cut or extended with `Owned` to exactly `n` entries.
-}
padModes : List Mode -> Int -> List Mode
padModes modes n =
    let
        len =
            List.length modes
    in
    if len >= n then
        List.take n modes

    else
        modes ++ List.repeat (n - len) Owned


{-| Returns the cause of the first poisoned answer in the list, if any.
-}
firstPoison : List CalleeFacts -> Maybe PoisonCause
firstPoison list =
    case list of
        [] ->
            Nothing

        (Poison c) :: _ ->
            Just c

        (Routed _) :: rest ->
            firstPoison rest


{-| Returns the signatures of the routed answers in the list, in order.
-}
routedSigs : List CalleeFacts -> List BorrowSig
routedSigs =
    List.filterMap
        (\cf ->
            case cf of
                Routed s ->
                    Just s

                Poison _ ->
                    Nothing
        )



-- MEET


{-| Combines two signatures into one for a call that may reach either function:
a parameter position is `Owned` if it is owned in either, a result position is
`Borrowed` if it is borrowed in either, and the result aliasing of both is kept.

Positions are paired in order. Where one signature has more parameters, or more
positions in a value, than the other, the extra entries are kept unchanged. The
result types are taken from `a`.

-}
meetSig : BorrowSig -> BorrowSig -> BorrowSig
meetSig a b =
    { params = map2Safe (meetSigTyWith modeOwnedWins) a.params b.params
    , result = meetSigTyWith modeBorrowedWins a.result b.result
    , resultLts = a.resultLts ++ b.resultLts
    }


{-| Combines the modes of two `SigTy`s position by position with `combine`,
keeping `a`'s type.
-}
meetSigTyWith : (Mode -> Mode -> Mode) -> Sig.SigTy -> Sig.SigTy -> Sig.SigTy
meetSigTyWith combine a b =
    { shape = a.shape
    , modes = Array.fromList (map2Safe combine (Array.toList a.modes) (Array.toList b.modes))
    }


{-| Returns `Owned` if either mode is `Owned`, otherwise `Borrowed`.
-}
modeOwnedWins : Mode -> Mode -> Mode
modeOwnedWins x y =
    case ( x, y ) of
        ( Owned, _ ) ->
            Owned

        ( _, Owned ) ->
            Owned

        _ ->
            Borrowed


{-| Returns `Borrowed` if either mode is `Borrowed`, otherwise `Owned`.
-}
modeBorrowedWins : Mode -> Mode -> Mode
modeBorrowedWins x y =
    case ( x, y ) of
        ( Borrowed, _ ) ->
            Borrowed

        ( _, Borrowed ) ->
            Borrowed

        _ ->
            Owned


{-| Combines two lists element by element like `List.map2`, but keeps the
leftover tail of the longer list instead of dropping it.
-}
map2Safe : (a -> a -> a) -> List a -> List a -> List a
map2Safe f xs ys =
    case ( xs, ys ) of
        ( x :: xr, y :: yr ) ->
            f x y :: map2Safe f xr yr

        ( rest, [] ) ->
            rest

        ( [], rest ) ->
            rest
