module ArrayUnsafeSetCharOverwriteTest exposing (main)

{-| `Array.set 0 'b' (Array.fromList ['a'])`. Reaches `JsArray.unsafeSet`,
    which writes the new Char via `unboxInt(value)` — the write reads 8
    bytes from a 2-byte slot, so non-zero padding can leak into the stored
    value. The round-trip should still round-trip to `'b'`.
-}

-- CHECK: result: Just 'b'
-- CHECK: match: True

import Array
import Html exposing (text)


main =
    let
        arr1 =
            Array.fromList [ 'a' ]

        arr2 =
            Array.set 0 'b' arr1

        result =
            Array.get 0 arr2

        _ =
            Debug.log "result" result

        _ =
            Debug.log "match" (result == Just 'b')
    in
    text "done"
