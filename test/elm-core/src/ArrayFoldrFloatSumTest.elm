module ArrayFoldrFloatSumTest exposing (main)

{-| `Array.foldr (+) 0.0` on `Array Float`. Reaches `JsArray.foldr`, which
    re-boxes each unboxed slot as `ElmInt` before the fold function.
-}

-- CHECK: result: 7
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        result =
            Array.foldr (+) 0.0 (Array.fromList [ 1.5, 2.5, 3.0 ])

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == 7.0)
    in
    text "done"
