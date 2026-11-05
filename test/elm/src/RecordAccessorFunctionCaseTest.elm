module RecordAccessorFunctionCaseTest exposing (..)

{-| Accessor function.

From `SourceIR.RecordCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 1

import Basics exposing (..)
import List exposing (..)
import Html


testFn =
    .x


testValue =
    testFn { x = 1 }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
