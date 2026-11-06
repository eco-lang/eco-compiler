module HigherOrderFunctionChosenByIfTest exposing (..)

{-| A higher-order function chosen by an `if` and then applied to a function argument gives the right result.

`useH` chooses between two functions of type `(Int -> Int) -> Int`. With
`True` it picks `\f -> f 1` and applies it to `\x -> x * 2`, giving 2.

-}

-- CHECK: testValue: 2

import Basics exposing (..)
import Char exposing (..)
import Html exposing (text)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)


useH : Bool -> ((Int -> Int) -> Int) -> ((Int -> Int) -> Int) -> (Int -> Int) -> Int
useH b hof1 hof2 k =
    let
        h =
            if b then
                hof1

            else
                hof2
    in
    h k


testValue : Int
testValue =
    useH Basics.True (\f -> f 1) (\g -> g 2) (\x -> x * 2)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
