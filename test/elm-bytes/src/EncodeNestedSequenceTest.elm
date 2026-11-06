module EncodeNestedSequenceTest exposing (main)

{-| A `Bytes.Encode.sequence` that contains other sequences produces the sum of all their widths.

The outer sequence holds a two-byte inner sequence, a big-endian `unsignedInt16`, and a
second two-byte inner sequence, so the logged width is 2 + 2 + 2 = 6.
-}

-- CHECK: EncodeNestedSequenceTest: 6

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        inner1 =
            E.sequence [ E.unsignedInt8 1, E.unsignedInt8 2 ]

        inner2 =
            E.sequence [ E.unsignedInt8 3, E.unsignedInt8 4 ]

        bytes =
            E.encode
                (E.sequence
                    [ inner1
                    , E.unsignedInt16 BE 0x0506
                    , inner2
                    ]
                )

        result =
            Bytes.width bytes

        _ =
            Debug.log "EncodeNestedSequenceTest" result
    in
    text (String.fromInt result)
