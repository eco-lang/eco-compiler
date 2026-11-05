module HigherOrderFilterLikeFunctionTest exposing (..)

{-| Filter-like function.

From `SourceIR.HigherOrderCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: [1]

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        myFilter pred list =
            case list of
                [] ->
                    []

                h :: t ->
                    if pred h then
                        [ h ]

                    else
                        []
    in
    myFilter (\_ -> Basics.True) [ 1 ]


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
