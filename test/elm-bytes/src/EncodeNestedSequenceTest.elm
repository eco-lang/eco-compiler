module EncodeNestedSequenceTest exposing (main)

{-| Test nested sequence encoding.
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
