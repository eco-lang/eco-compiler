module DecodeArrayShapeTest exposing (main)

{-| `Json.Decode.array` produces an `Array` that `Array.length`, `Array.get` and `==` treat like
the one it was encoded from.

`Array.fromList [ 10, 20, 30 ]` is encoded with `Json.Encode.array`, decoded back with
`Json.Decode.array Json.Decode.int`, and the result's length, its three elements and its
equality with the original array are logged.
-}

-- CHECK: length: 3
-- CHECK: get0: Just 10
-- CHECK: get1: Just 20
-- CHECK: get2: Just 30
-- CHECK: equalsOriginal: True

import Array
import Html exposing (text)
import Json.Decode as Decode
import Json.Encode as Encode


main =
    let
        original =
            Array.fromList [ 10, 20, 30 ]

        encoded =
            Encode.encode 0 (Encode.array Encode.int original)

        decoded =
            Result.withDefault Array.empty
                (Decode.decodeString (Decode.array Decode.int) encoded)

        _ =
            Debug.log "length" (Array.length decoded)

        _ =
            Debug.log "get0" (Array.get 0 decoded)

        _ =
            Debug.log "get1" (Array.get 1 decoded)

        _ =
            Debug.log "get2" (Array.get 2 decoded)

        _ =
            Debug.log "equalsOriginal" (decoded == original)
    in
    text "done"
