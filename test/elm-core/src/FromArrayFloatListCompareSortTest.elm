module FromArrayFloatListCompareSortTest exposing (main)

{-| `List.sort` orders a `List Float` that came out of an `Array` via `Array.fromList` and `Array.toList`.

`[3.0, 1.0, 2.0]` sorts to `[1.0, 2.0, 3.0]`; the test logs the sorted list and compares it with the expected one.
-}

-- CHECK: sorted: [1,2,3]
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        arr = Array.fromList [3.0, 1.0, 2.0]
        sorted = List.sort (Array.toList arr)
        _ = Debug.log "sorted" sorted
        _ = Debug.log "match" (sorted == [1.0, 2.0, 3.0])
    in
    text "done"
