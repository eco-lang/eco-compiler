module CovMonoSolverUnusedLocalTailRecursiveFunctionTest exposing (..)

{-| A program containing a self-recursive `let`-bound function that is never called still compiles and runs, alongside a used one.

`testValue` defines two local functions that call themselves in tail position: `unused`, which nothing calls, and `used`, which doubles its accumulator `n` times. The result is `used 3 1`, which is 8.

The expected value is what Elm 0.19.1 prints for this program.

## eco

This is the end-to-end form of the case "unused local tail-recursive function" in compiler/tests/SourceIR/CovMonoSolverCases.elm.

Because `unused` is never called, the solver (compiler/src/Compiler/Monomorphize/Solver/Engine.elm) records no instance for it, so the test exercises translating a local tail-recursive definition that has no specialization.

-}

-- CHECK: testValue: 8

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
    let
        unused n acc =
            if n <= 0 then
                acc

            else
                unused (n - 1) (acc + n)

        used n acc =
            if n <= 0 then
                acc

            else
                used (n - 1) (acc * 2)
    in
    used 3 1


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
