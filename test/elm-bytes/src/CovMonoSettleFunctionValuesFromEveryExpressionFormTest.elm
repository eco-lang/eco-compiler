module CovMonoSettleFunctionValuesFromEveryExpressionFormTest exposing (..)

{-| function values from every expression form.

From `SourceIR.CovMonoSettleCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

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
