module EncodeSequenceTest exposing (main)

{-| `Bytes.Encode.sequence` of mixed-width encoders produces the sum of their widths.

The sequence holds an `unsignedInt8`, a big-endian `unsignedInt16` and a big-endian
`unsignedInt32`, so the logged width is 1 + 2 + 4 = 7.
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
