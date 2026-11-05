module EdgeCaseAllDestructPatternsTest exposing (..)

{-| All destruct patterns.

From `SourceIR.EdgeCaseCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: [1,3,4,6]

import Basics exposing (..)
import List exposing (..)
import Html


testValue =
    let
        ( a, b ) =
            ( 1, 2 )

        { x } =
            { x = 3 }

        ( h, t ) =
            case [ 4, 5 ] of
                y :: ys ->
                    ( y, ys )

                [] ->
                    ( 0, [] )

        (v as w) =
            6
    in
    [ a, x, h, v ]


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
