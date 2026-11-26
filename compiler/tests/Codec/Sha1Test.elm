module Codec.Sha1Test exposing (suite)

{-| `Codec.Sha1.hex` against the FIPS 180 examples and messages whose lengths sit around the
padding boundaries (55/56 and 63/64/65 bytes leave no room, exactly room, or a whole extra
block for the length). Expected digests are from `sha1sum` / Python's `hashlib`.
-}

import Bytes exposing (Bytes)
import Bytes.Encode as Encode
import Codec.Sha1 as Sha1
import Expect
import Test exposing (Test)


ascii : String -> Bytes
ascii s =
    Encode.encode (Encode.string s)


{-| The bytes 0, 1, 2, … n - 1.
-}
counting : Int -> Bytes
counting n =
    Encode.encode (Encode.sequence (List.map Encode.unsignedInt8 (List.range 0 (n - 1))))


suite : Test
suite =
    Test.describe "Codec.Sha1"
        [ Test.test "empty message" <|
            \_ -> Sha1.hex (ascii "") |> Expect.equal "da39a3ee5e6b4b0d3255bfef95601890afd80709"
        , Test.test "abc" <|
            \_ -> Sha1.hex (ascii "abc") |> Expect.equal "a9993e364706816aba3e25717850c26c9cd0d89d"
        , Test.test "448-bit message" <|
            \_ ->
                Sha1.hex (ascii "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                    |> Expect.equal "84983e441c3bd26ebaae4aa1f95129e5e54670f1"
        , Test.test "one million a" <|
            \_ ->
                Sha1.hex (ascii (String.repeat 1000000 "a"))
                    |> Expect.equal "34aa973cd4c4daa4f61eeb2bdbad27316534016f"
        , Test.test "lengths around the padding boundary" <|
            \_ ->
                List.map (\n -> Sha1.hex (counting n)) [ 55, 56, 63, 64, 65, 119, 128 ]
                    |> Expect.equal
                        [ "8ae2d46729cfe68ff927af5eec9c7d1b66d65ac2"
                        , "636e2ec698dac903498e648bd2f3af641d3c88cb"
                        , "6d942da0c4392b123528f2905c713a3ce28364bd"
                        , "c6138d514ffa2135bfce0ed0b8fac65669917ec7"
                        , "69bd728ad6e13cd76ff19751fde427b00e395746"
                        , "41c89d06001bab4ab78736b44efe7ce18ce6ae08"
                        , "e6434bc401f98603d7eda504790c98c67385d535"
                        ]
        ]
