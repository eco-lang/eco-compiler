module DecodeAndThenTest exposing (main)

{-| Test Bytes.Decode.andThen for sequential decoding.
-}

-- CHECK: DecodeAndThenTest: "Hi"

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


main =
    let
        -- Encode: length (1 byte) followed by string
        bytes =
            E.encode
                (E.sequence
                    [ E.unsignedInt8 2
                    , E.string "Hi"
                    ]
                )

        -- Decode length, then decode that many chars
        decoder =
            D.unsignedInt8
                |> D.andThen (\len -> D.string len)

        result =
            D.decode decoder bytes
                |> Maybe.withDefault "FAIL"

        _ =
            Debug.log "DecodeAndThenTest" result
    in
    text result
