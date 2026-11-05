module FunctionUnannotatedCompappendTest exposing (..)

{-| unannotated compappend.

From `SourceIR.FunctionCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 0

import Basics exposing (..)
import List exposing (..)
import Html


zsortcat x y =
    if x < y then
        x ++ y

    else
        y ++ x


testValue =
    0


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
