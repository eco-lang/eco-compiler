module AccessorPlaceholderAccessorOfAFunctionFieldPassedInTailCallsTest exposing (..)

{-| Accessor of a function field passed in tail calls.

From `SourceIR.AccessorPlaceholderCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 8

import Basics exposing (..)
import Char exposing (Char)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple
import Html


type alias Ops =
    { f : Int -> Int }


testValue : Int
testValue =
    loop .f 3 + loop (\o x -> o.f x) 2 + wrapper 2 + loop2 (\x -> x + 1) .f 2


loop2 : (Int -> Int) -> (Ops -> Int -> Int) -> Int -> Int
loop2 k h n =
    if n <= 0 then
        k (h { f = \x -> x } 1)

    else
        loop2 k .f (n - 1)


wrapper : Int -> Int
wrapper n =
    let
        z =
            n + 1

        inner g k =
            let
                p =
                    add3 k
            in
            if k <= 0 then
                g { f = \x -> x * 2 } 1

            else
                inner .f (p 1 -2)
    in
    inner .f z


add3 : Int -> Int -> Int -> Int
add3 a b c =
    a + b + c


loop : (Ops -> Int -> Int) -> Int -> Int
loop g n =
    if n <= 0 then
        g { f = \x -> x + 1 } 1

    else
        loop .f (n - 1)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
