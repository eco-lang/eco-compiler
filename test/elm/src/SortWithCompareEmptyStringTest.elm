module SortWithCompareEmptyStringTest exposing (main)

{-| `List.sortWith compare` on Strings including `""`. `List.sortWith`
does NOT have the F3 bug (passes elements to the user comparator by
encoded HPointer, never resolves), so this should pass today —
regression guard against a fix that disturbs sortWith.
-}

-- CHECK: result: ["", "", "a", "b"]

import Html exposing (text)


main =
    let
        result : List String
        result = List.sortWith compare [ "", "b", "a", "" ]

        _ = Debug.log "result" result
    in
    text "done"
