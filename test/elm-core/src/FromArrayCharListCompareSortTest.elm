module FromArrayCharListCompareSortTest exposing (main)

{-| Array.fromList → Array.toList → List.sort on Char. Char equivalent of
    `FromArrayFloatListCompareSortTest`; exercises the JsArray round-trip
    plus the List sort re-box path with Char content.
-}

-- CHECK: sorted: ['a', 'b', 'c']
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
