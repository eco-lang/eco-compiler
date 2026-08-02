module Compiler.GlobalOpt.Borrow.LssFacts exposing
    ( Facts, LambdaRef, CalleeFacts(..), PoisonCause(..)
    , buildInstances, query
    )

{-| LSS handshake facts (borrow-inference B3.5, design §10). Where LSS knows a
singleton lambda set, route the closure-call boundary through the member's
real signature instead of poisoning it — sound on blocked/unresolvable
members, and inert on all-`LTop` (subst) graphs (`headAnno` never `LSet`).

**v1 scope (documented):** this resolves **lambda members** (a closure whose
singleton set is found in the instance index → its computed lambda signature).
Standalone members (globals/ctors/kernels/accessors appearing in a lambda-set
position) resolve to `PUnresolved` — the full `MonoGraph.lssMemberOrigins`
routing for those is deferred. Sound (conservative) and still recovers the
bulk of closure poison (direct closure calls).

The `byMember` index keying primitives (`instanceMember`/`isWrapperHome`) are
duplicated from `AbiCloning` (not exported there; ~14 LoC) per the plan.

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


type alias LambdaRef =
    { lambdaId : Mono.LambdaId
    , enclosingSpecId : Mono.SpecId
    , closureInfo : Mono.ClosureInfo
    , body : Mono.MonoExpr
    }


type alias Facts =
    { byMember : Dict Int (List LambdaRef)
    , blocked : Set Int
    , lambdaSigsByMember : Dict Int BorrowSig

    -- B3.5 standalone-member routing:
    , origins : Dict Int Mono.MemberOrigin
    , globalIndex : Dict String (List ( Mono.MonoType, Mono.SpecId ))
    , sigs : Mono.SpecId -> Maybe BorrowSig
    }


type CalleeFacts
    = Routed BorrowSig
    | Poison PoisonCause


type PoisonCause
    = PTop
    | PBlocked
    | PUnresolved
    | PNoSig
    | PMixedMeet



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
minted-under member id (Fix B / LSS_017), else the raw srcLambda, else the
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


query : Facts -> Mono.MonoType -> CalleeFacts
query facts calleeType =
    case Mono.headAnno calleeType of
        Mono.LTop ->
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
    if Set.member m facts.blocked then
        Poison PBlocked

    else if Dict.member m facts.byMember then
        -- lambda member → its computed lambda signature.
        case Dict.get m facts.lambdaSigsByMember of
            Just sig ->
                Routed sig

            Nothing ->
                Poison PNoSig

    else
        -- standalone member (global/ctor/kernel/accessor) via lssMemberOrigins.
        case Dict.get m facts.origins of
            Just (Mono.OriginKernel home name) ->
                case KernelSigs.lookup ( home, name ) of
                    Just ksig ->
                        Routed (kernelToSig ksig calleeType)

                    Nothing ->
                        Poison PUnresolved

            Just (Mono.OriginCtor _) ->
                Routed (constructSig calleeType)

            Just (Mono.OriginAccessor _) ->
                Routed (accessorSig calleeType)

            Just (Mono.OriginGlobal g) ->
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
        Mono.MFunction _ params result ->
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
