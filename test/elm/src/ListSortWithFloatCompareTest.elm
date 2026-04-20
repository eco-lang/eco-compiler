module ListSortWithFloatCompareTest exposing (main)

{-| `List.sortWith compare` on `List Float`. Hits `List.sortWith`, which
    re-boxes both operands as `ElmInt` before calling the comparator.
-}

-- CHECK: result: [1, 2, 3]
-- CHECK: match: True

import Html exposing (text)


main =
    let
        result =
            List.sortWith compare [ 3.0, 1.0, 2.0 ]

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == [ 1.0, 2.0, 3.0 ])
    in
    text "done"
