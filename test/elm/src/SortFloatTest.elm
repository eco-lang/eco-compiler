module SortFloatTest exposing (main)

{-| `List.sort`, `List.sortBy`, `List.sortWith` on `List Float`.

    These functions dispatch to the `Elm_Kernel_List_sortWith` / `sortBy`
    kernels, which currently re-box each unboxed list head as an `Elm Int`
    before handing it to the user comparator/key function. For a `List Float`
    that should pass the float through unchanged, so whole-number inputs
    must sort to themselves and non-integer inputs must be preserved.
-}

-- CHECK: sort: [1, 2, 3, 4]
-- CHECK: sortBy: [1.5, 2.5, 3]
-- CHECK: sortWith: [1, 2.5, 3]
-- CHECK: reverseSort: [3, 2, 1]
-- CHECK: sortByKey: [1.5, 2.5, 3, 4]

import Html exposing (text)


main =
    let
        _ = Debug.log "sort" (List.sort [3.0, 1.0, 2.0, 4.0])
        _ = Debug.log "sortBy" (List.sortBy identity [3.0, 1.5, 2.5])
        _ = Debug.log "sortWith" (List.sortWith compare [2.5, 1.0, 3.0])
        _ = Debug.log "reverseSort" (List.sortWith (\a b -> compare b a) [1.0, 2.0, 3.0])
        _ = Debug.log "sortByKey" (List.sortBy (\x -> x) [2.5, 4.0, 1.5, 3.0])
    in
    text "done"
