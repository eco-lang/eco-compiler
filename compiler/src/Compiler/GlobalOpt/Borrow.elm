module Compiler.GlobalOpt.Borrow exposing
    ( run, deriveFacts
    , BorrowStats, emptyStats, renderStats
    , analyzeDefForTest
    )

{-| Borrow inference asks, for every function in the monomorphized graph,
which of its arguments it only reads and which it consumes. A function
_borrows_ an argument when the caller still owns the value after the call, and
_owns_ it when the function takes the value over. This module drives that
analysis over the whole graph and reports what it found; it never changes the
graph.

The analysis of one definition is done elsewhere: `Compiler.GlobalOpt.Borrow.Constrain`
generates constraints over its _resources_ (the heap objects inside its
values) and `Compiler.GlobalOpt.Borrow.Solve` solves them. What this module
adds is the interprocedural part. A call can only be analysed if the callee's
_signature_ (`BorrowSig`: the mode of each heap position of each parameter and
of the result, and which result positions may alias which parameters) is
known, so the signatures of all specializations are solved together, into a
_signature table_ indexed by `SpecId`.

The signature table is built one strongly connected component of the
reference graph at a time, callees before callers. An edge is a `MonoVarGlobal`
in a body, as `Compiler.Monomorphize.MonoTraverse.collectSpecEdges` collects
them, and the components come in the order `Compiler.Graph.stronglyConnCompInt`
returns, which puts each component after the ones it refers to. A definition
outside any cycle is analysed once against the signatures solved so far. The
members of a cycle start from the optimistic signature (every position
borrowed) and are re-analysed until no signature changes; if that has not
happened after 20 rounds, every member is given the all-owned signature
instead, and the run counts a bailout. A node that is not a definition, such as
a constructor or an extern, gets the all-owned signature. While building the
table, closure calls are not routed through lambda sets, so every call of a
function value counts as consuming its arguments.

A function value reached through a lambda set is named by its lambda-set
member id, not a `SpecId`, and needs a signature of its own, its _lambda
signature_. One member can have several closure instances. When it has one, or
all of them have the same `Compiler.GlobalOpt.AbiCloning.instanceFingerprint`,
the first instance's signature is used; otherwise the instances' signatures are
combined with `Compiler.GlobalOpt.Borrow.LssFacts.meetSig`, which is safe for
whichever instance is called.

The results are used in two ways. `run` analyses every definition once more
against the finished tables, this time routing closure calls through the lambda
sets, and adds up a _census_ of counters (`BorrowStats`). `deriveFacts` stops
after the signatures and reduces them to the oracle facts of
`Compiler.GlobalOpt.Borrow.Facts`.

Most of the census is about what an ownership-aware back end could save, and
part of it is an escape analysis: an owned resource that cannot outlive the
call that made it could live on the stack. Two counts bound that from either
side. `nonEscapingOwned` treats a resource as escaping when it may alias a
parameter, is part of the result, or has a lifetime that reaches the
parameters; it does not follow a resource stored into another that escapes, so
it overcounts. `nonEscapingOwnedLB` also joins resources that are read out of
or stored into each other, and treats every resource joined to an escaping one,
to a tail-call argument, or to a resource the constraint walk marked as
escaping as escaping too.


# Running

@docs run, deriveFacts


# Statistics

@docs BorrowStats, emptyStats, renderStats


# Testing

@docs analyzeDefForTest

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.BitSet as BitSet
import Compiler.Data.Name exposing (Name)
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.AbiCloning as AbiCloning
import Compiler.GlobalOpt.Borrow.Constrain as C
import Compiler.GlobalOpt.Borrow.Dsu as Dsu
import Compiler.GlobalOpt.Borrow.Facts as Facts
import Compiler.GlobalOpt.Borrow.Lifetime as L exposing (Life(..), Lifetime(..))
import Compiler.GlobalOpt.Borrow.LssFacts as LssFacts
import Compiler.GlobalOpt.Borrow.Mode exposing (Mode(..))
import Compiler.GlobalOpt.Borrow.Rty as Rty exposing (ResVar)
import Compiler.GlobalOpt.Borrow.Sig as Sig exposing (BorrowSig)
import Compiler.GlobalOpt.Borrow.Solve as Solve
import Compiler.Graph as Graph
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict exposing (Dict)
import Set exposing (Set)



-- CENSUS


{-| The census a borrow-inference run collects over the whole graph, as
`renderStats` prints it.

Most fields are sums over every analysed definition. `maxSccIter` and
`maxBorrowExtension` are maxima, and `sccFixpointBailouts`, `maxSccIter`,
`lambdaSigMeets` and `poisonedParams` come from the signature tables rather
than from the per-definition analyses. `poisonedParams` counts owned parameter
positions in every signature in the table, including the all-owned signatures
of nodes that are not definitions.

-}
type alias BorrowStats =
    { defsAnalyzed : Int
    , resources : Int
    , borrowedResources : Int
    , wouldDup : Int
    , wouldDrop : Int
    , wouldFree : Int
    , poisonedByClosure : Int
    , closureRouted : Int -- closure calls given a signature through the lambda sets
    , poisonedByErased : Int
    , poisonedByKernel : Int
    , poisonedParams : Int -- owned parameter positions across all signatures
    , poisoningCallSites : Int
    , sigMissReads : Int
    , kernelSigHits : Int -- kernel calls given a signature from the kernel table
    , kernelDefaultedHeapCalls : Int -- kernel calls with heap arguments and no table entry
    , sccFixpointBailouts : Int
    , maxSccIter : Int -- most signature-changing rounds any cycle took
    , lambdaSigMeets : Int -- members whose lambda signature is a meet of differing instances
    , capturesForcedOwned : Int
    , nonVarOperandHeapOwnedFresh : Int
    , nonVarOperandHeapBorrowedProducer : Int
    , updateCopiedHeapFields : Int
    , maxBorrowExtension : Int -- deepest nesting of a borrowed resource's precise lifetime
    , ltpRefined : Int -- resources whose precise lifetime differs from the approximate one
    , ownedResources : Int -- resources that must be treated as owned
    , nonEscapingOwned : Int -- upper bound
    , nonEscapingOwnedLB : Int -- lower bound
    , escClassHisto : Dict String ( Int, Int ) -- per allocation-site class: (weighted sites, weighted sites that are owned and do not escape by the lower bound)
    , kernelDefaultedNames : Dict ( Name, Name ) Int -- kernelDefaultedHeapCalls per kernel (home, name)
    , immortalLiterals : Int
    }


{-| A census with every counter at zero and empty histograms.
-}
emptyStats : BorrowStats
emptyStats =
    { defsAnalyzed = 0
    , resources = 0
    , borrowedResources = 0
    , wouldDup = 0
    , wouldDrop = 0
    , wouldFree = 0
    , poisonedByClosure = 0
    , closureRouted = 0
    , poisonedByErased = 0
    , poisonedByKernel = 0
    , poisonedParams = 0
    , poisoningCallSites = 0
    , sigMissReads = 0
    , kernelSigHits = 0
    , kernelDefaultedHeapCalls = 0
    , sccFixpointBailouts = 0
    , maxSccIter = 0
    , lambdaSigMeets = 0
    , capturesForcedOwned = 0
    , nonVarOperandHeapOwnedFresh = 0
    , nonVarOperandHeapBorrowedProducer = 0
    , updateCopiedHeapFields = 0
    , maxBorrowExtension = 0
    , ltpRefined = 0
    , ownedResources = 0
    , nonEscapingOwned = 0
    , nonEscapingOwnedLB = 0
    , escClassHisto = Dict.empty
    , kernelDefaultedNames = Dict.empty
    , immortalLiterals = 0
    }


{-| The most rounds a cycle of definitions is re-analysed before its
signatures are given up as all-owned.
-}
maxIterConst : Int
maxIterConst =
    20



-- DRIVER


{-| Runs borrow inference over the graph and returns the graph unchanged together
with its census. Unless `cfg` turns on `report` or `validate`, or sets `reify`
to something other than `ROff`, nothing is analysed and the census is
`emptyStats`. Every `reify` mode leaves the graph unchanged.
-}
run : Config.BorrowConfig -> Mono.MonoGraph -> ( Mono.MonoGraph, BorrowStats )
run cfg graph =
    if not (cfg.report || cfg.validate || cfg.reify /= Config.ROff) then
        ( graph, emptyStats )

    else
        runCensus graph


{-| Solves the signature and lambda-signature tables of `graph`, then analyses
every definition against them with closure calls routed through the lambda
sets, and returns the graph unchanged with the summed census.
-}
runCensus : Mono.MonoGraph -> ( Mono.MonoGraph, BorrowStats )
runCensus graph =
    let
        (Mono.MonoGraph { nodes, registry, lssMemberOrigins }) =
            graph

        sigTable =
            solveSigs nodes

        ( _, bailouts, maxIter ) =
            sigTable

        table =
            firstOf sigTable

        ( byMember, _ ) =
            LssFacts.buildInstances nodes

        ( lambdaSigs, sigMeets ) =
            buildLambdaSigs table byMember

        facts =
            { members = LssFacts.buildMemberTable nodes lssMemberOrigins
            , lambdaSigsByMember = lambdaSigs
            , globalIndex = buildGlobalIndex registry
            , sigs = sigLookup table
            }

        stats0 =
            { emptyStats | sccFixpointBailouts = bailouts, maxSccIter = maxIter, lambdaSigMeets = sigMeets }

        stats1 =
            Array.foldl
                (\maybeNode acc ->
                    case maybeNode of
                        Just node ->
                            censusNode table facts node acc

                        Nothing ->
                            acc
                )
                stats0
                nodes
    in
    ( graph, { stats1 | poisonedParams = countPoisonedParams table } )


{-| Returns the lambda signature of every member in `byMember`, with the
number of members whose signature is a meet.

A member with one instance, or whose instances all have the same
`AbiCloning.instanceFingerprint`, gets the first instance's signature. Any
other member gets the `LssFacts.meetSig` of all its instances' signatures:
instances that share a member id can still behave differently, and the meet is
safe for whichever one is called. Fingerprints are computed only for members
with more than one instance. Members with no instances get no entry.

-}
buildLambdaSigs : SigTable -> Dict Int (List LssFacts.LambdaRef) -> ( Dict Int BorrowSig, Int )
buildLambdaSigs table byMember =
    Dict.foldl
        (\m refs ( acc, meets ) ->
            case refs of
                [] ->
                    ( acc, meets )

                ref :: rest ->
                    if List.isEmpty rest || fpUnanimousRefs ref rest then
                        ( Dict.insert m (memberInstanceSig table ref) acc, meets )

                    else
                        ( Dict.insert m
                            (List.foldl
                                (\r s -> LssFacts.meetSig s (memberInstanceSig table r))
                                (memberInstanceSig table ref)
                                rest
                            )
                            acc
                        , meets + 1
                        )
        )
        ( Dict.empty, 0 )
        byMember


{-| Analyses one closure instance as if it were a definition, against `table`
and with closure calls not routed, and returns its signature.
-}
memberInstanceSig : SigTable -> LssFacts.LambdaRef -> BorrowSig
memberInstanceSig table ref =
    let
        da =
            C.constrainClosureForSig (mkEnv (sigLookup table) Nothing) ref.closureInfo ref.body C.emptyGen

        solved =
            Solve.solve da.gen.next False da.gen.cs
    in
    readbackSig solved da


{-| Tells whether every instance in `rest` has the same
`AbiCloning.instanceFingerprint` as `ref`.
-}
fpUnanimousRefs : LssFacts.LambdaRef -> List LssFacts.LambdaRef -> Bool
fpUnanimousRefs ref rest =
    let
        fp0 =
            AbiCloning.instanceFingerprint ref.closureInfo ref.body
    in
    List.all (\r -> AbiCloning.instanceFingerprint r.closureInfo r.body == fp0) rest


{-| A signature table: the signature of each specialization, indexed by
`SpecId`, with `Nothing` where there is no node or it has not been solved yet.
-}
type alias SigTable =
    Array (Maybe BorrowSig)


{-| Returns the table from the result of `solveSigs`.
-}
firstOf : ( SigTable, Int, Int ) -> SigTable
firstOf ( t, _, _ ) =
    t


{-| Solves the signature table of `nodes` one strongly connected component at a
time, callees first, and returns it with the number of cycles that gave up and
the most signature-changing rounds any cycle took.
-}
solveSigs : Array (Maybe Mono.MonoNode) -> ( SigTable, Int, Int )
solveSigs nodes =
    let
        edges =
            MonoTraverse.collectSpecEdges nodes

        ( indexToSpecId, sccs ) =
            buildSCC nodes edges

        emptyTable =
            Array.repeat (Array.length nodes) Nothing
    in
    List.foldl (solveScc nodes indexToSpecId) ( emptyTable, 0, 0 ) sccs


{-| Looks up the signature of a specialization in a table.
-}
sigLookup : SigTable -> Mono.SpecId -> Maybe BorrowSig
sigLookup table specId =
    Array.get specId table |> Maybe.andThen identity


{-| Derives the oracle facts of a graph: for each specialization and each
lambda-set member, the parameters it wholly borrows, as
`Compiler.GlobalOpt.Borrow.Facts` defines that.

Only the signature table and the lambda signatures are computed, not the
census. Both are built with closure calls not routed through the lambda sets,
so an argument passed to a call of a function value is never found borrowed.
The facts describe `graph`; a later rewrite of the graph is not reflected in
them.

-}
deriveFacts : Mono.MonoGraph -> Facts.OracleFacts
deriveFacts (Mono.MonoGraph { nodes }) =
    let
        ( table, _, _ ) =
            solveSigs nodes

        ( byMember, _ ) =
            LssFacts.buildInstances nodes

        bySpec =
            Tuple.second
                (Array.foldl
                    (\maybeSig ( specId, acc ) ->
                        case maybeSig of
                            Just sig ->
                                ( specId + 1, Dict.insert specId (distillSig sig) acc )

                            Nothing ->
                                ( specId + 1, acc )
                    )
                    ( 0, Dict.empty )
                    table
                )

        byLambda =
            Dict.map (\_ sig -> distillSig sig) (Tuple.first (buildLambdaSigs table byMember))
    in
    { bySpec = bySpec
    , byLambda = byLambda
    }


{-| Returns the parameter indices of `sig` that are wholly borrowed: the
parameter has at least one heap position, every one of them is `Borrowed`, and
no `resultLts` entry names it. A parameter with no heap position is never
included.
-}
distillSig : BorrowSig -> Facts.CalleeParamFacts
distillSig sig =
    let
        coupled =
            List.foldl (\( _, s ) acc -> Set.union s acc) Set.empty sig.resultLts

        whollyBorrowed sigTy =
            not (Array.isEmpty sigTy.modes)
                && Array.foldl (\m ok -> ok && m == Borrowed) True sigTy.modes

        step sigTy ( i, acc ) =
            ( i + 1
            , if whollyBorrowed sigTy && not (Set.member i coupled) then
                Set.insert i acc

              else
                acc
            )
    in
    { borrowedParams =
        Tuple.second (List.foldl step ( 0, Set.empty ) sig.params)
    }


{-| Builds, from the registry, every specialization of each global, keyed by
`Mono.toComparableGlobal`, as pairs of its type and `SpecId`. One global can
have several specializations.
-}
buildGlobalIndex : Mono.SpecializationRegistry -> Dict String (List ( Mono.MonoType, Mono.SpecId ))
buildGlobalIndex registry =
    Tuple.second
        (Array.foldl
            (\maybe ( specId, acc ) ->
                case maybe of
                    Just ( g, ty ) ->
                        ( specId + 1
                        , Dict.update (Mono.toComparableGlobal g)
                            (\ex -> Just (( ty, specId ) :: Maybe.withDefault [] ex))
                            acc
                        )

                    Nothing ->
                        ( specId + 1, acc )
            )
            ( 0, Dict.empty )
            registry.reverseMapping
        )


{-| Builds a constraint environment that finds callee signatures with `lookup`
and routes closure calls through `facts`, or does not route them when `facts`
is `Nothing`.
-}
mkEnv : (Mono.SpecId -> Maybe BorrowSig) -> Maybe LssFacts.Facts -> C.Env
mkEnv lookup facts =
    let
        base =
            C.emptyEnv
    in
    { base | sigs = lookup, lssFacts = facts }



-- STRONGLY CONNECTED COMPONENTS


{-| Returns the strongly connected components of the reference graph `edges`
over the nodes present in `nodes`, callees first, together with the `SpecId`
of each component vertex. Vertices are numbered densely over the present
nodes, in `SpecId` order, and an edge to an absent node is dropped.
-}
buildSCC : Array (Maybe Mono.MonoNode) -> Array (Maybe (List Mono.SpecId)) -> ( Array Mono.SpecId, List (Graph.SCC Int) )
buildSCC nodes edges =
    let
        specIds =
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Just _ ->
                            ( specId + 1, specId :: acc )

                        Nothing ->
                            ( specId + 1, acc )
                )
                ( 0, [] )
                nodes
                |> Tuple.second
                |> List.reverse

        n =
            List.length specIds

        indexToSpecId =
            Array.fromList specIds

        idToIndex =
            List.foldl (\( idx, specId ) acc -> Dict.insert specId idx acc)
                Dict.empty
                (List.indexedMap Tuple.pair specIds)

        buildResult =
            Array.foldl
                (\maybeNode ( specId, acc ) ->
                    case maybeNode of
                        Nothing ->
                            ( specId + 1, acc )

                        Just _ ->
                            let
                                idx =
                                    Dict.get specId idToIndex |> Maybe.withDefault -1

                                neighborSpecIds =
                                    Array.get specId edges |> Maybe.andThen identity |> Maybe.withDefault []

                                neighborIdxs =
                                    List.filterMap (\sid -> Dict.get sid idToIndex) neighborSpecIds

                                hasSelfLoop =
                                    List.member idx neighborIdxs

                                newFwd =
                                    if idx >= 0 then
                                        Dict.insert idx neighborIdxs acc.fwd

                                    else
                                        acc.fwd

                                newTrans =
                                    List.foldl
                                        (\target t ->
                                            Dict.insert target (idx :: (Dict.get target t |> Maybe.withDefault [])) t
                                        )
                                        acc.trans
                                        neighborIdxs

                                newSelfLoops =
                                    if hasSelfLoop && idx >= 0 then
                                        BitSet.insert idx acc.selfLoops

                                    else
                                        acc.selfLoops
                            in
                            ( specId + 1, { fwd = newFwd, trans = newTrans, selfLoops = newSelfLoops } )
                )
                ( 0, { fwd = Dict.empty, trans = Dict.empty, selfLoops = BitSet.emptyWithSize n } )
                nodes
                |> Tuple.second

        fwdArray =
            Array.initialize n (\i -> Dict.get i buildResult.fwd |> Maybe.withDefault [])

        transArray =
            Array.initialize n (\i -> Dict.get i buildResult.trans |> Maybe.withDefault [])

        sccsInt =
            Graph.stronglyConnCompInt
                { fwd = fwdArray, trans = transArray, selfLoops = buildResult.selfLoops, size = n }
    in
    ( indexToSpecId, sccsInt )



-- FIXPOINT


{-| Solves the signatures of one component into the table, adding to the
bailout count and the most rounds seen. A cycle starts from optimistic
signatures; if it has not settled within `maxIterConst` rounds, every member
gets the all-owned signature.
-}
solveScc : Array (Maybe Mono.MonoNode) -> Array Mono.SpecId -> Graph.SCC Int -> ( SigTable, Int, Int ) -> ( SigTable, Int, Int )
solveScc nodes indexToSpecId scc ( table, bailouts, maxIter ) =
    case scc of
        Graph.AcyclicSCC idx ->
            case Array.get idx indexToSpecId of
                Just specId ->
                    ( setSig table specId (analyzeAndReadback nodes table specId), bailouts, maxIter )

                Nothing ->
                    ( table, bailouts, maxIter )

        Graph.CyclicSCC idxs ->
            let
                specIds =
                    List.filterMap (\i -> Array.get i indexToSpecId) idxs

                table0 =
                    List.foldl (\sid t -> setSig t sid (Just (initSig nodes sid))) table specIds

                ( tableN, iters, converged ) =
                    iterateScc nodes specIds table0 0
            in
            if converged then
                ( tableN, bailouts, max maxIter iters )

            else
                ( List.foldl (\sid t -> setSig t sid (Just (allOwnedSigFor nodes sid))) tableN specIds
                , bailouts + 1
                , max maxIter iters
                )


{-| Re-analyses the members of a cycle in order, each against the table as
updated by the members before it, until a round changes no signature. Returns
the table, the number of rounds that changed something, and whether it
settled before `maxIterConst` rounds.
-}
iterateScc : Array (Maybe Mono.MonoNode) -> List Mono.SpecId -> SigTable -> Int -> ( SigTable, Int, Bool )
iterateScc nodes specIds table iter =
    if iter >= maxIterConst then
        ( table, iter, False )

    else
        let
            ( table1, changed ) =
                List.foldl
                    (\sid ( t, ch ) ->
                        case analyzeAndReadback nodes t sid of
                            Just newSig ->
                                case sigLookup t sid of
                                    Just oldSig ->
                                        if Sig.sigEq oldSig newSig then
                                            ( t, ch )

                                        else
                                            ( setSig t sid (Just newSig), True )

                                    Nothing ->
                                        ( setSig t sid (Just newSig), True )

                            Nothing ->
                                ( t, ch )
                    )
                    ( table, False )
                    specIds
        in
        if changed then
            iterateScc nodes specIds table1 (iter + 1)

        else
            ( table1, iter, True )


{-| Sets the signature of one specialization in a table.
-}
setSig : SigTable -> Mono.SpecId -> Maybe BorrowSig -> SigTable
setSig table specId maybeSig =
    Array.set specId maybeSig table


{-| Returns the signature of a node against `table`: analysed for a tail
function or a define, all-owned for any other node, and `Nothing` when there
is no node at `specId`.
-}
analyzeAndReadback : Array (Maybe Mono.MonoNode) -> SigTable -> Mono.SpecId -> Maybe BorrowSig
analyzeAndReadback nodes table specId =
    case Array.get specId nodes |> Maybe.andThen identity of
        Just node ->
            case node of
                Mono.MonoTailFunc _ _ _ ->
                    Just (analyzeNodeSig table node)

                Mono.MonoDefine _ _ ->
                    Just (analyzeNodeSig table node)

                _ ->
                    Just (allOwnedSigFor nodes specId)

        Nothing ->
            Nothing


{-| Analyses a definition against `table`, with closure calls not routed, and
returns its signature.
-}
analyzeNodeSig : SigTable -> Mono.MonoNode -> BorrowSig
analyzeNodeSig table node =
    let
        env =
            mkEnv (sigLookup table) Nothing

        da =
            C.constrainDef env node C.emptyGen

        solved =
            Solve.solve da.gen.next False da.gen.cs
    in
    readbackSig solved da


{-| Returns the parameter types and result type a node's signature is shaped
from. A define whose body is not a closure has no parameters.
-}
defSigShapes : Mono.MonoNode -> ( List Mono.MonoType, Mono.MonoType )
defSigShapes node =
    case node of
        Mono.MonoTailFunc params body _ ->
            ( List.map Tuple.second params, Mono.typeOf body )

        Mono.MonoDefine (Mono.MonoClosure info inner _) _ ->
            ( List.map Tuple.second info.params, Mono.typeOf inner )

        Mono.MonoDefine body _ ->
            ( [], Mono.typeOf body )

        _ ->
            ( [], Mono.nodeType node )


{-| Returns the optimistic signature of a node, the starting point for a cycle.
-}
initSig : Array (Maybe Mono.MonoNode) -> Mono.SpecId -> BorrowSig
initSig nodes specId =
    case Array.get specId nodes |> Maybe.andThen identity of
        Just node ->
            let
                ( ps, r ) =
                    defSigShapes node
            in
            Sig.optimisticSig ps r

        Nothing ->
            Sig.optimisticSig [] Mono.MUnit


{-| Returns the all-owned signature of a node.
-}
allOwnedSigFor : Array (Maybe Mono.MonoNode) -> Mono.SpecId -> BorrowSig
allOwnedSigFor nodes specId =
    case Array.get specId nodes |> Maybe.andThen identity of
        Just node ->
            let
                ( ps, r ) =
                    defSigShapes node
            in
            Sig.allOwnedSig ps r

        Nothing ->
            Sig.allOwnedSig [] Mono.MUnit



-- SIGNATURE READBACK


{-| Reads a definition's signature out of its solution: each parameter and
result position is `Owned` when its resource must be treated as owned, and the
result's aliasing comes from the alpha sets.
-}
readbackSig : Solve.Solved -> C.DefAnalysis -> BorrowSig
readbackSig solved da =
    { params = List.map2 (sigTyReadback solved) da.paramTys da.paramRtys
    , result = sigTyReadback solved da.resultTy da.resultRty
    , resultLts = resultLtsOf solved da.resultRty
    }


{-| Returns, for each result position whose resource has a non-empty alpha
set, that position and the parameter positions in the set.
-}
resultLtsOf : Solve.Solved -> Rty.RTy -> List ( Int, Set Int )
resultLtsOf solved resultRty =
    List.filterMap
        (\( pos, r ) ->
            let
                s =
                    Solve.alphaOf r solved
            in
            if Set.isEmpty s then
                Nothing

            else
                Just ( pos, s )
        )
        (List.indexedMap Tuple.pair (Rty.allRes resultRty))


{-| Reads the mode of each heap position of a value of type `ty` with
resources `rty`.
-}
sigTyReadback : Solve.Solved -> Mono.MonoType -> Rty.RTy -> Sig.SigTy
sigTyReadback solved ty rty =
    { shape = ty
    , modes =
        Array.fromList
            (List.map
                (\r ->
                    if Solve.reifiedOwned r solved then
                        Owned

                    else
                        Borrowed
                )
                (Rty.allRes rty)
            )
    }


{-| Counts the owned parameter positions over every signature in the table.
-}
countPoisonedParams : SigTable -> Int
countPoisonedParams table =
    Array.foldl
        (\maybeSig acc ->
            case maybeSig of
                Just sig ->
                    List.foldl (\st a -> Array.foldl ownedInc a st.modes) acc sig.params

                Nothing ->
                    acc
        )
        0
        table


{-| Adds one to the count for an `Owned` mode.
-}
ownedInc : Mode -> Int -> Int
ownedInc m a =
    case m of
        Owned ->
            a + 1

        Borrowed ->
            a



-- CENSUS PASS


{-| Adds a node's counts to the census when it is a define or a tail function,
and leaves the census unchanged otherwise.
-}
censusNode : SigTable -> LssFacts.Facts -> Mono.MonoNode -> BorrowStats -> BorrowStats
censusNode table facts node stats =
    case node of
        Mono.MonoDefine _ _ ->
            mergeDef table facts node stats

        Mono.MonoTailFunc _ _ _ ->
            mergeDef table facts node stats

        _ ->
            stats


{-| Analyses one definition against the finished tables, routing closure calls
through `facts`, and adds its counts to the census.

A resource counts as borrowed when it need not be treated as owned. `wouldDup`
counts uses whose first resource is owned, `wouldDrop` owned resources with a
recorded scope, and `wouldFree` those of them that are strings.

-}
mergeDef : SigTable -> LssFacts.Facts -> Mono.MonoNode -> BorrowStats -> BorrowStats
mergeDef table facts node stats =
    let
        env =
            mkEnv (sigLookup table) (Just facts)

        da =
            C.constrainDef env node C.emptyGen

        g =
            da.gen

        nRes =
            g.next

        solved =
            Solve.solve nRes False g.cs

        resList =
            List.range 0 (nRes - 1)

        borrowed =
            countWhere (\r -> Solve.accessMode r solved == Borrowed && not (Solve.storageOwnedOf r solved)) resList

        wouldDup =
            countWhere
                (\occ ->
                    case occ.res of
                        r :: _ ->
                            Solve.reifiedOwned r solved

                        [] ->
                            False
                )
                g.cs.occs

        ownedScoped =
            List.filter (\r -> Solve.reifiedOwned r solved) (Dict.keys g.cs.scopes)

        wouldDrop =
            List.length ownedScoped

        stringSet =
            List.foldl BitSet.insertGrowing BitSet.empty g.stringRes

        wouldFree =
            countWhere (\r -> BitSet.member r stringSet) ownedScoped

        maxExt =
            List.foldl
                (\r acc ->
                    if Solve.accessMode r solved == Borrowed then
                        max acc (lifeDepth (Solve.ltPOf r solved))

                    else
                        acc
                )
                0
                resList

        ltpRefined =
            countWhere (\r -> not (L.eq (Solve.ltPOf r solved) (Solve.ltAOf r solved))) resList

        -- Escaping for the upper bound: aliases a parameter, is in the result,
        -- or lives into the parameters.
        resultResSet =
            List.foldl BitSet.insertGrowing BitSet.empty (Rty.allRes da.resultRty)

        escapesR r =
            not (Set.isEmpty (Solve.alphaOf r solved))
                || BitSet.member r resultResSet
                || (case Solve.ltPOf r solved of
                        LParams _ ->
                            True

                        _ ->
                            False
                   )

        ownedResources =
            countWhere (\r -> Solve.reifiedOwned r solved) resList

        nonEscapingOwned =
            countWhere (\r -> Solve.reifiedOwned r solved && not (escapesR r)) resList

        -- The storage classes, also joined across container reads and escEdges;
        -- a class escapes for the lower bound when it holds an escSeeds or
        -- tail-call resource or one escaping for the upper bound.
        escDsu =
            List.foldl (\( a, b ) d -> Dsu.union a b d)
                (List.foldl
                    (\get d -> List.foldl (\( a, b ) dd -> Dsu.union a b dd) d get.out)
                    solved.dsu
                    g.cs.gets
                )
                g.cs.escEdges

        addRoots rs bits =
            List.foldl (\r b -> BitSet.insertGrowing (Dsu.findRoot r escDsu) b) bits rs

        escRoots =
            List.foldl
                (\r b ->
                    if escapesR r then
                        BitSet.insertGrowing (Dsu.findRoot r escDsu) b

                    else
                        b
                )
                (addRoots g.tailArgRes (addRoots g.escSeeds BitSet.empty))
                resList

        escapesLB r =
            BitSet.member (Dsu.findRoot r escDsu) escRoots

        nonEscapingOwnedLB =
            countWhere (\r -> Solve.reifiedOwned r solved && not (escapesLB r)) resList

        classHisto =
            List.foldl
                (\( top, cls, w ) acc ->
                    let
                        cand =
                            Solve.reifiedOwned top solved && not (escapesLB top)
                    in
                    Dict.update cls
                        (\m ->
                            let
                                ( t0, n0 ) =
                                    Maybe.withDefault ( 0, 0 ) m
                            in
                            Just
                                ( t0 + w
                                , if cand then
                                    n0 + w

                                  else
                                    n0
                                )
                        )
                        acc
                )
                Dict.empty
                g.freshSites
    in
    { stats
        | defsAnalyzed = stats.defsAnalyzed + 1
        , resources = stats.resources + nRes
        , borrowedResources = stats.borrowedResources + borrowed
        , wouldDup = stats.wouldDup + wouldDup
        , wouldDrop = stats.wouldDrop + wouldDrop
        , wouldFree = stats.wouldFree + wouldFree
        , poisonedByClosure = stats.poisonedByClosure + g.poisonedByClosure
        , closureRouted = stats.closureRouted + g.closureRouted
        , poisonedByErased = stats.poisonedByErased + g.poisonedByErased
        , poisonedByKernel = stats.poisonedByKernel + g.poisonedByKernel
        , poisoningCallSites = stats.poisoningCallSites + g.poisoningCallSites
        , sigMissReads = stats.sigMissReads + g.sigMissReads
        , kernelSigHits = stats.kernelSigHits + g.kernelSigHits
        , kernelDefaultedHeapCalls = stats.kernelDefaultedHeapCalls + g.kernelDefaultedHeapCalls
        , capturesForcedOwned = stats.capturesForcedOwned + g.capturesForcedOwned
        , nonVarOperandHeapOwnedFresh = stats.nonVarOperandHeapOwnedFresh + g.nonVarOwnedFresh
        , nonVarOperandHeapBorrowedProducer = stats.nonVarOperandHeapBorrowedProducer + g.nonVarBorrowedProducer
        , updateCopiedHeapFields = stats.updateCopiedHeapFields + g.updateCopiedHeapFields
        , maxBorrowExtension = max stats.maxBorrowExtension maxExt
        , ltpRefined = stats.ltpRefined + ltpRefined
        , ownedResources = stats.ownedResources + ownedResources
        , nonEscapingOwned = stats.nonEscapingOwned + nonEscapingOwned
        , nonEscapingOwnedLB = stats.nonEscapingOwnedLB + nonEscapingOwnedLB
        , escClassHisto =
            Dict.foldl
                (\k ( t, ne ) acc ->
                    Dict.update k
                        (\m ->
                            let
                                ( t0, n0 ) =
                                    Maybe.withDefault ( 0, 0 ) m
                            in
                            Just ( t0 + t, n0 + ne )
                        )
                        acc
                )
                stats.escClassHisto
                classHisto
        , kernelDefaultedNames =
            Dict.foldl
                (\k v acc -> Dict.update k (\m -> Just (v + Maybe.withDefault 0 m)) acc)
                stats.kernelDefaultedNames
                g.kernelDefaultedNames
        , immortalLiterals = stats.immortalLiterals + g.immortalLiterals
    }


{-| Solves the signature table of the whole graph, then analyses the node at
`specId` against it, with closure calls not routed. Returns its solution, the
resources of its tail-call arguments and its resource count, or `Nothing` when
there is no node at that id. It exists for tests.
-}
analyzeDefForTest : Mono.MonoGraph -> Mono.SpecId -> Maybe ( Solve.Solved, List ResVar, Int )
analyzeDefForTest graph specId =
    let
        (Mono.MonoGraph { nodes }) =
            graph

        table =
            firstOf (solveSigs nodes)
    in
    case Array.get specId nodes |> Maybe.andThen identity of
        Just node ->
            let
                env =
                    mkEnv (sigLookup table) Nothing

                da =
                    C.constrainDef env node C.emptyGen
            in
            Just ( Solve.solve da.gen.next False da.gen.cs, da.gen.tailArgRes, da.gen.next )

        Nothing ->
            Nothing



-- HELPERS


{-| Counts the elements of a list that satisfy `pred`.
-}
countWhere : (a -> Bool) -> List a -> Int
countWhere pred =
    List.foldl
        (\x acc ->
            if pred x then
                acc + 1

            else
                acc
        )
        0


{-| Returns how deeply a lifetime's end is nested in the skeleton: 0 for
`LEmpty`, `LParams` and an end at the root.
-}
lifeDepth : Lifetime -> Int
lifeDepth lt =
    case lt of
        LEmpty ->
            0

        LParams _ ->
            0

        LLocal l ->
            localDepth l


{-| Returns the nesting depth of a local lifetime's end, taking the deepest
arm of an alternatives node.
-}
localDepth : Life -> Int
localDepth l =
    case l of
        Star ->
            0

        InSeq _ _ inner ->
            1 + localDepth inner

        InAlts _ d ->
            1 + Dict.foldl (\_ v acc -> max acc (localDepth v)) 0 d



-- RENDER


{-| Renders a census as a line of `key=value` pairs, followed by the
escape-class histogram and the kernel audit list, one entry per line.
-}
renderStats : BorrowStats -> String
renderStats s =
    let
        pct =
            if s.resources == 0 then
                0

            else
                (s.borrowedResources * 100) // s.resources
    in
    "borrow: defs="
        ++ String.fromInt s.defsAnalyzed
        ++ " resources="
        ++ String.fromInt s.resources
        ++ " borrowed="
        ++ String.fromInt s.borrowedResources
        ++ " ("
        ++ String.fromInt pct
        ++ "%) wouldDup="
        ++ String.fromInt s.wouldDup
        ++ " wouldDrop="
        ++ String.fromInt s.wouldDrop
        ++ " wouldFree="
        ++ String.fromInt s.wouldFree
        ++ " poisonedByClosure="
        ++ String.fromInt s.poisonedByClosure
        ++ " closureRouted="
        ++ String.fromInt s.closureRouted
        ++ " lambdaSigMeets="
        ++ String.fromInt s.lambdaSigMeets
        ++ " poisonedByErased="
        ++ String.fromInt s.poisonedByErased
        ++ " poisonedByKernel="
        ++ String.fromInt s.poisonedByKernel
        ++ " poisonedParams="
        ++ String.fromInt s.poisonedParams
        ++ " poisoningCallSites="
        ++ String.fromInt s.poisoningCallSites
        ++ " sigMissReads="
        ++ String.fromInt s.sigMissReads
        ++ " kernelSigHits="
        ++ String.fromInt s.kernelSigHits
        ++ " kernelDefaultedHeapCalls="
        ++ String.fromInt s.kernelDefaultedHeapCalls
        ++ " sccBailouts="
        ++ String.fromInt s.sccFixpointBailouts
        ++ " maxSccIter="
        ++ String.fromInt s.maxSccIter
        ++ " capturesForcedOwned="
        ++ String.fromInt s.capturesForcedOwned
        ++ " nonVarOwnedFresh="
        ++ String.fromInt s.nonVarOperandHeapOwnedFresh
        ++ " nonVarBorrowedProducer="
        ++ String.fromInt s.nonVarOperandHeapBorrowedProducer
        ++ " updateCopiedHeapFields="
        ++ String.fromInt s.updateCopiedHeapFields
        ++ " immortal="
        ++ String.fromInt s.immortalLiterals
        ++ " maxExt="
        ++ String.fromInt s.maxBorrowExtension
        ++ " ltpRefined="
        ++ String.fromInt s.ltpRefined
        ++ " ownedResources="
        ++ String.fromInt s.ownedResources
        ++ " nonEscapingOwned="
        ++ String.fromInt s.nonEscapingOwned
        ++ " nonEscapingOwnedLB="
        ++ String.fromInt s.nonEscapingOwnedLB
        ++ "\nborrow-esc-class (allocation sites nonEscLB/total by class; lit:=in-def construct, call:=call result):\n"
        ++ renderEscClasses s.escClassHisto
        ++ "\nborrow-kernel-audit (top un-audited kernels by heap-defaulting call count):\n"
        ++ renderKernelAudit s.kernelDefaultedNames


{-| Renders the escape-class histogram as one `class=ownedNonEscaping/total`
line per class, largest total first, the numerator counting owned sites that do
not escape by the lower bound.
-}
renderEscClasses : Dict String ( Int, Int ) -> String
renderEscClasses d =
    Dict.toList d
        |> List.sortBy (\( _, ( t, _ ) ) -> negate t)
        |> List.map
            (\( cls, ( t, ne ) ) ->
                "  " ++ cls ++ "=" ++ String.fromInt ne ++ "/" ++ String.fromInt t
            )
        |> String.join "\n"


{-| Renders the 40 kernels with the most calls that had heap arguments and no
kernel-table entry, one `home.name=count` line each, most calls first.
-}
renderKernelAudit : Dict ( Name, Name ) Int -> String
renderKernelAudit d =
    Dict.toList d
        |> List.sortBy (\( _, n ) -> negate n)
        |> List.take 40
        |> List.map (\( ( home, name ), n ) -> "  " ++ home ++ "." ++ name ++ "=" ++ String.fromInt n)
        |> String.join "\n"
