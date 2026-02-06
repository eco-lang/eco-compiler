module Compiler.Monomorphize.Segmentation exposing
    ( Segmentation
    , segmentLengths
    , chooseCanonicalSegmentation
    , buildSegmentedFunctionType
    , decomposeFunctionType
    , countTotalArity
    , stageParamTypes, stageArity, stageReturnType
    )

{-| Currying segmentation utilities for monomorphized function types.

This module provides functions for analyzing and transforming the segmented
structure of curried function types in the monomorphized IR.

In monomorphized Elm, multi-argument functions can be segmented into stages
(each stage takes some arguments and returns another function or the final value).
This module helps normalize and manipulate these segmentations.


# Segmentation Type

@docs Segmentation


# Segmentation Analysis

@docs segmentLengths
@docs chooseCanonicalSegmentation


# Segmentation Construction

@docs buildSegmentedFunctionType
@docs decomposeFunctionType


# Function Arity Utilities

@docs countTotalArity
@docs stageParamTypes, stageArity, stageReturnType

-}

import Compiler.AST.Monomorphized exposing (MonoType(..))
import Data.Map as Dict



-- ====== SEGMENTATION TYPE ======


{-| A segmentation is a list of integers representing how many arguments each
stage of a curried function takes.

For example, `[2, 1]` means a function that takes 2 arguments, returns a function
that takes 1 argument, and then returns the final result.

-}
type alias Segmentation =
    List Int



-- ====== SEGMENTATION ANALYSIS ======


{-| Extract the segmentation from a function type.

Returns a list of integers representing how many arguments each currying
stage of the function takes.

    segmentLengths (MFunction [a, b] (MFunction [c] result)) == [2, 1]

-}
segmentLengths : MonoType -> Segmentation
segmentLengths monoType =
    let
        go t acc =
            case t of
                MFunction stageArgs stageRet ->
                    go stageRet (List.length stageArgs :: acc)

                _ ->
                    List.reverse acc
    in
    go monoType []


{-| Choose a canonical segmentation from a list of types (e.g., from case branch types).

This finds the most common segmentation among the given types, preferring
flatter segmentations (fewer stages) when there are ties.

Returns: (canonical segmentation, flat argument types, final return type)

-}
chooseCanonicalSegmentation : List MonoType -> ( Segmentation, List MonoType, MonoType )
chooseCanonicalSegmentation leafTypes =
    case leafTypes of
        [] ->
            -- Should not happen for well-formed MonoCase
            ( [], [], MUnit )

        firstType :: _ ->
            let
                -- Shared flattened signature (all branches must agree)
                ( flatArgs, flatRet ) =
                    decomposeFunctionType firstType

                -- Count how often each segmentation occurs
                countSegmentations : List MonoType -> Dict.Dict (List Int) (List Int) Int
                countSegmentations types =
                    List.foldl
                        (\t accDict ->
                            let
                                seg =
                                    segmentLengths t

                                current =
                                    Dict.get identity seg accDict |> Maybe.withDefault 0
                            in
                            Dict.insert identity seg (current + 1) accDict
                        )
                        Dict.empty
                        types

                freqDict =
                    countSegmentations leafTypes

                -- Find maximum count
                maxCount =
                    Dict.foldl compare (\_ count acc -> max count acc) 0 freqDict

                -- All segmentations that hit maxCount
                bestSegs =
                    Dict.foldl compare
                        (\seg count acc ->
                            if count == maxCount then
                                seg :: acc

                            else
                                acc
                        )
                        []
                        freqDict

                -- Among them, prefer fewest stages (most flat)
                canonicalSeg =
                    case List.sortBy List.length bestSegs of
                        shortest :: _ ->
                            shortest

                        [] ->
                            -- Fallback: use first type's segmentation
                            segmentLengths firstType
            in
            ( canonicalSeg, flatArgs, flatRet )



-- ====== SEGMENTATION CONSTRUCTION ======


{-| Build a segmented function type from flat arguments and a segmentation.

    buildSegmentedFunctionType [a, b, c] result [2, 1]
        == MFunction [a, b] (MFunction [c] result)

-}
buildSegmentedFunctionType : List MonoType -> MonoType -> Segmentation -> MonoType
buildSegmentedFunctionType flatArgs finalRet seg =
    let
        -- Split flatArgs according to seg = [m1, m2, ...]
        splitBySegments : List MonoType -> Segmentation -> List (List MonoType)
        splitBySegments remaining segLengths =
            case segLengths of
                [] ->
                    []

                m :: rest ->
                    let
                        ( now, later ) =
                            ( List.take m remaining, List.drop m remaining )
                    in
                    now :: splitBySegments later rest

        stageArgsLists =
            splitBySegments flatArgs seg
    in
    -- Build nested MFunction from inside out
    List.foldr
        (\stageArgs acc -> MFunction stageArgs acc)
        finalRet
        stageArgsLists


{-| Decompose a function type into a flat list of arguments and the final return type.

    decomposeFunctionType (MFunction [a, b] (MFunction [c] result))
        == ([a, b, c], result)

-}
decomposeFunctionType : MonoType -> ( List MonoType, MonoType )
decomposeFunctionType monoType =
    case monoType of
        MFunction argTypes result ->
            let
                ( nestedArgs, finalResult ) =
                    decomposeFunctionType result
            in
            ( argTypes ++ nestedArgs, finalResult )

        other ->
            ( [], other )



-- ====== FUNCTION ARITY UTILITIES ======


{-| Count the total arity of a function type (sum of all stage arities).
-}
countTotalArity : MonoType -> Int
countTotalArity monoType =
    case monoType of
        MFunction argTypes result ->
            List.length argTypes + countTotalArity result

        _ ->
            0


{-| Get the parameter types of the first stage of a function type.
-}
stageParamTypes : MonoType -> List MonoType
stageParamTypes monoType =
    case monoType of
        MFunction argTypes _ ->
            argTypes

        _ ->
            []


{-| Get the arity of the first stage of a function type.
-}
stageArity : MonoType -> Int
stageArity monoType =
    List.length (stageParamTypes monoType)


{-| Get the return type of the first stage of a function type.

For `MFunction [a, b] result`, this returns `result`.

-}
stageReturnType : MonoType -> MonoType
stageReturnType monoType =
    case monoType of
        MFunction _ result ->
            result

        other ->
            other
