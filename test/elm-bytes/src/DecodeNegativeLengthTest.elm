module DecodeNegativeLengthTest exposing (main)

{-| Bytes.Decode.bytes with a negative length read from the input. In Elm on JS, `bytes n` with
n < 0 throws a RangeError (`new DataView(buffer, offset, -1)`), so the decode is Nothing. Eco's
kernel path agrees; this pins it (cpp-review-bugs.md "elm\_utf8\_decode has no bounds check": the
fused bf.require would accept a negative length, test/bf-codegen/bf\_require\_negative.mlir, but no
decode of a read length fuses today).
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
