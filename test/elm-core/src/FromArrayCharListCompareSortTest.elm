module FromArrayCharListCompareSortTest exposing (main)

{-| `List.sort` orders a `List Char` that came out of an `Array` via `Array.fromList` and `Array.toList`.

`['c', 'a', 'b']` sorts to `['a', 'b', 'c']`; the test logs the sorted list and compares it with the expected one.
-}

-- CHECK: sorted: ['a','b','c']
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        arr = Array.fromList ['c', 'a', 'b']
        sorted = List.sort (Array.toList arr)
        _ = Debug.log "sorted" sorted
        _ = Debug.log "match" (sorted == ['a', 'b', 'c'])
    in
    text "done"
