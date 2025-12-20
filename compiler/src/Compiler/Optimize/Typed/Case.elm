module Compiler.Optimize.Typed.Case exposing (optimize)

{-| Optimizes typed case expressions using decision trees.

This module bridges the gap between decision tree compilation and the typed optimized
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

import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as Name
import Compiler.Optimize.Erased.DecisionTree as DT
import Data.Map as Dict exposing (Dict)
import Prelude
import Utils.Crash exposing (crash)
import Utils.Main as Utils



-- OPTIMIZE A CASE EXPRESSION


{-| Optimize a typed case expression into a decision tree.
Takes a temporary variable name, the root variable being matched, the pattern-matched branches,
and the result type. Returns an optimized Case expression with decision tree and inline/jump choices.
-}
optimize : Name.Name -> Name.Name -> List ( Can.Pattern, TOpt.Expr ) -> Can.Type -> TOpt.Expr
optimize temp root optBranches resultType =
    let
        ( patterns, indexedBranches ) =
            List.unzip (List.indexedMap indexify optBranches)

        decider : TOpt.Decider Int
        decider =
            treeToDecider (DT.compile patterns)

        targetCounts : Dict Int Int Int
        targetCounts =
            countTargets decider

        ( choices, maybeJumps ) =
            List.unzip (List.map (createChoices targetCounts) indexedBranches)
    in
    TOpt.Case temp
        root
        (insertChoices (Dict.fromList identity choices) decider)
        (List.filterMap identity maybeJumps)
        resultType


indexify : Int -> ( a, b ) -> ( ( a, Int ), ( Int, b ) )
indexify index ( pattern, branch ) =
    ( ( pattern, index )
    , ( index, branch )
    )



-- TREE TO DECIDER
--
-- Decision trees may have some redundancies, so we convert them to a Decider
-- which has special constructs to avoid code duplication when possible.


treeToDecider : DT.DecisionTree -> TOpt.Decider Int
treeToDecider tree =
    case tree of
        DT.Match target ->
            TOpt.Leaf target

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
        DT.Decision path edges Nothing ->
            let
                ( necessaryTests, fallback ) =
                    ( Prelude.init edges, Tuple.second (Prelude.last edges) )
            in
            TOpt.FanOut
                path
                (List.map (Tuple.mapSecond treeToDecider) necessaryTests)
                (treeToDecider fallback)

        DT.Decision path edges (Just fallback) ->
            TOpt.FanOut path (List.map (Tuple.mapSecond treeToDecider) edges) (treeToDecider fallback)


toChain : DT.Path -> DT.Test -> DT.DecisionTree -> DT.DecisionTree -> TOpt.Decider Int
toChain path test successTree failureTree =
    let
        failure : TOpt.Decider Int
        failure =
            treeToDecider failureTree
    in
    case treeToDecider successTree of
        (TOpt.Chain testChain success subFailure) as success_ ->
            if failure == subFailure then
                TOpt.Chain (( path, test ) :: testChain) success failure

            else
                TOpt.Chain [ ( path, test ) ] success_ failure

        success ->
            TOpt.Chain [ ( path, test ) ] success failure



-- INSERT CHOICES
--
-- If a target appears exactly once in a Decider, the corresponding expression
-- can be inlined. Whether things are inlined or jumps is called a "choice".


countTargets : TOpt.Decider Int -> Dict Int Int Int
countTargets decisionTree =
    case decisionTree of
        TOpt.Leaf target ->
            Dict.singleton identity target 1

        TOpt.Chain _ success failure ->
            Utils.mapUnionWith identity compare (+) (countTargets success) (countTargets failure)

        TOpt.FanOut _ tests fallback ->
            Utils.mapUnionsWith identity compare (+) (List.map countTargets (fallback :: List.map Tuple.second tests))


createChoices : Dict Int Int Int -> ( Int, TOpt.Expr ) -> ( ( Int, TOpt.Choice ), Maybe ( Int, TOpt.Expr ) )
createChoices targetCounts ( target, branch ) =
    if Dict.get identity target targetCounts == Just 1 then
        ( ( target, TOpt.Inline branch )
        , Nothing
        )

    else
        ( ( target, TOpt.Jump target )
        , Just ( target, branch )
        )


insertChoices : Dict Int Int TOpt.Choice -> TOpt.Decider Int -> TOpt.Decider TOpt.Choice
insertChoices choiceDict decider =
    let
        go : TOpt.Decider Int -> TOpt.Decider TOpt.Choice
        go =
            insertChoices choiceDict
    in
    case decider of
        TOpt.Leaf target ->
            TOpt.Leaf (Utils.find identity target choiceDict)

        TOpt.Chain testChain success failure ->
            TOpt.Chain testChain (go success) (go failure)

        TOpt.FanOut path tests fallback ->
            TOpt.FanOut path (List.map (Tuple.mapSecond go) tests) (go fallback)
