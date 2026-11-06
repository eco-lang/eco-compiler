module CovMonoSolverCycleWithATailRecursiveMemberTest exposing (..)

{-| Two pairs of mutually recursive functions, each with one self-recursive member, compute the right result.

`countDown` calls itself until `n` reaches zero and then calls `finish`, which calls back into `countDown` only when the total exceeds 100. `loopFn`, annotated `Int -> Fn` where `Fn` is an alias for `Int -> Int` and defined with two parameters, counts `n` down while adding one to `x` and then calls `other`, which calls back into `loopFn` only when `x` exceeds 10. Neither call back is taken here: `countDown 5 0` is 15 and `loopFn 2 3` is 5, giving 20.

The expected value is what Elm 0.19.1 prints for this program.

## eco

This is the end-to-end form of the case "cycle with a tail-recursive member" in compiler/tests/SourceIR/CovMonoSolverCases.elm.

It exercises the solver (compiler/src/Compiler/Monomorphize/Solver/Engine.elm) on recursive groups in which one member is self tail-recursive, including one (`loopFn`) whose written arity matches its type only after the `Fn` alias is expanded.

-}

-- CHECK: testValue: 20

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


type alias Fn =
    Int -> Int


testValue : Int
testValue =
    countDown 5 0 + loopFn 2 3


other : Int -> Int
other x =
    if x > 10 then
        loopFn 0 (x - 10)

    else
        x


loopFn : Int -> Fn
loopFn n x =
    if n <= 0 then
        other x

    else
        loopFn (n - 1) (x + 1)


finish : Int -> Int
finish acc =
    if acc > 100 then
        countDown 1 (acc - 100)

    else
        acc


countDown : Int -> Int -> Int
countDown n acc =
    if n <= 0 then
        finish acc

    else
        countDown (n - 1) (acc + n)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
