module Compiler.LocalOpt.Erased.Case exposing (optimize)

{-| Turns the branches of one `case` into the optimized AST's `Opt.Case`.

A `case` is compiled in two steps. `Compiler.LocalOpt.Erased.DecisionTree`
builds a decision tree of runtime tests whose leaves name a branch by its
position. This module turns that tree into an `Opt.Decider`, and then decides,
for each branch, where its body goes.

A branch can be reached by more than one leaf of the tree, and a branch that
an earlier one shadows is reached by none. That fact drives the second step.
Each branch gets a _choice_: a branch reached by exactly one leaf is `Inline`,
its body written at that leaf; any other branch is a `Jump`, its body listed
once in the `Case`'s jump list under its position and every leaf that reaches
it referring to that position.

Converting the tree also removes redundant structure. A decision with one way
out is replaced by that way out, a two-way decision becomes a `Chain` (merged
with a nested `Chain` that has the same failure), and a wider one becomes a
`FanOut`.

-}

import Array exposing (Array)
import Compiler.Core.Name as Name
import Compiler.IR.Canonical as Can
import Compiler.IR.DecisionTree.Test as Test
import Compiler.IR.Optimized as Opt
import Compiler.LocalOpt.Erased.DecisionTree as DT
import Data.NonEmptyList as NE
import System.Crash exposing (crash)



-- ====== OPTIMIZE A CASE EXPRESSION ======


{-| Builds the `Opt.Case` that selects among `optBranches`, with `temp` as its
label name and `root` as the variable holding the value matched.

Branches are numbered by their position in `optBranches`, and a `Jump` refers
to a branch by that number. A branch reached by no leaf is still a `Jump` and
its body is kept in the jump list.

-}
optimize : Name.Name -> Name.Name -> List ( Can.Pattern, Opt.Expr ) -> Opt.Expr
optimize temp root optBranches =
    let
        ( patterns, indexedBranches ) =
            List.unzip (List.indexedMap indexify optBranches)

        decider : Opt.Decider Int
        decider =
            treeToDecider (DT.compile patterns)

        numBranches : Int
        numBranches =
            List.length indexedBranches

        targetCounts : Array Int
        targetCounts =
            countTargets numBranches decider

        ( choices, maybeJumps ) =
            List.unzip (List.map (createChoices targetCounts) indexedBranches)
    in
    Opt.Case temp
        root
        (insertChoices (Array.fromList (List.map Tuple.second choices)) decider)
        (List.filterMap identity maybeJumps)


{-| Pairs a branch's pattern and its body each with the branch's position
`index`.
-}
indexify : Int -> ( a, b ) -> ( ( a, Int ), ( Int, b ) )
indexify index ( pattern, branch ) =
    ( ( pattern, index )
    , ( index, branch )
    )



-- ====== TREE TO DECIDER ======


{-| Converts a decision tree into a `Decider` whose leaves are branch positions.

A decision with a single way out, a lone edge with no fallback, is replaced by
the converted subtree, since no test is needed. A decision with two ways out,
one edge and a fallback or two edges and no fallback, becomes a `Chain` built
by `toChain`. Any wider decision becomes a `FanOut`; when it has no fallback,
its last edge's subtree becomes the fallback and that edge's test is dropped.

-}
treeToDecider : DT.DecisionTree -> Opt.Decider Int
treeToDecider tree =
    case tree of
        DT.Match target ->
            Opt.Leaf target

        DT.Decision _ (NE.Nonempty ( _, subTree ) []) Nothing ->
            treeToDecider subTree

        DT.Decision path (NE.Nonempty ( test, successTree ) []) (Just failureTree) ->
            toChain path test successTree failureTree

        DT.Decision path (NE.Nonempty ( test, successTree ) [ ( _, failureTree ) ]) Nothing ->
            toChain path test successTree failureTree

        -- A missing fallback means the edges' tests cover every value, so
        -- the last edge can stand in as the fallback without its test.
        DT.Decision path (NE.Nonempty edge1 (edge2 :: edge3 :: moreEdges)) Nothing ->
            let
                ( necessaryEdges, ( _, fallback ) ) =
                    splitLast edge1 edge2 (edge3 :: moreEdges)
            in
            Opt.FanOut path (NE.map toFanEdge necessaryEdges) (treeToDecider fallback)

        DT.Decision path edges (Just fallback) ->
            Opt.FanOut path (NE.map toFanEdge edges) (treeToDecider fallback)


{-| Returns the list `first :: second :: more` without its last element, and
that element.
-}
splitLast : a -> a -> List a -> ( NE.Nonempty a, a )
splitLast first second more =
    case more of
        [] ->
            ( NE.singleton first, second )

        third :: rest ->
            let
                ( NE.Nonempty head tail, last ) =
                    splitLast second third rest
            in
            ( NE.Nonempty first (head :: tail), last )


{-| Converts a decision-tree edge into a fan-out edge: its test as a
`DT.FanTest`, and its subtree converted. A fan-out is built only for three or
more ways out, and a position with a `Bool` or list test has at most two, so
the test is always a constructor or literal test.
-}
toFanEdge : ( DT.Test, DT.DecisionTree ) -> ( Test.FanTest, Opt.Decider Int )
toFanEdge ( test, subTree ) =
    case Test.toFanTest test of
        Just fanTest ->
            ( fanTest, treeToDecider subTree )

        Nothing ->
            crash "Erased.Case.toFanEdge: a Bool or list test has at most two ways out, so it makes a Chain"


{-| Builds a `Chain` that runs `test` at `path` and continues with the converted
`successTree` when it passes and the converted `failureTree` otherwise.

When the converted success side is itself a `Chain` with the same failure, the
two are merged into one `Chain` whose test list starts with `test`.

-}
toChain : DT.Path -> DT.Test -> DT.DecisionTree -> DT.DecisionTree -> Opt.Decider Int
toChain path test successTree failureTree =
    let
        failure : Opt.Decider Int
        failure =
            treeToDecider failureTree
    in
    case treeToDecider successTree of
        (Opt.Chain (NE.Nonempty firstTest otherTests) success subFailure) as success_ ->
            if failure == subFailure then
                Opt.Chain (NE.Nonempty ( path, test ) (firstTest :: otherTests)) success failure

            else
                Opt.Chain (NE.singleton ( path, test )) success_ failure

        success ->
            Opt.Chain (NE.singleton ( path, test )) success failure



-- ====== INSERT CHOICES ======


{-| Returns, for each of the `numBranches` branch positions, how many leaves of
`decider` reach it.
-}
countTargets : Int -> Opt.Decider Int -> Array Int
countTargets numBranches decider =
    countTargetsHelp (Array.repeat numBranches 0) decider


{-| Returns `counts` with one added at each leaf of `decider`.
-}
countTargetsHelp : Array Int -> Opt.Decider Int -> Array Int
countTargetsHelp counts decider =
    case decider of
        Opt.Leaf target ->
            Array.set target (arrayGetOr 0 target counts + 1) counts

        Opt.Chain _ success failure ->
            countTargetsHelp (countTargetsHelp counts success) failure

        Opt.FanOut _ tests fallback ->
            List.foldl (\( _, sub ) acc -> countTargetsHelp acc sub)
                (countTargetsHelp counts fallback)
                (NE.toList tests)


{-| Returns the element at `idx`, or `default` when `idx` is out of range.
-}
arrayGetOr : a -> Int -> Array a -> a
arrayGetOr default idx arr =
    Array.get idx arr |> Maybe.withDefault default


{-| Returns the choice for one numbered branch, and the jump list entry it
needs, if any.

The branch is `Inline` when exactly one leaf reaches it, according to
`targetCounts`, and needs no jump list entry. Otherwise it is a `Jump` to its
own position, and its body is listed under that position.

-}
createChoices : Array Int -> ( Int, Opt.Expr ) -> ( ( Int, Opt.Choice ), Maybe ( Int, Opt.Expr ) )
createChoices targetCounts ( target, branch ) =
    if arrayGetOr 0 target targetCounts == 1 then
        ( ( target, Opt.Inline branch )
        , Nothing
        )

    else
        ( ( target, Opt.Jump target )
        , Just ( target, branch )
        )


{-| Replaces each branch position at a leaf of `decider` with that branch's
choice, looked up by position in `choiceArray`. Crashes on a position the
array does not hold.
-}
insertChoices : Array Opt.Choice -> Opt.Decider Int -> Opt.Decider Opt.Choice
insertChoices choiceArray decider =
    let
        go : Opt.Decider Int -> Opt.Decider Opt.Choice
        go =
            insertChoices choiceArray
    in
    case decider of
        Opt.Leaf target ->
            case Array.get target choiceArray of
                Just choice ->
                    Opt.Leaf choice

                Nothing ->
                    crash ("insertChoices: target " ++ String.fromInt target ++ " not found in choice array")

        Opt.Chain testChain success failure ->
            Opt.Chain testChain (go success) (go failure)

        Opt.FanOut path tests fallback ->
            Opt.FanOut path (NE.map (Tuple.mapSecond go) tests) (go fallback)
