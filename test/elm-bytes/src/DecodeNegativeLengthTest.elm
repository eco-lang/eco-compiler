module DecodeNegativeLengthTest exposing (main)

{-| Bytes.Decode.bytes given a negative length fails the decode, giving `Nothing`.

Each case reads a signed length from the input and passes it to `bytes`:

  - `neg8`: a signed 8-bit 0xFF, which is -1, so the decode is `Nothing`.
  - `neg32`: a big-endian signed 32-bit 0xFFFFFFFF, which is -1, so the decode
    is `Nothing`.
  - `control`: a signed 8-bit length of 1 followed by one byte, so `bytes 1`
    succeeds and the width of the result, `Just 1`, is logged.

-}

-- CHECK: neg8 bytes: Nothing
-- CHECK: neg32 bytes: Nothing
-- CHECK: control bytes: Just 1

import Bytes
import Bytes.Decode as D
import Bytes.Encode as E


bs : List Int -> Bytes.Bytes
bs xs =
    E.encode (E.sequence (List.map E.unsignedInt8 xs))


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        Debug.log "neg8 bytes" (D.decode (D.signedInt8 |> D.andThen D.bytes |> D.map Bytes.width) (bs [ 0xFF, 1, 2, 3 ]))

                    _ =
                        Debug.log "neg32 bytes" (D.decode (D.signedInt32 Bytes.BE |> D.andThen D.bytes |> D.map Bytes.width) (bs [ 0xFF, 0xFF, 0xFF, 0xFF, 1, 2 ]))

                    _ =
                        Debug.log "control bytes" (D.decode (D.signedInt8 |> D.andThen D.bytes |> D.map Bytes.width) (bs [ 1, 9 ]))
                in
                ( (), Cmd.none )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
