module DecodeArrayShapeTest exposing (main)

{-| The value produced by `Json.Decode.array` must have the same runtime
    shape as an `Array` built with `Array.fromList` or `Array.initialize`,
    so that further Array operations (`length`, `get`, `==`) work on it.
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
