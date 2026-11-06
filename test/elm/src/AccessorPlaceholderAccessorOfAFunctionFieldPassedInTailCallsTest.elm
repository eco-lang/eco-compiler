module AccessorPlaceholderAccessorOfAFunctionFieldPassedInTailCallsTest exposing (..)

{-| Record accessors for function-typed fields can be passed as arguments of tail calls, at top level and in an unannotated let-bound function.

`testValue` adds four results, each of which is 2. `loop` and `loop2` are
top-level functions that pass `.f` to themselves, `loop2` with a fixed first
argument. `inner`, inside `wrapper`, passes `.f` to itself and computes its
next counter with a partially applied `add3`.

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
