module ArrayIndexedMapFloatAddIndexTest exposing (main)

{-| `Array.indexedMap` on `Array Float`. Reaches `JsArray.indexedMap`, which
    re-boxes each unboxed element as `ElmInt` before the mapper.
-}

-- CHECK: result: [10, 21, 32]
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        arr =
            Array.fromList [ 10.0, 20.0, 30.0 ]

        result =
            Array.toList (Array.indexedMap (\i x -> x + toFloat i) arr)

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == [ 10.0, 21.0, 32.0 ])
    in
    text "done"
