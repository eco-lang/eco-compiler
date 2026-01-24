module DecodeLoopTest exposing (main)

{-| Test Bytes.Decode.loop for iterative decoding.
-}

-- CHECK: DecodeLoopTest: 6

import Bytes exposing (Bytes)
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


type Step state a
    = Loop state
    | Done a


main =
    let
        -- Encode 3 bytes
        bytes =
            E.encode
                (E.sequence
                    [ E.unsignedInt8 1
                    , E.unsignedInt8 2
                    , E.unsignedInt8 3
                    ]
                )

        -- Sum up 3 bytes
        step ( count, sum ) =
            if count <= 0 then
                D.succeed (D.Done sum)

            else
                D.unsignedInt8
                    |> D.map (\n -> D.Loop ( count - 1, sum + n ))

        decoder =
            D.loop ( 3, 0 ) step

        result =
            D.decode decoder bytes
                |> Maybe.withDefault -1

        _ =
            Debug.log "DecodeLoopTest" result
    in
    text (String.fromInt result)
