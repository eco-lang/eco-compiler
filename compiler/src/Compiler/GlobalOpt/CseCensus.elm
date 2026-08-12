module Compiler.GlobalOpt.CseCensus exposing (report)

{-| C1 census for Mono-level CSE (kernel-opt-13 Phase 0, executing
`plans/cse-pure-calls.md` §4). **Measures only — no behaviour change.** Runs
behind `ECO_CSE_REPORT=1`, writes to stderr, and is excluded from `Config.hash`.

Its job is to answer, before a line of transform is written, whether a
bounded-scope CSE pass has anything to merge. The load-bearing definition is the
DISTANCE BUCKET: two structurally equal occurrences are only mergeable without
speculation if at least one of them dominates the other's continuation. Each
occurrence carries its root→node path; the pair's bucket is read off the two
path suffixes below their lowest common ancestor.

Equality machinery is reused verbatim from `CafHoist`/`CafDedupe`
(`fingerprintOf` to bucket, `zeroRegions` + `==` inside the bucket) — this
module invents none of its own.

The `cse-dce:` lines are kernel-opt-11's free ride-along, per that plan's
Phase 0.

-}

import Array
import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..))
import Compiler.Data.Name as Name exposing (Name)
import Compiler.GlobalOpt.CafHoist as CafHoist
import Compiler.GlobalOpt.CsePurity as CsePurity
import Compiler.GlobalOpt.KernelFacts as KernelFacts
import Dict exposing (Dict)
import System.TypeCheck.IO as IO


{-| One step of a root→node path.

`SGuard 0` is the ONLY guard position treated as unconditional: it is the first
condition of a `MonoIf` chain, so it is evaluated on every path reaching the
chain. `SGuard i>0` is reached only if guards `<i` all failed.

`SClosure` marks entering a closure body — a DIFFERENT evaluation frequency,
which is why `b3_frame` is excluded permanently rather than deferred.

-}
type Step
    = SStrict Int
    | SSeq Int
    | SGuard Int
    | SBranch Int
    | SClosure


{-| Unconditional steps: the suffix shapes that dominate the LCA's continuation.
-}
isUnconditional : Step -> Bool
isUnconditional step =
    case step of
        SStrict _ ->
            True

        SSeq _ ->
            True

        SGuard i ->
            i == 0

        SBranch _ ->
            False

        SClosure ->
            False


type Head
    = HGlobal Int
    | HKernel Name Name
    | HOther


type alias Occ =
    { key : String
    , shape : MonoExpr
    , head : Head
    , path : List Step
    , cost : Int
    }


type alias Counts =
    { specs : Int
    , callOccs : Int
    , candidateOccs : Int
    , groups : Int
    , redundantOccs : Int
    , b0Block : Int
    , b1Seq : Int
    , b1cProbe : Int
    , b2Branch : Int
    , b3Frame : Int
    , b4Crossdef : Int
    , nearRedundant : Int
    , nearCost : Int
    , loopNear : Int
    , shadowBlocked : Int
    , callInfoBlocked : Int
    , fnResultExcluded : Int
    , binderExcluded : Int
    , belowMinCost : Int
    , debugExcluded : Int
    , c1_4 : Int
    , c5_9 : Int
    , c10_49 : Int
    , c50plus : Int
    , deadLets : Int
    , deadPureLets : Int
    , deadDroppableKernelLets : Int
    , perHead : Dict String Int
    , perSpec : Dict String Int
    , deadHeads : Dict String Int
    }


empty : Counts
empty =
    { specs = 0
    , callOccs = 0
    , candidateOccs = 0
    , groups = 0
    , redundantOccs = 0
    , b0Block = 0
    , b1Seq = 0
    , b1cProbe = 0
    , b2Branch = 0
    , b3Frame = 0
    , b4Crossdef = 0
    , nearRedundant = 0
    , nearCost = 0
    , loopNear = 0
    , shadowBlocked = 0
    , callInfoBlocked = 0
    , fnResultExcluded = 0
    , binderExcluded = 0
    , belowMinCost = 0
    , debugExcluded = 0
    , c1_4 = 0
    , c5_9 = 0
    , c10_49 = 0
    , c50plus = 0
    , deadLets = 0
    , deadPureLets = 0
    , deadDroppableKernelLets = 0
    , perHead = Dict.empty
    , perSpec = Dict.empty
    , deadHeads = Dict.empty
    }


{-| Render the census for one graph. `minCost` matches the pass's own cut so the
histogram and the exclusion agree.
-}
report : String -> Int -> Mono.MonoGraph -> String
report label minCost ((Mono.MonoGraph g) as graph) =
    let
        oracle =
            CsePurity.analyze graph

        specName sid =
            case Array.get sid g.registry.reverseMapping |> Maybe.andThen identity of
                Just ( Mono.Global (IO.Canonical _ moduleName) n, _ ) ->
                    moduleName ++ "." ++ Name.toElmString n

                Just ( Mono.Accessor f, _ ) ->
                    "accessor." ++ Name.toElmString f

                Nothing ->
                    "spec" ++ String.fromInt sid

        headName head =
            case head of
                HGlobal sid ->
                    specName sid

                HKernel home name ->
                    Name.toElmString home ++ "." ++ Name.toElmString name

                HOther ->
                    "?"

        counts =
            Array.foldl
                (\maybeNode ( sid, acc ) ->
                    case maybeNode of
                        Nothing ->
                            ( sid + 1, acc )

                        Just node ->
                            case bodyOf node of
                                Nothing ->
                                    ( sid + 1, acc )

                                Just ( body, inLoop ) ->
                                    ( sid + 1
                                    , scanSpec oracle
                                        minCost
                                        specName
                                        headName
                                        sid
                                        body
                                        inLoop
                                        { acc | specs = acc.specs + 1 }
                                    )
                )
                ( 0, empty )
                g.nodes
                |> Tuple.second

        bp num den =
            if den == 0 then
                0

            else
                10000 * num // den

        top n dict =
            Dict.toList dict
                |> List.sortBy (\( _, c ) -> -c)
                |> List.take n

        nearTop20 =
            top 20 counts.perHead |> List.foldl (\( _, c ) n -> n + c) 0
    in
    String.join "\n"
        [ "cse-census"
            ++ label
            ++ ": specs="
            ++ n_ counts.specs
            ++ " safeSpecs="
            ++ n_ (CsePurity.safeSpecCount oracle)
            ++ " callOccs="
            ++ n_ counts.callOccs
            ++ " candidateOccs="
            ++ n_ counts.candidateOccs
            ++ " groups="
            ++ n_ counts.groups
            ++ " redundantOccs="
            ++ n_ counts.redundantOccs
        , "cse-census"
            ++ label
            ++ " dist: b0_block="
            ++ n_ counts.b0Block
            ++ " b1_seq="
            ++ n_ counts.b1Seq
            ++ " b1c_probe="
            ++ n_ counts.b1cProbe
            ++ " b2_branch="
            ++ n_ counts.b2Branch
            ++ " b3_frame="
            ++ n_ counts.b3Frame
            ++ " b4_crossdef="
            ++ n_ counts.b4Crossdef
        , "cse-census"
            ++ label
            ++ " near: nearRedundant="
            ++ n_ counts.nearRedundant
            ++ " nearShareBp="
            ++ n_ (bp counts.nearRedundant counts.callOccs)
            ++ " nearCost="
            ++ n_ counts.nearCost
            ++ " loopNear="
            ++ n_ counts.loopNear
            ++ " nearTop20Bp="
            ++ n_ (bp nearTop20 counts.nearRedundant)
        , "cse-census"
            ++ label
            ++ " blocked: shadowBlocked="
            ++ n_ counts.shadowBlocked
            ++ " callInfoBlocked="
            ++ n_ counts.callInfoBlocked
            ++ " fnResultExcluded="
            ++ n_ counts.fnResultExcluded
            ++ " binderExcluded="
            ++ n_ counts.binderExcluded
            ++ " belowMinCost="
            ++ n_ counts.belowMinCost
            ++ " debugExcluded="
            ++ n_ counts.debugExcluded
        , "cse-census"
            ++ label
            ++ " cost: c1_4="
            ++ n_ counts.c1_4
            ++ " c5_9="
            ++ n_ counts.c5_9
            ++ " c10_49="
            ++ n_ counts.c10_49
            ++ " c50plus="
            ++ n_ counts.c50plus
        , "cse-census"
            ++ label
            ++ " top heads: "
            ++ String.join " " (List.map (\( n, c ) -> n ++ "=" ++ n_ c) (top 20 counts.perHead))
        , "cse-census"
            ++ label
            ++ " top specs: "
            ++ String.join " " (List.map (\( n, c ) -> n ++ "=" ++ n_ c) (top 10 counts.perSpec))
        , "cse-dce"
            ++ label
            ++ ": deadLets="
            ++ n_ counts.deadLets
            ++ " deadPureLets="
            ++ n_ counts.deadPureLets
            ++ " deadDroppableKernelLets="
            ++ n_ counts.deadDroppableKernelLets
        , "cse-dce"
            ++ label
            ++ " top: "
            ++ String.join " " (List.map (\( n, c ) -> n ++ "=" ++ n_ c) (top 10 counts.deadHeads))
        ]


n_ : Int -> String
n_ =
    String.fromInt


bodyOf : Mono.MonoNode -> Maybe ( MonoExpr, Bool )
bodyOf node =
    case node of
        Mono.MonoDefine body _ ->
            Just ( body, False )

        Mono.MonoTailFunc _ body _ ->
            -- loopNear's dynamic-heat proxy: redundancy inside a tail-recursive
            -- body is executed many times, so it is worth more than its static
            -- count suggests.
            Just ( body, True )

        Mono.MonoPortIncoming body _ ->
            Just ( body, False )

        Mono.MonoPortOutgoing body _ ->
            Just ( body, False )

        _ ->
            Nothing


{-| Walk one spec body: collect candidate occurrences with their paths, group
them, classify each group's pairs into distance buckets, and fold the
kernel-opt-11 dead-let counters in the same pass.
-}
scanSpec :
    CsePurity.Oracle
    -> Int
    -> (Int -> String)
    -> (Head -> String)
    -> Int
    -> MonoExpr
    -> Bool
    -> Counts
    -> Counts
scanSpec oracle minCost specName headName sid body inLoop acc0 =
    let
        ( occs, acc1 ) =
            collect oracle minCost body [] ( [], acc0 )

        buckets =
            List.foldl
                (\occ d -> Dict.update occ.key (\m -> Just (occ :: Maybe.withDefault [] m)) d)
                Dict.empty
                occs

        acc2 =
            Dict.foldl
                (\_ members a -> classifyBucket headName specName sid inLoop members a)
                acc1
                buckets
    in
    acc2


{-| Exact equality inside a fingerprint bucket, then distance classification of
each group. `CafDedupe.classify`'s partition idiom, on `Occ` instead of specs.
-}
classifyBucket :
    (Head -> String)
    -> (Int -> String)
    -> Int
    -> Bool
    -> List Occ
    -> Counts
    -> Counts
classifyBucket headName specName sid inLoop members acc =
    case members of
        [] ->
            acc

        first :: rest ->
            let
                ( same, different ) =
                    List.partition (\o -> o.shape == first.shape) rest

                acc1 =
                    if List.isEmpty same then
                        acc

                    else
                        let
                            group =
                                first :: same

                            n =
                                List.length group

                            bucket =
                                groupBucket group

                            isNear =
                                bucket == B0Block || bucket == B1Seq || bucket == B1cProbe

                            redundant =
                                n - 1

                            hn =
                                headName first.head
                        in
                        { acc
                            | groups = acc.groups + 1
                            , redundantOccs = acc.redundantOccs + redundant
                            , b0Block = bump (bucket == B0Block) redundant acc.b0Block
                            , b1Seq = bump (bucket == B1Seq) redundant acc.b1Seq
                            , b1cProbe = bump (bucket == B1cProbe) redundant acc.b1cProbe
                            , b2Branch = bump (bucket == B2Branch) redundant acc.b2Branch
                            , b3Frame = bump (bucket == B3Frame) redundant acc.b3Frame
                            , b4Crossdef = bump (bucket == B4Crossdef) redundant acc.b4Crossdef
                            , nearRedundant = bump isNear redundant acc.nearRedundant
                            , nearCost = bump isNear (redundant * first.cost) acc.nearCost
                            , loopNear = bump (isNear && inLoop) redundant acc.loopNear
                            , perHead =
                                if isNear then
                                    Dict.update hn (\m -> Just (redundant + Maybe.withDefault 0 m)) acc.perHead

                                else
                                    acc.perHead
                            , perSpec =
                                if isNear then
                                    Dict.update (specName sid)
                                        (\m -> Just (redundant + Maybe.withDefault 0 m))
                                        acc.perSpec

                                else
                                    acc.perSpec
                        }
            in
            classifyBucket headName specName sid inLoop different acc1


bump : Bool -> Int -> Int -> Int
bump cond amount current =
    if cond then
        current + amount

    else
        current


type Bucket
    = B4Crossdef
    | B3Frame
    | B0Block
    | B1Seq
    | B1cProbe
    | B2Branch


{-| A group's bucket is the WORST of its pairwise buckets: a group is only
mergeable at bounded distance if every member is. Ordered decision list, first
match wins, catch-all last, so every group lands in exactly one bucket.
-}
groupBucket : List Occ -> Bucket
groupBucket group =
    let
        suffixes =
            List.map (\o -> dropCommonPrefix (List.map .path group) o.path) group

        anyClosure =
            List.any (List.any (\s -> s == SClosure)) suffixes

        allStrict =
            List.all (List.all (\s -> isStrictStep s)) suffixes

        allSeqish =
            List.all (List.all (\s -> isStrictStep s || isSeqStep s)) suffixes

        anyDominates =
            List.any (List.all isUnconditional) suffixes
    in
    if anyClosure then
        B3Frame

    else if allStrict then
        B0Block

    else if allSeqish then
        B1Seq

    else if anyDominates then
        B1cProbe

    else
        B2Branch


isStrictStep : Step -> Bool
isStrictStep s =
    case s of
        SStrict _ ->
            True

        _ ->
            False


isSeqStep : Step -> Bool
isSeqStep s =
    case s of
        SSeq _ ->
            True

        _ ->
            False


{-| The suffix of `path` below the lowest common ancestor of every path in
`paths`. All paths are root-anchored, so the LCA is their longest common prefix.
-}
dropCommonPrefix : List (List Step) -> List Step -> List Step
dropCommonPrefix paths path =
    let
        commonLen =
            case paths of
                [] ->
                    0

                p0 :: rest ->
                    List.foldl (\p n -> min n (sharedLen p0 p)) (List.length p0) rest
    in
    List.drop commonLen path


sharedLen : List Step -> List Step -> Int
sharedLen a b =
    case ( a, b ) of
        ( x :: xs, y :: ys ) ->
            if x == y then
                1 + sharedLen xs ys

            else
                0

        _ ->
            0


{-| Collect candidate occurrences, counting every exclusion so the gate can see
what was thrown away, and folding in kernel-opt-11's dead-let counters.
-}
collect :
    CsePurity.Oracle
    -> Int
    -> MonoExpr
    -> List Step
    -> ( List Occ, Counts )
    -> ( List Occ, Counts )
collect oracle minCost expr path ( occs, acc ) =
    let
        acc1 =
            case expr of
                MonoCall _ _ _ _ _ ->
                    { acc | callOccs = acc.callOccs + 1 }

                _ ->
                    acc

        -- kernel-opt-11 ride-along, on the same walk.
        acc2 =
            case expr of
                MonoLet (Mono.MonoDef n bound) body _ ->
                    if CsePurity.countLocalUses n body == 0 then
                        { acc1
                            | deadLets = acc1.deadLets + 1
                            , deadPureLets =
                                bump (CsePurity.isSafeCall oracle bound) 1 acc1.deadPureLets
                            , deadDroppableKernelLets =
                                case bound of
                                    MonoCall _ (MonoVarKernel _ _ home name _) _ _ _ ->
                                        bump (KernelFacts.droppableFor ( home, name )) 1 acc1.deadDroppableKernelLets

                                    _ ->
                                        acc1.deadDroppableKernelLets
                            , deadHeads =
                                case bound of
                                    MonoCall _ (MonoVarKernel _ _ home name _) _ _ _ ->
                                        Dict.update
                                            (Name.toElmString home ++ "." ++ Name.toElmString name)
                                            (\m -> Just (1 + Maybe.withDefault 0 m))
                                            acc1.deadHeads

                                    _ ->
                                        acc1.deadHeads
                        }

                    else
                        acc1

                _ ->
                    acc1

        ( occs1, acc3 ) =
            admit oracle minCost expr path ( occs, acc2 )
    in
    foldWithPaths (collect oracle minCost) path ( occs1, acc3 ) expr


{-| Is this node a CSE candidate? Each rejection is counted.
-}
admit :
    CsePurity.Oracle
    -> Int
    -> MonoExpr
    -> List Step
    -> ( List Occ, Counts )
    -> ( List Occ, Counts )
admit oracle minCost expr path ( occs, acc ) =
    case expr of
        MonoCall _ func _ ty _ ->
            let
                cost =
                    CsePurity.costOf expr

                head =
                    case func of
                        MonoVarGlobal _ sid _ ->
                            HGlobal sid

                        MonoVarKernel _ _ home name _ ->
                            HKernel home name

                        _ ->
                            HOther

                mentionsDebug =
                    hasDebug expr
            in
            if Mono.isFunctionType ty then
                -- CGEN_069: a hoisted function-typed value invalidates the
                -- enclosing call's staged CallInfo (typed-apply arity assert).
                ( occs, { acc | fnResultExcluded = acc.fnResultExcluded + 1 } )

            else if hasBinder expr then
                ( occs, { acc | binderExcluded = acc.binderExcluded + 1 } )

            else if mentionsDebug then
                ( occs, { acc | debugExcluded = acc.debugExcluded + 1 } )

            else if not (CsePurity.isSafeExpr oracle expr) then
                ( occs, acc )

            else if cost < minCost then
                ( occs, { acc | belowMinCost = acc.belowMinCost + 1 } )

            else
                ( { key = CafHoist.fingerprintOf expr ty
                  , shape = CafHoist.zeroRegions expr
                  , head = head
                  , path = path
                  , cost = cost
                  }
                    :: occs
                , { acc
                    | candidateOccs = acc.candidateOccs + 1
                    , c1_4 = bump (cost < 5) 1 acc.c1_4
                    , c5_9 = bump (cost >= 5 && cost < 10) 1 acc.c5_9
                    , c10_49 = bump (cost >= 10 && cost < 50) 1 acc.c10_49
                    , c50plus = bump (cost >= 50) 1 acc.c50plus
                  }
                )

        _ ->
            ( occs, acc )


{-| Does any node in the tree satisfy `pred`? Plain structural recursion; the
path-carrying fold is the wrong tool for a yes/no question.
-}
anyNode : (MonoExpr -> Bool) -> MonoExpr -> Bool
anyNode pred root =
    pred root || List.any (anyNode pred) (childrenOf root)


hasDebug : MonoExpr -> Bool
hasDebug =
    anyNode
        (\e ->
            case e of
                MonoVarKernel _ _ home _ _ ->
                    home == "Debug"

                _ ->
                    False
        )


{-| v1 keeps clear of every binder-capture and duplicate-SSA-name question by
refusing any candidate that contains a binder or a closure.
-}
hasBinder : MonoExpr -> Bool
hasBinder =
    anyNode
        (\e ->
            case e of
                MonoLet _ _ _ ->
                    True

                MonoDestruct _ _ _ ->
                    True

                MonoCase _ _ _ _ _ ->
                    True

                MonoClosure _ _ _ ->
                    True

                _ ->
                    False
        )


{-| Direct sub-expressions, order irrelevant (only `anyNode` consumes this).
-}
childrenOf : MonoExpr -> List MonoExpr
childrenOf expr =
    case expr of
        MonoLiteral _ _ ->
            []

        MonoVarLocal _ _ ->
            []

        MonoVarGlobal _ _ _ ->
            []

        MonoVarKernel _ _ _ _ _ ->
            []

        MonoUnit ->
            []

        MonoAccessorValue _ _ _ ->
            []

        MonoList _ items _ ->
            items

        MonoClosure _ body _ ->
            [ body ]

        MonoCall _ func args _ _ ->
            func :: args

        MonoTailCall _ args _ ->
            List.map Tuple.second args

        MonoIf branches final _ ->
            List.concatMap (\( c, t ) -> [ c, t ]) branches ++ [ final ]

        MonoLet def body _ ->
            [ defBound def, body ]

        MonoDestruct _ body _ ->
            [ body ]

        MonoCase _ _ decider branches _ ->
            deciderExprs decider ++ List.map Tuple.second branches

        MonoRecordCreate fields _ ->
            List.map Tuple.second fields

        MonoRecordAccess inner _ _ ->
            [ inner ]

        MonoRecordUpdate inner updates _ ->
            inner :: List.map Tuple.second updates

        MonoTupleCreate _ items _ ->
            items


deciderExprs : Mono.Decider Mono.MonoChoice -> List MonoExpr
deciderExprs decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            [ e ]

        Mono.Leaf (Mono.Jump _) ->
            []

        Mono.Chain _ success failure ->
            deciderExprs success ++ deciderExprs failure

        Mono.FanOut _ tests fallback ->
            List.concatMap (\( _, d ) -> deciderExprs d) tests ++ deciderExprs fallback


{-| Fold over direct children, extending the path with each child's step.

Exhaustive on purpose: a new `MonoExpr` constructor must break this compile
rather than silently drop a sub-tree from the census.

-}
foldWithPaths :
    (MonoExpr -> List Step -> ( List Occ, Counts ) -> ( List Occ, Counts ))
    -> List Step
    -> ( List Occ, Counts )
    -> MonoExpr
    -> ( List Occ, Counts )
foldWithPaths f path acc expr =
    let
        at step child a =
            f child (path ++ [ step ]) a

        indexed step items a =
            List.foldl (\( n, e ) b -> at (step n) e b) a (List.indexedMap Tuple.pair items)
    in
    case expr of
        MonoLiteral _ _ ->
            acc

        MonoVarLocal _ _ ->
            acc

        MonoVarGlobal _ _ _ ->
            acc

        MonoVarKernel _ _ _ _ _ ->
            acc

        MonoUnit ->
            acc

        MonoAccessorValue _ _ _ ->
            acc

        MonoList _ items _ ->
            indexed SStrict items acc

        MonoClosure _ body _ ->
            at SClosure body acc

        MonoCall _ func args _ _ ->
            indexed (\n -> SStrict (n + 1)) args (at (SStrict 0) func acc)

        MonoTailCall _ args _ ->
            indexed SStrict (List.map Tuple.second args) acc

        MonoIf branches final _ ->
            let
                a1 =
                    List.foldl
                        (\( n, ( c, t ) ) b -> at (SBranch n) t (at (SGuard n) c b))
                        acc
                        (List.indexedMap Tuple.pair branches)
            in
            at (SBranch (List.length branches)) final a1

        MonoLet def body _ ->
            at (SSeq 1) body (at (SSeq 0) (defBound def) acc)

        MonoDestruct _ body _ ->
            at (SSeq 1) body acc

        MonoCase _ _ decider branches _ ->
            indexed SBranch
                (List.map Tuple.second branches)
                (foldDeciderPaths f path 0 acc decider)

        MonoRecordCreate fields _ ->
            indexed SStrict (List.map Tuple.second fields) acc

        MonoRecordAccess inner _ _ ->
            at (SStrict 0) inner acc

        MonoRecordUpdate inner updates _ ->
            indexed (\n -> SStrict (n + 1))
                (List.map Tuple.second updates)
                (at (SStrict 0) inner acc)

        MonoTupleCreate _ items _ ->
            indexed SStrict items acc


{-| `depth` distinguishes decider leaves.

Every `Leaf (Inline _)` in a `Chain`/`FanOut` tree is a branch position, but they
are DIFFERENT branch positions. Giving them all one path step would make two
distinct occurrences share a path key, their common prefix would swallow both
suffixes, and the pair would classify as `b0_block` — silently inflating the
near pool with occurrences that are not mergeable at all.

-}
foldDeciderPaths :
    (MonoExpr -> List Step -> ( List Occ, Counts ) -> ( List Occ, Counts ))
    -> List Step
    -> Int
    -> ( List Occ, Counts )
    -> Mono.Decider Mono.MonoChoice
    -> ( List Occ, Counts )
foldDeciderPaths f path depth acc decider =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            f e (path ++ [ SBranch depth ]) acc

        Mono.Leaf (Mono.Jump _) ->
            acc

        Mono.Chain _ success failure ->
            foldDeciderPaths f
                path
                (depth * 2 + 2)
                (foldDeciderPaths f path (depth * 2 + 1) acc success)
                failure

        Mono.FanOut _ tests fallback ->
            foldDeciderPaths f
                path
                (depth * 2 + 2)
                (List.foldl
                    (\( n, ( _, d ) ) a -> foldDeciderPaths f path (depth * 2 + 3 + n) a d)
                    acc
                    (List.indexedMap Tuple.pair tests)
                )
                fallback


defBound : Mono.MonoDef -> MonoExpr
defBound def =
    case def of
        Mono.MonoDef _ bound ->
            bound

        Mono.MonoTailDef _ _ bound ->
            bound
