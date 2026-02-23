module ListRangeTest exposing (main)

-- CHECK: range1: [1, 2, 3, 4, 5]
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
