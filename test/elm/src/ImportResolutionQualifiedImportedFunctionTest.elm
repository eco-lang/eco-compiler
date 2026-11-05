module ImportResolutionQualifiedImportedFunctionTest exposing (..)

{-| qualified imported function.

From `SourceIR.ImportResolutionCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: [-1,-2]

import Basics exposing (..)
import List exposing (..)
import Html


xs =
    List.map negate [ 1, 2 ]


testValue =
    xs


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
