module Codec.Utf8Test exposing (suite)

{-| `Codec.Utf8.decodeLossy` replaces each maximal invalid subsequence with U+FFFD, as Node's
`Buffer.toString('utf8')` does; the expected code points were recorded from
`node -e 'Buffer.from([...]).toString("utf8")'` (v22).
-}

import Bytes.Encode as Encode
import Codec.Utf8 as Utf8
import Expect
import Test exposing (Test)


codePoints : List Int -> List Int
codePoints bytes =
    Encode.sequence (List.map Encode.unsignedInt8 bytes)
        |> Encode.encode
        |> Utf8.decodeLossy
        |> String.toList
        |> List.map Char.toCode


case_ : String -> List Int -> List Int -> Test
case_ name bytes expected =
    Test.test name <| \_ -> codePoints bytes |> Expect.equal expected


suite : Test
suite =
    Test.describe "Codec.Utf8"
        [ case_ "ascii" [ 0x61, 0x62, 0x63 ] [ 97, 98, 99 ]
        , case_ "multi-byte" [ 0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80 ] [ 233, 8364, 128512 ]
        , case_ "truncated sequence" [ 0x61, 0xE2, 0x82 ] [ 97, 65533 ]
        , case_ "stray continuation" [ 0x80, 0x61 ] [ 65533, 97 ]
        , case_ "overlong form" [ 0xC0, 0xAF, 0x61 ] [ 65533, 65533, 97 ]
        , case_ "surrogate" [ 0xED, 0xA0, 0x80, 0x61 ] [ 65533, 65533, 65533, 97 ]
        , case_ "bad second byte" [ 0xE2, 0x41, 0x42 ] [ 65533, 65, 66 ]
        , case_ "above U+10FFFF" [ 0xF4, 0x90, 0x80, 0x80 ] [ 65533, 65533, 65533, 65533 ]
        , case_ "0xF5 lead" [ 0xF5, 0x61 ] [ 65533, 97 ]
        , Test.test "encode then decode" <|
            \_ -> Utf8.decode (Utf8.encode "héllo €") |> Expect.equal "héllo €"
        ]
