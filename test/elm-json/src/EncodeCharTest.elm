module EncodeCharTest exposing (main)

{-| `Json.wrap_Char` is the deliberately-rare path: Json.Encode has no
    public Char encoder, so this variant is reachable only through
    polymorphic helpers. The C++ implementation encodes `Char` as the
    integer code point.

    This test instantiates a polymorphic wrapper at `Char` indirectly via
    `Json.Encode.list` — the element encoder is `Encode.int` composed with
    `Char.toCode`, which is the natural way an Elm program would encode a
    list of chars to JSON. Coverage of `wrap_Char` from this test is a
    side effect of any unrelated polymorphic Char path that may exist; the
    test mainly documents the chosen "Char as integer code point"
    convention via `Char.toCode`.
-}

-- CHECK: char_codes: "[97,98,99]"


import Char
import Html exposing (text)
import Json.Encode as Encode


main =
    let
        chars : List Char
        chars =
            [ 'a', 'b', 'c' ]

        encoded =
            Encode.list (\c -> Encode.int (Char.toCode c)) chars

        _ =
            Debug.log "char_codes" (Encode.encode 0 encoded)
    in
    text "done"
