module Utf8Bytes exposing (bench)

{-| UTF-8 through `elm/bytes`: build a string of `n` code points mixing ASCII and two- and
three-byte characters, encode it with `Encode.string`, and decode it back with `Decode.string`.
(No four-byte characters: on eco's native backend a `Char` cannot hold a code point above
U+FFFF; see `UnicodeString`.) eco never fuses `Decode.string` (it allocates a string of a
run-time length), so this prices the general string path in both directions.

Checked at every size against the code points: `Encode.getStringWidth` and the buffer's width
must equal the UTF-8 length computed from them (1 to 3 bytes each), and decoding must give back
the same string.

-}

import Bytes
import Bytes.Decode as Decode
import Bytes.Encode as Encode


pool : List Int
pool =
    [ 0x61, 0x62, 0x63, 0x20, 0x7A, 0xE9, 0x0436, 0x05D0, 0x4E2D, 0x6587, 0x20AC, 0x00DF, 0xFB01 ]


poolSize : Int
poolSize =
    List.length pool


utf8Width : Int -> Int
utf8Width cp =
    if cp < 0x80 then
        1

    else if cp < 0x0800 then
        2

    else if cp < 0x00010000 then
        3

    else
        4


codePoints : Int -> List Int
codePoints n =
    List.map (\i -> Maybe.withDefault 0x61 (List.head (List.drop (modBy poolSize (i * 7919 + i // 13)) pool))) (List.range 0 (n - 1))


bench : Int -> Bool
bench n =
    let
        points =
            codePoints n

        text =
            String.fromList (List.map Char.fromCode points)

        width =
            List.sum (List.map utf8Width points)

        bytes =
            Encode.encode (Encode.string text)
    in
    Encode.getStringWidth text
        == width
        && Bytes.width bytes
        == width
        && Decode.decode (Decode.string width) bytes
        == Just text
