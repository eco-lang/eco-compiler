module Compiler.GlobalOpt.AbiCloning exposing
    ( AbiCloningStats, abiCloningPass
    , instanceFingerprint, peelStages
    )

{-| Lets a call through a closure value jump straight to the closure's code when
the pass can prove which closure arrives there, and leaves every other call on
generic dispatch.

Each arrow in a monomorphized type carries a lambda-set annotation naming the
functions, called _members_, that may flow through it (see
`Compiler.AST.Monomorphized`). When the outermost arrow of a call's callee type
is annotated with an `LSet` of exactly one member, the call is a _singleton
site_: only that member can arrive there. Knowing the member is not yet enough
to call its code. One source lambda becomes many closures in the graph, its
_instances_, one per specialization or inlined copy, and they may differ in the
types of their parameters, return value and captures. The pass looks for an
instance that whatever arrives at the site must be interchangeable with, and
_stamps_ the call's `CallInfo` with it: `closureKind`, `captureAbi`,
`fastEvaluator`, `fastEvaluatorSpec` and, for a partial application,
`fastPapPrefix`, with the meanings `Mono.CallInfo` gives them. A stamp is
trusted, not checked when the program runs, so a wrong one is a silent
miscompile. Each rule below makes the pass decline when interchangeability is
not proven, and a declined call keeps its `CallInfo` as it was.

The pass works in two halves.

The first builds an index of instances by member. A closure counts against the
member in its `lssMember`, or else its source lambda's id. A closure with
neither, whose own type names a single member, has an _adopted_ identity: it
claims the member without being a copy of the member's code, so it _blocks_
the member, and so does being listed in the graph's `lssBlockedMembers`. A
blocked member's sites are never stamped or rewritten. A member's instances are
divided into _layout groups_, whose instances have the same parameter and
return types apart from arrow annotations (`Mono.eqLayout`). The first instance
of a group in node order is its _representative_, the one a stamp names. A
group is stamped only while every instance in it has the representative's
capture types, apart from arrow annotations, there is no `Char` capture, and
every instance with another lambda id has the representative's
_fingerprint_. The fingerprint (`instanceFingerprint`) is a text rendering of a
closure in which the details that differ between copies of the same code are
left out or renumbered.

The second half walks the graph and decides each call. Only nodes that contain
a singleton site are walked; the others are kept as they are. At a singleton
site whose member has instances, the argument count is compared with the
callee type. A call that supplies exactly the parameters of a group is stamped
with its representative, directly or after flattening a curried callee type. A
call that supplies more is stamped for the first stage alone when only that
matches, and a callee that is an instance partially applied to some arguments
is stamped as such. At a singleton site whose member has no instance, the
member's origin in the graph's `lssMemberOrigins` can still name a target. A
call through a local variable to a global function or a constructor, supplying
all of its arguments, is rewritten to call the one specialization of that
global whose type matches, and a call through a partial application of a global
is stamped with that global's specialization. The match must be unique: two
specializations of one global with the same layout can compute different
functions. Sites whose annotation is any other `LSet`, an `LTop`, an `LVar` or
an `LPartial` are never stamped.

Most of the rest of the module is the census: the counts in `AbiCloningStats`,
and, when the pass runs with `census` on, tallies keyed by text that attribute
each outcome to the specialization containing the site. The census changes no
decision.


# API

@docs AbiCloningStats, abiCloningPass
@docs instanceFingerprint, peelStages

-}

import Array
import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Id as Id
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Compiler.Reporting.Annotation exposing (Region)
import Dict exposing (Dict)



-- ============================================================================
-- ====== STATS ======
-- ============================================================================


{-| The counts the pass reports about the calls it saw and what it did with each.

Only calls in nodes that contain at least one singleton site are seen, and none
at all when the graph has no closure, no member listed as blocked and no member
origin, in which case every count is zero.

Stamps: `dispatchUpgraded` counts sites stamped with an instance whose
parameters the call supplies exactly, either as the callee type's first stage
or after flattening a curried callee type (the latter also counted in
`instQual.flatStamped`). `stampedStaged` counts sites supplying more arguments
than the first stage, stamped for that stage. `stampedPapPrefix` counts sites
whose callee is an instance partially applied, and `stampedPapGlobal` sites
whose callee is a global function partially applied.

Declines at a member in the index (one with instances, or one that is blocked):
`declinedBlocked` for a blocked member. `declinedShape` for a site no layout
group fits, or whose fitting group has a `Char` capture or `Char` prefix, split
into `declinedShapeArity` (itself split into `Zero`, `Under` and `Over` by how
the argument count compares with the callee type's first stage),
`declinedShapeBucketMiss`, `declinedShapeLayout`, `declinedShapeChar` and
`declinedShapeNonArrow`, so that the parts add up to the whole.
`declinedAbiMismatch` counts sites whose group's capture types disagree, and
`declinedBodyMismatch` sites whose group's fingerprints disagree.

Sites whose member is not in the index (it has no instance and is not blocked):
`devirtPost.fn` and `devirtPost.ctor` count calls rewritten to call a function
or constructor specialization directly. `declinedNoInstance` counts the others
that were not stamped, among them `devirtPost.noSpec`, where no specialization
matched, and `devirtPost.ambiguous`, where no single one did.
`devirtPost.partialDeclined` counts `LPartial` sites, which are never stamped.

`multiInstanceGroups` counts layout groups holding two or more distinct lambda
ids. `blockedMembers` lists the blocked members in ascending order, each with
the adopted closure that blocked it, or `Nothing` when the graph listed it as
blocked.

Always collected as well: `declineByMember` counts the declines at each member
in the index (one with instances, or one that is blocked), and `memberReps`
gives the group representatives of the members appearing there or in a set of
several members. `multiSetSiteHist` counts sites by the size of a set that is
not a singleton, and `multiSetMembers` counts each member's appearances in such
sets. `topSiteShapes` and `varSiteShapes` count `LTop` and `LVar` sites by the
form of the callee expression.

`instQual` holds tallies keyed by text, filled only when the pass runs with
`census`: `byHost` counts outcomes by the global containing the site, `shape`
the over-applying declines, `niGuard` the reasons sites without an instance were
turned away, `absentL` rows per site and per member, and `multiSites` the
make-up of sets of other than one member. `papSites` is never added to: the only
key it accepts belongs to a site that is stamped instead. `flatStamped` is
counted whether or not `census` is on.

-}
type alias AbiCloningStats =
    { dispatchUpgraded : Int
    , stampedPapPrefix : Int
    , stampedPapGlobal : Int
    , stampedStaged : Int
    , declinedBlocked : Int
    , declinedNoInstance : Int
    , declinedShape : Int
    , declinedShapeArity : Int
    , declinedShapeArityZero : Int
    , declinedShapeArityUnder : Int
    , declinedShapeArityOver : Int
    , declinedShapeBucketMiss : Int
    , declinedShapeLayout : Int
    , declinedShapeChar : Int
    , declinedShapeNonArrow : Int
    , declinedAbiMismatch : Int
    , declinedBodyMismatch : Int
    , devirtPost : { fn : Int, ctor : Int, noSpec : Int, partialDeclined : Int, ambiguous : Int }
    , multiInstanceGroups : Int
    , declineByMember : Dict Int Int
    , memberReps : Dict Int (List Mono.LambdaId)
    , multiSetSiteHist : Dict Int Int
    , multiSetMembers : Dict Int Int
    , topSiteShapes : Dict String Int
    , varSiteShapes : Dict String Int
    , instQual : { byHost : Dict String Int, flatStamped : Int, shape : Dict String Int, niGuard : Dict String Int, papSites : Dict String Int, absentL : Dict String Int, multiSites : Dict String Int }
    , blockedMembers : List ( Int, Maybe Mono.LambdaId )
    }


{-| Statistics with every count zero and every tally empty.
-}
emptyStats : AbiCloningStats
emptyStats =
    { dispatchUpgraded = 0
    , stampedPapPrefix = 0
    , stampedPapGlobal = 0
    , stampedStaged = 0
    , declinedBlocked = 0
    , declinedNoInstance = 0
    , declinedShape = 0
    , declinedShapeArity = 0
    , declinedShapeArityZero = 0
    , declinedShapeArityUnder = 0
    , declinedShapeArityOver = 0
    , declinedShapeBucketMiss = 0
    , declinedShapeLayout = 0
    , declinedShapeChar = 0
    , declinedShapeNonArrow = 0
    , declinedAbiMismatch = 0
    , declinedBodyMismatch = 0
    , devirtPost = { fn = 0, ctor = 0, noSpec = 0, partialDeclined = 0, ambiguous = 0 }
    , multiInstanceGroups = 0
    , declineByMember = Dict.empty
    , memberReps = Dict.empty
    , multiSetSiteHist = Dict.empty
    , multiSetMembers = Dict.empty
    , topSiteShapes = Dict.empty
    , varSiteShapes = Dict.empty
    , instQual = { byHost = Dict.empty, flatStamped = 0, shape = Dict.empty, niGuard = Dict.empty, papSites = Dict.empty, absentL = Dict.empty, multiSites = Dict.empty }
    , blockedMembers = []
    }



-- ============================================================================
-- ====== INSTANCE INDEX ======
-- ============================================================================


{-| What the index holds for one member: whether its sites may be stamped, and its
instances in layout groups.

`buckets` files the groups under `siteFingerprint` keys. One key can cover
several groups, which `Mono.eqLayout` tells apart. A blocked member has no
buckets.

-}
type alias MemberInfo =
    { blocked : Bool
    , blockedBy : Maybe Mono.LambdaId -- the adopted closure that blocked it; Nothing when the graph lists it
    , buckets : Dict String (List LayoutGroup)
    }


{-| The instances of one member that share a parameter and return layout, with what
is known about whether a stamp naming `rep` is right for all of them.

`rep` is the first instance in node order and is the one a stamp names.
`unanimous` is whether every instance's capture types equal `rep`'s apart from
arrow annotations, and `charFree` whether `rep` has no `Char` capture.
`fpUnanimous` is whether every instance with a lambda id other than `rep`'s has
`rep`'s fingerprint; it is kept up to date only while it and `unanimous` are
both `True`, and once either is `False` the group is never stamped.
`paramCount` is the number of `rep`'s parameters.

-}
type alias LayoutGroup =
    { rep : Instance
    , paramCount : Int
    , unanimous : Bool
    , charFree : Bool
    , multi : Bool -- statistics only
    , fpUnanimous : Bool
    , repFp : Maybe String -- computed on first need
    , count : Int -- statistics only
    }


{-| One closure as the index records it: its lambda id, its capture, parameter and
return types, its header and body for the fingerprint, and `topLevelSpec`.

`topLevelSpec` is the SpecId whose function this closure is emitted as, set
when the closure is the capture-free top-level expression of a definition or
port node, and `Nothing` otherwise (see `fastEvaluatorSpec` on `Mono.CallInfo`).

-}
type alias Instance =
    { lambdaId : Mono.LambdaId
    , captureTypes : List Mono.MonoType
    , paramTypes : List Mono.MonoType
    , returnType : Mono.MonoType
    , info : Mono.ClosureInfo
    , body : Mono.MonoExpr
    , topLevelSpec : Maybe Mono.SpecId
    }


{-| The depth to which `siteFingerprint` renders each type. Layouts that agree to
this depth share a bucket key and are told apart by a full `Mono.eqLayout`
comparison, so a shared key costs a comparison, not a wrong stamp.
-}
fingerprintDepth : Int
fingerprintDepth =
    4


{-| Returns the bucket key for parameter types `params` and return type `ret`: each
type's `Mono.shallowLayoutKey` to `fingerprintDepth`.
-}
siteFingerprint : List Mono.MonoType -> Mono.MonoType -> String
siteFingerprint params ret =
    String.join "," (List.map (Mono.shallowLayoutKey fingerprintDepth) params)
        ++ "->"
        ++ Mono.shallowLayoutKey fingerprintDepth ret


{-| Builds the instance index of a graph, by member id. Nodes are walked in SpecId
order, which decides each layout group's representative. Members the graph
lists as blocked are not added here.
-}
collectInstances : Mono.MonoGraph -> Dict Int MemberInfo
collectInstances (Mono.MonoGraph record) =
    Tuple.second
        (Array.foldl
            (\maybeNode ( specId, acc ) ->
                case maybeNode of
                    Just node ->
                        ( specId + 1, collectNode specId node acc )

                    Nothing ->
                        ( specId + 1, acc )
            )
            ( 0, Dict.empty )
            record.nodes
        )


{-| Adds the closures of one node to the index. When a `MonoDefine` or port node's
whole expression is a closure, that closure is offered `specId` as its
`topLevelSpec`, which `collectClosure` keeps only for a capture-free closure.
A `MonoTailFunc`'s expression is its body, so a closure there
is a nested one.
-}
collectNode : Mono.SpecId -> Mono.MonoNode -> Dict Int MemberInfo -> Dict Int MemberInfo
collectNode specId node acc =
    case node of
        Mono.MonoDefine ((Mono.MonoClosure _ _ _) as expr) _ ->
            collectClosure (Just specId) expr acc

        Mono.MonoPortIncoming ((Mono.MonoClosure _ _ _) as expr) _ ->
            collectClosure (Just specId) expr acc

        Mono.MonoPortOutgoing ((Mono.MonoClosure _ _ _) as expr) _ ->
            collectClosure (Just specId) expr acc

        _ ->
            List.foldl collectGo acc (nodeExprs node)


{-| Returns the expression a definition, tail function or port node holds, or
nothing for the other kinds of node.
-}
nodeExprs : Mono.MonoNode -> List Mono.MonoExpr
nodeExprs node =
    case node of
        Mono.MonoDefine expr _ ->
            [ expr ]

        Mono.MonoTailFunc _ expr _ ->
            [ expr ]

        Mono.MonoPortIncoming expr _ ->
            [ expr ]

        Mono.MonoPortOutgoing expr _ ->
            [ expr ]

        Mono.MonoCtor _ _ ->
            []

        Mono.MonoEnum _ _ ->
            []

        Mono.MonoExtern _ ->
            []

        Mono.MonoManagerLeaf _ _ ->
            []


{-| Adds every closure in `expr`, at any depth, to the index as a nested closure.
-}
collectGo : Mono.MonoExpr -> Dict Int MemberInfo -> Dict Int MemberInfo
collectGo expr acc =
    case expr of
        Mono.MonoClosure _ _ _ ->
            collectClosure Nothing expr acc

        _ ->
            collectOther expr acc


{-| Adds one closure, and every closure in its captures and body, to the index.

`topLevelSpec` is recorded on the instance only when the closure has no
captures. A closure with an adopted identity replaces its member's entry with a
blocked one and no groups, and a closure of a member that is already blocked is
ignored. Given an expression that is not a closure, it returns `acc` unchanged.

-}
collectClosure : Maybe Mono.SpecId -> Mono.MonoExpr -> Dict Int MemberInfo -> Dict Int MemberInfo
collectClosure topLevelSpec expr acc =
    case expr of
        Mono.MonoClosure closureInfo body tipe ->
            let
                emittedSpec =
                    if List.isEmpty closureInfo.captures then
                        topLevelSpec

                    else
                        Nothing

                acc1 =
                    case instanceMember closureInfo tipe of
                        Just ( m, isAdopted ) ->
                            if isAdopted then
                                Dict.insert m { blocked = True, blockedBy = Just closureInfo.lambdaId, buckets = Dict.empty } acc

                            else
                                Dict.update m
                                    (\present ->
                                        case present of
                                            Just mi ->
                                                if mi.blocked then
                                                    present

                                                else
                                                    Just { mi | buckets = insertInstance emittedSpec closureInfo body mi.buckets }

                                            Nothing ->
                                                Just { blocked = False, blockedBy = Nothing, buckets = insertInstance emittedSpec closureInfo body Dict.empty }
                                    )
                                    acc

                        Nothing ->
                            acc

                acc2 =
                    List.foldl (\( _, e, _ ) a -> collectGo e a) acc1 closureInfo.captures
            in
            collectGo body acc2

        _ ->
            acc


{-| Adds the closures inside an expression to the index, as nested closures.
-}
collectOther : Mono.MonoExpr -> Dict Int MemberInfo -> Dict Int MemberInfo
collectOther expr acc =
    case expr of
        Mono.MonoCall _ func args _ _ ->
            List.foldl collectGo (collectGo func acc) args

        Mono.MonoTailCall _ args _ ->
            List.foldl (\( _, e ) a -> collectGo e a) acc args

        Mono.MonoIf branches final _ ->
            collectGo final (List.foldl (\( c, t ) a -> collectGo t (collectGo c a)) acc branches)

        Mono.MonoLet def body _ ->
            collectGo body (collectGoDef def acc)

        Mono.MonoDestruct _ inner _ ->
            collectGo inner acc

        Mono.MonoCase _ _ decider jumps _ ->
            List.foldl (\( _, e ) a -> collectGo e a) (collectGoDecider decider acc) jumps

        Mono.MonoList _ items _ ->
            List.foldl collectGo acc items

        Mono.MonoRecordCreate fields _ ->
            List.foldl (\( _, e ) a -> collectGo e a) acc fields

        Mono.MonoRecordAccess inner _ _ ->
            collectGo inner acc

        Mono.MonoRecordUpdate record updates _ ->
            List.foldl (\( _, e ) a -> collectGo e a) (collectGo record acc) updates

        Mono.MonoTupleCreate _ elements _ ->
            List.foldl collectGo acc elements

        Mono.MonoLiteral _ _ ->
            acc

        Mono.MonoVarLocal _ _ ->
            acc

        Mono.MonoVarGlobal _ _ _ ->
            acc

        Mono.MonoVarKernel _ _ _ _ _ ->
            acc

        Mono.MonoUnit ->
            acc

        Mono.MonoAccessorValue _ _ _ ->
            acc

        Mono.MonoClosure _ _ _ ->
            collectClosure Nothing expr acc


{-| Adds the closures inside a let definition's expression to the index.
-}
collectGoDef : Mono.MonoDef -> Dict Int MemberInfo -> Dict Int MemberInfo
collectGoDef def acc =
    case def of
        Mono.MonoDef _ e ->
            collectGo e acc

        Mono.MonoTailDef _ _ e ->
            collectGo e acc


{-| Adds the closures in a decision tree's inline leaves to the index. Jump targets
are reached through the case's jump list instead.
-}
collectGoDecider : Mono.Decider Mono.MonoChoice -> Dict Int MemberInfo -> Dict Int MemberInfo
collectGoDecider decider acc =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            collectGo e acc

        Mono.Leaf (Mono.Jump _) ->
            acc

        Mono.Chain _ success failure ->
            collectGoDecider failure (collectGoDecider success acc)

        Mono.FanOut _ edges fallback ->
            collectGoDecider fallback (List.foldl (\( _, d ) a -> collectGoDecider d a) acc edges)


{-| Files a closure as an instance in `buckets`, under the key of its parameter
types and its body's type, joining or starting a layout group.
-}
insertInstance : Maybe Mono.SpecId -> Mono.ClosureInfo -> Mono.MonoExpr -> Dict String (List LayoutGroup) -> Dict String (List LayoutGroup)
insertInstance emittedSpec closureInfo body buckets =
    let
        paramTypes =
            List.map Tuple.second closureInfo.params

        returnType =
            Mono.typeOf body

        inst =
            { lambdaId = closureInfo.lambdaId
            , captureTypes = List.map (\( _, e, _ ) -> Mono.typeOf e) closureInfo.captures
            , paramTypes = paramTypes
            , returnType = returnType
            , info = closureInfo
            , body = body
            , topLevelSpec = emittedSpec
            }
    in
    Dict.update (siteFingerprint paramTypes returnType)
        (\present -> Just (joinGroup inst (Maybe.withDefault [] present)))
        buckets


{-| Adds `inst` to the first group in `groups` with the same parameter and return
layout, or puts it in a new group of its own, last, as representative.

An instance with the representative's own lambda id updates only `unanimous` and
the count. Any other marks the group `multi` and, while `unanimous` and
`fpUnanimous` both hold, compares its fingerprint with the representative's,
computing the representative's and keeping it in `repFp` the first time it is
needed.

-}
joinGroup : Instance -> List LayoutGroup -> List LayoutGroup
joinGroup inst groups =
    case groups of
        [] ->
            [ { rep = inst
              , paramCount = List.length inst.paramTypes
              , unanimous = True
              , charFree = not (List.any ((==) Mono.MChar) inst.captureTypes)
              , multi = False
              , fpUnanimous = True
              , repFp = Nothing
              , count = 1
              }
            ]

        g :: rest ->
            if sameSignatureLayout g.rep inst then
                if inst.lambdaId == g.rep.lambdaId then
                    { g | unanimous = g.unanimous && sameCaptureLayout g.rep inst, count = g.count + 1 } :: rest

                else
                    let
                        uni1 =
                            g.unanimous && sameCaptureLayout g.rep inst

                        ( fpU1, repFp1 ) =
                            if not (uni1 && g.fpUnanimous) then
                                ( g.fpUnanimous, g.repFp )

                            else
                                let
                                    rf =
                                        case g.repFp of
                                            Just f ->
                                                f

                                            Nothing ->
                                                fpOf g.rep
                                in
                                ( fpOf inst == rf, Just rf )
                    in
                    { g
                        | unanimous = uni1
                        , multi = True
                        , fpUnanimous = fpU1
                        , repFp = repFp1
                        , count = g.count + 1
                    }
                        :: rest

            else
                g :: joinGroup inst rest


{-| Returns whether two instances' parameter and return types are the same apart
from arrow annotations.
-}
sameSignatureLayout : Instance -> Instance -> Bool
sameSignatureLayout a b =
    eqLayoutLists a.paramTypes b.paramTypes && Mono.eqLayout a.returnType b.returnType


{-| Returns whether two instances' capture types are the same apart from arrow
annotations.
-}
sameCaptureLayout : Instance -> Instance -> Bool
sameCaptureLayout a b =
    eqLayoutLists a.captureTypes b.captureTypes


{-| Returns whether two lists of types have the same length and are pairwise equal
apart from arrow annotations.
-}
eqLayoutLists : List Mono.MonoType -> List Mono.MonoType -> Bool
eqLayoutLists xs ys =
    case ( xs, ys ) of
        ( [], [] ) ->
            True

        ( x :: restX, y :: restY ) ->
            Mono.eqLayout x y && eqLayoutLists restX restY

        _ ->
            False


{-| Returns the member id a closure counts against, and whether that identity is
adopted.

The closure's `lssMember` is used when it has one, and its source lambda's id
otherwise. A closure with neither takes the member that the head annotation of
its own type names, when that annotation is an `LSet` of one member, and that
identity is adopted: the closure claims the member through its type without
being a copy of the member's code. Any other closure with neither id is not
indexed.

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



-- ============================================================================
-- ====== STAMPING ======
-- ============================================================================


{-| The state threaded through the walk: the closure kind numbers given out so
far, the statistics, and the tables the post-settle path and the census read.

`kindIds` gives each stamped member a `ClosureKindId` number, in the order
members are first stamped, and `nextKind` is the next number to give.
`hostGlobal` and `hostSpecId` name the node being walked, for the census.

-}
type alias StampCtx =
    { kindIds : Dict Int Int
    , nextKind : Int
    , stats : AbiCloningStats
    , origins : Dict Int Mono.MemberOrigin -- the graph's lssMemberOrigins
    , specsByGlobal : Dict String (List ( Int, Mono.MonoType )) -- each global's (SpecId, type) pairs
    , hostGlobal : String -- the global owning the node walked; "?" off census
    , hostSpecId : Int
    , specNodes : Array.Array (Maybe Mono.MonoNode) -- the graph's nodes, by SpecId
    , memberKinds : Dict Int String -- the graph's lssMemberKinds
    , srcIndex : Dict Int (List (Maybe Int)) -- empty off census; see collectSrcIndex
    , census : Bool
    }


{-| Stamps every call through a closure value whose target it can prove, as the
module docstring describes, and returns the new graph with the statistics.
`census` turns on the tallies in `AbiCloningStats.instQual`; it changes no
stamping decision.

The graph is returned unchanged, with every count zero, when it has no closure,
no member listed in `lssBlockedMembers` and no entry in `lssMemberOrigins`.
Otherwise every node is walked, and a node with no singleton site is returned
as it was.

-}
abiCloningPass : Bool -> Mono.MonoGraph -> ( Mono.MonoGraph, AbiCloningStats )
abiCloningPass census ((Mono.MonoGraph record) as graph) =
    let
        -- Members the graph lists as blocked replace whatever the walk found.
        index =
            Dict.foldl
                (\m () acc -> Dict.insert m { blocked = True, blockedBy = Nothing, buckets = Dict.empty } acc)
                (collectInstances graph)
                record.lssBlockedMembers
    in
    if Dict.isEmpty index && Dict.isEmpty record.lssMemberOrigins then
        -- Post-settle rewriting reads the origins, not the index, so an
        -- empty index alone is no reason to stop.
        ( graph, emptyStats )

    else
        let
            stats0 =
                { emptyStats
                    | multiInstanceGroups = countMultiInstanceGroups index
                    , instQual =
                        { byHost = Dict.empty
                        , flatStamped = 0
                        , shape = Dict.empty
                        , niGuard = Dict.empty
                        , papSites = Dict.empty
                        , absentL =
                            if census then
                                indexSummary index

                            else
                                Dict.empty
                        , multiSites = Dict.empty
                        }
                    , blockedMembers =
                        Dict.foldr
                            (\m mi acc ->
                                if mi.blocked then
                                    ( m, mi.blockedBy ) :: acc

                                else
                                    acc
                            )
                            []
                            index
                }

            -- Each global's specs, in descending SpecId order.
            specsByGlobal =
                Tuple.second
                    (Array.foldl
                        (\maybeEntry ( i, acc ) ->
                            case maybeEntry of
                                Just ( global, specType ) ->
                                    ( i + 1
                                    , Dict.update (Mono.toComparableGlobal global)
                                        (\v -> Just (( i, specType ) :: Maybe.withDefault [] v))
                                        acc
                                    )

                                Nothing ->
                                    ( i + 1, acc )
                        )
                        ( 0, Dict.empty )
                        record.registry.reverseMapping
                    )

            ( ( nodes1, _ ), finalCtx ) =
                Array.foldl
                    (\maybeNode ( ( accNodes, specId ), accCtx ) ->
                        case maybeNode of
                            Just node ->
                                let
                                    ( newNode, ctx1 ) =
                                        stampNode index
                                            { accCtx
                                                | hostGlobal =
                                                    if census then
                                                        hostGlobalAt record.registry.reverseMapping specId

                                                    else
                                                        "?"
                                                , hostSpecId = specId
                                            }
                                            node
                                in
                                ( ( Array.push (Just newNode) accNodes, specId + 1 ), ctx1 )

                            Nothing ->
                                ( ( Array.push Nothing accNodes, specId + 1 ), accCtx )
                    )
                    ( ( Array.empty, 0 )
                    , { kindIds = Dict.empty
                      , nextKind = 0
                      , stats = stats0
                      , origins = record.lssMemberOrigins
                      , specsByGlobal = specsByGlobal
                      , census = census
                      , hostGlobal = "?"
                      , hostSpecId = -1
                      , specNodes = record.nodes
                      , memberKinds = record.lssMemberKinds
                      , srcIndex =
                            if census then
                                collectSrcIndex record.nodes

                            else
                                Dict.empty
                      }
                    )
                    record.nodes
        in
        ( Mono.MonoGraph { record | nodes = nodes1 }, finalCtx.stats )


{-| Returns the comparable key of the global that SpecId `specId` specializes, or
`"?"` when the registry has no entry for it.
-}
hostGlobalAt : Array.Array (Maybe ( Mono.Global, Mono.MonoType )) -> Int -> String
hostGlobalAt reverseMapping specId =
    case Array.get specId reverseMapping of
        Just (Just ( global, _ )) ->
            Mono.toComparableGlobal global

        _ ->
            "?"


{-| Counts the layout groups in the index that hold two or more distinct lambda
ids.
-}
countMultiInstanceGroups : Dict Int MemberInfo -> Int
countMultiInstanceGroups index =
    Dict.foldl
        (\_ mi acc ->
            Dict.foldl
                (\_ groups acc2 ->
                    List.foldl
                        (\g a ->
                            if g.multi then
                                a + 1

                            else
                                a
                        )
                        acc2
                        groups
                )
                acc
                mi.buckets
        )
        0
        index


{-| Stamps the calls in a node's expression. Nodes that hold no expression are
returned unchanged.
-}
stampNode : Dict Int MemberInfo -> StampCtx -> Mono.MonoNode -> ( Mono.MonoNode, StampCtx )
stampNode index ctx node =
    case node of
        Mono.MonoDefine expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    stampExprTree index ctx expr
            in
            ( Mono.MonoDefine newExpr tipe, ctx1 )

        Mono.MonoTailFunc params expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    stampExprTree index ctx expr
            in
            ( Mono.MonoTailFunc params newExpr tipe, ctx1 )

        Mono.MonoPortIncoming expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    stampExprTree index ctx expr
            in
            ( Mono.MonoPortIncoming newExpr tipe, ctx1 )

        Mono.MonoPortOutgoing expr tipe ->
            let
                ( newExpr, ctx1 ) =
                    stampExprTree index ctx expr
            in
            ( Mono.MonoPortOutgoing newExpr tipe, ctx1 )

        other ->
            ( other, ctx )


{-| Stamps the calls in one expression tree, or returns the tree unchanged, without
rebuilding it, when it contains no singleton site.
-}
stampExprTree : Dict Int MemberInfo -> StampCtx -> Mono.MonoExpr -> ( Mono.MonoExpr, StampCtx )
stampExprTree index ctx expr =
    if scanExpr index expr then
        goExpr index ctx expr

    else
        ( expr, ctx )


{-| Returns whether `expr` contains a call whose callee type has an `LSet` of
exactly one member as its head annotation. `index` is not read.
-}
scanExpr : Dict Int MemberInfo -> Mono.MonoExpr -> Bool
scanExpr index expr =
    case expr of
        Mono.MonoCall _ func args _ _ ->
            isSingletonHead func || scanExpr index func || List.any (scanExpr index) args

        Mono.MonoClosure info body _ ->
            List.any (\( _, e, _ ) -> scanExpr index e) info.captures || scanExpr index body

        Mono.MonoTailCall _ args _ ->
            List.any (\( _, e ) -> scanExpr index e) args

        Mono.MonoIf branches final _ ->
            List.any (\( c, t ) -> scanExpr index c || scanExpr index t) branches || scanExpr index final

        Mono.MonoLet def body _ ->
            scanDef index def || scanExpr index body

        Mono.MonoDestruct _ inner _ ->
            scanExpr index inner

        Mono.MonoCase _ _ decider jumps _ ->
            scanDecider index decider || List.any (\( _, e ) -> scanExpr index e) jumps

        Mono.MonoList _ items _ ->
            List.any (scanExpr index) items

        Mono.MonoRecordCreate fields _ ->
            List.any (\( _, e ) -> scanExpr index e) fields

        Mono.MonoRecordAccess inner _ _ ->
            scanExpr index inner

        Mono.MonoRecordUpdate record updates _ ->
            scanExpr index record || List.any (\( _, e ) -> scanExpr index e) updates

        Mono.MonoTupleCreate _ elements _ ->
            List.any (scanExpr index) elements

        Mono.MonoLiteral _ _ ->
            False

        Mono.MonoVarLocal _ _ ->
            False

        Mono.MonoVarGlobal _ _ _ ->
            False

        Mono.MonoVarKernel _ _ _ _ _ ->
            False

        Mono.MonoUnit ->
            False

        Mono.MonoAccessorValue _ _ _ ->
            False


{-| Returns whether the head annotation of `func`'s type is an `LSet` of exactly
one member.
-}
isSingletonHead : Mono.MonoExpr -> Bool
isSingletonHead func =
    case Mono.headAnno (Mono.typeOf func) of
        Mono.LSet [ _ ] ->
            True

        _ ->
            False


{-| Returns whether a let definition's expression contains a singleton site.
-}
scanDef : Dict Int MemberInfo -> Mono.MonoDef -> Bool
scanDef index def =
    case def of
        Mono.MonoDef _ e ->
            scanExpr index e

        Mono.MonoTailDef _ _ e ->
            scanExpr index e


{-| Returns whether a decision tree's inline leaves contain a singleton site.
-}
scanDecider : Dict Int MemberInfo -> Mono.Decider Mono.MonoChoice -> Bool
scanDecider index decider =
    case decider of
        Mono.Leaf choice ->
            scanChoice index choice

        Mono.Chain _ success failure ->
            scanDecider index success || scanDecider index failure

        Mono.FanOut _ edges fallback ->
            List.any (\( _, d ) -> scanDecider index d) edges || scanDecider index fallback


{-| Returns whether a decision-tree leaf's inline expression contains a singleton
site; a jump does not.
-}
scanChoice : Dict Int MemberInfo -> Mono.MonoChoice -> Bool
scanChoice index choice =
    case choice of
        Mono.Inline e ->
            scanExpr index e

        Mono.Jump _ ->
            False


{-| Stamps every call in `expr`, stamping a call's callee and arguments before the
call itself and threading the context left to right.
-}
goExpr : Dict Int MemberInfo -> StampCtx -> Mono.MonoExpr -> ( Mono.MonoExpr, StampCtx )
goExpr index ctx expr =
    case expr of
        Mono.MonoCall region func args resultType callInfo ->
            let
                ( newFunc, ctx1 ) =
                    goExpr index ctx func

                ( newArgs, ctx2 ) =
                    goList index ctx1 args
            in
            stampCall index ctx2 region newFunc newArgs resultType callInfo

        Mono.MonoClosure info body closureType ->
            let
                ( newCaptures, ctx1 ) =
                    goCaptures index ctx info.captures

                ( newBody, ctx2 ) =
                    goExpr index ctx1 body
            in
            ( Mono.MonoClosure { info | captures = newCaptures } newBody closureType, ctx2 )

        Mono.MonoTailCall name args resultType ->
            let
                ( newArgs, ctx1 ) =
                    goNamedList index ctx args
            in
            ( Mono.MonoTailCall name newArgs resultType, ctx1 )

        Mono.MonoIf branches final resultType ->
            let
                ( newBranches, ctx1 ) =
                    goBranches index ctx branches

                ( newFinal, ctx2 ) =
                    goExpr index ctx1 final
            in
            ( Mono.MonoIf newBranches newFinal resultType, ctx2 )

        Mono.MonoLet def body resultType ->
            let
                ( newDef, ctx1 ) =
                    goDef index ctx def

                ( newBody, ctx2 ) =
                    goExpr index ctx1 body
            in
            ( Mono.MonoLet newDef newBody resultType, ctx2 )

        Mono.MonoDestruct path inner resultType ->
            let
                ( newInner, ctx1 ) =
                    goExpr index ctx inner
            in
            ( Mono.MonoDestruct path newInner resultType, ctx1 )

        Mono.MonoCase label scrutinee decider jumps resultType ->
            let
                ( newDecider, ctx1 ) =
                    goDecider index ctx decider

                ( newJumps, ctx2 ) =
                    goJumps index ctx1 jumps
            in
            ( Mono.MonoCase label scrutinee newDecider newJumps resultType, ctx2 )

        Mono.MonoList region items resultType ->
            let
                ( newItems, ctx1 ) =
                    goList index ctx items
            in
            ( Mono.MonoList region newItems resultType, ctx1 )

        Mono.MonoRecordCreate fields resultType ->
            let
                ( newFields, ctx1 ) =
                    goNamedList index ctx fields
            in
            ( Mono.MonoRecordCreate newFields resultType, ctx1 )

        Mono.MonoRecordAccess inner field resultType ->
            let
                ( newInner, ctx1 ) =
                    goExpr index ctx inner
            in
            ( Mono.MonoRecordAccess newInner field resultType, ctx1 )

        Mono.MonoRecordUpdate record updates resultType ->
            let
                ( newRecord, ctx1 ) =
                    goExpr index ctx record

                ( newUpdates, ctx2 ) =
                    goNamedList index ctx1 updates
            in
            ( Mono.MonoRecordUpdate newRecord newUpdates resultType, ctx2 )

        Mono.MonoTupleCreate region elements resultType ->
            let
                ( newElements, ctx1 ) =
                    goList index ctx elements
            in
            ( Mono.MonoTupleCreate region newElements resultType, ctx1 )

        Mono.MonoLiteral _ _ ->
            ( expr, ctx )

        Mono.MonoVarLocal _ _ ->
            ( expr, ctx )

        Mono.MonoVarGlobal _ _ _ ->
            ( expr, ctx )

        Mono.MonoVarKernel _ _ _ _ _ ->
            ( expr, ctx )

        Mono.MonoUnit ->
            ( expr, ctx )

        Mono.MonoAccessorValue _ _ _ ->
            ( expr, ctx )


{-| Stamps the calls in each expression of a list, in order.
-}
goList : Dict Int MemberInfo -> StampCtx -> List Mono.MonoExpr -> ( List Mono.MonoExpr, StampCtx )
goList index ctx items =
    case items of
        [] ->
            ( [], ctx )

        e :: rest ->
            let
                ( e1, ctx1 ) =
                    goExpr index ctx e

                ( rest1, ctx2 ) =
                    goList index ctx1 rest
            in
            ( e1 :: rest1, ctx2 )


{-| Stamps the calls in each named expression of a list, in order.
-}
goNamedList : Dict Int MemberInfo -> StampCtx -> List ( a, Mono.MonoExpr ) -> ( List ( a, Mono.MonoExpr ), StampCtx )
goNamedList index ctx items =
    case items of
        [] ->
            ( [], ctx )

        ( n, e ) :: rest ->
            let
                ( e1, ctx1 ) =
                    goExpr index ctx e

                ( rest1, ctx2 ) =
                    goNamedList index ctx1 rest
            in
            ( ( n, e1 ) :: rest1, ctx2 )


{-| Stamps the calls in each capture expression of a closure, in order.
-}
goCaptures : Dict Int MemberInfo -> StampCtx -> List ( a, Mono.MonoExpr, b ) -> ( List ( a, Mono.MonoExpr, b ), StampCtx )
goCaptures index ctx items =
    case items of
        [] ->
            ( [], ctx )

        ( n, e, t ) :: rest ->
            let
                ( e1, ctx1 ) =
                    goExpr index ctx e

                ( rest1, ctx2 ) =
                    goCaptures index ctx1 rest
            in
            ( ( n, e1, t ) :: rest1, ctx2 )


{-| Stamps the calls in each condition and branch of an `if`, in order.
-}
goBranches : Dict Int MemberInfo -> StampCtx -> List ( Mono.MonoExpr, Mono.MonoExpr ) -> ( List ( Mono.MonoExpr, Mono.MonoExpr ), StampCtx )
goBranches index ctx branches =
    case branches of
        [] ->
            ( [], ctx )

        ( c, t ) :: rest ->
            let
                ( c1, ctx1 ) =
                    goExpr index ctx c

                ( t1, ctx2 ) =
                    goExpr index ctx1 t

                ( rest1, ctx3 ) =
                    goBranches index ctx2 rest
            in
            ( ( c1, t1 ) :: rest1, ctx3 )


{-| Stamps the calls in a case's jump bodies, in order.
-}
goJumps : Dict Int MemberInfo -> StampCtx -> List ( Int, Mono.MonoExpr ) -> ( List ( Int, Mono.MonoExpr ), StampCtx )
goJumps =
    goNamedList


{-| Stamps the calls in a let definition's expression.
-}
goDef : Dict Int MemberInfo -> StampCtx -> Mono.MonoDef -> ( Mono.MonoDef, StampCtx )
goDef index ctx def =
    case def of
        Mono.MonoDef name e ->
            let
                ( e1, ctx1 ) =
                    goExpr index ctx e
            in
            ( Mono.MonoDef name e1, ctx1 )

        Mono.MonoTailDef name params e ->
            let
                ( e1, ctx1 ) =
                    goExpr index ctx e
            in
            ( Mono.MonoTailDef name params e1, ctx1 )


{-| Stamps the calls in a decision tree's inline leaves.
-}
goDecider : Dict Int MemberInfo -> StampCtx -> Mono.Decider Mono.MonoChoice -> ( Mono.Decider Mono.MonoChoice, StampCtx )
goDecider index ctx decider =
    case decider of
        Mono.Leaf choice ->
            let
                ( c1, ctx1 ) =
                    goChoice index ctx choice
            in
            ( Mono.Leaf c1, ctx1 )

        Mono.Chain testChain success failure ->
            let
                ( s1, ctx1 ) =
                    goDecider index ctx success

                ( f1, ctx2 ) =
                    goDecider index ctx1 failure
            in
            ( Mono.Chain testChain s1 f1, ctx2 )

        Mono.FanOut path edges fallback ->
            let
                ( edges1, ctx1 ) =
                    goEdges index ctx edges

                ( fb1, ctx2 ) =
                    goDecider index ctx1 fallback
            in
            ( Mono.FanOut path edges1 fb1, ctx2 )


{-| Stamps the calls in each subtree of a fan-out, in order.
-}
goEdges : Dict Int MemberInfo -> StampCtx -> List ( a, Mono.Decider Mono.MonoChoice ) -> ( List ( a, Mono.Decider Mono.MonoChoice ), StampCtx )
goEdges index ctx edges =
    case edges of
        [] ->
            ( [], ctx )

        ( t, d ) :: rest ->
            let
                ( d1, ctx1 ) =
                    goDecider index ctx d

                ( rest1, ctx2 ) =
                    goEdges index ctx1 rest
            in
            ( ( t, d1 ) :: rest1, ctx2 )


{-| Stamps the calls in a decision-tree leaf's inline expression.
-}
goChoice : Dict Int MemberInfo -> StampCtx -> Mono.MonoChoice -> ( Mono.MonoChoice, StampCtx )
goChoice index ctx choice =
    case choice of
        Mono.Inline e ->
            let
                ( e1, ctx1 ) =
                    goExpr index ctx e
            in
            ( Mono.Inline e1, ctx1 )

        Mono.Jump _ ->
            ( choice, ctx )


{-| Decides one call whose callee and arguments are already stamped, returning the
call, stamped, rewritten or unchanged, and the updated context.

The head annotation of the callee's type picks the path. For an `LSet` of one
member that is in the index, `resolveRepresentative` decides, and a stamp names
the chosen instance; a declined call keeps its `CallInfo` and the decline is
counted against its reason and its member. For an `LSet` of one member that is
not in the index, `postSettleTarget` decides: `PsStamp` replaces the callee by
a `MonoVarGlobal` of the chosen specialization, keeping the arguments and the
`CallInfo`; `PsStampPap` stamps the call with the global's specialization; and
every other outcome leaves the call as it was and counts it in
`declinedNoInstance`. Any other annotation leaves the call as it was and is
only counted.

-}
stampCall : Dict Int MemberInfo -> StampCtx -> Region -> Mono.MonoExpr -> List Mono.MonoExpr -> Mono.MonoType -> Mono.CallInfo -> ( Mono.MonoExpr, StampCtx )
stampCall index ctx region func args resultType callInfo =
    case Mono.headAnno (Mono.typeOf func) of
        Mono.LSet [ m ] ->
            case Dict.get m index of
                Just memberInfo ->
                    case resolveRepresentative (Mono.typeOf func) (List.length args) memberInfo of
                        Stamp inst ->
                            let
                                ( kindId, ctx1 ) =
                                    kindIdFor m ctx

                                stamped =
                                    { callInfo
                                        | closureKind = Just (Mono.Known (Mono.ClosureKindId kindId))
                                        , captureAbi =
                                            Just
                                                { captureTypes = inst.captureTypes
                                                , paramTypes = inst.paramTypes
                                                , returnType = inst.returnType
                                                }
                                        , fastEvaluator = Just inst.lambdaId
                                        , fastEvaluatorSpec = inst.topLevelSpec
                                    }

                                stats1 =
                                    ctx1.stats
                            in
                            ( Mono.MonoCall region func args resultType stamped
                            , bumpHost "stamped"
                                { ctx1
                                    | stats =
                                        { stats1
                                            | dispatchUpgraded = stats1.dispatchUpgraded + 1
                                        }
                                }
                            )

                        StampFlat inst ->
                            let
                                ( kindIdF, ctxF ) =
                                    kindIdFor m ctx

                                statsF =
                                    ctxF.stats

                                iqF =
                                    statsF.instQual
                            in
                            ( Mono.MonoCall region
                                func
                                args
                                resultType
                                { callInfo
                                    | closureKind = Just (Mono.Known (Mono.ClosureKindId kindIdF))
                                    , captureAbi =
                                        Just
                                            { captureTypes = inst.captureTypes
                                            , paramTypes = inst.paramTypes
                                            , returnType = inst.returnType
                                            }
                                    , fastEvaluator = Just inst.lambdaId
                                    , fastEvaluatorSpec = inst.topLevelSpec
                                }
                            , bumpHost "stampedFlat"
                                { ctxF
                                    | stats =
                                        { statsF
                                            | dispatchUpgraded = statsF.dispatchUpgraded + 1
                                            , instQual = { iqF | flatStamped = iqF.flatStamped + 1 }
                                        }
                                }
                            )

                        StampPap inst k ->
                            let
                                ( kindId, ctx1 ) =
                                    kindIdFor m ctx

                                stamped =
                                    { callInfo
                                        | closureKind = Just (Mono.Known (Mono.ClosureKindId kindId))
                                        , captureAbi =
                                            Just
                                                { captureTypes = inst.captureTypes ++ List.take k inst.paramTypes
                                                , paramTypes = List.drop k inst.paramTypes
                                                , returnType = inst.returnType
                                                }
                                        , fastEvaluator = Just inst.lambdaId
                                        , fastEvaluatorSpec = inst.topLevelSpec
                                        , fastPapPrefix = Just k
                                    }

                                stats1 =
                                    ctx1.stats
                            in
                            ( Mono.MonoCall region func args resultType stamped
                            , { ctx1 | stats = { stats1 | stampedPapPrefix = stats1.stampedPapPrefix + 1 } }
                            )

                        StampStaged inst ->
                            let
                                ( kindId, ctx1 ) =
                                    kindIdFor m ctx

                                stamped =
                                    { callInfo
                                        | closureKind = Just (Mono.Known (Mono.ClosureKindId kindId))
                                        , captureAbi =
                                            Just
                                                { captureTypes = inst.captureTypes
                                                , paramTypes = inst.paramTypes
                                                , returnType = inst.returnType
                                                }
                                        , fastEvaluator = Just inst.lambdaId
                                        , fastEvaluatorSpec = inst.topLevelSpec
                                    }

                                stats1 =
                                    ctx1.stats
                            in
                            ( Mono.MonoCall region func args resultType stamped
                            , { ctx1 | stats = { stats1 | stampedStaged = stats1.stampedStaged + 1 } }
                            )

                        Decline reason bump ->
                            let
                                ctxB =
                                    bumpShape (Mono.typeOf func) (List.length args) reason (bumpHost reason (bump ctx))

                                statsB =
                                    ctxB.stats
                            in
                            ( Mono.MonoCall region func args resultType callInfo
                            , noteSite m
                                reason
                                { ctxB
                                    | stats =
                                        { statsB
                                            | declineByMember = bumpDict m statsB.declineByMember
                                            , memberReps = Dict.insert m (memberRepsOf memberInfo) statsB.memberReps
                                        }
                                }
                            )

                Nothing ->
                    case postSettleTarget m func (List.length args) ctx of
                        PsStamp specId isCtor ->
                            let
                                stats1 =
                                    ctx.stats

                                stats2 =
                                    if isCtor then
                                        let
                                            dp1 =
                                                stats1.devirtPost
                                        in
                                        { stats1 | devirtPost = { dp1 | ctor = dp1.ctor + 1 } }

                                    else
                                        let
                                            dp1 =
                                                stats1.devirtPost
                                        in
                                        { stats1 | devirtPost = { dp1 | fn = dp1.fn + 1 } }
                            in
                            ( Mono.MonoCall region
                                (Mono.MonoVarGlobal region specId (Mono.typeOf func))
                                args
                                resultType
                                callInfo
                            , { ctx | stats = stats2 }
                            )

                        PsNoSpec ->
                            let
                                statsN =
                                    ctx.stats
                            in
                            ( Mono.MonoCall region func args resultType callInfo
                            , bumpHost "noInstanceNoSpec"
                                (bumpNoInstance
                                    (let
                                        dpN =
                                            statsN.devirtPost
                                     in
                                     { ctx | stats = { statsN | devirtPost = { dpN | noSpec = dpN.noSpec + 1 } } }
                                    )
                                )
                            )

                        PsAmbiguous n ->
                            let
                                statsA =
                                    ctx.stats
                            in
                            ( Mono.MonoCall region func args resultType callInfo
                            , bumpHost ("noInstanceAmbiguous|" ++ String.fromInt n)
                                (bumpNoInstance
                                    (let
                                        dpA =
                                            statsA.devirtPost
                                     in
                                     { ctx | stats = { statsA | devirtPost = { dpA | ambiguous = dpA.ambiguous + 1 } } }
                                    )
                                )
                            )

                        PsStampPap target ->
                            -- The callee expression is kept as it is: the
                            -- bound arguments are read back out of it.
                            let
                                ( kindId, ctx1 ) =
                                    kindIdFor m ctx

                                stamped =
                                    { callInfo
                                        | closureKind = Just (Mono.Known (Mono.ClosureKindId kindId))
                                        , captureAbi =
                                            Just
                                                { captureTypes = target.captureTypes
                                                , paramTypes = target.paramTypes
                                                , returnType = target.returnType
                                                }
                                        , fastEvaluator = Just target.sentinel
                                        , fastEvaluatorSpec = Just target.specId
                                        , fastPapPrefix = Just target.k
                                    }

                                stats1 =
                                    ctx1.stats
                            in
                            ( Mono.MonoCall region func args resultType stamped
                            , bumpHost "stampedPapGlobal"
                                { ctx1 | stats = { stats1 | stampedPapGlobal = stats1.stampedPapGlobal + 1 } }
                            )

                        PsNotCandidate why ->
                            ( Mono.MonoCall region func args resultType callInfo
                            , bumpAbsentL why
                                m
                                func
                                (List.length args)
                                (bumpPapSite why (bumpNiGuard why (bumpHost "noInstance" (bumpNoInstance ctx))))
                            )

        Mono.LSet ms ->
            -- Any set but a singleton, including an empty one.
            let
                stats0 =
                    ctx.stats

                statsMembers =
                    List.foldl
                        (\mid acc ->
                            { acc
                                | multiSetMembers = bumpDict mid acc.multiSetMembers
                                , memberReps =
                                    case Dict.get mid index of
                                        Just mi ->
                                            Dict.insert mid (memberRepsOf mi) acc.memberReps

                                        Nothing ->
                                            acc.memberReps
                            }
                        )
                        { stats0 | multiSetSiteHist = bumpDict (List.length ms) stats0.multiSetSiteHist }
                        ms

                statsSites =
                    noteMultiSite ctx.memberKinds ctx.census ms statsMembers
            in
            ( Mono.MonoCall region func args resultType callInfo
            , bumpHost ("multi" ++ String.fromInt (List.length ms)) { ctx | stats = statsSites }
            )

        Mono.LTop _ ->
            let
                stats0 =
                    ctx.stats
            in
            ( Mono.MonoCall region func args resultType callInfo
            , { ctx | stats = { stats0 | topSiteShapes = bumpDictStr (calleeShape func) stats0.topSiteShapes } }
            )

        Mono.LPartial _ ->
            -- A lower bound: members it does not list may flow here too.
            let
                stats0p =
                    ctx.stats
            in
            ( Mono.MonoCall region func args resultType callInfo
            , let
                dp0 =
                    stats0p.devirtPost
              in
              { ctx | stats = { stats0p | devirtPost = { dp0 | partialDeclined = dp0.partialDeclined + 1 } } }
            )

        Mono.LVar _ ->
            let
                stats0 =
                    ctx.stats
            in
            ( Mono.MonoCall region func args resultType callInfo
            , { ctx | stats = { stats0 | varSiteShapes = bumpDictStr (calleeShape func) stats0.varSiteShapes } }
            )


{-| Records, on census, a declined call that supplies more arguments than its
callee type's first stage takes, in the `shape` tally, keyed
`<firstStage>-><argCount>|exact|<reason>` when `peelStages` lands exactly on
the argument count and with `miss` in place of `exact` when it does not.
-}
bumpShape : Mono.MonoType -> Int -> String -> StampCtx -> StampCtx
bumpShape calleeType argCount reason ctx =
    case calleeType of
        Mono.MFunction _ _ fargs _ ->
            if not ctx.census || argCount <= List.length fargs then
                ctx

            else
                let
                    key =
                        String.fromInt (List.length fargs)
                            ++ "->"
                            ++ String.fromInt argCount
                            ++ "|"
                            ++ (case peelStages argCount calleeType of
                                    Just _ ->
                                        "exact"

                                    Nothing ->
                                        "miss"
                               )
                            ++ "|"
                            ++ reason

                    st =
                        ctx.stats

                    iq =
                        st.instQual
                in
                { ctx | stats = { st | instQual = { iq | shape = bumpDictStr key iq.shape } } }

        _ ->
            ctx


{-| Records, on census, a site keyed `<host>|<specId>` in the `papSites` tally when
its reason begins `g1absentp|WOULDSTAMP`, and ignores every other reason.

`papResolve` gives that reason only together with a target, and such a site is
stamped rather than passed here, so the tally stays empty.

-}
bumpPapSite : String -> StampCtx -> StampCtx
bumpPapSite why ctx =
    if not ctx.census || not (String.startsWith "g1absentp|WOULDSTAMP" why) then
        ctx

    else
        let
            st =
                ctx.stats

            iq =
                st.instQual
        in
        { ctx
            | stats =
                { st
                    | instQual =
                        { iq | papSites = bumpDictStr (ctx.hostGlobal ++ "|" ++ String.fromInt ctx.hostSpecId) iq.papSites }
                }
        }


{-| Records, on census, a site whose member is not in the index: a `T|` row
(`noteSite`) and, when `why` is `g1absentl`, five rows in the `absentL` tally. They
are `M|` with the member id, `S|` with the callee's form and the argument
count, `H|` with the host, its SpecId and the callee's form, `K|` with the
shape of the member's interned key, and `R|` with how many closures made from
the member's source lambda carry this member, another member, or none.
-}
bumpAbsentL : String -> Int -> Mono.MonoExpr -> Int -> StampCtx -> StampCtx
bumpAbsentL why m func argCount ctx0 =
    let
        ctx =
            noteSite m ("ni:" ++ why) ctx0
    in
    if not ctx.census || why /= "g1absentl" then
        ctx

    else
        let
            st =
                ctx.stats

            iq =
                st.instQual

            shape =
                calleeShape func

            key =
                Maybe.withDefault "?" (Dict.get m ctx.memberKinds)

            ( keyShape, raw ) =
                case String.split "|" key of
                    "l" :: r :: rest ->
                        ( "l|R|"
                            ++ (case rest of
                                    q :: _ ->
                                        if String.all Char.isDigit q then
                                            "spec"

                                        else
                                            "layout"

                                    [] ->
                                        "?"
                               )
                            ++ (if List.any (String.startsWith "#") rest then
                                    "|inst"

                                else
                                    ""
                               )
                        , String.toInt r
                        )

                    _ ->
                        ( key, Nothing )

            sourceRow =
                case raw of
                    Nothing ->
                        "noRaw"

                    Just r ->
                        case Dict.get r ctx.srcIndex of
                            Nothing ->
                                "closures=0"

                            Just members ->
                                let
                                    eq =
                                        List.length (List.filter (\x -> x == Just m) members)

                                    none =
                                        List.length (List.filter (\x -> x == Nothing) members)
                                in
                                "closures="
                                    ++ String.fromInt (List.length members)
                                    ++ "|sameMember="
                                    ++ String.fromInt eq
                                    ++ "|otherMember="
                                    ++ String.fromInt (List.length members - eq - none)
                                    ++ "|noMember="
                                    ++ String.fromInt none

            d1 =
                bumpDictStr ("M|" ++ String.fromInt m) iq.absentL

            d2 =
                bumpDictStr ("S|" ++ shape ++ "|" ++ String.fromInt argCount) d1

            d3 =
                bumpDictStr ("H|" ++ ctx.hostGlobal ++ "|" ++ String.fromInt ctx.hostSpecId ++ "|" ++ shape) d2

            d4 =
                bumpDictStr ("K|" ++ keyShape) d3

            d5 =
                bumpDictStr ("R|" ++ sourceRow) d4
        in
        { ctx | stats = { st | instQual = { iq | absentL = d5 } } }


{-| Records, on census, one `T|<host>|<specId>|<member>|<outcome>` row in the
`absentL` tally.
-}
noteSite : Int -> String -> StampCtx -> StampCtx
noteSite m outcome ctx =
    if not ctx.census then
        ctx

    else
        let
            st =
                ctx.stats

            iq =
                st.instQual
        in
        { ctx
            | stats =
                { st
                    | instQual =
                        { iq
                            | absentL =
                                bumpDictStr
                                    ("T|" ++ ctx.hostGlobal ++ "|" ++ String.fromInt ctx.hostSpecId ++ "|" ++ String.fromInt m ++ "|" ++ outcome)
                                    iq.absentL
                        }
                }
        }


{-| Returns one `I|<member>|<representative uids>|n=<instances>` row per indexed
member, with `|blocked` added for a blocked member.
-}
indexSummary : Dict Int MemberInfo -> Dict String Int
indexSummary index =
    Dict.foldl
        (\m mi acc ->
            let
                uids =
                    memberRepsOf mi
                        |> List.map (\(Mono.AnonymousLambda _ uid) -> String.fromInt uid)
                        |> String.join ","

                n =
                    Dict.foldl (\_ groups a -> List.foldl (\g b -> b + g.count) a groups) 0 mi.buckets
            in
            Dict.insert
                ("I|"
                    ++ String.fromInt m
                    ++ "|"
                    ++ uids
                    ++ "|n="
                    ++ String.fromInt n
                    ++ (if mi.blocked then
                            "|blocked"

                        else
                            ""
                       )
                )
                1
                acc
        )
        Dict.empty
        index


{-| Returns, for every closure in the graph that has a source lambda, its
`lssMember`, filed under that source lambda's id, whether or not the closure is
indexed.
-}
collectSrcIndex : Array.Array (Maybe Mono.MonoNode) -> Dict Int (List (Maybe Int))
collectSrcIndex nodes =
    Array.foldl
        (\maybeNode acc ->
            case maybeNode of
                Just node ->
                    List.foldl (\e a -> MonoTraverse.foldExprAccFirst noteSrc a e) acc (nodeExprs node)

                Nothing ->
                    acc
        )
        Dict.empty
        nodes


{-| Files one closure's `lssMember` under its source lambda's id, and ignores any
other expression.
-}
noteSrc : Dict Int (List (Maybe Int)) -> Mono.MonoExpr -> Dict Int (List (Maybe Int))
noteSrc acc expr =
    case expr of
        Mono.MonoClosure info _ _ ->
            case info.srcLambda of
                Just src ->
                    Dict.update (Id.toComparable src) (\v -> Just (info.lssMember :: Maybe.withDefault [] v)) acc

                Nothing ->
                    acc

        _ ->
            acc


{-| Records, on census, a site without an instance as `<host>|<why>` in the
`niGuard` tally, where `why` is the reason `postSettleTarget` gave.
-}
bumpNiGuard : String -> StampCtx -> StampCtx
bumpNiGuard why ctx =
    if not ctx.census then
        ctx

    else
        let
            st =
                ctx.stats

            iq =
                st.instQual
        in
        { ctx | stats = { st | instQual = { iq | niGuard = bumpDictStr (ctx.hostGlobal ++ "|" ++ why) iq.niGuard } } }


{-| Records, on census, one site's outcome as `<host>|<outcome>` in the `byHost`
tally.
-}
bumpHost : String -> StampCtx -> StampCtx
bumpHost outcome ctx =
    if not ctx.census then
        ctx

    else
        let
            st =
                ctx.stats

            iq =
                st.instQual
        in
        { ctx | stats = { st | instQual = { iq | byHost = bumpDictStr (ctx.hostGlobal ++ "|" ++ outcome) iq.byHost } } }


{-| Adds one to the count at `k`, starting from zero.
-}
bumpDict : Int -> Dict Int Int -> Dict Int Int
bumpDict k d =
    Dict.update k (\v -> Just (Maybe.withDefault 0 v + 1)) d


{-| Adds one to the count at `k`, starting from zero.
-}
bumpDictStr : String -> Dict String Int -> Dict String Int
bumpDictStr k d =
    Dict.update k (\v -> Just (Maybe.withDefault 0 v + 1)) d


{-| Records, on census, a site whose set has other than one member in the
`multiSites` tally, keyed `<size>|<kinds>|<n>id|<identities>`: the number of
members, their distinct kind letters, and how many distinct code objects they
name followed by those names (`memberIdentityOf`).

When `memberKinds` is empty a single `DISARMED` row is counted instead, because
without the interned keys every member would look like a distinct code object.

-}
noteMultiSite : Dict Int String -> Bool -> List Int -> AbiCloningStats -> AbiCloningStats
noteMultiSite memberKinds censusOn ms stats =
    if not censusOn then
        stats

    else if Dict.isEmpty memberKinds then
        let
            iq =
                stats.instQual
        in
        { stats | instQual = { iq | multiSites = bumpDictStr "DISARMED|set ECO_MONO_LSS_REPORT=1 too" iq.multiSites } }

    else
        let
            idents =
                distinctSorted (List.map (memberIdentityOf memberKinds) ms)

            kinds =
                String.concat (distinctSorted (List.map (memberKindOf memberKinds) ms))

            key =
                String.fromInt (List.length ms)
                    ++ "|"
                    ++ kinds
                    ++ "|"
                    ++ String.fromInt (List.length idents)
                    ++ "id|"
                    ++ String.join "," idents

            iq =
                stats.instQual
        in
        { stats | instQual = { iq | multiSites = bumpDictStr key iq.multiSites } }


{-| Returns the kind letter that begins a member's interned key, or `"?"` when the
key is not known.
-}
memberKindOf : Dict Int String -> Int -> String
memberKindOf memberKinds mid =
    case Dict.get mid memberKinds of
        Just k ->
            String.left 1 k

        Nothing ->
            "?"


{-| Returns the second `|`-separated field of a member's interned key, which names
the code object, so that `g|G|...` and `p|G|...` both give `G`. A key with one
field is returned whole, and a member with no key gives `"?"` followed by its
id.
-}
memberIdentityOf : Dict Int String -> Int -> String
memberIdentityOf memberKinds mid =
    case Dict.get mid memberKinds of
        Just k ->
            case String.split "|" k of
                _ :: ident :: _ ->
                    ident

                _ ->
                    k

        Nothing ->
            "?" ++ String.fromInt mid


{-| Returns the distinct strings of `xs` in ascending order.
-}
distinctSorted : List String -> List String
distinctSorted xs =
    Dict.keys (List.foldl (\x d -> Dict.insert x () d) Dict.empty xs)


{-| Returns the representative lambda id of each of a member's layout groups.
-}
memberRepsOf : MemberInfo -> List Mono.LambdaId
memberRepsOf mi =
    Dict.foldl
        (\_ groups acc -> List.foldl (\g a -> g.rep.lambdaId :: a) acc groups)
        []
        mi.buckets


{-| Returns a short name for the form of a callee expression, used in census keys:
`local`, `recordAccess`, `callResult`, `global`, `kernel`, `closureLiteral`,
`case`, `if`, `let`, or `other`.
-}
calleeShape : Mono.MonoExpr -> String
calleeShape f =
    case f of
        Mono.MonoVarLocal _ _ ->
            "local"

        Mono.MonoRecordAccess _ _ _ ->
            "recordAccess"

        Mono.MonoCall _ _ _ _ _ ->
            "callResult"

        Mono.MonoVarGlobal _ _ _ ->
            "global"

        Mono.MonoVarKernel _ _ _ _ _ ->
            "kernel"

        Mono.MonoClosure _ _ _ ->
            "closureLiteral"

        Mono.MonoCase _ _ _ _ _ ->
            "case"

        Mono.MonoIf _ _ _ ->
            "if"

        Mono.MonoLet _ _ _ ->
            "let"

        _ ->
            "other"


{-| The verdict for a singleton site whose member has instances: which instance to
stamp and how, or why not.

`Stamp` is a site that supplies exactly the arguments its callee type's first
stage takes, where a group has that parameter and return layout.

`StampFlat` is a site that supplies more arguments than its callee type's first
stage, where the curried type flattened to that many parameters matches a
group. Its stamp is the same as `Stamp`'s.

`StampStaged` is a site that supplies more arguments than its callee type's
first stage, where only that first stage matches a group. Its stamp is the same
as `Stamp`'s, so the call supplies more arguments than the stamp's `captureAbi`
lists.

`StampPap` carries an instance and a count `k`: the callee value is that
instance partially applied to `k` arguments.

`Decline` carries the reason, which the census keys use, and the function that
counts the decline.

-}
type Resolution
    = Stamp Instance
    | StampPap Instance Int
    | StampStaged Instance
    | StampFlat Instance
    | Decline String (StampCtx -> StampCtx)


{-| Chooses the stamp for a call with `argCount` arguments to a member through a
callee of type `calleeType`, or declines.

A blocked member declines, and so does a callee type that is not a function.
Otherwise `argCount` is compared with the number of parameters the outermost
arrow takes. No arguments, or fewer, decline. Exactly that many look for the
group with the same parameter and return layout, and failing that for a
partial application (`resolvePapSuffix`). More look first for a group matching
the type flattened to `argCount` parameters (`flattenedResolution`), then for
one matching the first stage alone (`resolveStagedFirstStage`).

A matching group is stamped only when its representative has no `Char` capture,
its capture types agree and its fingerprints agree, and each failure is a
decline of its own, checked in that order.

-}
resolveRepresentative : Mono.MonoType -> Int -> MemberInfo -> Resolution
resolveRepresentative calleeType argCount memberInfo =
    if memberInfo.blocked then
        Decline "blocked" bumpBlocked

    else
        case calleeType of
            Mono.MFunction _ _ fargs fret ->
                if argCount == 0 then
                    Decline "arityZero" bumpShapeArityZero

                else if argCount < List.length fargs then
                    Decline "arityUnder" bumpShapeArityUnder

                else if argCount > List.length fargs then
                    -- A curried callee type may be applied flat: try it
                    -- peeled to the argument count first.
                    case flattenedResolution argCount calleeType memberInfo of
                        Just resolution ->
                            resolution

                        Nothing ->
                            resolveStagedFirstStage fargs fret memberInfo

                else
                    case Dict.get (siteFingerprint fargs fret) memberInfo.buckets of
                        Nothing ->
                            resolvePapSuffix fargs fret argCount memberInfo bumpShapeBucketMiss

                        Just groups ->
                            resolveInGroups fargs fret argCount groups memberInfo

            _ ->
                Decline "nonArrow" bumpShapeNonArrow


{-| Returns the verdict for the first group in `groups` whose representative has
exactly the site's parameter and return layout. When none has, it looks for a
partial application, and a failure there is counted in `declinedShapeLayout`.
-}
resolveInGroups : List Mono.MonoType -> Mono.MonoType -> Int -> List LayoutGroup -> MemberInfo -> Resolution
resolveInGroups fargs fret argCount groups memberInfo =
    case groups of
        [] ->
            resolvePapSuffix fargs fret argCount memberInfo bumpShapeLayout

        g :: rest ->
            if g.paramCount == argCount && eqLayoutLists g.rep.paramTypes fargs && Mono.eqLayout g.rep.returnType fret then
                if not g.charFree then
                    Decline "char" bumpShapeChar

                else if not g.unanimous then
                    Decline "abiMismatch" bumpAbiMismatch

                else if g.fpUnanimous then
                    Stamp g.rep

                else
                    Decline "bodyMismatch" bumpBodyMismatch

            else
                resolveInGroups fargs fret argCount rest memberInfo


{-| Chooses a stamp for a call supplying more arguments than its callee type's
first stage, from a group matching that first stage, `fargs` to `fret`. It
declines as `arityOver` when no group matches.
-}
resolveStagedFirstStage : List Mono.MonoType -> Mono.MonoType -> MemberInfo -> Resolution
resolveStagedFirstStage fargs fret memberInfo =
    case Dict.get (siteFingerprint fargs fret) memberInfo.buckets of
        Nothing ->
            Decline "arityOver" bumpShapeArityOver

        Just groups ->
            stagedScan fargs fret groups


{-| Returns the verdict for the first group in `groups` matching `fargs` and
`fret`, with the same checks as `resolveInGroups`, or an `arityOver` decline.
-}
stagedScan : List Mono.MonoType -> Mono.MonoType -> List LayoutGroup -> Resolution
stagedScan fargs fret groups =
    case groups of
        [] ->
            Decline "arityOver" bumpShapeArityOver

        g :: rest ->
            if g.paramCount == List.length fargs && eqLayoutLists g.rep.paramTypes fargs && Mono.eqLayout g.rep.returnType fret then
                if not g.charFree then
                    Decline "char" bumpShapeChar

                else if not g.unanimous then
                    Decline "abiMismatch" bumpAbiMismatch

                else if g.fpUnanimous then
                    StampStaged g.rep

                else
                    Decline "bodyMismatch" bumpBodyMismatch

            else
                stagedScan fargs fret rest


{-| Flattens a curried function type until exactly `want` parameters have been
collected, and returns them with the type that remains after them.

The parameters are taken a whole stage at a time, so the result is `Nothing`
when a stage would take the count past `want`, and also when the type stops
being a function first. The annotations of the arrows flattened away are
dropped.

-}
peelStages : Int -> Mono.MonoType -> Maybe ( List Mono.MonoType, Mono.MonoType )
peelStages want ty =
    peelGo want 0 [] ty


{-| Continues `peelStages` with `have` parameters collected so far, held in `acc`
one list per stage, in reverse.
-}
peelGo : Int -> Int -> List (List Mono.MonoType) -> Mono.MonoType -> Maybe ( List Mono.MonoType, Mono.MonoType )
peelGo want have acc ty =
    case ty of
        Mono.MFunction _ _ params ret ->
            let
                have1 =
                    have + List.length params

                acc1 =
                    params :: acc
            in
            if have1 == want then
                Just ( List.concat (List.reverse acc1), ret )

            else if have1 > want then
                Nothing

            else
                peelGo want have1 acc1 ret

        _ ->
            Nothing


{-| Chooses a stamp for a call supplying more arguments than its callee type's
first stage, by flattening the callee type to `argCount` parameters, or returns
`Nothing` when the type does not flatten to exactly that count or no group has
that layout.

Unlike the exact path it never looks for a partial application: its stamp says
the call supplies every parameter the instance takes.

-}
flattenedResolution : Int -> Mono.MonoType -> MemberInfo -> Maybe Resolution
flattenedResolution argCount calleeType memberInfo =
    case peelStages argCount calleeType of
        Nothing ->
            Nothing

        Just ( flatArgs, flatRet ) ->
            case Dict.get (siteFingerprint flatArgs flatRet) memberInfo.buckets of
                Nothing ->
                    Nothing

                Just groups ->
                    flattenedScan argCount flatArgs flatRet groups


{-| Returns the verdict for the first group in `groups` matching the flattened
parameters and return, with the same checks as `resolveInGroups`, or `Nothing`
when no group matches.
-}
flattenedScan : Int -> List Mono.MonoType -> Mono.MonoType -> List LayoutGroup -> Maybe Resolution
flattenedScan argCount flatArgs flatRet groups =
    case groups of
        [] ->
            Nothing

        g :: rest ->
            if g.paramCount == argCount && eqLayoutLists g.rep.paramTypes flatArgs && Mono.eqLayout g.rep.returnType flatRet then
                Just
                    (if not g.charFree then
                        Decline "char" bumpShapeChar

                     else if not g.unanimous then
                        Decline "abiMismatch" bumpAbiMismatch

                     else if g.fpUnanimous then
                        StampFlat g.rep

                     else
                        Decline "bodyMismatch" bumpBodyMismatch
                    )

            else
                flattenedScan argCount flatArgs flatRet rest


{-| Looks for a group whose instance, partially applied to `k` arguments for some
`k` of at least one, takes the site's parameters and return: the parameters
after its first `k` match `fargs` and its return matches `fret`. All of the
member's groups are searched, in bucket-key order. `noMatch` counts the decline
when none matches.
-}
resolvePapSuffix : List Mono.MonoType -> Mono.MonoType -> Int -> MemberInfo -> (StampCtx -> StampCtx) -> Resolution
resolvePapSuffix fargs fret argCount memberInfo noMatch =
    papScan fargs fret argCount (List.concat (Dict.values memberInfo.buckets)) noMatch


{-| Returns the verdict for the first group in `groups` with a matching partial
application. Besides the checks `resolveInGroups` makes, none of the first `k`
parameter types may be `Char`, since a stamp lists them among the capture
types.
-}
papScan : List Mono.MonoType -> Mono.MonoType -> Int -> List LayoutGroup -> (StampCtx -> StampCtx) -> Resolution
papScan fargs fret argCount groups noMatch =
    case groups of
        [] ->
            Decline "bucketOrLayoutMiss" noMatch

        g :: rest ->
            let
                k =
                    g.paramCount - argCount
            in
            if k >= 1 && eqLayoutLists (List.drop k g.rep.paramTypes) fargs && Mono.eqLayout g.rep.returnType fret then
                if not g.charFree || List.any ((==) Mono.MChar) (List.take k g.rep.paramTypes) then
                    -- The first k parameters sit in capture slots.
                    Decline "char" bumpShapeChar

                else if not g.unanimous then
                    Decline "abiMismatch" bumpAbiMismatch

                else if g.fpUnanimous then
                    StampPap g.rep k

                else
                    Decline "bodyMismatch" bumpBodyMismatch

            else
                papScan fargs fret argCount rest noMatch


{-| Returns the `ClosureKindId` number of member `m`, giving it the next unused
one on first use, and records a `stamp` row for the site on census.
-}
kindIdFor : Int -> StampCtx -> ( Int, StampCtx )
kindIdFor m ctx0 =
    let
        ctx =
            noteSite m "stamp" ctx0
    in
    case Dict.get m ctx.kindIds of
        Just kid ->
            ( kid, ctx )

        Nothing ->
            ( ctx.nextKind
            , { ctx | kindIds = Dict.insert m ctx.nextKind ctx.kindIds, nextKind = ctx.nextKind + 1 }
            )


{-| Counts one site declined because its member is blocked.
-}
bumpBlocked : StampCtx -> StampCtx
bumpBlocked ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = { stats | declinedBlocked = stats.declinedBlocked + 1 } }


{-| The verdict for a singleton site whose member has no instance in the index.

`PsStamp` names the specialization the call is rewritten to call directly, and
says whether the target is a constructor.

`PsNoSpec` is a site that passed every check but where no specialization of the
target has the callee's layout.

`PsAmbiguous` is a site where no single specialization can be chosen, and
carries how many have the callee's layout.

`PsNotCandidate` carries the census key of the check that turned the site away.

`PsStampPap` is a partial application of a global, to be stamped as
`PapTarget` describes.

-}
type PostSettleOutcome
    = PsStamp Mono.SpecId Bool
    | PsNoSpec
    | PsAmbiguous Int
    | PsNotCandidate String
    | PsStampPap PapTarget


{-| Everything a stamp for a partial application of a global needs: the one
matching specialization, the number `k` of arguments the partial application
holds, and the specialization's parameter types split at `k`, the first `k` as
`captureTypes` since a global captures nothing of its own.

`sentinel` fills `fastEvaluator`, since a specialization has no lambda id of its
own. It is `AnonymousLambda home (negate specId - 1)`, with `home` the global's
module, so it is negative and differs from one specialization to another. The
stamp names the specialization in `fastEvaluatorSpec`.

-}
type alias PapTarget =
    { specId : Mono.SpecId
    , k : Int
    , captureTypes : List Mono.MonoType
    , paramTypes : List Mono.MonoType
    , returnType : Mono.MonoType
    , sentinel : Mono.LambdaId
    }


{-| Decides a singleton site whose member `m` has no instance, from the origin the
graph records for the member.

A member with no recorded origin is turned away, with the first letter of its
interned key in the reason. A partial application of a global goes to
`papResolve`. A global function or a constructor is a candidate only when the
callee is a local variable, and `postSettleArity` then checks the argument
count. Kernels, accessors, and any other callee expression are turned away.

-}
postSettleTarget : Int -> Mono.MonoExpr -> Int -> StampCtx -> PostSettleOutcome
postSettleTarget m func argCount ctx =
    case Dict.get m ctx.origins of
        Nothing ->
            PsNotCandidate ("g1absent" ++ Maybe.withDefault "?" (Maybe.map (String.left 1) (Dict.get m ctx.memberKinds)))

        Just (Mono.OriginPap g k) ->
            case papResolve g k func argCount ctx of
                ( Just target, _ ) ->
                    PsStampPap target

                ( Nothing, key ) ->
                    PsNotCandidate key

        Just origin ->
            case originTarget origin of
                Nothing ->
                    PsNotCandidate ("g1" ++ originKindName origin)

                Just ( target, isCtor ) ->
                    case func of
                        Mono.MonoVarLocal _ calleeType ->
                            postSettleArity target isCtor calleeType argCount ctx

                        _ ->
                            PsNotCandidate ("g2" ++ calleeShape func)


{-| Returns the global a function or constructor origin names, and whether it is a
constructor, or `Nothing` for any other origin.
-}
originTarget : Mono.MemberOrigin -> Maybe ( Mono.Global, Bool )
originTarget origin =
    case origin of
        Mono.OriginGlobal g ->
            Just ( g, False )

        Mono.OriginCtor g ->
            Just ( g, True )

        _ ->
            Nothing


{-| Returns the census name of a kernel or accessor origin, or `other`.
-}
originKindName : Mono.MemberOrigin -> String
originKindName origin =
    case origin of
        Mono.OriginKernel _ _ _ ->
            "kernel"

        Mono.OriginAccessor _ ->
            "accessor"

        _ ->
            "other"


{-| Decides a site whose member is global `g` partially applied to `k` arguments,
and returns the stamp target when every check passes, with a census key for the
verdict either way.

The callee must be a local variable, and its type must flatten to exactly
`argCount` parameters (`peelStages`). The specializations of `g` that match are
those whose node is callable (`specFunctionRow`), whose parameter count is `k`
plus the site's, and whose parameters after the first `k` and return match the
site's apart from arrow annotations. Exactly one must match: two
specializations of one global can share a layout, so picking one of several
would be a guess. Its first `k` parameters must not include `Char`.

The key is `g1absentp|<verdict>|k=<k>|site=<firstStage>-><argCount>`, with the
verdict `WOULDSTAMP` when there is a target, except for a callee that is not a
local variable, keyed `g1absentp|papCallee-<form>`.

-}
papResolve : Mono.Global -> Int -> Mono.MonoExpr -> Int -> StampCtx -> ( Maybe PapTarget, String )
papResolve g k func argCount ctx =
    let
        shape firstStage =
            "|k=" ++ String.fromInt k ++ "|site=" ++ String.fromInt firstStage ++ "->" ++ String.fromInt argCount

        no reason firstStage =
            ( Nothing, "g1absentp|" ++ reason ++ shape firstStage )
    in
    case func of
        Mono.MonoVarLocal _ calleeType ->
            let
                firstStage =
                    case calleeType of
                        Mono.MFunction _ _ params _ ->
                            List.length params

                        _ ->
                            0
            in
            case peelStages argCount calleeType of
                Nothing ->
                    no "unpeelable" firstStage

                Just ( fargs, fret ) ->
                    let
                        specs =
                            Dict.get (Mono.toComparableGlobal g) ctx.specsByGlobal
                                |> Maybe.withDefault []

                        ( matches, nonFn ) =
                            List.foldr
                                (\( specId, _ ) ( accM, accN ) ->
                                    case specFunctionRow specId ctx of
                                        Just ( params, ret ) ->
                                            if
                                                (List.length params == k + List.length fargs)
                                                    && eqLayoutLists (List.drop k params) fargs
                                                    && Mono.eqLayout ret fret
                                            then
                                                ( ( specId, params, ret ) :: accM, accN )

                                            else
                                                ( accM, accN )

                                        Nothing ->
                                            ( accM, True )
                                )
                                ( [], False )
                                specs
                    in
                    case matches of
                        [ ( specId, params, ret ) ] ->
                            if List.any ((==) Mono.MChar) (List.take k params) then
                                no "papChar" firstStage

                            else
                                case g of
                                    Mono.Global home _ ->
                                        ( Just
                                            { specId = specId
                                            , k = k
                                            , captureTypes = List.take k params
                                            , paramTypes = List.drop k params
                                            , returnType = ret
                                            , sentinel = Mono.AnonymousLambda home (negate specId - 1)
                                            }
                                        , "g1absentp|WOULDSTAMP" ++ shape firstStage
                                        )

                                    Mono.Accessor _ ->
                                        -- Not expected: an accessor takes one argument.
                                        no "papAccessor" firstStage

                        [] ->
                            if List.isEmpty specs then
                                no "papNoSpec" firstStage

                            else if nonFn then
                                no "papNonFn" firstStage

                            else
                                no "papShapeMiss" firstStage

                        _ ->
                            no "papAmbiguous" firstStage

        _ ->
            ( Nothing, "g1absentp|papCallee-" ++ calleeShape func )


{-| Returns the parameter types and return type of a specialization whose node is
callable: a definition whose expression is a closure, a tail function, or a
constructor, whose parameters are its fields. Returns `Nothing` for any other
node and for a SpecId with no node.
-}
specFunctionRow : Mono.SpecId -> StampCtx -> Maybe ( List Mono.MonoType, Mono.MonoType )
specFunctionRow specId ctx =
    case Array.get specId ctx.specNodes of
        Just (Just (Mono.MonoDefine (Mono.MonoClosure info body _) _)) ->
            Just ( List.map Tuple.second info.params, Mono.typeOf body )

        Just (Just (Mono.MonoTailFunc params body _)) ->
            Just ( List.map Tuple.second params, Mono.typeOf body )

        Just (Just (Mono.MonoCtor shape ty)) ->
            -- A constructor's parameters are its fields.
            Just ( shape.fieldTypes, Tuple.second (Mono.decomposeFunctionType ty) )

        _ ->
            Nothing


{-| Checks that a call through a local variable of type `calleeType` with
`argCount` arguments supplies the whole function, and if so picks the
specialization of `target` to call (`matchSpec`).

The call qualifies when `argCount` equals the number of parameters of the
outermost arrow, which must be at least one, or is greater and the type
flattens to exactly `argCount` parameters. Either way the specialization is
matched against the unflattened callee type. Any other site is turned away as
`g3over` or `g3under`.

-}
postSettleArity : Mono.Global -> Bool -> Mono.MonoType -> Int -> StampCtx -> PostSettleOutcome
postSettleArity target isCtor calleeType argCount ctx =
    let
        firstStage =
            case calleeType of
                Mono.MFunction _ _ params _ ->
                    List.length params

                _ ->
                    0
    in
    if firstStage >= 1 && firstStage == argCount then
        matchSpec target isCtor calleeType ctx

    else if argCount > firstStage then
        case peelStages argCount calleeType of
            Just _ ->
                matchSpec target isCtor calleeType ctx

            Nothing ->
                PsNotCandidate
                    ("g3over|"
                        ++ String.fromInt firstStage
                        ++ "->"
                        ++ String.fromInt argCount
                        ++ "|unpeelable"
                    )

    else
        PsNotCandidate ("g3under|" ++ String.fromInt firstStage ++ "->" ++ String.fromInt argCount)


{-| Picks the specialization of `target` to call: the only one whose type equals
`calleeType`, or failing that the only one equal to it apart from arrow
annotations.

Returns `PsNoSpec` when none matches even by layout, and `PsAmbiguous` when
neither rule gives exactly one. Two specializations of one global with the same
layout can compute different functions, so a choice among several is never
made.

-}
matchSpec : Mono.Global -> Bool -> Mono.MonoType -> StampCtx -> PostSettleOutcome
matchSpec target isCtor calleeType ctx =
    let
        ( layoutMatches, exactMatches ) =
            List.foldr
                (\(( _, specType ) as e) ( accL, accE ) ->
                    if Mono.eqLayout specType calleeType then
                        ( e :: accL
                        , if specType == calleeType then
                            e :: accE

                          else
                            accE
                        )

                    else
                        ( accL, accE )
                )
                ( [], [] )
                (Dict.get (Mono.toComparableGlobal target) ctx.specsByGlobal
                    |> Maybe.withDefault []
                )
    in
    case ( exactMatches, layoutMatches ) of
        ( [ ( specId, _ ) ], _ ) ->
            PsStamp specId isCtor

        ( [], [ ( specId, _ ) ] ) ->
            PsStamp specId isCtor

        ( [], [] ) ->
            PsNoSpec

        ( _, many ) ->
            PsAmbiguous (List.length many)


{-| Counts one singleton site whose member is not in the index and which was
neither rewritten nor stamped.
-}
bumpNoInstance : StampCtx -> StampCtx
bumpNoInstance ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = { stats | declinedNoInstance = stats.declinedNoInstance + 1 } }


{-| Counts one decline in `declinedShape` and, through `sub`, in one of its
sub-reasons, so the sub-reasons add up to `declinedShape`.
-}
bumpShapeWith : (AbiCloningStats -> AbiCloningStats) -> StampCtx -> StampCtx
bumpShapeWith sub ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = sub { stats | declinedShape = stats.declinedShape + 1 } }


{-| The counter for a call that supplies no arguments.
-}
bumpShapeArityZero : StampCtx -> StampCtx
bumpShapeArityZero =
    bumpShapeWith
        (\st ->
            { st
                | declinedShapeArity = st.declinedShapeArity + 1
                , declinedShapeArityZero = st.declinedShapeArityZero + 1
            }
        )


{-| The counter for a call that supplies fewer arguments than its callee type's
first stage takes.
-}
bumpShapeArityUnder : StampCtx -> StampCtx
bumpShapeArityUnder =
    bumpShapeWith
        (\st ->
            { st
                | declinedShapeArity = st.declinedShapeArity + 1
                , declinedShapeArityUnder = st.declinedShapeArityUnder + 1
            }
        )


{-| The counter for a call that supplies more arguments than its callee type's
first stage takes, where no group matches.
-}
bumpShapeArityOver : StampCtx -> StampCtx
bumpShapeArityOver =
    bumpShapeWith
        (\st ->
            { st
                | declinedShapeArity = st.declinedShapeArity + 1
                , declinedShapeArityOver = st.declinedShapeArityOver + 1
            }
        )


{-| The counter for a call whose parameter and return layout has no bucket and no
partial application matches.
-}
bumpShapeBucketMiss : StampCtx -> StampCtx
bumpShapeBucketMiss =
    bumpShapeWith (\st -> { st | declinedShapeBucketMiss = st.declinedShapeBucketMiss + 1 })


{-| The counter for a call whose bucket has no group with its layout and no partial
application matches.
-}
bumpShapeLayout : StampCtx -> StampCtx
bumpShapeLayout =
    bumpShapeWith (\st -> { st | declinedShapeLayout = st.declinedShapeLayout + 1 })


{-| The counter for a call whose matching group has a `Char` capture, or whose
partial application holds a `Char` argument.
-}
bumpShapeChar : StampCtx -> StampCtx
bumpShapeChar =
    bumpShapeWith (\st -> { st | declinedShapeChar = st.declinedShapeChar + 1 })


{-| The counter for a call whose callee type is not a function.
-}
bumpShapeNonArrow : StampCtx -> StampCtx
bumpShapeNonArrow =
    bumpShapeWith (\st -> { st | declinedShapeNonArrow = st.declinedShapeNonArrow + 1 })


{-| Counts one site declined because its group's capture types disagree.
-}
bumpAbiMismatch : StampCtx -> StampCtx
bumpAbiMismatch ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = { stats | declinedAbiMismatch = stats.declinedAbiMismatch + 1 } }


{-| Counts one site declined because its group's fingerprints disagree.
-}
bumpBodyMismatch : StampCtx -> StampCtx
bumpBodyMismatch ctx =
    let
        stats =
            ctx.stats
    in
    { ctx | stats = { stats | declinedBodyMismatch = stats.declinedBodyMismatch + 1 } }



-- ============================================================================
-- ====== FINGERPRINT ======
-- ============================================================================


{-| Returns the fingerprint of an instance (`instanceFingerprint`).
-}
fpOf : Instance -> String
fpOf inst =
    instanceFingerprint inst.info inst.body


{-| Returns a text rendering of a closure, from its header and body, that two
closures share when one is a copy of the other's code.

Source regions are left out. Local names, and the lambda ids of the closure and
of the closures inside it, are replaced by numbers in order of first appearance,
so copies that differ only in freshly chosen names and ids render alike. Types
are rendered by `Mono.toComparableMonoType`, so the fingerprint conflates
whatever that key conflates (for example `LPartial` and `LSet`).

Some things are not rendered at all: the closure's own type (the types of
closures inside it are), the home module of lambda ids and the
`fastEvaluatorSpec` of each `CallInfo`. A lambda id that a `CallInfo` refers to
and that has not been numbered yet is written as `x` followed by its uid.
String and character literals are written without quotes.

-}
instanceFingerprint : Mono.ClosureInfo -> Mono.MonoExpr -> String
instanceFingerprint info body =
    let
        ( frags, _ ) =
            fpClosureParts info body ( [], { lamMap = Dict.empty, nextLam = 0, nameMap = Dict.empty, nextName = 0 } )
    in
    String.concat (List.reverse frags)


{-| Appends a local name as its number, numbering it on first appearance.
-}
fpName : String -> FpState -> FpState
fpName name ( acc, ctx ) =
    case Dict.get name ctx.nameMap of
        Just pos ->
            ( ("n" ++ String.fromInt pos) :: acc, ctx )

        Nothing ->
            ( ("n" ++ String.fromInt ctx.nextName) :: acc
            , { ctx | nameMap = Dict.insert name ctx.nextName ctx.nameMap, nextName = ctx.nextName + 1 }
            )


{-| The numbering built up while a fingerprint is rendered: the numbers given so
far to lambda ids and to local names, and the next of each to give.
-}
type alias FpCtx =
    { lamMap : Dict Int Int -- lambda uid to its number
    , nextLam : Int
    , nameMap : Dict String Int -- local name to its number
    , nextName : Int
    }


{-| A fingerprint being built: its fragments so far, newest first, and the
numbering.
-}
type alias FpState =
    ( List String, FpCtx )


{-| Appends a fragment of text.
-}
fpStr : String -> FpState -> FpState
fpStr s ( acc, ctx ) =
    ( s :: acc, ctx )


{-| Appends a type, rendered by `Mono.toComparableMonoType`.
-}
fpTy : Mono.MonoType -> FpState -> FpState
fpTy t st =
    fpStr (Mono.toComparableMonoType t) st


{-| Appends the lambda id of a closure being rendered, numbering it on first
appearance.
-}
fpLam : Mono.LambdaId -> FpState -> FpState
fpLam (Mono.AnonymousLambda _ uid) ( acc, ctx ) =
    case Dict.get uid ctx.lamMap of
        Just pos ->
            ( ("l" ++ String.fromInt pos) :: acc, ctx )

        Nothing ->
            ( ("l" ++ String.fromInt ctx.nextLam) :: acc
            , { ctx | lamMap = Dict.insert uid ctx.nextLam ctx.lamMap, nextLam = ctx.nextLam + 1 }
            )


{-| Appends a lambda id that a `CallInfo` refers to: its number when it has one,
and otherwise `x` followed by its raw uid.
-}
fpLamRef : Mono.LambdaId -> FpState -> FpState
fpLamRef (Mono.AnonymousLambda _ uid) (( _, ctx ) as st) =
    case Dict.get uid ctx.lamMap of
        Just pos ->
            fpStr ("l" ++ String.fromInt pos) st

        Nothing ->
            fpStr ("x" ++ String.fromInt uid) st


{-| Appends a closure's lambda id, source lambda, member, captures, parameters,
closure kind, capture ABI and body. Its type is not included.
-}
fpClosureParts : Mono.ClosureInfo -> Mono.MonoExpr -> FpState -> FpState
fpClosureParts info body st =
    st
        |> fpStr "Clo("
        |> fpLam info.lambdaId
        |> fpStr ";src="
        |> fpStr
            (case info.srcLambda of
                Just sl ->
                    String.fromInt (Id.toComparable sl)

                Nothing ->
                    "-"
            )
        |> fpStr (";mem=" ++ fpMaybeInt info.lssMember ++ ";caps=[")
        |> fpCaps info.captures
        |> fpStr "];params=["
        |> fpParams info.params
        |> fpStr ("];ck=" ++ fpClosureKind info.closureKind ++ ";cabi=")
        |> fpCaptureAbi info.captureAbi
        |> fpStr ";"
        |> fpExpr body
        |> fpStr ")"


{-| Appends each capture's name, its flag and its expression.
-}
fpCaps : List ( String, Mono.MonoExpr, Bool ) -> FpState -> FpState
fpCaps caps st =
    List.foldl
        (\( n, e, b ) a ->
            a
                |> fpName n
                |> fpStr
                    (if b then
                        "!"

                     else
                        "="
                    )
                |> fpExpr e
                |> fpStr ","
        )
        st
        caps


{-| Appends each parameter's name and type.
-}
fpParams : List ( String, Mono.MonoType ) -> FpState -> FpState
fpParams params st =
    List.foldl (\( n, t ) a -> a |> fpName n |> fpStr ":" |> fpTy t |> fpStr ",") st params


{-| Renders an optional number, with `-` for `Nothing`.
-}
fpMaybeInt : Maybe Int -> String
fpMaybeInt m =
    case m of
        Just i ->
            String.fromInt i

        Nothing ->
            "-"


{-| Renders a closure kind, with `-` for `Nothing`.
-}
fpClosureKind : Mono.MaybeClosureKind -> String
fpClosureKind mck =
    case mck of
        Just (Mono.Known (Mono.ClosureKindId k)) ->
            "K" ++ String.fromInt k

        Nothing ->
            "-"


{-| Appends a capture ABI's capture, parameter and return types, or `-` for
`Nothing`.
-}
fpCaptureAbi : Maybe Mono.CaptureABI -> FpState -> FpState
fpCaptureAbi mabi st =
    case mabi of
        Nothing ->
            fpStr "-" st

        Just abi ->
            st
                |> fpStr "{c="
                |> fpTys abi.captureTypes
                |> fpStr ";p="
                |> fpTys abi.paramTypes
                |> fpStr ";r="
                |> fpTy abi.returnType
                |> fpStr "}"


{-| Appends each type of a list.
-}
fpTys : List Mono.MonoType -> FpState -> FpState
fpTys ts st =
    List.foldl (\t a -> a |> fpTy t |> fpStr ",") st ts


{-| Renders a list of numbers, separated by commas.
-}
fpInts : List Int -> String
fpInts xs =
    String.join "," (List.map String.fromInt xs)


{-| Appends every field of a `CallInfo` except `fastEvaluatorSpec`.
-}
fpCallInfo : Mono.CallInfo -> FpState -> FpState
fpCallInfo ci st =
    st
        |> fpStr
            ((case ci.callModel of
                Mono.FlattenedExternal ->
                    "FE"

                Mono.StageCurried ->
                    "SC"
             )
                ++ "|sa="
                ++ fpInts ci.stageArities
                ++ (if ci.isSingleStageSaturated then
                        "|s1"

                    else
                        "|s0"
                   )
                ++ "|ir="
                ++ String.fromInt ci.initialRemaining
                ++ "|ra="
                ++ fpInts ci.remainingStageArities
                ++ "|ck="
                ++ fpClosureKind ci.closureKind
                ++ "|ca="
            )
        |> fpCaptureAbi ci.captureAbi
        |> fpStr "|fe="
        |> (\a ->
                case ci.fastEvaluator of
                    Just lid ->
                        fpLamRef lid a

                    Nothing ->
                        fpStr "-" a
           )
        |> fpStr
            ("|pp="
                ++ fpMaybeInt ci.fastPapPrefix
                ++ "|"
                ++ (case ci.callKind of
                        Mono.CallDirectKnownSegmentation ->
                            "KS"

                        Mono.CallDirectFlat ->
                            "DF"

                        Mono.CallGenericApply ->
                            "GA"

                        Mono.CallSegmentationUnknown ->
                            "SU"
                   )
                ++ "|rt="
            )
        |> fpTy ci.evaluatorReturnType


{-| Appends an expression, with the type of each node that has one, leaving out
regions.
-}
fpExpr : Mono.MonoExpr -> FpState -> FpState
fpExpr expr st =
    case expr of
        Mono.MonoLiteral lit t ->
            st |> fpStr ("Li(" ++ fpLit lit ++ "):") |> fpTy t

        Mono.MonoVarLocal name t ->
            st |> fpStr "VL(" |> fpName name |> fpStr "):" |> fpTy t

        Mono.MonoVarGlobal _ specId t ->
            st |> fpStr ("VG(" ++ String.fromInt specId ++ "):") |> fpTy t

        Mono.MonoVarKernel _ prefix home name t ->
            st |> fpStr ("VK(" ++ prefix ++ "." ++ home ++ "." ++ name ++ "):") |> fpTy t

        Mono.MonoList _ items t ->
            st |> fpStr "Ls[" |> fpExprs items |> fpStr "]:" |> fpTy t

        Mono.MonoClosure info body t ->
            st |> fpClosureParts info body |> fpStr ":" |> fpTy t

        Mono.MonoCall _ func args t callInfo ->
            st
                |> fpStr "Ca("
                |> fpExpr func
                |> fpStr ",["
                |> fpExprs args
                |> fpStr "];ci="
                |> fpCallInfo callInfo
                |> fpStr "):"
                |> fpTy t

        Mono.MonoTailCall name args t ->
            st
                |> fpStr "TC("
                |> fpName name
                |> fpStr ",["
                |> (\a -> List.foldl (\( n, e ) acc -> acc |> fpName n |> fpStr "=" |> fpExpr e |> fpStr ",") a args)
                |> fpStr "]):"
                |> fpTy t

        Mono.MonoIf branches final t ->
            st
                |> fpStr "If(["
                |> (\a -> List.foldl (\( c, b ) acc -> acc |> fpExpr c |> fpStr "->" |> fpExpr b |> fpStr ";") a branches)
                |> fpStr "],"
                |> fpExpr final
                |> fpStr "):"
                |> fpTy t

        Mono.MonoLet def body t ->
            st |> fpStr "Le(" |> fpDef def |> fpStr "," |> fpExpr body |> fpStr "):" |> fpTy t

        Mono.MonoDestruct dtor body t ->
            st |> fpStr "De(" |> fpDtor dtor |> fpStr "," |> fpExpr body |> fpStr "):" |> fpTy t

        Mono.MonoCase n1 n2 decider jumps t ->
            st
                |> fpStr "Cs("
                |> fpName n1
                |> fpStr ","
                |> fpName n2
                |> fpStr ","
                |> fpDecider decider
                |> fpStr ",j=["
                |> (\a -> List.foldl (\( i, e ) acc -> acc |> fpStr (String.fromInt i ++ "=") |> fpExpr e |> fpStr ",") a jumps)
                |> fpStr "]):"
                |> fpTy t

        Mono.MonoRecordCreate fields t ->
            st |> fpStr "Rc[" |> fpNamedExprs fields |> fpStr "]:" |> fpTy t

        Mono.MonoRecordAccess record name t ->
            st |> fpStr "Ra(" |> fpExpr record |> fpStr ("." ++ name ++ "):") |> fpTy t

        Mono.MonoRecordUpdate record updates t ->
            st |> fpStr "Ru(" |> fpExpr record |> fpStr ",[" |> fpNamedExprs updates |> fpStr "]):" |> fpTy t

        Mono.MonoTupleCreate _ items t ->
            st |> fpStr "Tu[" |> fpExprs items |> fpStr "]:" |> fpTy t

        Mono.MonoUnit ->
            fpStr "U" st

        Mono.MonoAccessorValue _ name t ->
            st |> fpStr ("Av(" ++ name ++ "):") |> fpTy t


{-| Appends each expression of a list.
-}
fpExprs : List Mono.MonoExpr -> FpState -> FpState
fpExprs items st =
    List.foldl (\e a -> a |> fpExpr e |> fpStr ",") st items


{-| Appends each field name, as written, and its expression.
-}
fpNamedExprs : List ( String, Mono.MonoExpr ) -> FpState -> FpState
fpNamedExprs fields st =
    List.foldl (\( n, e ) a -> a |> fpStr (n ++ "=") |> fpExpr e |> fpStr ",") st fields


{-| Renders a literal behind a one-letter tag. Strings and characters are written
as they are, without quotes.
-}
fpLit : Mono.Literal -> String
fpLit lit =
    case lit of
        Mono.LBool b ->
            if b then
                "BT"

            else
                "BF"

        Mono.LInt i ->
            "I" ++ String.fromInt i

        Mono.LFloat f ->
            "F" ++ String.fromFloat f

        Mono.LChar c ->
            "C" ++ c

        Mono.LStr s ->
            "S" ++ s


{-| Appends a let definition: its name, a tail definition's parameters, and its
expression.
-}
fpDef : Mono.MonoDef -> FpState -> FpState
fpDef def st =
    case def of
        Mono.MonoDef name e ->
            st |> fpName name |> fpStr "=" |> fpExpr e

        Mono.MonoTailDef name params e ->
            st |> fpName name |> fpStr "([" |> fpParams params |> fpStr "])=" |> fpExpr e


{-| Appends a destructuring binding: the name it binds, the path it reads, and its
type.
-}
fpDtor : Mono.MonoDestructor -> FpState -> FpState
fpDtor (Mono.MonoDestructor name path t) st =
    st |> fpName name |> fpStr "<-" |> fpPath path |> fpStr ":" |> fpTy t


{-| Appends a destructuring path.
-}
fpPath : Mono.MonoPath -> FpState -> FpState
fpPath path st =
    case path of
        Mono.MonoIndex i ck t sub ->
            st |> fpStr ("Ix" ++ String.fromInt i ++ fpContainer ck ++ ":") |> fpTy t |> fpStr "." |> fpPath sub

        Mono.MonoField name t sub ->
            st |> fpStr ("Fd" ++ name ++ ":") |> fpTy t |> fpStr "." |> fpPath sub

        Mono.MonoUnbox t sub ->
            st |> fpStr "Ub:" |> fpTy t |> fpStr "." |> fpPath sub

        Mono.MonoRoot name t ->
            st |> fpStr "Rt" |> fpName name |> fpStr ":" |> fpTy t


{-| Renders a container kind.
-}
fpContainer : Mono.ContainerKind -> String
fpContainer ck =
    case ck of
        Mono.ListContainer ->
            "@L"

        Mono.Tuple2Container ->
            "@2"

        Mono.Tuple3Container ->
            "@3"

        Mono.CustomContainer n ->
            "@C" ++ n


{-| Appends a decision tree, rendering its tests with `DT.testToComparable`.
-}
fpDecider : Mono.Decider Mono.MonoChoice -> FpState -> FpState
fpDecider decider st =
    case decider of
        Mono.Leaf choice ->
            st |> fpStr "Lf(" |> fpChoice choice |> fpStr ")"

        Mono.Chain tests success failure ->
            st
                |> fpStr "Ch(["
                |> (\a -> List.foldl (\( p, t ) acc -> acc |> fpDtPath p |> fpStr ("?" ++ DT.testToComparable t ++ ";")) a tests)
                |> fpStr "],"
                |> fpDecider success
                |> fpStr ","
                |> fpDecider failure
                |> fpStr ")"

        Mono.FanOut path edges fallback ->
            st
                |> fpStr "Fo("
                |> fpDtPath path
                |> fpStr ",["
                |> (\a -> List.foldl (\( t, d ) acc -> acc |> fpStr (DT.testToComparable t ++ "->") |> fpDecider d |> fpStr ";") a edges)
                |> fpStr "],"
                |> fpDecider fallback
                |> fpStr ")"


{-| Appends a decision-tree leaf: an inline expression or a jump number.
-}
fpChoice : Mono.MonoChoice -> FpState -> FpState
fpChoice choice st =
    case choice of
        Mono.Inline e ->
            st |> fpStr "In(" |> fpExpr e |> fpStr ")"

        Mono.Jump j ->
            fpStr ("Jm" ++ String.fromInt j) st


{-| Appends a decision-tree path.
-}
fpDtPath : Mono.MonoDtPath -> FpState -> FpState
fpDtPath path st =
    case path of
        Mono.DtRoot name t ->
            st |> fpStr "dR" |> fpName name |> fpStr ":" |> fpTy t

        Mono.DtIndex i ck t sub ->
            st |> fpStr ("dI" ++ String.fromInt i ++ fpContainer ck ++ ":") |> fpTy t |> fpStr "." |> fpDtPath sub

        Mono.DtUnbox t sub ->
            st |> fpStr "dU:" |> fpTy t |> fpStr "." |> fpDtPath sub
