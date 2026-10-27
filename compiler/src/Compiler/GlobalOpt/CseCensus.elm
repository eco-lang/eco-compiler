module Compiler.GlobalOpt.CseCensus exposing (report)

{-| Common subexpression elimination (CSE) merges structurally equal
expressions into one shared value. This module measures how much such a pass
could merge inside each spec body, without changing the graph, so the answer is
known before the pass is relied on. `report` returns the measurements as text
lines, and nothing in the module writes them anywhere.

A _candidate_ is a call that a merge could take: one whose result is not a
function, that contains no binder (`let`, destructuring, `case` or closure),
mentions no `Debug` kernel, is accepted by `CsePurity.isSafeExpr`, and whose
`CsePurity.costOf` is at least `minCost`. Each rejection except the purity one
is counted. Candidates are first divided by `CafHoist.kindTagOf` and result
type, and then grouped by `==` after `CafHoist.zeroRegions`, so two calls are
"the same" exactly when those functions say so. A _group_ of `n` equal
candidates holds `n - 1` redundant occurrences.

Whether a group can be merged without evaluating something that would not
otherwise have been evaluated depends on where its members sit relative to
each other. Every occurrence therefore carries its _path_, the list of `Step`s
from the body's root down to it. The members' longest common path prefix is
their lowest common ancestor, and each member's _suffix_ is the rest of its
path. The group's _distance bucket_ is read off those suffixes, first rule
that applies:

  - `b3_frame`: some suffix enters a closure body, which runs at a different
    time and frequency from the code around it.
  - `b0_block`: every suffix is strict argument or field steps only.
  - `b1_seq`: every suffix is strict or `let`/destructuring steps only.
  - `b1c_probe`: at least one member's suffix is all unconditional steps
    (strict, sequential, or the first guard of an `if`).
  - `b2_branch`: everything else.

Redundancy in `b0_block`, `b1_seq` or `b1c_probe` is _near_ redundancy.
`b4_crossdef` is printed but no group is ever put in it, so it is always 0.
_loopNear_ counts near redundancy in the body of a top-level tail-recursive
function, whose body runs once per iteration.

The same walk also counts dead plain `let`s, those whose name
`CsePurity.countLocalUses` finds unused in the body, and how many of those bind
a safe call or a call to a kernel that `KernelFacts.droppableFor` allows to be
deleted. These are the `cse-dce` lines.

@docs report

-}

import Array
import Compiler.AST.Monomorphized as Mono exposing (MonoExpr(..))
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.GlobalOpt.CafHoist as CafHoist
import Compiler.GlobalOpt.CsePurity as CsePurity
import Compiler.GlobalOpt.KernelFacts as KernelFacts
import Dict exposing (Dict)


{-| One step of a path from a spec body's root down to a sub-expression.

`SStrict` is the position of an argument, list item, field or other operand
that is always evaluated with its parent, counted from 0 (a call's function is
0 and its arguments follow).

`SSeq` is the bound expression (0) or the body (1) of a `let`, or the body (1)
of a destructuring.

`SGuard` is the condition at that position in an `if` chain. Only `SGuard 0`
counts as unconditional, because the first condition is evaluated whenever the
chain is; a later one is reached only when every condition before it fails.

`SBranch` is a branch: the result at that position of an `if` chain (the final
`else` takes the next number), a jump branch of a `case`, or an inline leaf of
a `case` decision tree, numbered as `foldDeciderPaths` describes.

`SClosure` is the body of a closure.

-}
type Step
    = SStrict Int
    | SSeq Int
    | SGuard Int
    | SBranch Int
    | SClosure


{-| Returns whether a step is always taken when its parent is evaluated:
strict and sequential steps, and the first guard of an `if`.
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


{-| The callee of a candidate call, used to name it in the per-head counts: a
global spec by SpecId, a kernel by home and name, or anything else.
-}
type Head
    = HGlobal Int
    | HKernel Name Name
    | HOther


{-| One candidate call and where it sits.

`key` and `ty` together pick the partition the candidate is compared in, and
`shape` is the call with its regions zeroed, compared by `==` within that
partition. `cost` is the call's `CsePurity.costOf`.

-}
type alias Occ =
    { key : String
    , ty : Mono.MonoType
    , shape : MonoExpr
    , head : Head
    , path : List Step
    , cost : Int
    }


{-| The census totals over every spec visited, as `report` prints them.

`callOccs` counts every `MonoCall` the walk reaches, candidate or not. The `b*`
fields, `nearRedundant`, `loopNear`, `perHead` and `perSpec` count redundant
occurrences, `n - 1` per group of `n`, and `nearCost` weights each by the
call's cost. `perHead` and `perSpec` count near redundancy only. The `c*` fields bin candidates by cost.
`b4Crossdef`, `shadowBlocked` and `callInfoBlocked` are never increased and
stay 0. `deadHeads` counts dead `let`s by kernel callee.

-}
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


{-| The census with every count at zero.
-}
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


{-| Returns the census of `graph` as text lines, each starting `cse-census`
or `cse-dce` followed by `label`.

The bodies visited are those of defines, tail functions and ports; other nodes
are skipped. A call costing less than `minCost` is counted as excluded rather
than taken as a candidate. A spec is named by its module and name, so the
per-spec counts add together different specializations of one definition.
`nearShareBp` is near redundancy per 10,000 calls, and `nearTop20Bp` is the
share, per 10,000, of near redundancy that falls to the 20 most frequent callee
heads.

-}
report : String -> Int -> Mono.MonoGraph -> String
report label minCost ((Mono.MonoGraph g) as graph) =
    let
        oracle =
            CsePurity.analyze graph

        specName sid =
            case Array.get sid g.registry.reverseMapping |> Maybe.andThen identity of
                Just ( Mono.Global (ModuleName.Canonical _ moduleName) n, _ ) ->
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


{-| Returns an integer as decimal text.
-}
n_ : Int -> String
n_ =
    String.fromInt


{-| Returns the body of a node the census visits, with whether it is the body
of a tail-recursive function, or `Nothing` for any other node.
-}
bodyOf : Mono.MonoNode -> Maybe ( MonoExpr, Bool )
bodyOf node =
    case node of
        Mono.MonoDefine body _ ->
            Just ( body, False )

        Mono.MonoTailFunc _ body _ ->
            Just ( body, True )

        Mono.MonoPortIncoming body _ ->
            Just ( body, False )

        Mono.MonoPortOutgoing body _ ->
            Just ( body, False )

        _ ->
            Nothing


{-| Returns `acc0` with the census of one spec body added: its candidates
grouped and each group given a distance bucket, and its dead `let`s counted.
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
                (\occ d ->
                    Dict.update occ.key
                        (\m ->
                            let
                                inner =
                                    Maybe.withDefault Mono.specMapEmpty m

                                prev =
                                    Maybe.withDefault [] (Mono.specMapGet occ.ty inner)
                            in
                            Just (Mono.specMapInsert occ.ty (occ :: prev) inner)
                        )
                        d
                )
                Dict.empty
                occs
    in
    Dict.foldl
        (\_ inner a ->
            Mono.specMapFoldl
                (\_ members b -> classifyBucket headName specName sid inLoop members b)
                a
                inner
        )
        acc1
        buckets


{-| Returns `acc` with the groups among `members` counted.

`members` share a kind tag and type. Each is grouped with every later member
whose `shape` is `==` to it, a group of one is ignored, and each group of two or
more is given its bucket by `groupBucket`.

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
                            , b4Crossdef = bump False redundant acc.b4Crossdef
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


{-| Returns `current` plus `amount` when `cond` holds, else `current`.
-}
bump : Bool -> Int -> Int -> Int
bump cond amount current =
    if cond then
        current + amount

    else
        current


{-| The distance bucket of a group, as the module docstring defines them.
`b4_crossdef` has no constructor because no group is put in it.
-}
type Bucket
    = B3Frame
    | B0Block
    | B1Seq
    | B1cProbe
    | B2Branch


{-| Returns the distance bucket of a group, by the first rule in the module
docstring's list that holds for the members' suffixes below their longest
common path prefix.
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


{-| Returns whether a step is `SStrict`.
-}
isStrictStep : Step -> Bool
isStrictStep s =
    case s of
        SStrict _ ->
            True

        _ ->
            False


{-| Returns whether a step is `SSeq`.
-}
isSeqStep : Step -> Bool
isSeqStep s =
    case s of
        SSeq _ ->
            True

        _ ->
            False


{-| Returns `path` without the longest prefix shared by every path in
`paths`. All paths start at the body's root, so that prefix leads to their
lowest common ancestor.
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


{-| Returns the length of the longest common prefix of two paths.
-}
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


{-| Returns the candidates and counts of `expr` and everything below it added
to the accumulator, where `path` leads to `expr`.

A `let` is dead when `CsePurity.countLocalUses` finds no use of its name in the
body. Only `let`s of a plain definition are checked; a tail-recursive local
definition never counts as dead.

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
                                    MonoCall _ (MonoVarKernel _ prefix home name _) _ _ _ ->
                                        bump (KernelFacts.droppableFor ( prefix, home, name )) 1 acc1.deadDroppableKernelLets

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


{-| Returns the accumulator with `expr` added as a candidate if it is one.

Only a `MonoCall` can be a candidate. The tests run in order, and a call
rejected for a function-typed result, a binder, a `Debug` mention or a cost
below `minCost` is counted under that reason; a call `CsePurity.isSafeExpr`
rejects is not counted anywhere.

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
                -- Moving a function-typed result into a binding would invalidate
                -- the CallInfo of the enclosing call that applies it.
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
                ( { key = CafHoist.kindTagOf expr
                  , ty = ty
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


{-| Returns whether `pred` holds for `root` or any expression below it that
`childrenOf` reaches.
-}
anyNode : (MonoExpr -> Bool) -> MonoExpr -> Bool
anyNode pred root =
    pred root || List.any (anyNode pred) (childrenOf root)


{-| Returns whether an expression references a kernel whose home is `Debug`,
outside closure captures.
-}
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


{-| Returns whether an expression contains a `let`, destructuring, `case` or
closure. Such a candidate is refused, so a merge never has to deal with
variables bound inside it.
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


{-| Returns the direct sub-expressions of an expression, in no particular
order.

A closure's capture expressions are not included.

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


{-| Returns the expressions held inline at the leaves of a decision tree.
-}
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


{-| Returns `acc` after applying `f` to each direct sub-expression of `expr`,
each with `path` extended by the step that reaches it.

The steps given are those `Step` describes. A closure's capture expressions
are not visited. The `case` is written out for every `MonoExpr` constructor, so
a new constructor fails to compile here instead of being skipped.

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


{-| Returns `acc` after applying `f` to each expression held inline at a leaf
of a `case` decision tree, each with `path` extended by `SBranch` and a number
derived from `depth`.

The number exists so that two leaves do not share a path, which would let
their common prefix absorb both and classify them as near. At a `Chain` the
success side gets `2 * depth + 1` and the failure side `2 * depth + 2`; at a
`FanOut` test `n` gets `2 * depth + 3 + n` and the fallback `2 * depth + 2`.
These numbers are not unique across a whole tree, and they can equal the
numbers `foldWithPaths` gives the `case`'s jump branches, which start at 0, so
two different leaves or branches can share a step.

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


{-| Returns the expression a local definition binds, which for a
tail-recursive one is its body.
-}
defBound : Mono.MonoDef -> MonoExpr
defBound def =
    case def of
        Mono.MonoDef _ bound ->
            bound

        Mono.MonoTailDef _ _ bound ->
            bound
