module ListSortByFloatIdentityTest exposing (main)

{-| `List.sortBy identity` on `List Float`. Hits `List.sortBy`, which
    re-boxes each unboxed element as `ElmInt` before calling the key
    function.
-}

-- CHECK: result: [1, 2, 3]
-- CHECK: match: True

import Html exposing (text)


main =
    let
        result =
            List.sortBy identity [ 3.0, 1.0, 2.0 ]

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == [ 1.0, 2.0, 3.0 ])
    in
    text "done"
