module SortFloatTest exposing (main)

{-| `List.sort`, `List.sortBy` and `List.sortWith` order a `List Float` correctly and keep fractional values intact.

The test checks five results:

  - `List.sort` on whole-number floats.
  - `List.sortBy identity` on a list containing `1.5` and `2.5`.
  - `List.sortWith compare` on a mixed list.
  - `List.sortWith` with the comparison flipped, giving descending order.
  - `List.sortBy` with an anonymous identity function.

`Debug.log` prints a whole-number `Float` without a decimal point, so `3.0`
appears as `3`.

-}

-- CHECK: sort: [1,2,3,4]
-- CHECK: sortBy: [1.5,2.5,3]
-- CHECK: sortWith: [1,2.5,3]
-- CHECK: reverseSort: [3,2,1]
-- CHECK: sortByKey: [1.5,2.5,3,4]

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
