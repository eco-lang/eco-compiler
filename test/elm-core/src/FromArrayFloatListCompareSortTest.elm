module FromArrayFloatListCompareSortTest exposing (main)

{-| Array.fromList → Array.toList → List.sort on Float. Exercises the full
    chain: Array build, JsArray foldr round-trip, then `List.sort` (which
    dispatches to `Elm_Kernel_List_sortWith`). Hits both the JsArray foldr
    path and the List sort re-box-as-Int path with Float content.
-}

-- CHECK: sorted: [1, 2, 3]
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
