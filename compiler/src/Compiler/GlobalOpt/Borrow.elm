module Compiler.GlobalOpt.Borrow exposing
    ( BorrowStats, emptyStats, run, renderStats
    , deriveFacts
    , analyzeDefForTest
    )

{-| Borrow-inference driver (GlobalOpt Phase 6).

  - **B2**: per-def constraint generation + Stage A–D solving + census.
  - **B3**: interprocedural `BorrowSig`s via a reverse-topological SCC
    fixpoint (`Borrow/Sig.elm`) plus the audited kernel table
    (`Borrow/KernelSigs.elm`), so direct and kernel calls stop being
    all-owned poison.

`reify = ROff` (the only mode) ⇒ the graph is returned UNCHANGED (census /
uniqueness oracle only; byte-identical emitted MLIR). The census is computed
in a single pass AFTER the fixpoint converges, so intermediate iterations
never contribute to the counters.

`deriveFacts` (OC0.2, plans/borrow-oracle-consumers.md) is the codegen-facing
readback: sig fixpoint + lambda sigs distilled to SpecId/member-keyed
borrowed-param sets, invoked at MLIR-emission time under `borrow.oracleOpt`.

`readbackSig` lives here (not in `Sig`) so `Sig` stays free of a `Solve`
import (`Constrain` imports `Sig`; `Solve` imports `Constrain`).

-}

import Array exposing (Array)
import Compiler.AST.Monomorphized as Mono
import Compiler.Data.Name exposing (Name)
import Compiler.Data.BitSet as BitSet
import Compiler.Eco.Config as Config
import Compiler.GlobalOpt.Borrow.Constrain as C
import Compiler.GlobalOpt.Borrow.Dsu as Dsu
import Compiler.GlobalOpt.Borrow.Facts as Facts
import Compiler.GlobalOpt.Borrow.Lifetime as L exposing (Life(..), Lifetime(..))
import Compiler.GlobalOpt.Borrow.LssFacts as LssFacts
import Compiler.GlobalOpt.Borrow.Mode as Mode exposing (Mode(..))
import Compiler.GlobalOpt.Borrow.Rty as Rty exposing (ResVar)
import Compiler.GlobalOpt.Borrow.Sig as Sig exposing (BorrowSig)
import Compiler.GlobalOpt.Borrow.Solve as Solve
import Compiler.Graph as Graph
import Compiler.Monomorphize.MonoTraverse as MonoTraverse
import Dict exposing (Dict)
import Set exposing (Set)



-- CENSUS (design §13 counter set; ≤32 fields)


type alias BorrowStats =
    { defsAnalyzed : Int
    , resources : Int
    , borrowedResources : Int
    , wouldDup : Int
    , wouldDrop : Int
    , wouldFree : Int
    , poisonedByClosure : Int
    , closureRouted : Int -- B3.5: closure calls routed via LSS (recovered)
    , poisonedByErased : Int
    , poisonedByKernel : Int
    , poisonedParams : Int -- B3: owned param positions across all sigs
    , poisoningCallSites : Int -- B3: direct-call sites forcing ≥1 heap arg owned
    , sigMissReads : Int -- B3: expected 0 steady-state
    , kernelSigHits : Int -- B3: allowlisted kernel calls
    , kernelDefaultedHeapCalls : Int -- B3: kernel misses with heap args
    , sccFixpointBailouts : Int -- B3: expected 0
    , maxSccIter : Int -- B3: max fixpoint iterations observed (design predicts 2-3)
    , capturesForcedOwned : Int
    , nonVarOperandHeapOwnedFresh : Int
    , nonVarOperandHeapBorrowedProducer : Int
    , updateCopiedHeapFields : Int
    , maxBorrowExtension : Int
    , ltpRefined : Int -- Stage D: resources whose precise ltP differs from ltA
    , ownedResources : Int -- reifiedOwned resources (escape-analysis universe)
    , nonEscapingOwned : Int -- owned + not coupled to a param, not returned, ltP-local (stack-alloc candidate proxy; upper bound — misses transitive store-escape)
    , nonEscapingOwnedLB : Int -- U-T1.1: owned + provably non-escaping under the storage-transitive escape closure (the tight LOWER bound)
    , escClassHisto : Dict String ( Int, Int ) -- U-T1.1: per allocation-site class → (total sites, nonEscLB sites), weighted (list literals weigh their cell count)
    , kernelDefaultedNames : Dict ( Name, Name ) Int -- audit histogram: per-kernel heap-defaulting call count
    , immortalLiterals : Int
    }


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


maxIterConst : Int
maxIterConst =
    20



-- DRIVER


run : Config.BorrowConfig -> Mono.MonoGraph -> ( Mono.MonoGraph, BorrowStats )
run cfg graph =
    if not (cfg.report || cfg.validate || cfg.reify /= Config.ROff) then
        -- The census/oracle is the ONLY product of the analysis (reify=ROff leaves
        -- the graph untouched), and it is consumed only when `report`/`validate` is
        -- on. When neither is, running `solveSigs` + the whole-graph `censusNode`
        -- fold (which re-invokes constrainDef+Solve.solve on every def) is pure dead
        -- work — skip it entirely. (perf item 1)
        ( graph, emptyStats )

    else
        runCensus graph


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

        -- B3.5: build LSS handshake facts (instance index + per-member lambda
        -- sigs), computed once after the def-fixpoint converges.
        ( byMember, blocked ) =
            LssFacts.buildInstances nodes

        facts =
            { byMember = byMember
            , blocked = blocked
            , lambdaSigsByMember = buildLambdaSigs table byMember
            , origins = lssMemberOrigins
            , globalIndex = buildGlobalIndex registry
            , sigs = sigLookup table
            }

        stats0 =
            { emptyStats | sccFixpointBailouts = bailouts, maxSccIter = maxIter }

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


{-| Per-member lambda signatures (B3.5): analyze one representative instance
of each (non-blocked) member — LSS_009 makes verbatim instances
interchangeable — with the converged def SigTable and NO lambda routing
(lambda→lambda calls conservatively poison; sound v1).
-}
buildLambdaSigs : SigTable -> Dict Int (List LssFacts.LambdaRef) -> Dict Int BorrowSig
buildLambdaSigs table byMember =
    Dict.foldl
        (\m refs acc ->
            case refs of
                ref :: _ ->
                    let
                        da =
                            C.constrainClosureForSig (mkEnv (sigLookup table) Nothing) ref.closureInfo ref.body C.emptyGen

                        solved =
                            Solve.solve da.gen.next False da.gen.cs
                    in
                    Dict.insert m (readbackSig solved da) acc

                [] ->
                    acc
        )
        Dict.empty
        byMember


type alias SigTable =
    Array (Maybe BorrowSig)


firstOf : ( SigTable, Int, Int ) -> SigTable
firstOf ( t, _, _ ) =
    t


{-| Run the SCC fixpoint, returning the converged table + bailout/iteration
counts.
-}
solveSigs : Array (Maybe Mono.MonoNode) -> ( SigTable, Int, Int )
solveSigs nodes =
    let
        edges =
            collectEdges nodes

        ( indexToSpecId, sccs ) =
            buildSCC nodes edges

        emptyTable =
            Array.repeat (Array.length nodes) Nothing
    in
    List.foldl (solveScc nodes indexToSpecId) ( emptyTable, 0, 0 ) sccs


sigLookup : SigTable -> Mono.SpecId -> Maybe BorrowSig
sigLookup table specId =
    Array.get specId table |> Maybe.andThen identity


{-| OC0.2 (plans/borrow-oracle-consumers.md): derive the distilled oracle
facts for codegen consumers. Runs the sig fixpoint + per-member lambda sigs
ONLY — no census fold, no escape closure — so its wall toll is the sigs-only
slice (measured in OC0.4), not the full report-mode analysis.

Called at MLIR-emission time on the FINAL graph (post CafDedupe/CafHoist —
those passes mutate the graph after GlobalOpt Phase 6, so facts derived
inside the phase would be stale by emission). Keyed by SpecId / LSS member
id only, so the facts carry no per-def state.
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
            Dict.map (\_ sig -> distillSig sig) (buildLambdaSigs table byMember)
    in
    { bySpec = bySpec
    , byLambda = byLambda
    }


{-| A param index is "wholly borrowed" when its `SigTy` carries at least one
heap position, EVERY position's mode is `Borrowed`, and the index appears in
no `resultLts` coupling — the callee neither retains nor returns-any-alias-of
the argument. Scalar params (empty `modes`) are excluded: membership in
`borrowedParams` must mean "heap-carrying and proven borrowed", never
"vacuously true".
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


{-| Index `registry.reverseMapping` (SpecId → (Global, MonoType)) into
`Global-key → [(MonoType, SpecId)]` for B3.5 OriginGlobal resolution. A Global
is one-to-many over SpecIds; the query layout-matches by type.
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


{-| Build an analysis Env with the given sig lookup (record-update on the
qualified `C.emptyEnv` must go through a local binding).
-}
mkEnv : (Mono.SpecId -> Maybe BorrowSig) -> Maybe LssFacts.Facts -> C.Env
mkEnv lookup facts =
    let
        base =
            C.emptyEnv
    in
    { base | sigs = lookup, lssFacts = facts }



-- EDGE RE-COLLECTION (callEdges is empty at Phase 6 — verified fact 1)


collectEdges : Array (Maybe Mono.MonoNode) -> Array (Maybe (List Mono.SpecId))
collectEdges nodes =
    -- Array.map preserves index = SpecId, exactly the shape buildSCC consumes.
    -- B3.5 will also collect routed edges here.
    Array.map (Maybe.map collectFromNode) nodes


collectFromNode : Mono.MonoNode -> List Mono.SpecId
collectFromNode node =
    case node of
        Mono.MonoDefine body _ ->
            collectFromExpr body

        Mono.MonoTailFunc _ body _ ->
            collectFromExpr body

        Mono.MonoPortIncoming body _ ->
            collectFromExpr body

        Mono.MonoPortOutgoing body _ ->
            collectFromExpr body

        _ ->
            []


collectFromExpr : Mono.MonoExpr -> List Mono.SpecId
collectFromExpr body =
    MonoTraverse.foldExpr
        (\e acc ->
            case e of
                Mono.MonoVarGlobal _ specId _ ->
                    specId :: acc

                _ ->
                    acc
        )
        []
        body



-- SCC COMPUTATION (copied from MonoInlineSimplify.buildCallGraph, modified to
-- return (indexToSpecId, sccs) — reverse-topological, callees first)


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


solveScc : Array (Maybe Mono.MonoNode) -> Array Mono.SpecId -> Graph.SCC Int -> ( SigTable, Int, Int ) -> ( SigTable, Int, Int )
solveScc nodes indexToSpecId scc ( table, bailouts, maxIter ) =
    case scc of
        Graph.AcyclicSCC idx ->
            case Array.get idx indexToSpecId of
                Just specId ->
                    ( setSig nodes table specId (analyzeAndReadback nodes table specId), bailouts, maxIter )

                Nothing ->
                    ( table, bailouts, maxIter )

        Graph.CyclicSCC idxs ->
            let
                specIds =
                    List.filterMap (\i -> Array.get i indexToSpecId) idxs

                table0 =
                    List.foldl (\sid t -> setSig nodes t sid (Just (initSig nodes sid))) table specIds

                ( tableN, iters, converged ) =
                    iterateScc nodes specIds table0 0
            in
            if converged then
                ( tableN, bailouts, max maxIter iters )

            else
                -- bailout: total poison fallback (design §5.3 discipline)
                ( List.foldl (\sid t -> setSig nodes t sid (Just (allOwnedSigFor nodes sid))) tableN specIds
                , bailouts + 1
                , max maxIter iters
                )


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
                                            ( setSig nodes t sid (Just newSig), True )

                                    Nothing ->
                                        ( setSig nodes t sid (Just newSig), True )

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


setSig : Array (Maybe Mono.MonoNode) -> SigTable -> Mono.SpecId -> Maybe BorrowSig -> SigTable
setSig _ table specId maybeSig =
    Array.set specId maybeSig table


{-| Analyze a def against the current table and read back its signature; for
non-def nodes return the appropriate baseline sig.
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
                    -- ctor/enum → construct (result owned); extern/manager/port → RPort poison.
                    Just (allOwnedSigFor nodes specId)

        Nothing ->
            Nothing


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



-- SIGNATURE READBACK (needs Solved ⇒ lives here, not in Sig)


readbackSig : Solve.Solved -> C.DefAnalysis -> BorrowSig
readbackSig solved da =
    { params = List.map2 (sigTyReadback solved) da.paramTys da.paramRtys
    , result = sigTyReadback solved da.resultTy da.resultRty
    , resultLts = resultLtsOf solved da.resultRty
    }


{-| Argument-return coupling (paper §5.1): each result resource position that
carries a non-empty α-set couples to those param positions.
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


countPoisonedParams : SigTable -> Int
countPoisonedParams table =
    Array.foldl
        (\maybeSig acc ->
            case maybeSig of
                Just sig ->
                    -- item 27: fold param sig-tys directly (no intermediate List.map list)
                    List.foldl (\st a -> Array.foldl ownedInc a st.modes) acc sig.params

                Nothing ->
                    acc
        )
        0
        table


ownedInc : Mode -> Int -> Int
ownedInc m a =
    case m of
        Owned ->
            a + 1

        Borrowed ->
            a



-- CENSUS PASS (one analysis per def with the converged sig table)


censusNode : SigTable -> LssFacts.Facts -> Mono.MonoNode -> BorrowStats -> BorrowStats
censusNode table facts node stats =
    case node of
        Mono.MonoDefine _ _ ->
            mergeDef table facts node stats

        Mono.MonoTailFunc _ _ _ ->
            mergeDef table facts node stats

        _ ->
            stats


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

        -- precise borrow-lifetime depth (Stage D ltP, not the ltA approximation).
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

        -- how many resources Stage D refined vs the ltA approximation.
        ltpRefined =
            countWhere (\r -> not (L.eq (Solve.ltPOf r solved) (Solve.ltAOf r solved))) resList

        -- ESCAPE ANALYSIS (stack-allocation proxy): an owned resource is
        -- stack-allocatable iff it does not escape the activation. We treat r
        -- as escaping if it couples to a param (α non-empty), is part of the
        -- returned value (a result resvar), or its lifetime reaches a param
        -- position (LParams). This is an UPPER bound — it does not chase
        -- transitive store-into-escaping-container escape.
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

        -- U-T1.1: STORAGE-TRANSITIVE ESCAPE CLOSURE (the tight lower bound).
        -- Stage A already unions flows+storageEq into the DSU, so value webs
        -- are one class; extend a copy of it with the projection (`gets`) and
        -- escape-only (`escEdges`) alias pairs, then mark every class that
        -- contains an escape seed: the §15.1 predicate resvars, consumption
        -- seeds from the walk (poisoned/owned call args, captures,
        -- global-resident values, immortals), and tail-call args (BORROW_005).
        -- A resource is non-escaping-LB iff its component holds no seed.
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



-- BORROW_005 test hook: analyze one def (with converged sigs) → its Solved.


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


lifeDepth : Lifetime -> Int
lifeDepth lt =
    case lt of
        LEmpty ->
            0

        LParams _ ->
            0

        LLocal l ->
            localDepth l


localDepth : Life -> Int
localDepth l =
    case l of
        Star ->
            0

        InSeq _ _ inner ->
            1 + localDepth inner

        InAlts _ d ->
            1 + Dict.foldl (\_ v acc -> max acc (localDepth v)) 0 d



-- RENDER (stderr census line; grep -a-safe key=value)


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


renderEscClasses : Dict String ( Int, Int ) -> String
renderEscClasses d =
    Dict.toList d
        |> List.sortBy (\( _, ( t, _ ) ) -> negate t)
        |> List.map
            (\( cls, ( t, ne ) ) ->
                "  " ++ cls ++ "=" ++ String.fromInt ne ++ "/" ++ String.fromInt t
            )
        |> String.join "\n"


{-| Rank un-audited kernels by how many heap-bearing call sites they poison —
the audit worklist (biggest blast-radius reduction first).
-}
renderKernelAudit : Dict ( Name, Name ) Int -> String
renderKernelAudit d =
    Dict.toList d
        |> List.sortBy (\( _, n ) -> negate n)
        |> List.take 40
        |> List.map (\( ( home, name ), n ) -> "  " ++ home ++ "." ++ name ++ "=" ++ String.fromInt n)
        |> String.join "\n"
