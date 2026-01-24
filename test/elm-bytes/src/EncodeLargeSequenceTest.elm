module EncodeLargeSequenceTest exposing (main)

{-| Test encoding a large sequence.
-}

-- CHECK: EncodeLargeSequenceTest: 100

import Bytes exposing (Bytes)
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        -- Create 100 bytes
        encoders =
            List.repeat 100 (E.unsignedInt8 0)

        bytes =
            E.encode (E.sequence encoders)

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeLargeSequenceTest" result
    in
    text (String.fromInt result)
