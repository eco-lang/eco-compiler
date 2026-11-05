module Compiler.LocalOpt.Typed.Case exposing (optimize)

{-| A `case` expression is compiled into a decision tree, and the tree can reach
the same branch along more than one path. This module turns that tree into the
`Case` node of the typed optimized program, deciding for each branch whether
its body is copied into the tree or shared.

The tree comes from `Compiler.LocalOpt.Typed.DecisionTree.compile`, whose
leaves carry branch numbers: the position of the branch in the `case`. It is
first rewritten into a `TOpt.Decider` with the same leaves. Then the leaves
naming each branch are counted. A _choice_ is what a leaf leads to: a branch
named by exactly one leaf is placed in the tree there (`Inline`), and any other
branch is placed once in the `Case`'s jump list and every leaf naming it holds
a `Jump` to it. So no branch body is duplicated.

The `TOpt.Decider` and `TOpt.Choice` types, and what the parts of a `Case`
node are, are described in `Compiler.IR.Typed.Optimized`.

-}

import Array exposing (Array)
import Compiler.Core.Name as Name exposing (Name)
import Compiler.IR.Canonical as Can
import Compiler.IR.DecisionTree.Test as Test
import Compiler.IR.Typed.Optimized as TOpt
import Compiler.IR.Typed.TypeVars as Vars
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Data.NonEmptyList as NE
import System.Crash exposing (crash)



-- ====== OPTIMIZE A CASE EXPRESSION ======


{-| Builds the `Case` node for a `case` whose branches are `optBranches`, each a
pattern and its already optimized body, in source order.

`temp` is the node's label name and `root` the variable whose value is
inspected. `resultType` and `tvar` are the type and solver variable of the
whole `case` expression, and become the node's own type; the branch bodies keep
theirs.

-}
optimize : Name.Name -> Name.Name -> List ( Can.Pattern, TOpt.Expr Name ) -> Can.Type Name -> Maybe Vars.Variable -> TOpt.Expr Name
optimize temp root optBranches resultType tvar =
    let
        ( patterns, indexedBranches ) =
            List.unzip (List.indexedMap indexify optBranches)

        decider : TOpt.Decider Int
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
    TOpt.Case temp
        root
        (insertChoices (Array.fromList (List.map Tuple.second choices)) decider)
        (List.filterMap identity maybeJumps)
        { tipe = resultType, tvar = tvar }


{-| Pairs a branch's pattern and its body each with the branch number `index`.
-}
indexify : Int -> ( a, b ) -> ( ( a, Int ), ( Int, b ) )
indexify index ( pattern, branch ) =
    ( ( pattern, index )
    , ( index, branch )
    )



-- ====== TREE TO DECIDER ======


{-| Converts a decision tree into a `TOpt.Decider` with the same leaves.

A node with no fallback is one where, for any value that reaches it, some
edge's test passes, so its last edge becomes the fallback and that edge's test
is not made. A node with a single path forward, one edge and no fallback, is
replaced by that path. A node with one test and a fallback, or two edges and
no fallback, becomes a `Chain` (see `toChain`); any other node becomes a
`FanOut`.

-}
treeToDecider : DT.DecisionTree -> TOpt.Decider Int
treeToDecider tree =
    case tree of
        DT.Match target ->
            TOpt.Leaf target

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
            TOpt.FanOut path (NE.map toFanEdge necessaryEdges) (treeToDecider fallback)

        DT.Decision path edges (Just fallback) ->
            TOpt.FanOut path (NE.map toFanEdge edges) (treeToDecider fallback)


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
toFanEdge : ( DT.Test, DT.DecisionTree ) -> ( Test.FanTest, TOpt.Decider Int )
toFanEdge ( test, subTree ) =
    case Test.toFanTest test of
        Just fanTest ->
            ( fanTest, treeToDecider subTree )

        Nothing ->
            crash "Typed.Case.toFanEdge: a Bool or list test has at most two ways out, so it makes a Chain"


{-| Builds a `Chain` that makes `test` at `path`, continuing with
`successTree` if it passes and `failureTree` otherwise.

When the success side is itself a `Chain` with the same failure side, the two
are merged into one `Chain` whose test list starts with `test`.

-}
toChain : DT.Path -> DT.Test -> DT.DecisionTree -> DT.DecisionTree -> TOpt.Decider Int
toChain path test successTree failureTree =
    let
        failure : TOpt.Decider Int
        failure =
            treeToDecider failureTree
    in
    case treeToDecider successTree of
        (TOpt.Chain (NE.Nonempty firstTest otherTests) success subFailure) as success_ ->
            if failure == subFailure then
                TOpt.Chain (NE.Nonempty ( path, test ) (firstTest :: otherTests)) success failure

            else
                TOpt.Chain (NE.singleton ( path, test )) success_ failure

        success ->
            TOpt.Chain (NE.singleton ( path, test )) success failure



-- ====== INSERT CHOICES ======


{-| Returns, for each of the `numBranches` branch numbers, how many leaves of
`decider` name it.
-}
countTargets : Int -> TOpt.Decider Int -> Array Int
countTargets numBranches decider =
    countTargetsHelp (Array.repeat numBranches 0) decider


{-| Adds to `counts` one for each leaf of `decider` naming a branch number.
-}
countTargetsHelp : Array Int -> TOpt.Decider Int -> Array Int
countTargetsHelp counts decider =
    case decider of
        TOpt.Leaf target ->
            Array.set target (arrayGetOr 0 target counts + 1) counts

        TOpt.Chain _ success failure ->
            countTargetsHelp (countTargetsHelp counts success) failure

        TOpt.FanOut _ tests fallback ->
            List.foldl (\( _, sub ) acc -> countTargetsHelp acc sub)
                (countTargetsHelp counts fallback)
                (NE.toList tests)


{-| Returns the element of `arr` at `idx`, or `default` when there is none.
-}
arrayGetOr : a -> Int -> Array a -> a
arrayGetOr default idx arr =
    Array.get idx arr |> Maybe.withDefault default


{-| Returns the choice for one numbered branch, and the jump list entry it
needs, if any.

A branch named by exactly one leaf is inlined and needs no entry. Any other
count gives a `Jump` and an entry holding the body; that includes a branch no
leaf names, whose body is then in the jump list but never jumped to.

-}
createChoices : Array Int -> ( Int, TOpt.Expr Name ) -> ( ( Int, TOpt.Choice Name ), Maybe ( Int, TOpt.Expr Name ) )
createChoices targetCounts ( target, branch ) =
    if arrayGetOr 0 target targetCounts == 1 then
        ( ( target, TOpt.Inline branch )
        , Nothing
        )

    else
        ( ( target, TOpt.Jump target )
        , Just ( target, branch )
        )


{-| Replaces each branch number at a leaf of `decider` with that branch's
choice from `choiceArray`, indexed by branch number. Crashes on a number with
no entry.
-}
insertChoices : Array (TOpt.Choice Name) -> TOpt.Decider Int -> TOpt.Decider (TOpt.Choice Name)
insertChoices choiceArray decider =
    let
        go : TOpt.Decider Int -> TOpt.Decider (TOpt.Choice Name)
        go =
            insertChoices choiceArray
    in
    case decider of
        TOpt.Leaf target ->
            case Array.get target choiceArray of
                Just choice ->
                    TOpt.Leaf choice

                Nothing ->
                    crash ("insertChoices: target " ++ String.fromInt target ++ " not found in choice array")

        TOpt.Chain testChain success failure ->
            TOpt.Chain testChain (go success) (go failure)

        TOpt.FanOut path tests fallback ->
            TOpt.FanOut path (NE.map (Tuple.mapSecond go) tests) (go fallback)
