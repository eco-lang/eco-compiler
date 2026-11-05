module DecisionTreeAdvancedDeepNestingWithFallbackTest exposing (..)

{-| Deep nesting with fallback.

From `SourceIR.DecisionTreeAdvancedCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 5

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


extract : ( ( Int, Int ), ( Int, Int ) ) -> Int
extract t =
    case t of
        ( ( 0, 0 ), ( 0, 0 ) ) ->
            0

        ( ( a, _ ), ( _, d ) ) ->
            a + d


testValue : Int
testValue =
    extract ( ( 1, 2 ), ( 3, 4 ) )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
