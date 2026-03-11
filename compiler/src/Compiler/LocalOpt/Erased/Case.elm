module Compiler.LocalOpt.Erased.Case exposing (optimize)

{-| Optimizes case expressions using decision trees.

This module bridges the gap between decision tree compilation and the optimized
AST. It takes pattern-matched branches and converts them into an efficient
case expression with:

  - A decision tree that determines which branch to execute
  - Inline choices for branches that are only reached from one path
  - Jump labels for branches that can be reached from multiple paths

The optimization reduces code duplication by sharing branch implementations
when the same code would be reached through different pattern match paths.


# Optimization

@docs optimize

-}

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.Optimized as Opt
import Compiler.Data.Name as Name
import Compiler.LocalOpt.Erased.DecisionTree as DT
import Prelude
import Utils.Crash exposing (crash)



-- ====== OPTIMIZE A CASE EXPRESSION ======


{-| Optimize a case expression into a decision tree.
Takes a temporary variable name, the root variable being matched, and the pattern-matched branches.
Returns an optimized Case expression with decision tree and inline/jump choices.
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


indexify : Int -> ( a, b ) -> ( ( a, Int ), ( Int, b ) )
indexify index ( pattern, branch ) =
    ( ( pattern, index )
    , ( index, branch )
    )



-- ====== TREE TO DECIDER ======
--
-- Decision trees may have some redundancies, so we convert them to a Decider
-- which has special constructs to avoid code duplication when possible.


treeToDecider : DT.DecisionTree -> Opt.Decider Int
treeToDecider tree =
    case tree of
        DT.Match target ->
            Opt.Leaf target

        -- zero options
        DT.Decision _ [] Nothing ->
            crash "compiler bug, somehow created an empty decision tree"

        -- one option
        DT.Decision _ [ ( _, subTree ) ] Nothing ->
            treeToDecider subTree

        DT.Decision _ [] (Just subTree) ->
            treeToDecider subTree

        -- two options
        DT.Decision path [ ( test, successTree ) ] (Just failureTree) ->
            toChain path test successTree failureTree

        DT.Decision path [ ( test, successTree ), ( _, failureTree ) ] Nothing ->
            toChain path test successTree failureTree

        -- many options
        -- INVARIANT: When DT.Decision has Nothing as fallback, the edges list
        -- forms an exhaustive set of tests. The last edge is treated as the
        -- catch-all case. This is guaranteed by:
        -- 1. Pattern exhaustiveness checking in Compiler.Reporting.Error.PatternMatches
        -- 2. The isComplete function in DecisionTree.elm
        -- 3. gatherEdges only returning empty fallback when isComplete returns True
        DT.Decision path edges Nothing ->
            case edges of
                [] ->
                    crash "treeToDecider: empty edges with no fallback (should be unreachable)"

                [ ( _, singleTree ) ] ->
                    -- Single edge with no fallback means it's guaranteed to match
                    treeToDecider singleTree

                _ ->
                    let
                        ( necessaryTests, fallback ) =
                            ( Prelude.init edges, Tuple.second (Prelude.last edges) )
                    in
                    Opt.FanOut
                        path
                        (List.map (Tuple.mapSecond treeToDecider) necessaryTests)
                        (treeToDecider fallback)

        DT.Decision path edges (Just fallback) ->
            Opt.FanOut path (List.map (Tuple.mapSecond treeToDecider) edges) (treeToDecider fallback)


toChain : DT.Path -> DT.Test -> DT.DecisionTree -> DT.DecisionTree -> Opt.Decider Int
toChain path test successTree failureTree =
    let
        failure : Opt.Decider Int
        failure =
            treeToDecider failureTree
    in
    case treeToDecider successTree of
        (Opt.Chain testChain success subFailure) as success_ ->
            if failure == subFailure then
                Opt.Chain (( path, test ) :: testChain) success failure

            else
                Opt.Chain [ ( path, test ) ] success_ failure

        success ->
            Opt.Chain [ ( path, test ) ] success failure



-- ====== INSERT CHOICES ======
--
-- If a target appears exactly once in a Decider, the corresponding expression
-- can be inlined. Whether things are inlined or jumps is called a "choice".


countTargets : Int -> Opt.Decider Int -> Array Int
countTargets numBranches decider =
    countTargetsHelp (Array.repeat numBranches 0) decider


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
                tests


arrayGetOr : a -> Int -> Array a -> a
arrayGetOr default idx arr =
    Array.get idx arr |> Maybe.withDefault default


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
            Opt.FanOut path (List.map (Tuple.mapSecond go) tests) (go fallback)
