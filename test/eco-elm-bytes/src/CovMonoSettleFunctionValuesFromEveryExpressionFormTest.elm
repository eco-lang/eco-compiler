module CovMonoSettleFunctionValuesFromEveryExpressionFormTest exposing (..)

{-| Functions of type `Int -> Int` produced by many kinds of expression give the right results when passed to a higher-order function, stored in a record, or collected in a list and folded over.

The function values come from a partial application of `makeAdder` (defined with one parameter, annotated with two), an `if` and a `case` whose branches mix `makeAdder` results with `negate` or a lambda, a nested `let`, a record field, an inline lambda, and `negate` passed through a second higher-order function `pass`. `run` applies each one through `apply` and also folds the list `all` of five such functions over `0`. `testValue` is `run 0` (34) plus `run 1` (49), so both branches of each `if` and `case` are used.

The expected value is what Elm 0.19.1 prints for this program.

## eco

This is the end-to-end form of the case "function values from every expression form" in compiler/tests/SourceIR/CovMonoSettleCases.elm.

Each function value reaches the one higher-order `apply`, and the list `all`, so the solver (compiler/src/Compiler/Monomorphize/Solver/LssInfer.elm) must join the lambda sets of a partial application, an `if`, a `case`, a `let`, a lambda literal, a parameter and a record field into the types demanded of `apply`'s specializations.

-}

-- CHECK: testValue: 83

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
    run 0 + run 1


run : Int -> Int
run c =
    let
        viaLet =
            let
                h =
                    makeAdder 2
            in
            h

        rec =
            { fn = makeAdder 3 }

        all =
            [ makeAdder 1
            , if c > 0 then
                makeAdder 4

              else
                negate
            , case c of
                0 ->
                    makeAdder 5

                _ ->
                    \z -> z * 2
            , viaLet
            , rec.fn
            ]
    in
    apply (makeAdder 1) 2
        + apply
            (if c > 0 then
                makeAdder 4

             else
                negate
            )
            3
        + apply
            (case c of
                0 ->
                    makeAdder 5

                _ ->
                    \z -> z * 2
            )
            4
        + apply viaLet 5
        + apply (\w -> w - 1) 6
        + pass negate 7
        + apply rec.fn 8
        + List.foldl (\f acc -> f acc) 0 all


pass : (Int -> Int) -> Int -> Int
pass g y =
    apply g y


makeAdder : Int -> Int -> Int
makeAdder n =
    \x -> x + n


apply : (Int -> Int) -> Int -> Int
apply f x =
    f x


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
