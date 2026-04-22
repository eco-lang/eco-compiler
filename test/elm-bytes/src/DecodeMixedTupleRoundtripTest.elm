module DecodeMixedTupleRoundtripTest exposing (main)

{-| Small-scale test that a `(Int, String)` tuple — an unboxed primitive
    field packed next to a heap-allocated String — survives a bytes
    encode/decode roundtrip.

    The tuple shape matches the loop-state shape used by
    `Utils.Bytes.Decode.list` (`(Int, List a)`). If the closure unboxed
    bitmap is miscomputed so that the primitive slot is scanned as a boxed
    pointer (or vice versa), the returned tuple will hold corrupted values
    and the comparison below will fail — all visible without any minor GC
    firing.
-}

-- CHECK: DecodeMixedTupleRoundtripTest: True

import Bytes exposing (Endianness(..))
import Bytes.Decode as D
import Bytes.Encode as E
import Html exposing (text)


original : ( Int, String )
original =
    ( 0x01020304, "hello" )


encoder : ( Int, String ) -> E.Encoder
encoder ( n, s ) =
    let
        width =
            E.getStringWidth s
    in
    E.sequence
        [ E.signedInt32 BE n
        , E.unsignedInt16 BE width
        , E.string s
        ]


decoder : D.Decoder ( Int, String )
decoder =
    D.signedInt32 BE
        |> D.andThen
            (\n ->
                D.unsignedInt16 BE
                    |> D.andThen
                        (\width ->
                            D.string width
                                |> D.map (\s -> ( n, s ))
                        )
            )


main =
    let
        decoded =
            D.decode decoder (E.encode (encoder original))

        ok =
            case decoded of
                Just v ->
                    v == original

                Nothing ->
                    False

        _ =
            Debug.log "DecodeMixedTupleRoundtripTest" ok
    in
    text
        (if ok then
            "True"

         else
            "False"
        )
