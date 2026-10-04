module Compiler.GlobalOpt.Borrow.LssFacts exposing
    ( Facts, CalleeFacts(..), PoisonCause, LambdaRef, MemberInfo(..)
    , buildInstances, buildMemberTable, query, meetSig
    )

{-| Facts from lambda-set specialization (LSS) for borrow inference. Where LSS
knows a singleton lambda set, route the closure-call boundary through the
member's real signature instead of poisoning it — sound on
blocked/unresolvable members, and inert on all-`LTop` (subst) graphs
(`headAnno` never `LSet`).

**Scope:** this resolves **lambda members** (a closure whose singleton set is
found in the instance index → its computed lambda signature).
Standalone members (globals/ctors/kernels/accessors appearing in a lambda-set
position) resolve to `PUnresolved` — the full `MonoGraph.lssMemberOrigins`
routing for those is not implemented. Sound (conservative) and still recovers the
bulk of closure poison (direct closure calls).

The `byMember` index keying primitives (`instanceMember`/`isWrapperHome`) are
duplicated from `AbiCloning`, which does not export them.


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
import Compiler.GlobalOpt.Staging.Rewriter as Rewriter
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


{-| What a lambda-set member IS — one arm per member, never two.

The three arms partition the member universe by construction: `buildInstances`
EXCLUDES blocked members from the instance index, and standalone members
(`g|`/`c|`/`k|`/`a|` keys) never carry closure instances (`l|` keys do). That
is why this is one dict of a sum rather than three parallel dicts of the same
key set — `resolveMember`'s dispatch becomes ONE lookup instead of a
`Set.member` + `Dict.member` + `Dict.get` probe chain, and the graph carries
one tree instead of three.

-}
type MemberInfo
    = MemberBlocked
    | MemberInstances (List LambdaRef)
    | MemberStandalone Mono.MemberOrigin


{-| What the borrow analysis knows about lambda-set members: what each member is,
the signature computed for each lambda member, an index from global names to
their specializations, and the signature lookup for specializations.
-}
type alias Facts =
    { members : Dict Int MemberInfo
    , lambdaSigsByMember : Dict Int BorrowSig
    , globalIndex : Dict String (List ( Mono.MonoType, Mono.SpecId ))
    , sigs : Mono.SpecId -> Maybe BorrowSig
    }


{-| The outcome of asking about a closure-call callee: either a signature the
call can be routed through, or the reason the call boundary stays poisoned
(all-owned).
-}
type CalleeFacts
    = Routed BorrowSig
    | Poison PoisonCause


{-| Why a closure call could not be routed: the lambda set is unknown or only
partly known (`PTop`), a member is blocked (`PBlocked`), a member could not be
resolved to a signature source (`PUnresolved`), or the resolved member has no
signature (`PNoSig`).
-}
type PoisonCause
    = PTop
    | PBlocked
    | PUnresolved
    | PNoSig



-- INSTANCE INDEX (scan 1)


{-| `( byMember, blocked )` over all closures in the graph. A member is BLOCKED
iff any instance is adopted or wrapper-homed (block wins); blocked members
carry no refs.
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


{-| The member universe as ONE table (see `MemberInfo`).

Standalone origins seed it; blocked and instance members then claim their own
ids. The three sources are disjoint by construction, so insertion order is
immaterial — it is written origins-first only so the cheap map runs before the
fold.

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


collectFromNode : Mono.SpecId -> Mono.MonoNode -> List ( Int, Bool, LambdaRef )
collectFromNode specId node =
    case bodyOf node of
        Just body ->
            MonoTraverse.foldExpr (collectClosure specId) [] body

        Nothing ->
            []


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


collectClosure : Mono.SpecId -> Mono.MonoExpr -> List ( Int, Bool, LambdaRef ) -> List ( Int, Bool, LambdaRef )
collectClosure specId expr acc =
    case expr of
        Mono.MonoClosure closureInfo body tipe ->
            case instanceMember closureInfo tipe of
                Just ( m, isAdopted ) ->
                    ( m
                    , isAdopted || isWrapperHome closureInfo.lambdaId
                    , { lambdaId = closureInfo.lambdaId, enclosingSpecId = specId, closureInfo = closureInfo, body = body }
                    )
                        :: acc

                Nothing ->
                    acc

        _ ->
            acc


{-| Duplicated from `AbiCloning.instanceMember` (not exported): prefer the
minted-under member id (Fix B / LSS\_017), else the raw srcLambda, else the
singleton head member (adopted).
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


isWrapperHome : Mono.LambdaId -> Bool
isWrapperHome (Mono.AnonymousLambda home _) =
    home == Rewriter.wrapperHome



-- QUERY + DECLINE LADDER (design §10.3)


{-| Returns the facts for a call through a closure of the given type, from the
lambda set on its head. A known set has each member resolved; the first poison
wins, otherwise the members' signatures are combined with `meetSig`.
-}
query : Facts -> Mono.MonoType -> CalleeFacts
query facts calleeType =
    case Mono.headAnno calleeType of
        Mono.LTop _ ->
            Poison PTop

        Mono.LVar _ ->
            -- A set VARIABLE: to be determined, so it names no members yet.
            -- Exactly as unusable as a genuine ⊤ for the borrow oracle.
            Poison PTop

        Mono.LPartial _ ->
            -- A LOWER bound (lss-lpartial §2): unknown inhabitants may
            -- exist, so the oracle must not reason from the listed members.
            Poison PTop

        Mono.LSet [ m ] ->
            resolveMember facts calleeType m

        Mono.LSet ms ->
            -- multi-member: resolve each; propagate the first poison, else meet.
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
                            -- meet is call-site-only (BORROW_006), never written back.
                            Routed (List.foldl meetSig s rest)

                        [] ->
                            Poison PUnresolved


resolveMember : Facts -> Mono.MonoType -> Int -> CalleeFacts
resolveMember facts calleeType m =
    case Dict.get m facts.members of
        Just MemberBlocked ->
            Poison PBlocked

        Just (MemberInstances _) ->
            -- lambda member → its computed lambda signature.
            case Dict.get m facts.lambdaSigsByMember of
                Just sig ->
                    Routed sig

                Nothing ->
                    Poison PNoSig

        -- standalone member (global/ctor/kernel/accessor) via lssMemberOrigins.
        Just (MemberStandalone origin) ->
            case origin of
                Mono.OriginKernel home name ->
                    case KernelSigs.lookup ( home, name ) of
                        Just ksig ->
                            Routed (kernelToSig ksig calleeType)

                        Nothing ->
                            Poison PUnresolved

                Mono.OriginCtor _ ->
                    Routed (constructSig calleeType)

                Mono.OriginAccessor _ ->
                    Routed (accessorSig calleeType)

                Mono.OriginPap _ _ ->
                    -- A partial application's borrow signature is the
                    -- global's with its first `supplied` params already
                    -- consumed. Not derived here (v1 scope, BORROW_006's
                    -- standalone-v2 note); an unresolved member is the
                    -- all-owned boundary, which is sound.
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


{-| Resolve `OriginGlobal g` to a unique SpecId by layout-matching the callee
type against `globalIndex` (a Global is one-to-many over SpecIds). 0 or
ambiguous matches → `Nothing` (→ PUnresolved).
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



-- STANDALONE ADAPTERS (call-site-only sigs from the peeled callee type)


decompose : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )
decompose ty =
    case ty of
        Mono.MFunction _ _ params result ->
            ( params, result )

        _ ->
            ( [], ty )


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
        -- resultAliases is a list of param indices (U-T1.2): the result
        -- couples to every possibly-aliased param.
        case ksig.resultAliases of
            [] ->
                []

            is ->
                [ ( 0, Set.fromList is ) ]
    }


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


accessorSig : Mono.MonoType -> BorrowSig
accessorSig calleeType =
    let
        ( paramTypes, resultType ) =
            decompose calleeType
    in
    { params = List.map (Sig.uniformSigTy Borrowed) paramTypes
    , result = Sig.uniformSigTy Borrowed resultType

    -- the accessor's result is (a field of) its record arg → couples to param 0.
    , resultLts = [ ( 0, Set.singleton 0 ) ]
    }


paramModeToMode : KernelSigs.ParamMode -> Mode
paramModeToMode pm =
    case pm of
        KernelSigs.PBorrowed ->
            Borrowed

        KernelSigs.POwned ->
            Owned


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


firstPoison : List CalleeFacts -> Maybe PoisonCause
firstPoison list =
    case list of
        [] ->
            Nothing

        (Poison c) :: _ ->
            Just c

        (Routed _) :: rest ->
            firstPoison rest


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



-- MEET (BORROW_006): params any-owned wins, result any-borrowed wins.


{-| Combines two signatures into one that is safe for a call that may reach
either: a parameter position is `Owned` if it is owned in either, a result
position is `Borrowed` if it is borrowed in either, and the result couplings of
both are kept.
-}
meetSig : BorrowSig -> BorrowSig -> BorrowSig
meetSig a b =
    { params = map2Safe (meetSigTyWith modeOwnedWins) a.params b.params
    , result = meetSigTyWith modeBorrowedWins a.result b.result

    -- union the couplings (duplicate positions just add the same flows).
    , resultLts = a.resultLts ++ b.resultLts
    }


meetSigTyWith : (Mode -> Mode -> Mode) -> Sig.SigTy -> Sig.SigTy -> Sig.SigTy
meetSigTyWith combine a b =
    { shape = a.shape
    , modes = Array.fromList (map2Safe combine (Array.toList a.modes) (Array.toList b.modes))
    }


modeOwnedWins : Mode -> Mode -> Mode
modeOwnedWins x y =
    case ( x, y ) of
        ( Owned, _ ) ->
            Owned

        ( _, Owned ) ->
            Owned

        _ ->
            Borrowed


modeBorrowedWins : Mode -> Mode -> Mode
modeBorrowedWins x y =
    case ( x, y ) of
        ( Borrowed, _ ) ->
            Borrowed

        ( _, Borrowed ) ->
            Borrowed

        _ ->
            Owned


{-| `List.map2` that keeps the longer tail (defensive on shape mismatch).
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
