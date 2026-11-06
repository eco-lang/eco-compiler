module CovPreMonoEtaExpandedBodyHoldingEveryLeafKindTest exposing (..)

{-| A function with one declared parameter whose result type is a function alias, returning a
local function whose body binds a local loop, a `Char`, a `Float`, a constructor and a
constructor with an argument, then matches on a tuple of them.

`mk 3 4` takes the `( Green, Box 4 )` branch: `go 4 3` is `4 + 3 + 2 + 1 = 10`, plus
`floor 1.5 = 1`, giving `11`.

## eco

One of the pre-monomorphization coverage cases of compiler/tests/SourceIR/CovPreMonoCases.elm, turned into a program with a `main` that logs `testValue`; the CHECK line is what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 11

import Basics exposing (..)
import List exposing (..)
import Html


type Box
    = Box Int


type Color
    = Red
    | Green
    | Blue


type alias Fn =
    Int -> Int


testValue : Int
testValue =
    mk 3 4


mk : Int -> Fn
mk n =
    let
        h z =
            let
                go acc k =
                    if k <= 0 then
                        acc

                    else
                        go (acc + k) (k - 1)

                c =
                    'x'

                f =
                    1.5

                col =
                    Green

                b =
                    Box z
            in
            case ( col, b ) of
                ( Green, Box v ) ->
                    go v n + floor f

                _ ->
                    if c == 'x' then
                        0

                    else
                        1
    in
    h


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
