module MonoCompoundNestedLetWithShadowingTest exposing (..)

{-| nested let with shadowing.

From `SourceIR.MonoCompoundCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 9

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


testValue : Int
testValue =
    let
        x =
            1
    in
    let
        y =
            x + 2
    in
    let
        z =
            y * 3
    in
    z


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
