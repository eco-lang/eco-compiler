module CovPreMonoConstructorAliasAndSaturatedCallReturningAFunctionTest exposing (..)

{-| constructor alias and saturated call returning a function.

From `SourceIR.CovPreMonoCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 3

import Basics exposing (..)
import List exposing (..)
import Html


type Pair
    = Pair Int Int


type Box
    = Box Int


type alias Fn =
    Int -> Int


testValue : Int
testValue =
    case ( mkBox 2, mkPair 1 2 ) of
        ( Box v, Pair a _ ) ->
            mk v a


mk : Int -> Fn
mk n =
    pick n (add n)


pick : Int -> a -> a
pick _ x =
    x


add : Int -> Int -> Int
add a b =
    a + b


mkPair : Int -> Int -> Pair
mkPair =
    Pair


mkBox : Int -> Box
mkBox =
    Box


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
