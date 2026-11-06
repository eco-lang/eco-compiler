module LetMutualRecursionBetweenLocalsTest exposing (..)

{-| Two functions defined in the same `let` call each other.

`f` counts `k` up by one until it exceeds 10, then hands it to `g`; `g` doubles it
and hands it back to `f` until it exceeds 20. From `f 0` the path is 11, then 22,
so `testValue` is 22.

-}

-- CHECK: testValue: 22

import Basics exposing (..)
import Char exposing (Char)
import Html exposing (text)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple


testValue : Int
testValue =
    let
        f k =
            if k > 10 then
                g k

            else
                f (k + 1)

        g k =
            if k > 20 then
                k

            else
                f (k * 2)
    in
    f 0


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
