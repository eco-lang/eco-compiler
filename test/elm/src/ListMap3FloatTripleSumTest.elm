module ListMap3FloatTripleSumTest exposing (main)

{-| `List.map3` on three `List Float`s. Same bug surface as `List.map2` but
    with three inputs re-boxed as `ElmInt`.
-}

-- CHECK: result: [111, 222]
-- CHECK: match: True

import Html exposing (text)


main =
    let
        result =
            List.map3 (\a b c -> a + b + c) [ 1.0, 2.0 ] [ 10.0, 20.0 ] [ 100.0, 200.0 ]

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == [ 111.0, 222.0 ])
    in
    text "done"
