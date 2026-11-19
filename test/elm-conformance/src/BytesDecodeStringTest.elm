module BytesDecodeStringTest exposing (main)

{-| `Bytes.Decode.string` reads back what `Bytes.Encode.string` wrote, for characters of every UTF-8
length: 1 byte (`a`), 2 (`é`), 3 (`€`) and 4 (`𝄞`, outside the Basic Multilingual Plane, so two UTF-16
units), mixed, empty, and in a String of 10,000 characters.

On JavaScript, `_Bytes_read_string` is eco's kernel override (compiler/kernel-overrides/
BytesReadString.js, plans/js-kernel-overrides.md), which builds the String from an array instead of
by `+=`; this pins that it decodes exactly as elm/bytes does. Each line logs the encoded width, the
decoded String's code points, and whether it equals the original. Only ASCII is printed, as the
recorded expectations require.
-}

-- CHECK: a: (1,[97],True)
-- CHECK: e-acute: (2,[233],True)
-- CHECK: euro: (3,[8364],True)
-- CHECK: g-clef: (4,[119070],True)
-- CHECK: mixed: (10,[97,233,8364,119070],True)
-- CHECK: empty: (0,[],True)
-- CHECK: long: (25000,10000,True)

import Bytes
import Bytes.Decode as Decode
import Bytes.Encode as Encode


roundTrip : String -> ( Int, Maybe String )
roundTrip s =
    let
        bytes =
            Encode.encode (Encode.string s)
    in
    ( Bytes.width bytes, Decode.decode (Decode.string (Bytes.width bytes)) bytes )


report : String -> String -> ()
report label s =
    let
        ( width, decoded ) =
            roundTrip s

        _ =
            Debug.log label
                ( width
                , decoded |> Maybe.map (String.toList >> List.map Char.toCode) |> Maybe.withDefault [ -1 ]
                , decoded == Just s
                )
    in
    ()


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                let
                    _ =
                        List.map (\( label, s ) -> report label s)
                            [ ( "a", "a" )
                            , ( "e-acute", "é" )
                            , ( "euro", "€" )
                            , ( "g-clef", "𝄞" )
                            , ( "mixed", "aé€𝄞" )
                            , ( "empty", "" )
                            ]

                    long =
                        String.repeat 2500 "aé€𝄞"

                    ( longWidth, longDecoded ) =
                        roundTrip long

                    _ =
                        Debug.log "long"
                            ( longWidth
                            , longDecoded |> Maybe.map (String.toList >> List.length) |> Maybe.withDefault -1
                            , longDecoded == Just long
                            )
                in
                ( (), Cmd.none )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
