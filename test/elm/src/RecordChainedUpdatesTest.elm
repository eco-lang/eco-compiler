module RecordChainedUpdatesTest exposing (..)

{-| Chained updates.

From `SourceIR.RecordCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: { x = 10, y = 20 }

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        r =
            { x = 1, y = 2 }

        r2 =
            { r | x = 10 }
    in
    { r2 | y = 20 }


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
