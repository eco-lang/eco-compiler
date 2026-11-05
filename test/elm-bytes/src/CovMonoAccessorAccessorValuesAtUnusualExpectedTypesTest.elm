module CovMonoAccessorAccessorValuesAtUnusualExpectedTypesTest exposing (..)

{-| accessor values at unusual expected types.

From `SourceIR.CovMonoAccessorCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 8

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


type alias Ops =
    { f : Int -> Int, h : Int -> Int }


testValue : Int
testValue =
    call2 .f + pass .g + pick True .h + pick False .f


pick : Bool -> (Ops -> Int -> Int) -> Int
pick c other =
    let
        r =
            if c then
                { a = .f }

            else
                { a = other }
    in
    r.a ops 2


pass : ({ g : a -> a } -> a -> a) -> Int
pass _ =
    0


call2 : (Ops -> Int -> Int) -> Int
call2 k =
    k ops 1


ops : Ops
ops =
    { f = \x -> x + 1, h = \x -> x * 2 }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
