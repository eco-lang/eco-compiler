module ArrayMapFloatIncrementTest exposing (main)

{-| `Array.map` on `Array Float`. Reaches `JsArray.map`, which re-boxes each
    unboxed slot as `ElmInt` before the mapper — the increment must still
    yield correct Float results.
-}

-- CHECK: result: [2, 3]
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        arr =
            Array.fromList [ 1.5, 2.5 ]

        result =
            Array.toList (Array.map ((+) 0.5) arr)

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == [ 2.0, 3.0 ])
    in
    text "done"
