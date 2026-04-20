module ListMap2FloatSumTest exposing (main)

{-| `List.map2 (+)` on two `List Float`s. Hits the `List.map2` kernel, which
    re-boxes each unboxed list head as `ElmInt` before calling `(+)` — the
    float values should nonetheless survive to the mapper and the sums should
    match IEEE addition.
-}

-- CHECK: result: [12, 23]
-- CHECK: match: True

import Html exposing (text)


main =
    let
        result =
            List.map2 (+) [ 1.5, 2.5 ] [ 10.5, 20.5 ]

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == [ 12.0, 23.0 ])
    in
    text "done"
