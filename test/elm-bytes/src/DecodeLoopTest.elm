module DecodeLoopTest exposing (main)

{-| `Bytes.Decode.loop` repeats a step decoder until it returns `Done`: three steps over the bytes 1, 2 and 3 sum them to 6.

The module declares its own `Step` type with `Loop` and `Done` constructors, which nothing uses; the step function returns the qualified `D.Loop` and `D.Done` from `Bytes.Decode`.
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
        bytes =
            E.encode
                (E.sequence
                    [ E.unsignedInt8 1
                    , E.unsignedInt8 2
                    , E.unsignedInt8 3
                    ]
                )

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
