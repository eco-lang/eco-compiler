module ListRangeTest exposing (main)

{-| `List.range` lists the integers from its first argument to its second inclusive, and gives an empty list when the first is greater.

`List.range 1 5` gives 1 to 5, `List.range 5 1` gives `[]`, and `List.range 3 3` gives `[3]`.

-}

-- CHECK: range1: [1,2,3,4,5]
-- CHECK: range_empty: []
-- CHECK: range_single: [3]

import Html exposing (text)

main =
    let
        _ = Debug.log "range1" (List.range 1 5)
        _ = Debug.log "range_empty" (List.range 5 1)
        _ = Debug.log "range_single" (List.range 3 3)
    in
    text "done"
