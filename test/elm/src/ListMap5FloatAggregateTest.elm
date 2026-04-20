module ListMap5FloatAggregateTest exposing (main)

{-| `List.map5` on five `List Float`s. Same bug surface — five unboxed heads
    re-boxed as `ElmInt` before the mapper.
-}

-- CHECK: result: [15]
-- CHECK: match: True

import Html exposing (text)


main =
    let
        result =
            List.map5 (\a b c d e -> a + b + c + d + e) [ 1.0 ] [ 2.0 ] [ 3.0 ] [ 4.0 ] [ 5.0 ]

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == [ 15.0 ])
    in
    text "done"
