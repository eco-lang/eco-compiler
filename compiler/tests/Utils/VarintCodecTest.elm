module Utils.VarintCodecTest exposing (suite)

{-| Checks that the compact integer codecs of `Utils.Bytes.Encode` and
`Utils.Bytes.Decode` read back exactly what they write, and that the
variable-width ones keep small numbers small. A codec that does not read back
what it wrote corrupts whatever is stored with it.

Three integer codecs are tested. `uintV` writes a non-negative Int as a
_varint_: seven bits per byte, low bits first, with the top bit of a byte set
when another byte follows. `sintV` writes a possibly negative Int by first
mapping it to a non-negative one by _zigzag_ (0, -1, 1, -2, ... become 0, 1, 2,
3, ...) and then writing that with `uintV`, so a number of small magnitude is
short whatever its sign. `int64` writes any Int in a fixed eight bytes. A fourth
pair, `regionEncoderV` and `regionDecoderV` of `Compiler.Reporting.Annotation`,
writes a source region as four of these varints: the start row, start column
and end column with `uintV`, and the end row as a `sintV` difference from the
start row.

There is no fixture: the tests use literal values and fuzzed ranges. They
establish:

  - `uintV` round-trips 0, 1, 255, 2^32 - 1, and 2^k - 1 and 2^k for k = 7,
    14, 21 and 28, where its width grows by a byte.
  - `uintV` writes 0 and 127 in one byte, 128 and 16383 in two, 16384 in three
    and 2^32 - 1 in five.
  - `uintV` round-trips fuzzed values from 0 to 2^32 - 1.
  - `sintV` round-trips fuzzed values from -2^31 to 2^31 - 1.
  - `sintV` writes -1 in one byte.
  - `uintV` decoding fails on five bytes of 0xFF followed by 0x01. The decoder
    rejects the fifth byte, because its continuation bit is still set.
  - `int64` round-trips 0, 1, -1, the signed 32-bit extremes 2^31 - 1 and
    -2^31, 2^32 - 1 and 2^32, -2^32 and -2^32 - 1, and 2^53 - 1 and
    -(2^53 - 1), the ends of the range in which a JavaScript number represents
    every integer exactly.
  - `int64` round-trips fuzzed values from -(2^53 - 1) to 2^53 - 1.
  - `int64` writes -5 in eight bytes.
  - `regionDecoderV` reads back what `regionEncoderV` writes for fuzzed regions
    with rows from 0 to 100000 and columns from 0 to 5000, all four chosen
    independently, so the end row may come before the start row.

The `uintV` tests, both literal and fuzzed, and the `sintV` fuzz range go
beyond the preconditions that `Utils.Bytes.Encode` states for those encoders,
`0 <= n < 2^31` and `|n| < 2^30`.

Among what is not tested: the bytes themselves, which no test compares with
expected values; `uintV` on values above 2^32 - 1 or below 0; the width of
`sintV` on any value but -1; and the fixed-width `regionEncoder`.

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


{-| Returns what `BD.uintV` reads back from the bytes `BE.uintV` writes for
`n`, or `Nothing` if decoding fails.
-}
roundTripU : Int -> Maybe Int
roundTripU n =
    Bytes.Decode.decode BD.uintV (Bytes.Encode.encode (BE.uintV n))


{-| Returns what `BD.sintV` reads back from the bytes `BE.sintV` writes for
`n`, or `Nothing` if decoding fails.
-}
roundTripS : Int -> Maybe Int
roundTripS n =
    Bytes.Decode.decode BD.sintV (Bytes.Encode.encode (BE.sintV n))


{-| Returns the number of bytes `BE.uintV` writes for `n`.
-}
widthU : Int -> Int
widthU n =
    Bytes.width (Bytes.Encode.encode (BE.uintV n))


{-| The `uintV`, `sintV`, `int64` and region codec tests listed in the module
docstring.
-}
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
