module Utils.VarintCodecTest exposing (suite)

{-| Cache-serialization plan S10: LEB128 `uintV` / zigzag `sintV` and the
varint region codec round-trip, and small values stay small.
-}

import Bytes
import Bytes.Decode
import Bytes.Encode
import Compiler.Reporting.Annotation as A
import Expect
import Fuzz
import Test exposing (Test)
import Utils.Bytes.Decode as BD
import Utils.Bytes.Encode as BE


roundTripU : Int -> Maybe Int
roundTripU n =
    Bytes.Decode.decode BD.uintV (Bytes.Encode.encode (BE.uintV n))


roundTripS : Int -> Maybe Int
roundTripS n =
    Bytes.Decode.decode BD.sintV (Bytes.Encode.encode (BE.sintV n))


widthU : Int -> Int
widthU n =
    Bytes.width (Bytes.Encode.encode (BE.uintV n))


suite : Test
suite =
    Test.describe "varint codecs (cache-serialization S10)"
        [ Test.test "uintV boundaries round-trip" <|
            \_ ->
                let
                    ns =
                        [ 0, 1, 127, 128, 255, 16383, 16384, 2097151, 2097152, 268435455, 268435456, 4294967295 ]
                in
                Expect.equal (List.map Just ns) (List.map roundTripU ns)
        , Test.test "uintV widths" <|
            \_ -> Expect.equal [ 1, 1, 2, 2, 3, 5 ] (List.map widthU [ 0, 127, 128, 16383, 16384, 4294967295 ])
        , Test.fuzz (Fuzz.intRange 0 4294967295) "uintV fuzz" <|
            \n -> Expect.equal (Just n) (roundTripU n)
        , Test.fuzz (Fuzz.intRange -2147483648 2147483647) "sintV fuzz" <|
            \n -> Expect.equal (Just n) (roundTripS n)
        , Test.test "sintV small negatives are one byte" <|
            \_ -> Expect.equal 1 (Bytes.width (Bytes.Encode.encode (BE.sintV -1)))
        , Test.test "a 6-byte uintV fails" <|
            \_ ->
                Expect.equal Nothing
                    (Bytes.Decode.decode BD.uintV
                        (Bytes.Encode.encode (Bytes.Encode.sequence (List.repeat 5 (Bytes.Encode.unsignedInt8 0xFF) ++ [ Bytes.Encode.unsignedInt8 1 ])))
                    )
        , Test.test "int64 round-trips exactly at the JS-exact extremes and the 2^32 word edges" <|
            \_ ->
                let
                    ns =
                        [ 0, 1, -1, 4294967295, 4294967296, -4294967296, -4294967297, 2147483647, -2147483648, 9007199254740991, -9007199254740991 ]
                in
                Expect.equal (List.map Just ns)
                    (List.map (\n -> Bytes.Decode.decode BD.int64 (Bytes.Encode.encode (BE.int64 n))) ns)
        , Test.fuzz (Fuzz.intRange -9007199254740991 9007199254740991) "int64 fuzz (JS-exact range)" <|
            \n -> Expect.equal (Just n) (Bytes.Decode.decode BD.int64 (Bytes.Encode.encode (BE.int64 n)))
        , Test.test "int64 is 8 bytes" <|
            \_ -> Expect.equal 8 (Bytes.width (Bytes.Encode.encode (BE.int64 -5)))
        , Test.fuzz
            (Fuzz.map4 (\a b c d -> A.Region (A.Position a b) (A.Position c d))
                (Fuzz.intRange 0 100000)
                (Fuzz.intRange 0 5000)
                (Fuzz.intRange 0 100000)
                (Fuzz.intRange 0 5000)
            )
            "regionEncoderV round-trips (including end row < start row)"
          <|
            \r -> Expect.equal (Just r) (Bytes.Decode.decode A.regionDecoderV (Bytes.Encode.encode (A.regionEncoderV r)))
        ]
