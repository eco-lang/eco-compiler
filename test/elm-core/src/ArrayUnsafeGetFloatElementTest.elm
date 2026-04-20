module ArrayUnsafeGetFloatElementTest exposing (main)

{-| `Array.get 0 arr` on an `Array Float`. Reaches `JsArray.unsafeGet`,
    which re-boxes the unboxed slot as `ElmInt` — the resulting `Maybe Float`
    should still equal `Just 1.5`.
-}

-- CHECK: result: Just 1.5
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        arr =
            Array.fromList [ 1.5, 2.5 ]

        result =
            Array.get 0 arr

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == Just 1.5)
    in
    text "done"
