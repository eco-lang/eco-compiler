module Compiler.LocalOpt.Typed.Case exposing (optimize)

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

import Array exposing (Array)
import Compiler.AST.Canonical as Can
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name as Name
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Prelude
import Utils.Crash exposing (crash)



-- ====== OPTIMIZE A CASE EXPRESSION ======


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
        { tipe = resultType, tvar = Nothing }


indexify : Int -> ( a, b ) -> ( ( a, Int ), ( Int, b ) )
indexify index ( pattern, branch ) =
    ( ( pattern, index )
    , ( index, branch )
    )



-- ====== TREE TO DECIDER ======
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



-- ====== INSERT CHOICES ======
--
-- If a target appears exactly once in a Decider, the corresponding expression
-- can be inlined. Whether things are inlined or jumps is called a "choice".


countTargets : Int -> TOpt.Decider Int -> Array Int
countTargets numBranches decider =
    countTargetsHelp (Array.repeat numBranches 0) decider


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
                tests


arrayGetOr : a -> Int -> Array a -> a
arrayGetOr default idx arr =
    Array.get idx arr |> Maybe.withDefault default


createChoices : Array Int -> ( Int, TOpt.Expr ) -> ( ( Int, TOpt.Choice ), Maybe ( Int, TOpt.Expr ) )
createChoices targetCounts ( target, branch ) =
    if arrayGetOr 0 target targetCounts == 1 then
        ( ( target, TOpt.Inline branch )
        , Nothing
        )

    else
        ( ( target, TOpt.Jump target )
        , Just ( target, branch )
        )


insertChoices : Array TOpt.Choice -> TOpt.Decider Int -> TOpt.Decider TOpt.Choice
insertChoices choiceArray decider =
    let
        go : TOpt.Decider Int -> TOpt.Decider TOpt.Choice
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
            TOpt.FanOut path (List.map (Tuple.mapSecond go) tests) (go fallback)
