module ListMap4FloatAggregateTest exposing (main)

{-| `List.map4` on four `List Float`s. Same bug surface — four unboxed heads
    re-boxed as `ElmInt` before the mapper receives them.
-}

-- CHECK: result: [6]
-- CHECK: match: True

import Html exposing (text)


main =
    let
        result =
            List.map4 (\a b c d -> a + b - c - d) [ 10.0 ] [ 1.0 ] [ 2.0 ] [ 3.0 ]

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == [ 6.0 ])
    in
    text "done"
