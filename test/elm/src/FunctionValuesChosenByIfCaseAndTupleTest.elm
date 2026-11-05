module FunctionValuesChosenByIfCaseAndTupleTest exposing (..)

{-| Function values chosen by `if`, `case` and a returned tuple, then called.

From `Compiler.Monomorphize.Solver.ChosenFunctionValuesTest`, an elm-test unit test, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 38

import Basics exposing (..)
import Bitwise exposing (..)
import Bytes exposing (..)
import Bytes.Decode exposing (..)
import Bytes.Encode exposing (..)
import Char exposing (..)
import Html exposing (text)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Tuple exposing (..)


testValue : Int
testValue =
    let
        ( p, q ) =
            chooseC 1 (\x -> x + 1) (\x -> x * 2)
    in
    chooseA 3 (\x -> x + 1) (\x -> x - 1) 4 + chooseA 12 negate abs 5 + chooseB 2 (\x -> x * 3) 6 + chooseB 1 (chooseA 7 p q) 7 + p 1 + q 2


chooseC : Int -> (Int -> Int) -> (Int -> Int) -> ( Int -> Int, Int -> Int )
chooseC n f g =
    if n > 0 then
        ( f, g )

    else
        ( g, f )


chooseB : Int -> (Int -> Int) -> Int -> Int
chooseB n f =
    case n of
        0 ->
            f

        1 ->
            identity f

        2 ->
            let
                k =
                    f
            in
            k

        _ ->
            \x -> f x + 1


chooseA : Int -> (Int -> Int) -> (Int -> Int) -> Int -> Int
chooseA n f g =
    if n > 10 then
        f

    else if n > 5 then
        g

    else if n > 2 then
        f

    else
        let
            h =
                f
        in
        h


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
