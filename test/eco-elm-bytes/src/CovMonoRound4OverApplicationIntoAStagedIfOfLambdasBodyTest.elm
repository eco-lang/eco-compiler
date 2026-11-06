module CovMonoRound4OverApplicationIntoAStagedIfOfLambdasBodyTest exposing (..)

{-| A function defined with one parameter, whose body is an `if` returning nested lambdas, gives the right result when called with all four of its annotated arguments at once and when applied in stages.

`pick` is annotated `Int -> Int -> Int -> Int -> Int` but takes only `a`; each `if` branch returns `\b c -> \d -> ...`, a lambda of two arguments returning a lambda of one. `testValue` sums `pick 2 3 4 5`, which supplies all four arguments to the one-parameter definition, and two calls of `useIt`, which applies `pick` to three arguments and then applies that result separately to `4` and to `5`. The arguments `1` and `2` take the `then` branch and `-1` the `else` branch.

The expected value is what Elm 0.19.1 prints for this program.

## eco

This is the end-to-end form of the case "over-application into a staged if-of-lambdas body" in compiler/tests/SourceIR/CovMonoRound4Cases.elm, a catalogue of programs written to reach defensive paths of the solver monomorphizer (compiler/src/Compiler/Monomorphize/Solver/Engine.elm) and of the mono-level optimizations (compiler/src/Compiler/MonoOpt/GlobalOptimize.elm, compiler/src/Compiler/MonoOpt/AbiCloning.elm).

It exercises source-arity staging: `pick` has source arity 1 but its body returns closures staged as 2 then 1, so the local `h = pick n 2 3` over-applies the definition, and its arity has to be read from the later stages of the callee body (compiler/src/Compiler/MonoOpt/Staging.elm).

-}

-- CHECK: testValue: 51

import Basics exposing (..)
import Bitwise exposing (..)
import Bytes exposing (..)
import Bytes.Decode exposing (..)
import Bytes.Encode exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Tuple exposing (..)
import Html


testValue : Int
testValue =
    useIt 1 + useIt -1 + pick 2 3 4 5


useIt : Int -> Int
useIt n =
    let
        h =
            pick n 2 3
    in
    h 4 + h 5


pick : Int -> Int -> Int -> Int -> Int
pick a =
    if a > 0 then
        \b c -> \d -> a * 3 + b * 5 + c * 7 + d * 11 + a * b * c * d + (a + b) * (c + d) + (a - b) * (c - d)

    else
        \b c -> \d -> a * 13 - b * 17 - c * 19 - d * 23 + a * b - c * d + (a - b) * (c + d) - (a + b) * (c - d)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
