module ArrayUnsafeGetCharElementTest exposing (main)

{-| `Array.get 1 arr` on an `Array Char`. Reaches `JsArray.unsafeGet` on
    an unboxed `u16` Char slot.
-}

-- CHECK: result: Just 'y'
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        arr =
            Array.fromList [ 'x', 'y' ]

        result =
            Array.get 1 arr

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == Just 'y')
    in
    text "done"
