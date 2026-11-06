module CovPreMonoCheapLetChainBeforeAPartialApplicationTest exposing (..)

{-| Functions that return a partial application of `add` after a chain of `let` bindings (a
constructor, records and a record update, a `Float`, a `Char`, a tuple pattern) or a local
recursive loop.

`mk 1` returns `add 2` (the `Green` branch), so `mk 1 2` is `4`; `loop 3` returns `add 6`
(`3 + 2 + 1`), so `loop 3 4` is `10`. The sum is `14`.

## eco

One of the pre-monomorphization coverage cases of compiler/tests/SourceIR/CovPreMonoCases.elm, turned into a program with a `main` that logs `testValue`; the CHECK line is what Elm 0.19.1 prints for it.

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
