module EncodeSequenceTest exposing (main)

{-| Test Bytes.Encode.sequence combining multiple encoders.
-}

-- CHECK: EncodeSequenceTest: 7

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        bytes =
            E.encode
                (E.sequence
                    [ E.unsignedInt8 1
                    , E.unsignedInt16 BE 2
                    , E.unsignedInt32 BE 3
                    ]
                )

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeSequenceTest" result
    in
    text (String.fromInt result)
