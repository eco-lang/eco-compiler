module CovPreMonoCheapLetChainBeforeAPartialApplicationTest exposing (..)

{-| cheap let chain before a partial application.

From `SourceIR.CovPreMonoCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 14

import Basics exposing (..)
import List exposing (..)
import Html


type Color
    = Red
    | Green


type alias Fn =
    Int -> Int


testValue : Int
testValue =
    mk 1 2 + loop 3 4


loop : Int -> Fn
loop n =
    let
        go acc k =
            case k of
                0 ->
                    acc

                _ ->
                    go (acc + k) (k - 1)
    in
    add (go 0 n)


mk : Int -> Fn
mk n =
    let
        col =
            Green

        r =
            { a = n, b = 2 }

        r2 =
            { r | a = 3 }

        v =
            r2.b

        fl =
            1.5

        ch =
            'c'

        ( p, q ) =
            ( n, v )
    in
    case col of
        Green ->
            add q

        Red ->
            add p


add : Int -> Int -> Int
add a b =
    a + b


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
