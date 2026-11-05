module HigherOrderTripleNestedFunctionTest exposing (..)

{-| Triple nested function.

From `SourceIR.HigherOrderCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: [1,2,3]

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        triple a =
            \b -> \c -> [ a, b, c ]
    in
    triple 1 2 3


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
