module DecisionTreeAdvancedDeepNestingWithFallbackTest exposing (..)

{-| A `case` on a pair of pairs whose first branch matches all-zero literals and
whose second binds the first and last numbers falls through to the second branch.

`extract ( ( 1, 2 ), ( 3, 4 ) )` does not match `( ( 0, 0 ), ( 0, 0 ) )`, so it
returns `a + d` = 1 + 4 = 5.

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
