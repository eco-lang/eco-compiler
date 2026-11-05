module HigherOrderReturnLambdaBasedOnConditionTest exposing (..)

{-| Return lambda based on condition.

From `SourceIR.HigherOrderCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 42

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        choose flag =
            if flag then
                \x -> x

            else
                \_ -> 0
    in
    choose Basics.True 42


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
