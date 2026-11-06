module ListSortWithFloatCompareTest exposing (main)

{-| Checks `List.sortWith compare` on a `List Float`, by printing the sorted list
and comparing it with `[1.0, 2.0, 3.0]`.
-}

-- CHECK: result: [1,2,3]
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
