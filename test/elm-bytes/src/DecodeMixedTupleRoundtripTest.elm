module DecodeMixedTupleRoundtripTest exposing (main)

{-| A `( Int, String )` tuple survives a round trip through Bytes.Encode and
Bytes.Decode.

The encoder writes the `Int` as a big-endian signed 32-bit value, then the
string's UTF-8 width as a big-endian unsigned 16-bit value, then the string. The
decoder reads the three back with nested `andThen` calls and rebuilds the tuple.
The test logs `True` when the decoded tuple equals the original
`( 0x01020304, "hello" )`, and `False` if it differs or the decode fails.

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
