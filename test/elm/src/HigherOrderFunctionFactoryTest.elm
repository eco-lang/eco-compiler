module HigherOrderFunctionFactoryTest exposing (..)

{-| Function factory.

From `SourceIR.HigherOrderCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: (5,2)

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        makeTransform factor =
            \x -> ( x, factor )

        double =
            makeTransform 2
    in
    double 5


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
